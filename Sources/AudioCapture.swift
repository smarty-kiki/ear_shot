import AppKit
import AVFoundation
import CoreAudio
import Foundation

enum CaptureError: Error, CustomStringConvertible {
    case noAudioSource
    case systemAudioFailed(String)
    case micFailed(String)

    var description: String {
        switch self {
        case .noAudioSource:
            return "系统声音和麦克风都没开，没得可听"
        case .systemAudioFailed(let d):
            return "系统声音起不来：\(d)"
        case .micFailed(let d):
            return "麦克风起不来：\(d)"
        }
    }
}

/// 两路音频采集：系统声音（对方）+ 麦克风（我）。
///
/// 系统声音走 Core Audio 的 process tap，麦克风走 AVAudioEngine —— 两路天然
/// 分开送来，**说话人标注是白送的**，不用做分离。
///
/// 为什么换掉了 SCK（原来两路都是它）：SCK 的流挂在显示器上，锁屏必断
/// （-3815），开关窗口、插拔显示器也都在它的管辖范围里。tap 贴在音频层：
/// 锁屏、开窗关窗、插拔显示器、换输出设备都不打断 —— `--taptest` 探针实测过
/// （锁屏期间秒秒有帧、零中断），下面建 tap 的这段代码就是从那支探针搬来的。
///
/// 韧性（点名的场景都要活过）：
///  - 锁屏 / 开窗关窗 / 插拔显示器 / 换输出设备：tap 够不着这些，天然免疫
///  - 中途换麦克风（内置 ↔ 耳机）：系统会停掉引擎并发配置变更通知，收到就
///    重挂重开（`restartMicEngine`），拔掉再插回来也会自己接上
///
/// 权限：
///  - 系统声音：没有预检接口，第一次建 tap 时系统才弹「录制此电脑的音频」。
///    拒绝不报错 —— tap 建得起来但一直是零帧，靠看门狗认出来（见 `watchdogTick`）
///  - 麦克风：没有也能跑，只是听不见「我」
final class AudioCapture {

    /// 每收到一帧回调一次。**在对应那路的采集队列上**，别在这里碰界面。
    private let onBuffer: (Speaker, AVAudioPCMBuffer) -> Void
    /// 采集被系统掐了。起不来的错在 start 里抛，这里管跑起来之后翻脸的
    private let onInterrupted: (Error) -> Void
    /// 系统声音「有没有数据」的状态翻转（true = 来数据了）。不是故障提示 ——
    /// 采不采集由 Listener 定，这里只报事实：跑了一段还一帧没有（多半是权限
    /// 没给）报 false；后来开始有帧了报 true
    private let onSystemAudioState: (Bool) -> Void

    /// 每路一条串行队列：`Transcriber.feed` 里的重采样器不是线程安全的，
    /// 同一条路的所有帧必须落在同一条队列上（换设备重挂引擎后还是同一条，
    /// 所以「录到一半换麦克风」不会把识别器弄乱）
    private let micQueue = DispatchQueue(label: "com.smarty.earshot.mic")
    private let systemQueue = DispatchQueue(label: "com.smarty.earshot.system")
    /// 麦克风引擎的起停/重挂都在它上面串行做（配置变更通知从任意线程来）
    private let engineQueue = DispatchQueue(label: "com.smarty.earshot.engine")
    private let watchdogQueue = DispatchQueue(label: "com.smarty.earshot.watchdog")

    // 系统声音：tap + 私有聚合设备
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var systemEnabled = false
    private var tapStartedAt: Date?
    private let systemSignal = Signal()
    private var systemMissingReported = false
    private var watchdog: DispatchSourceTimer?

    // 麦克风：AVAudioEngine
    private var engine: AVAudioEngine?
    private var micTapInstalled = false
    private var micEnabled = false
    private var micRestartAttempts = 0
    private var configObserver: NSObjectProtocol?

    init(onBuffer: @escaping (Speaker, AVAudioPCMBuffer) -> Void,
         onInterrupted: @escaping (Error) -> Void,
         onSystemAudioState: @escaping (Bool) -> Void) {
        self.onBuffer = onBuffer
        self.onInterrupted = onInterrupted
        self.onSystemAudioState = onSystemAudioState
    }

