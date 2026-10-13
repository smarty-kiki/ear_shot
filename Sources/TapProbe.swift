import AVFoundation
import CoreAudio
import CoreGraphics
import Foundation

/// 锁屏收音探针：`EarShot --taptest [秒数]`
///
/// 「锁屏继续听」是立项条件，也已经落地：生产的系统声音采集就是这套 tap
/// （AudioCapture.startSystemTap 与这里同源）。探针留着做回归 —— 换系统、
/// 换机器、动过 tap 配置之后，锁屏断不断用它验，别拿真 app 赌。
///
/// 测试设计上最要紧的一条：**音源必须是别的进程**。生产的 tap 会排除耳录
/// 自己（自己的提示音别录进去），所以探针也用同一套配置（全局混音、排除
/// 自己），测试音交给 `afplay` 来放 —— 自己进程放音，验证不了「录别人的
/// 声音」这条路。
///
/// 主循环每秒打一行（帧数 + RMS + 锁屏状态），结束时按记录自动判定，
/// 对应的 exit code：0=通过，2=锁屏断了，3=实验没做（没锁屏/太短），
/// 4=连解锁状态都没信号（先查权限）。
///
/// 不是离线自检：要音频录制权限 + 真人锁一次屏，所以不进 `make test`。
enum TapProbe {

    // MARK: - 线程间的小工具

    /// IO 回调（实时线程）往里攒，主循环每秒取走一次。探针不计较这点锁开销。
    private final class SecondBucket {
        private let lock = NSLock()
        private var floats = 0
        private var sumSquares = 0.0

        func add(floats n: Int, sumSquares s: Double) {
            lock.lock()
            floats += n
            sumSquares += s
            lock.unlock()
        }

        /// 取走并清零，算好 RMS（对全部采样，交织/非交织都成立）
        func drain() -> (floats: Int, rms: Double) {
            lock.lock()
            defer { lock.unlock() }
            let f = floats
            let rms = f > 0 ? (sumSquares / Double(f)).squareRoot() : 0
            floats = 0
            sumSquares = 0
            return (f, rms)
        }
    }

    /// Ctrl-C 打的标记。信号处理在后台队列上跑，主循环在别处读。
    private final class Flag {
        private let lock = NSLock()
        private var v = false
        var value: Bool {
            lock.lock()
            defer { lock.unlock() }
            return v
        }
        func set() {
            lock.lock()
            v = true
            lock.unlock()
        }
    }

    // MARK: - 主流程

