import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureError: Error, CustomStringConvertible {
    case noDisplay
    case screenRecordingDenied
    case noAudioSource

    var description: String {
        switch self {
        case .noDisplay:
            return "找不到可采集的显示器"
        case .screenRecordingDenied:
            return "没有屏幕录制权限"
        case .noAudioSource:
            return "系统声音和麦克风都没开，没得可听"
        }
    }
}

/// 两路音频采集：系统声音（对方）+ 麦克风（我）。
///
/// 用一个 `SCStream` 同时开两路，比「AVAudioEngine 抓麦克风 + Core Audio Tap 抓
/// 系统」省事得多，而且两路分开送来 —— **说话人标注是白送的**，不用做分离。
///
/// 权限两样：
///  - 屏幕录制：SCK 整体的门槛，没它麦克风那路也起不来（授权后要重启 app 才生效）
///  - 麦克风：只收系统声音的话可以没有
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {

    /// 每收到一帧回调一次。**在对应那路的采集队列上**，别在这里碰界面。
    private let onBuffer: (Speaker, AVAudioPCMBuffer) -> Void
    /// 流被系统掐了（拔耳机、权限被撤……）
    private let onInterrupted: (Error) -> Void

    private var stream: SCStream?
    /// 每路一条串行队列：`Transcriber.feed` 里的重采样器不是线程安全的，
    /// 同一条路的所有帧必须落在同一条队列上
    private let micQueue = DispatchQueue(label: "com.smarty.earshot.mic")
    private let systemQueue = DispatchQueue(label: "com.smarty.earshot.system")

    init(onBuffer: @escaping (Speaker, AVAudioPCMBuffer) -> Void,
         onInterrupted: @escaping (Error) -> Void) {
        self.onBuffer = onBuffer
        self.onInterrupted = onInterrupted
    }

    // MARK: - 权限

    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    static var micGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// 弹「屏幕录制」授权（首次会跳系统设置；授权后要重启 app 才生效）
    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    /// 弹麦克风授权；已决定过就直接返回结果，不弹第二次
    static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: - 起停

    func start(captureSystem: Bool, captureMic: Bool) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.screenRecordingDenied }
        guard captureSystem || captureMic else { throw CaptureError.noAudioSource }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = captureSystem
        cfg.excludesCurrentProcessAudio = true    // 自己的提示音别录进去
        cfg.sampleRate = 16000                    // 识别器要的就是 16k，先在这里降，后面少转一道
        cfg.channelCount = 1
        cfg.captureMicrophone = captureMic
        // 只要音频。画面没有「关掉」的开关，就把尺寸给到最小、帧率压到 1fps，
        // 代价小到可以忽略
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.showsCursor = false
        cfg.queueDepth = 3

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        if captureSystem {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: systemQueue)
        }
        if captureMic {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        }
        try await stream.startCapture()
        self.stream = stream
        AppDebug.log("[capture] 已启动（系统 \(captureSystem ? "✓" : "✗")，麦克风 \(captureMic ? "✓" : "✗")）")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            AppDebug.log("[capture] 停止时报错：\(error.localizedDescription)")
        }
        AppDebug.log("[capture] 已停止")
    }

    // MARK: - SCStream 回调（都在采集队列上）

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        let speaker: Speaker
        switch type {
        case .microphone: speaker = .me
        case .audio:      speaker = .other
        default:          return          // 画面帧，直接丢
        }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        onBuffer(speaker, buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        AppDebug.log("[capture] 流被中断：\(error.localizedDescription)")
        onInterrupted(error)
    }

    /// CMSampleBuffer → AVAudioPCMBuffer。拷一份再走 —— SCK 的 sample buffer
    /// 出了这个回调就可能被回收，而我们要把它带到别的队列上去重采样。
    ///
    /// 不用 `CMSampleBufferCopyPCMDataIntoAudioBufferList`：SCK 的音频帧在它
    /// 上面必报 -12731（RequiredParameterMissing），一帧都取不出来。改成
    /// 「量大小 → 拿 AudioBufferList（连着 block buffer 一起保着）→ 自己按块
    /// memcpy」，这是取 sample buffer 里 PCM 数据的正路。
    ///
    /// 非 private 是给 `--pcmtest` 自检用（合成 SCK 形状的帧跑一遍）。
    static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard CMSampleBufferDataIsReady(sb),
              let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }

        // 先空手问一句「要多大」：AudioBufferList 的实际块数由声道布局决定
        var needed = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &needed,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil)
        guard status == noErr, needed > 0 else {
            AppDebug.log("[capture] 量 AudioBufferList 大小失败：OSStatus \(status)")
            return nil
        }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: needed,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &block)
        guard status == noErr else {
            AppDebug.log("[capture] 取 AudioBufferList 失败：OSStatus \(status)")
            return nil
        }

        // list 里各块的 mData 指的就是 block 的内存 —— 拷贝全程都得保着它，
        // 少了 withExtendedLifetime，ARC 提前放掉 block 就是一个悬垂指针
        return withExtendedLifetime(block) { () -> AVAudioPCMBuffer? in
            let src = UnsafeMutableAudioBufferListPointer(list)
            let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
            guard src.count == dst.count, src.count > 0 else {
                AppDebug.log("[capture] 声道布局对不上：源 \(src.count) 块 / 目标 \(dst.count) 块")
                return nil
            }
            // 三个坑连在一起，都是自检（--pcmtest）一个一个踩出来的：
            //  1. 目标 ABL 的 mDataByteSize 是跟着 frameLength 报的 —— 不先置
            //     frameLength，两个都是 0，min() 算出「拷 0 字节」，白拷
            //  2. 所以先把 frameLength 置上
            //  3. 字节数照格式自己算（每块 = 每帧字节数 × 帧数，交织/非交织都成立），
            //     不赌它报得对不对
            out.frameLength = AVAudioFrameCount(frames)
            let perBuffer = Int(format.streamDescription.pointee.mBytesPerFrame) * frames
            for i in 0..<src.count {
                guard let s = src[i].mData, let d = dst[i].mData else { return nil }
                let n = min(Int(src[i].mDataByteSize), perBuffer)
                memcpy(d, s, n)
                dst[i].mDataByteSize = UInt32(n)
            }
            return out
        }
    }
}