    // MARK: - 权限

    static var micGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// 弹麦克风授权；已决定过就直接返回结果，不弹第二次
    static func requestMic() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// 打开系统设置里能开关「录制电脑音频」的那一页。
    ///
    /// 系统声音没有 preflight / request 接口：权限只在第一次建 tap 时弹，
    /// 错过了就只剩这一页能改。条目列在「屏幕与系统音频录制」里（macOS 15
    /// 起改的名），跳转锚点还是老的 Privacy_ScreenCapture。
    static func openAudioCaptureSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 起停

    func start(captureSystem: Bool, captureMic: Bool) async throws {
        guard captureSystem || captureMic else { throw CaptureError.noAudioSource }

        systemEnabled = captureSystem
        if captureSystem { try startSystemTap() }

        if captureMic {
            do {
                try startMicEngine()
                micEnabled = true
            } catch {
                // 麦克风起不来不拖垮系统声音：降级成单路（和「麦克风没授权」
                // 一个待遇），日志里留痕；两路都指望它时才真起不来
                if !captureSystem { throw error }
                AppDebug.log("[capture] 麦克风起不来，降级只收系统声音：\(error)")
            }
        }
        AppDebug.log("[capture] 已启动（系统 \(captureSystem ? "✓" : "✗")，麦克风 \(micEnabled ? "✓" : "✗")）")
    }