    static func run(seconds: Double, logPath: String? = nil) async -> Int32 {
        // 这个探针必须用 `open`（LaunchServices）启动，不能从终端直跑 ——
        // 终端直跑时 TCC 把「责任进程」算在终端头上（attribution: responsible=
        // iTerm2, accessing=EarShot），终端 Info.plist 里没有录音权限说明键，
        // 系统直接拒绝（Refusing authorization request ... without
        // NSAudioCaptureUsageDescription key）、连弹窗都不给，tap 出来全是零。
        // 独立启动的副作用是 stdout 没地方去，所以 --log 把 stdout 整个接到
        // 文件里，看输出用 tail -f。
        if let logPath {
            _ = freopen(logPath, "w", stdout)
        }
        print("""
        === tap 锁屏探针 ===
        会有一阵很轻的 440 Hz 嗡声（afplay 放的，另一个进程 —— 生产同款路径）。
        tap 配置也和生产一致：全系统混音，排除耳录自己。
        第一次跑系统会弹「EarShot 想录制此电脑的音频」权限窗，点允许。
        步骤：
          1. 先看几行「解锁」的：RMS 约 0.03 上下。一直是 0 就先别锁屏，看末尾提示
          2. 锁屏（⌃⌘Q 或  菜单 →「锁定屏幕」），保持 15 秒以上
          3. 解锁回来，`make taptest-stop` 收尾（或等它跑满 \(Int(seconds)) 秒自己收尾）
        判定：锁屏期间每秒都收到帧、RMS 非零 → tap 能做到锁屏收音。
        """)
        fflush(stdout)

        // ---- 测试音：写文件 + afplay ----
        guard let toneURL = makeToneFile(seconds: seconds + 10) else { return 4 }
        defer { try? FileManager.default.removeItem(at: toneURL) }
        let afplay = Process()
        afplay.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        afplay.arguments = ["-v", "0.3", toneURL.path]
        do {
            try afplay.run()
        } catch {
            print("afplay 起不来：\(error.localizedDescription)")
            return 4
        }
        defer { if afplay.isRunning { afplay.terminate() } }

        // ---- tap：排除自己，其余全收（= 生产配置）----
        var exclude: [AudioObjectID] = []
        if let own = ownProcessObject() {
            exclude = [own]
        } else {
            print("（备注：拿不到自己的 process object，这轮不排除自己 —— 不影响判定）")
        }
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        desc.name = "耳录锁屏探针"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted      // 探针别把用户的系统声音掐了
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var st = AudioHardwareCreateProcessTap(desc, &tapID)
        guard st == noErr else {
            print("创建 tap 失败：OSStatus \(st)。")
            print("权限没给？系统设置 → 隐私与安全性 →「屏幕与系统音频录制」里找「耳录」。")
            return 4
        }
        defer { AudioHardwareDestroyProcessTap(tapID) }

        // tap 出来的格式（生产里重采样要按它配，这里顺便打出来）
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var fmtAddr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        st = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &size, &asbd)
        guard st == noErr, asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32 else {
            print("拿 tap 格式失败或不是 Float32：OSStatus \(st)")
            return 4
        }
        let channels = max(Int(asbd.mChannelsPerFrame), 1)
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        print("tap 就绪 #\(tapID)：\(Int(asbd.mSampleRate)) Hz · \(channels) 声道 · Float32"
              + "（\(interleaved ? "交织" : "非交织")）")
        print("默认输出设备：\(defaultOutputName() ?? "？")")
        fflush(stdout)