// MARK: - 采集自检

/// 采集 + 识别联跑：`EarShot --capture [秒数] [--verbose]`
///
/// 这个必须要屏幕录制权限（+麦克风），所以**不代表能免权限跑**；没授权时
/// 就把现状和怎么办打出来，不弹窗、不假装成功。
enum CaptureSelfCheck {

    static func run(seconds: Double, verbose: Bool) async -> Int32 {
        print("屏幕录制：" + (AudioCapture.screenRecordingGranted ? "✓ 已授权" : "✗ 未授权（采集合流的前置；授权后要重启 app）"))
        print("麦克风　：" + (AudioCapture.micGranted ? "✓ 已授权" : "✗ 未授权（只收系统声音的话可以不授）"))
        guard AudioCapture.screenRecordingGranted else {
            print("""

            没有屏幕录制权限，采不起来。两种给法：
              · 开监听时在面板里点「去授权」，或者
              · 系统设置 → 隐私与安全性 → 屏幕录制 → 打开 EarShot（再重启 app）
            """)
            return 2
        }

        let locale = Locale(identifier: "zh-CN")
        let mic: Transcriber?
        let sys: Transcriber?
        do {
            if AudioCapture.micGranted {
                mic = try await Transcriber.start(speaker: .me, locale: locale) { ev in
                    report(.me, ev, verbose: verbose)
                }
            } else {
                print("（麦克风没授权，只收系统声音）")
                mic = nil
            }
            sys = try await Transcriber.start(speaker: .other, locale: locale) { ev in
                report(.other, ev, verbose: verbose)
            }
        } catch {
            print("起识别器失败：\(error)")
            return 1
        }

        let capture = AudioCapture(onBuffer: { speaker, buffer in
            switch speaker {
            case .me:    mic?.feed(buffer)
            case .other: sys?.feed(buffer)
            }
        }, onInterrupted: { _ in })

        do {
            try await capture.start(captureSystem: true, captureMic: mic != nil)
        } catch {
            print("起采集失败：\(error)")
            return 1
        }

        print("=== 听 \(Int(seconds)) 秒，现在说话（放个有中文人声的视频也行）===")
        fflush(stdout)
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))

        await capture.stop()
        await mic?.stop()
        await sys?.stop()
        print("=== 采集已停 ===")
        return 0
    }

    /// 结果回调在识别器那边任意线程上，短句直接打（丢了不心疼）
    private static func report(_ speaker: Speaker, _ ev: TranscribeEvent, verbose: Bool) {
        switch ev {
        case .volatile(let t) where verbose:
            print("\r[\(speaker.label)] … \(t)                    ", terminator: "")
        case .volatile:
            break
        case .final(let t):
            print("\r[\(speaker.label)] \(t)                    ")
        }
        fflush(stdout)
    }
}