    func stop() async {
        systemEnabled = false
        micEnabled = false
        watchdog?.cancel()
        watchdog = nil
        systemMissingReported = false

        // 系统声音：拆除顺序和建的时候反过来（聚合设备引用着 tap）。
        // 每一步都认「建成了没有」的账，半路 start 失败的状态也拆得干净
        if let proc = procID {
            AudioDeviceStop(aggID, proc)
            AudioDeviceDestroyIOProcID(aggID, proc)
            procID = nil
        }
        if aggID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggID)
            aggID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        // 麦克风
        if let obs = configObserver {
            NotificationCenter.default.removeObserver(obs)
            configObserver = nil
        }
        if let e = engine {
            e.stop()
            if micTapInstalled {
                e.inputNode.removeTap(onBus: 0)
                micTapInstalled = false
            }
            engine = nil
        }
        AppDebug.log("[capture] 已停止")
    }

    // MARK: - 系统声音：process tap + 私有聚合设备（--taptest 探针同源的代码）

    private func startSystemTap() throws {
        var exclude: [AudioObjectID] = []
        if let own = Self.ownProcessObject() {
            exclude = [own]      // 自己的提示音别录进去
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.name = "耳录"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted     // 采归采，别把用户的系统声音掐了

        var tap = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else {
            throw CaptureError.systemAudioFailed("建 tap 失败（OSStatus \(st)）")
        }
        tapID = tap

        // tap 出来的格式：探针实测 48k · 2 声道 · Float32 交织，但不写死，按它报的来
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        st = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd)
        guard st == noErr, asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              let format = AVAudioFormat(streamDescription: &asbd) else {
            throw CaptureError.systemAudioFailed("tap 格式拿不到或不是 Float32（OSStatus \(st)）")
        }

        // 私有聚合设备把 tap 接出来（不挂任何真实设备，只当 tap 的取帧口）
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "耳录",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &agg)
        guard st == noErr else {
            throw CaptureError.systemAudioFailed("建聚合设备失败（OSStatus \(st)）")
        }
        aggID = agg

        // IO 回调（实时线程）：只做两件事 —— 记下「有帧来了」，把帧拷一份丢到
        // systemQueue 上喂识别器。重采样那种耗时活不在这里做
        var proc: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&proc, aggID, nil) { [weak self] _, inputData, _, _, _ in
            guard let self else { return }
            guard let buffer = Self.pcmBuffer(fromIOProc: inputData, format: format),
                  buffer.frameLength > 0 else { return }
            self.systemSignal.note()
            self.systemQueue.async { self.onBuffer(.other, buffer) }
        }
        guard st == noErr, let proc else {
            throw CaptureError.systemAudioFailed("挂 IO 回调失败（OSStatus \(st)）")
        }
        procID = proc

        st = AudioDeviceStart(aggID, proc)
        guard st == noErr else {
            throw CaptureError.systemAudioFailed("聚合设备起不来（OSStatus \(st)）")
        }

        // 看门狗：「建了 tap 却一帧都没来」= 多半没给权限。从这一刻起计时
        tapStartedAt = Date()
        systemMissingReported = false
        systemSignal.clear()
        startWatchdog()
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: watchdogQueue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = t
        t.resume()
    }

    /// 每秒看一眼系统声音有没有来过帧。
    ///
    /// 「拒绝了权限」在 tap 这条路上不报错：tap 建得出来、回调也在跑，只是
    /// 一直是零帧 —— 只能靠「一帧都没来过」认出来。8 秒是个折中：权限窗上
    /// 犹豫一会儿不会误报，真没给也不用干等。误报也不伤：来数据了会立刻
    /// 翻回 true（权限窗上现点的「允许」也算），提示自己就收掉了
    private func watchdogTick() {
        guard systemEnabled, let startedAt = tapStartedAt else { return }
        if systemSignal.hasData {
            if systemMissingReported {
                systemMissingReported = false
                AppDebug.log("[capture] 系统声音来数据了")
                onSystemAudioState(true)
            }
            return
        }
        guard !systemMissingReported, Date().timeIntervalSince(startedAt) >= 8 else { return }
        systemMissingReported = true
        AppDebug.log("[capture] tap 跑了 8 秒一帧都没来 —— 多半是「录制电脑音频」权限没给")
        onSystemAudioState(false)
    }

    // MARK: - 格式转换

    /// IO 回调的 AudioBufferList → AVAudioPCMBuffer。**拷一份再走** ——
    /// 回调的 buffer 出了这次调用就还给系统了，而帧要带去别的队列上重采样。
    ///
    /// 非 private 是给 `--pcmtest` 自检用：造一块同形状的 ABL 跑一遍。
    static func pcmBuffer(fromIOProc abl: UnsafePointer<AudioBufferList>,
                          format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        guard src.count > 0 else { return nil }

        // 帧数 = 每块字节数 ÷ 每帧字节数。交织时一块装全部声道；非交织时
        // mBytesPerFrame 报的是单声道一帧的字节数，除出来的同样是帧数
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let frames = Int(src[0].mDataByteSize) / bytesPerFrame
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }

        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        guard src.count == dst.count else {
            AppDebug.log("[capture] 声道布局对不上：源 \(src.count) 块 / 目标 \(dst.count) 块")
            return nil
        }
        // 先置 frameLength：不置的话目标 ABL 的 mDataByteSize 全是 0（--pcmtest
        // 踩过这个坑），字节数照格式自己算，不赌它报得对不对
        out.frameLength = AVAudioFrameCount(frames)
        let perBuffer = bytesPerFrame * frames
        for i in 0..<src.count {
            guard let s = src[i].mData, let d = dst[i].mData else { return nil }
            let n = min(Int(src[i].mDataByteSize), perBuffer)
            memcpy(d, s, n)
            dst[i].mDataByteSize = UInt32(n)
        }
        return out
    }

    /// 拷一份 AVAudioPCMBuffer。引擎 tap 给的 buffer 出了回调就作废（会被
    /// 复用），帧要带去别的队列上重采样 —— 必须自己拷
    private static func copyOf(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let out = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                         frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for i in 0..<src.count {
            guard let s = src[i].mData, let d = dst[i].mData else { return nil }
            let n = min(Int(src[i].mDataByteSize), Int(dst[i].mDataByteSize))
            memcpy(d, s, n)
            dst[i].mDataByteSize = UInt32(n)
        }
        return out
    }

    // MARK: - 麦克风：AVAudioEngine

    private func startMicEngine() throws {
        let e = AVAudioEngine()
        try attachMicTap(to: e)
        engine = e

        // 配置变更通知（object 钉死自己的引擎）：系统换默认输入设备（插拔耳机、
        // 设置里换麦克风）时引擎会被停掉并发这条 —— 重挂重开，这就是「录到一半
        // 换麦克风」能活下来的全部秘密。通知从任意线程来，统一收进 engineQueue
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: nil) { [weak self] _ in
                self?.engineQueue.async { self?.restartMicEngine() }
            }
    }

    /// 挂输入 tap 并启动引擎。格式按当前输入设备读 —— 换设备后格式可能变，
    /// 所以重挂时整个重来
    private func attachMicTap(to e: AVAudioEngine) throws {
        let input = e.inputNode
        let format = input.inputFormat(forBus: 0)
        // 没有可用输入设备时格式是 0，硬挂 tap 会直接崩 —— 先挡在这里
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureError.micFailed("没有可用的输入设备")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let copy = Self.copyOf(buffer) else { return }
            self.micQueue.async { self.onBuffer(.me, copy) }
        }
        micTapInstalled = true
        e.prepare()
        try e.start()
    }

    /// 配置变更后重挂重开。系统换输入设备时引擎被停掉，老 tap 连的还是老设备
    /// —— 把 tap 摘了，按新设备格式重挂、再开。
    ///
    /// 偶尔会撞上「新设备还没稳」（格式读到 0、或 start 抛错 —— 插拔耳机本身
    /// 就要几秒），那就隔 0.5 秒再试，十次为止；放弃也不中断监听 —— 麦克风
    /// 死了声纹和识别自己看得出来，系统声音那路不受影响
    private func restartMicEngine() {
        guard micEnabled, let e = engine else { return }
        e.stop()
        if micTapInstalled {
            e.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }
        do {
            try attachMicTap(to: e)
            micRestartAttempts = 0
            AppDebug.log("[capture] 换设备后麦克风已重挂：\(e.inputNode.inputFormat(forBus: 0))")
        } catch {
            micRestartAttempts += 1
            guard micRestartAttempts <= 10 else {
                AppDebug.log("[capture] 麦克风重挂失败太多次，这轮放弃：\(error)")
                return
            }
            AppDebug.log("[capture] 麦克风重挂没成（第 \(micRestartAttempts) 次）：\(error)，0.5 秒后再试")
            engineQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.restartMicEngine() }
        }
    }

    // MARK: - 小件

    /// 自己的 AudioObjectID，用来从 tap 里排除（PID → process object 是 Core Audio 的官方翻译）
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = getpid()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var proc = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &proc)
        return st == noErr && proc != kAudioObjectUnknown ? proc : nil
    }

    /// IO 回调（实时线程）写、看门狗（另一个队列）读 —— 一个小锁隔着
    private final class Signal {
        private let lock = NSLock()
        private var got = false
        func note() { lock.lock(); got = true; lock.unlock() }
        func clear() { lock.lock(); got = false; lock.unlock() }
        var hasData: Bool { lock.lock(); defer { lock.unlock() }; return got }
    }
}