        // ---- 私有聚合设备把 tap 接出来 ----
        let aggDict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "耳录锁屏探针",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: desc.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        st = AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)
        guard st == noErr else {
            print("建聚合设备失败：OSStatus \(st)")
            return 4
        }
        defer { AudioHardwareDestroyAggregateDevice(aggID) }

        // ---- IO 回调：只攒数字，判定留给主循环 ----
        let bucket = SecondBucket()
        var procID: AudioDeviceIOProcID?
        st = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inputData, _, _, _ in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            var floats = 0
            var sum = 0.0
            for buf in abl {
                guard let m = buf.mData else { continue }
                let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
                let p = m.assumingMemoryBound(to: Float.self)
                for i in 0..<n {
                    let x = Double(p[i])
                    sum += x * x
                }
                floats += n
            }
            if floats > 0 { bucket.add(floats: floats, sumSquares: sum) }
        }
        guard st == noErr, let procID else {
            print("挂 IO 回调失败：OSStatus \(st)")
            return 4
        }
        defer { AudioDeviceDestroyIOProcID(aggID, procID) }

        st = AudioDeviceStart(aggID, procID)
        guard st == noErr else {
            print("聚合设备起不来：OSStatus \(st)")
            return 4
        }
        defer { AudioDeviceStop(aggID, procID) }

        // ---- 主循环：每秒一行，Ctrl-C / SIGTERM 收尾 ----
        signal(SIGINT, SIG_IGN)     // 默认动作是直接死在半路，探针要自己收尾总结
        signal(SIGTERM, SIG_IGN)    // make taptest-stop 走的就是 TERM，同样要收尾
        let stop = Flag()
        let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigSrc.setEventHandler { stop.set() }
        sigSrc.resume()
        defer { sigSrc.cancel() }
        let termSrc = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        termSrc.setEventHandler { stop.set() }
        termSrc.resume()
        defer { termSrc.cancel() }

        let stamp = DateFormatter()
        stamp.dateFormat = "HH:mm:ss"
        // 有信号 = 收到帧且 RMS 明显非零。测试音约 0.03，阈值贴着噪声之上、离它很远
        let signalFloor = 0.0005
        var unlocked = 0, unlockedSignal = 0
        var locked = 0, lockedSignal = 0
        let deadline = Date().addingTimeInterval(seconds)
        var tick = 0
        while !stop.value && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            tick += 1
            if tick == 2 && !afplay.isRunning {
                print("⚠️ afplay 已经退出了（状态 \(afplay.terminationStatus)）—— 测试音没放出来，先查这个")
            }
            let (fl, rms) = bucket.drain()
            let frames = fl / channels
            let isLocked = screenIsLocked
            let hasSignal = frames > 0 && rms > signalFloor
            if isLocked {
                locked += 1
                if hasSignal { lockedSignal += 1 }
            } else {
                unlocked += 1
                if hasSignal { unlockedSignal += 1 }
            }
            let state = isLocked ? "锁屏" : "解锁"
            let reading = hasSignal
                ? String(format: "RMS %.3f", rms)
                : (frames == 0 ? "没收到帧" : "全是零")
            print(String(format: "%@ [tap] 第 %3d 秒 · %@ · %d 帧 · %@",
                         stamp.string(from: Date()), tick, state, frames, reading))
            fflush(stdout)
        }

        // ---- 判定 ----
        print("=== 结果 ===")
        print("解锁窗口 \(unlocked) 秒（有信号 \(unlockedSignal) 秒）；"
              + "锁屏窗口 \(locked) 秒（有信号 \(lockedSignal) 秒）")
        if unlocked < 3 {
            print("采样太短，没看到东西。重跑一次（默认 120 秒）。")
            return 3
        }
        if unlockedSignal == 0 {
            print("""
            ✗ 解锁状态下就收不到信号 —— 先排查这三样，再谈锁屏：
              · 系统设置 → 隐私与安全性 → 音频录制：里面有没有「耳录」，开没开
              · 系统输出设备对不对（上面打的那个）；afplay 没出声的话换首歌试试
                听不听得到
              · 输出设备是虚拟声卡/聚合设备的话，换回真实设备再跑
            """)
            return 4
        }
        if locked < 5 {
            print("？ 没观察到锁屏（或不到 5 秒）。实验没做：重跑，中间锁一次屏，保持 15 秒以上。")
            return 3
        }
        let ratio = Double(lockedSignal) / Double(locked)
        if ratio >= 0.8 {
            print("✓ 锁屏 \(locked) 秒里有信号 \(lockedSignal) 秒 —— 锁屏断不了采集。")
            return 0
        }
        print("✗ 锁屏 \(locked) 秒里有信号才 \(lockedSignal) 秒 —— 锁屏把 tap 掐了。")
        print("生产的采集用的就是这套 tap，这里断 = 真 app 也会断：看上面锁屏那几行是从第几秒开始断的。")
        return 2
    }

    // MARK: - 小件

    /// 屏幕锁没锁。`CGSSessionCopyCurrentDictionary` 是查这个的正规路子；
    /// 探针一秒查一次，不需要去注册锁屏通知。
    private static var screenIsLocked: Bool {
        guard let d = CGSessionCopyCurrentDictionary() as? [String: Any],
              let n = d["CGSSessionScreenIsLocked"] as? NSNumber else { return false }
        return n.boolValue
    }

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

    /// 默认输出设备的显示名。判定出问题时它帮忙区分「设备不对」还是「权限不对」
    private static func defaultOutputName() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         0, nil, &size, &dev) == noErr else { return nil }

        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, &cfName) == noErr,
              let cf = cfName else { return nil }
        return cf.takeRetainedValue() as String
    }

    /// 造一段 440 Hz、很轻、连续的测试音写进临时文件（afplay 只放文件）。
    /// 连绵不断是有意的：断没断，看每秒的 RMS 一眼就知道。
    private static func makeToneFile(seconds: Double) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("earshot-taptest-tone.aiff")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings)
            guard let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48000) else { return nil }
            let total = Int(seconds * 48000)
            var written = 0
            var phase = 0.0
            while written < total {
                let n = min(48000, total - written)
                let p = buf.floatChannelData![0]
                for i in 0..<n {
                    p[i] = Float(sin(2 * .pi * 440 * phase / 48000)) * 0.15
                    phase += 1
                }
                buf.frameLength = AVAudioFrameCount(n)
                try file.write(from: buf)
                written += n
            }
            return url
        } catch {
            print("写测试音文件失败：\(error.localizedDescription)")
            return nil
        }
    }
}