// MARK: - PCM 转换自检

/// CMSampleBuffer → AVAudioPCMBuffer 转换自检：`EarShot --pcmtest`
///
/// 合成一个「形状和 ScreenCaptureKit 送出来的一样」的音频帧（16k / Int16 /
/// 数据装在 block buffer 里），走一遍真正在用的转换函数，逐字节核对。
///
/// 为什么要有它：这段转换是采集链路上唯一不能靠音频文件自检覆盖的一段
/// （`--transcribe` 绕过了它），只能等真人授权、说话、再看日志 ——
/// -12731 那一轮就是这么白白烧掉一次授权的。
enum PcmSelfCheck {

    static func run() -> Int32 {
        var failed = 0
        for (label, channels) in [("单声道（采集就是这个形状）", 1), ("立体声（兜底形状）", 2)] {
            if !check(channels: channels, label: label) { failed += 1 }
        }
        print(failed == 0 ? "PCM 转换自检全部通过" : "PCM 转换自检有 \(failed) 项没过")
        return failed == 0 ? 0 : 1
    }

    /// 造帧 → 转换 → 核对帧数、格式、字节
    private static func check(channels: Int, label: String) -> Bool {
        let frames = 1600                       // 100ms @16k
        let bytesPerFrame = 2 * channels        // Int16 交织
        let bytes = frames * bytesPerFrame

        // 内容乱但确定，必须原样回来
        var src = [Int16](repeating: 0, count: frames * channels)
        for i in src.indices { src[i] = Int16(truncatingIfNeeded: i &* 7919 % 8192 - 4096) }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0)

        guard let sb = makeSampleBuffer(asbd: &asbd, byteCount: bytes, fill: { ptr in
            src.withUnsafeBytes { _ = memcpy(ptr, $0.baseAddress!, bytes) }
        }) else {
            print("✗ \(label)：造不出测试帧")
            return false
        }

        guard let out = AudioCapture.pcmBuffer(from: sb) else {
            print("✗ \(label)：转换返回 nil")
            return false
        }
        guard Int(out.frameLength) == frames,
              out.format.sampleRate == 16000,
              out.format.channelCount == AVAudioChannelCount(channels) else {
            print("✗ \(label)：帧数/格式不对 —— \(out.frameLength) 帧 \(out.format)")
            return false
        }
        guard let p = out.int16ChannelData?[0] else {
            print("✗ \(label)：转出来的 buffer 拿不到 Int16 指针")
            return false
        }
        if memcmp(p, src, bytes) != 0 {
            let bad = (0..<src.count).first { p[$0] != src[$0] } ?? -1
            print("✗ \(label)：PCM 不一致，第一处 #\(bad)"
                  + " 期望 \(bad >= 0 ? src[bad] : -1) / 实际 \(bad >= 0 ? p[bad] : -1)")
            print("   实际前 8：" + (0..<8).map { "\(p[$0])" }.joined(separator: ","))
            print("   期望前 8：" + (0..<8).map { "\(src[$0])" }.joined(separator: ","))
            dumpSourceABL(sb)
            return false
        }