// MARK: - 采集自检

/// 采集 + 识别联跑：`EarShot --capture [秒数] [--verbose]`
///
/// 要权限才听得到东西，所以**不代表能免权限跑**；现状和怎么办都打出来，
/// 不弹窗、不假装成功。注意系统声音那路从终端直跑测不到（TCC 把责任进程
/// 算在终端头上，终端没有音频采集权限说明键）—— 要验它得用真 app 试听。
enum CaptureSelfCheck {

    static func run(seconds: Double, verbose: Bool) async -> Int32 {
        print("麦克风　：" + (AudioCapture.micGranted ? "✓ 已授权" : "✗ 未授权（只收系统声音的话可以不授）"))
        print("系统声音：没有预检接口 —— 第一次建 tap 时才弹权限窗。"
              + "从终端直跑时系统声音收不到（TCC 把责任算在终端头上），要验它用 `make taptest`")

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
        }, onInterrupted: { _ in }, onSystemAudioState: { alive in
            print(alive
                  ? "（系统声音：来数据了）"
                  : "（系统声音：8 秒了还没帧 —— 没给权限，或者就是终端直跑，见上面那条）")
            fflush(stdout)
        })

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

/// AudioBufferList → AVAudioPCMBuffer 转换自检：`EarShot --pcmtest`
///
/// 造一块「形状和 Core Audio tap 送出来的一样」的 ABL（48k · 立体声 ·
/// Float32，交织 / 非交织各一块），走一遍真正在用的转换函数，逐字节核对。
///
/// 为什么要有它：这段转换是采集链路上唯一不能靠音频文件自检覆盖的一段
/// （`--transcribe` 绕过了它），只能等真人授权、说话、再看日志 ——
/// 上一代采集（SCK 那条路）就在这里白烧过一整轮授权。
enum PcmSelfCheck {