        // 记账：线上那个 -12731 是老 API 的锅。合成帧上它复不复现都打印出来，
        // 复现了说明这块合成帧是个忠实的替身，不复现也不是问题（新路不靠它）
        if let probe = AVAudioPCMBuffer(pcmFormat: out.format,
                                        frameCapacity: AVAudioFrameCount(frames)) {
            let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sb, at: 0, frameCount: Int32(frames), into: probe.mutableAudioBufferList)
            print("  （对照）老 API CopyPCMDataIntoAudioBufferList → OSStatus \(st)")
        }
        print("✓ \(label)：\(frames) 帧 / \(bytes) 字节原样转换")
        return true
    }

    /// 诊断用：同样「量大小 → 取 ABL」，直接看源帧里到底有没有数据
    private static func dumpSourceABL(_ sb: CMSampleBuffer) {
        var need = 0
        _ = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &need,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: max(need, 16), alignment: 16)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blk: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil,
            bufferListOut: list, bufferListSize: max(need, 16),
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blk)
        let abl = UnsafeMutableAudioBufferListPointer(list)
        print("  [诊断] need=\(need) OSStatus=\(st) 块数=\(abl.count)")
        withExtendedLifetime(blk) {
            for i in 0..<abl.count {
                if let m = abl[i].mData {
                    let a = m.load(as: Int16.self)
                    let b = m.load(fromByteOffset: 2, as: Int16.self)
                    print("  [诊断] 源块\(i)：\(abl[i].mDataByteSize) 字节，头两个 Int16 = \(a), \(b)")
                } else {
                    print("  [诊断] 源块\(i)：mData 空")
                }
            }
        }
    }

    /// 按 CoreMedia 的正规路子造一帧音频：block buffer 装数据 + 音频格式说明
    private static func makeSampleBuffer(asbd: inout AudioStreamBasicDescription,
                                         byteCount: Int,
                                         fill: (UnsafeMutableRawPointer) -> Void) -> CMSampleBuffer? {
        var fd: CMAudioFormatDescription?
        let stFd = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                                  layoutSize: 0, layout: nil,
                                                  magicCookieSize: 0, magicCookie: nil,
                                                  extensions: nil, formatDescriptionOut: &fd)
        guard stFd == noErr, let fd else {
            print("  造帧失败：格式说明 OSStatus \(stFd)")
            return nil
        }

        var block: CMBlockBuffer?
        let stBlock = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                         memoryBlock: nil, blockLength: byteCount,
                                                         blockAllocator: kCFAllocatorDefault,
                                                         customBlockSource: nil,
                                                         offsetToData: 0, dataLength: byteCount,
                                                         flags: 0, blockBufferOut: &block)
        guard stBlock == noErr, let block else {
            print("  造帧失败：block buffer OSStatus \(stBlock)")
            return nil
        }

        // memoryBlock 给 nil 造出来的 buffer 是「待分配」的，先让它把内存要下来
        let stAssure = CMBlockBufferAssureBlockMemory(block)
        guard stAssure == noErr else {
            print("  造帧失败：block buffer 申请内存 OSStatus \(stAssure)")
            return nil
        }

        var dataPtr: UnsafeMutablePointer<CChar>?
        let stPtr = CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                                totalLengthOut: nil, dataPointerOut: &dataPtr)
        guard stPtr == noErr, let dataPtr else {
            print("  造帧失败：取数据指针 OSStatus \(stPtr)")
            return nil
        }
        fill(UnsafeMutableRawPointer(dataPtr))

        var sb: CMSampleBuffer?
        let stSb = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                             dataBuffer: block, formatDescription: fd,
                                             sampleCount: byteCount / Int(asbd.mBytesPerFrame),
                                             sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                             sampleSizeEntryCount: 0, sampleSizeArray: nil,
                                             sampleBufferOut: &sb)
        guard stSb == noErr, let sb else {
            print("  造帧失败：sample buffer OSStatus \(stSb)")
            return nil
        }
        return sb
    }
}