    static func run() -> Int32 {
        var failed = 0
        if !check(label: "交织（tap 就是这个形状）", interleaved: true) { failed += 1 }
        if !check(label: "非交织（兜底形状）", interleaved: false) { failed += 1 }
        print(failed == 0 ? "PCM 转换自检全部通过" : "PCM 转换自检有 \(failed) 项没过")
        return failed == 0 ? 0 : 1
    }

    /// 造源数据 → 包成 ABL → 过转换函数 → 核对帧数、格式、逐字节内容
    private static func check(label: String, interleaved: Bool) -> Bool {
        let sampleRate = 48000.0
        let channels = 2
        let frames = 4800                      // 100ms @48k
        let bufferCount = interleaved ? 1 : channels
        let floatsPerBuffer = frames * (interleaved ? channels : 1)
        let bytesPerFrame = interleaved ? 4 * channels : 4

        // 源数据：确定但看着乱，必须原样回来
        let srcs: [[Float]] = (0..<bufferCount).map { b in
            (0..<floatsPerBuffer).map { i in
                Float((b * 100_003 + i * 7919) % 8192 - 4096) / 4096
            }
        }

        // ABL 的 AudioBuffer 数组是变长的：多出来的槽位跟着第一个走，申请够
        // 字节数、把 count 置上，此后统一用 UnsafeMutableAudioBufferListPointer
        let listSize = MemoryLayout<AudioBufferList>.size
            + (bufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let rawList = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: 16)
        defer { rawList.deallocate() }
        let abl = UnsafeMutableAudioBufferListPointer(rawList.assumingMemoryBound(to: AudioBufferList.self))
        abl.count = bufferCount
        var keepAlive: [UnsafeMutableRawPointer] = []
        defer { keepAlive.forEach { $0.deallocate() } }
        for b in 0..<bufferCount {
            let data = UnsafeMutableRawPointer.allocate(byteCount: floatsPerBuffer * 4, alignment: 16)
            keepAlive.append(data)
            srcs[b].withUnsafeBytes { _ = memcpy(data, $0.baseAddress!, floatsPerBuffer * 4) }
            abl[b] = AudioBuffer(mNumberChannels: UInt32(interleaved ? channels : 1),
                                 mDataByteSize: UInt32(floatsPerBuffer * 4),
                                 mData: data)
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0)
        guard let format = AVAudioFormat(streamDescription: &asbd) else {
            print("✗ \(label)：格式搭不出来")
            return false
        }

        guard let out = AudioCapture.pcmBuffer(fromIOProc: UnsafePointer(abl.unsafeMutablePointer),
                                               format: format) else {
            print("✗ \(label)：转换返回 nil")
            return false
        }
        guard Int(out.frameLength) == frames,
              out.format.sampleRate == sampleRate,
              out.format.channelCount == AVAudioChannelCount(channels) else {
            print("✗ \(label)：帧数/格式不对 —— \(out.frameLength) 帧 \(out.format)")
            return false
        }
        guard let dst = out.floatChannelData else {
            print("✗ \(label)：转出来的 buffer 拿不到 Float 指针")
            return false
        }

        // 逐字节比：交织版只有一块（floatChannelData[0] 就是交织基址），
        // 非交织版每条声道各一块
        for b in 0..<bufferCount {
            let got = dst[interleaved ? 0 : b]
            for i in 0..<floatsPerBuffer where got[i] != srcs[b][i] {
                print("✗ \(label)：PCM 不一致，块\(b) 第 \(i) 个：期望 \(srcs[b][i]) / 实际 \(got[i])")
                return false
            }
        }
        print("✓ \(label)：\(frames) 帧 × \(channels) 声道原样转换（\(floatsPerBuffer * 4 * bufferCount) 字节）")
        return true
    }
}
