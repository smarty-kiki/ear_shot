import AVFoundation
import Foundation
import QuartzCore

/// 标题栏两条「声纹」的数据源：麦克风（我）和系统声音（对方）各一串电平历史。
///
/// 电平在采集队列上算（`level(of:)`，纯函数、很便宜），**节流后跳主线程** push ——
/// 音频帧一秒来几十上百个，不节流的话每一帧都是一次 SwiftUI 更新。
/// 面板收着的时候没有视图订阅，这些更新自然没人理，不用特意停。
///
/// 和 TodoStore 一样是纯内存：不落盘，停止监听即清平。
final class AudioMeters: ObservableObject {

    /// 一串几根柱子。20Hz 推送下约等于最近 0.7 秒
    static let barCount = 14
    /// 相邻两次推送的最小间隔（秒）。50ms ≈ 20Hz —— 再密看着也不会更顺，
    /// 只是白烧 CPU
    static let pushInterval: CFTimeInterval = 0.05
    /// 快起慢落：电平掉下去时按这个系数逐次衰减。
    /// 直接跟着 RMS 大跳小会看着像在抽搐
    private static let decay: CGFloat = 0.86

    @Published private(set) var micBars: [CGFloat]
    @Published private(set) var systemBars: [CGFloat]

    private var micLast: CGFloat = 0
    private var systemLast: CGFloat = 0

    init() {
        micBars = Array(repeating: 0, count: Self.barCount)
        systemBars = Array(repeating: 0, count: Self.barCount)
    }

    /// 停止监听时把两串清平 —— 面板上留着上一场的波形是在说谎
    func reset() {
        micLast = 0
        systemLast = 0
        micBars = Array(repeating: 0, count: Self.barCount)
        systemBars = Array(repeating: 0, count: Self.barCount)
    }

    /// 新电平进门（主线程调用）。快起慢落之后挤进历史。
    func push(_ level: CGFloat, speaker: Speaker) {
        switch speaker {
        case .me:
            micLast = max(level, micLast * Self.decay)
            micBars.removeFirst()
            micBars.append(micLast)
        case .other:
            systemLast = max(level, systemLast * Self.decay)
            systemBars.removeFirst()
            systemBars.append(systemLast)
        }
    }

    /// 原始 PCM → 0…1 的显示电平。
    ///
    /// RMS → dBFS → 线性映射：-52dB（安静房间的本底）到 -4dB（近满幅）之外截顶。
    /// 直接用 RMS 线性映射的话，正常说话只占满量程的一小截，柱子永远矮矮的。
    static func level(of buffer: AVAudioPCMBuffer) -> CGFloat {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Double = 0
        if let ch = buffer.floatChannelData?[0] {
            for i in 0..<n { let v = Double(ch[i]); sum += v * v }
        } else if let ch = buffer.int16ChannelData?[0] {
            for i in 0..<n { let v = Double(ch[i]) / 32768.0; sum += v * v }
        } else {
            return 0
        }
        let rms = (sum / Double(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let t = (db + 52) / 48
        return CGFloat(min(max(t, 0), 1))
    }
}

/// 采集队列上的节流器：两路各一个，只被自己那条队列碰，不用加锁。
final class LevelThrottle {
    private var last: CFTimeInterval = 0
    func shouldFire() -> Bool {
        let now = CACurrentMediaTime()
        guard now - last >= AudioMeters.pushInterval else { return false }
        last = now
        return true
    }
}

// MARK: - 声纹自检

/// 声纹电平自检：`EarShot --wavetest`
///
/// 电平链路整段都长在「授权后说话才看得到」的那条路上，离屏没有音频帧经过它 ——
/// 和 PCM 转换一个处境，所以也走合成 buffer 打表：静音、满幅、正弦、Int16 路
/// 各算一遍，历史 / 快起慢落 / 清平各验一条。
enum WaveSelfCheck {

    static func run() -> Int32 {
        var failed = 0
        func check(_ cond: Bool, _ label: String) {
            print("\(cond ? "✓" : "✗") \(label)")
            if !cond { failed += 1 }
        }

        // 1) 电平映射
        let f32 = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                channels: 1, interleaved: false)!
        check(AudioMeters.level(of: tone(f32, amplitude: 0)) == 0, "静音 → 0")
        check(AudioMeters.level(of: tone(f32, amplitude: 1, square: true)) > 0.99,
              "满幅 → 1（截顶）")
        let sine = AudioMeters.level(of: tone(f32, amplitude: 0.1))
        check(sine > 0.5 && sine < 0.75,
              "0.1 幅正弦 → \(String(format: "%.2f", sine))（应在 0.50…0.75）")

        // 2) Int16 那条路（SCK 出来的就是它）跟 Float 路算出来一致
        let i16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                channels: 1, interleaved: false)!
        let sine16 = AudioMeters.level(of: tone(i16, amplitude: 0.1))
        check(abs(sine16 - sine) < 0.01,
              "Int16 与 Float 一致（\(String(format: "%.2f", sine16))）")

        // 3) 历史与快起慢落
        let m = AudioMeters()
        let n = AudioMeters.barCount + 6
        for i in 0..<n { m.push(CGFloat(i) / CGFloat(n - 1), speaker: .me) }
        check(m.micBars.count == AudioMeters.barCount,
              "历史只留 \(AudioMeters.barCount) 根")
        check(m.micBars.last! > 0.99, "最新一根 = 刚推的电平（快起）")
        m.push(0, speaker: .me)
        check(abs(m.micBars.last! - 0.86) < 0.01,
              "静音掉下来按 0.86 慢落（\(String(format: "%.2f", m.micBars.last!))）")

        // 4) 两路互不干扰 + 清平
        let bands = AudioMeters()
        bands.push(0.5, speaker: .other)
        check(bands.micBars.allSatisfy { $0 == 0 }
              && abs(bands.systemBars.last! - 0.5) < 0.001,
              "麦克风 / 系统两串各自独立")
        bands.reset()
        check(bands.systemBars.allSatisfy { $0 == 0 } && bands.micBars.allSatisfy { $0 == 0 },
              "reset 清平")

        print(failed == 0 ? "声纹自检全部通过" : "声纹自检有 \(failed) 项没过")
        return failed == 0 ? 0 : 1
    }

    /// 合成一段测试波形。square = 满幅方波（RMS = 幅值），否则 440Hz 正弦
    /// （RMS = 幅值 / √2）
    private static func tone(_ fmt: AVAudioFormat, frames: Int = 1600,
                             amplitude: Float, square: Bool = false) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: fmt,
                                   frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        func sample(_ i: Int) -> Float {
            square ? amplitude
                   : amplitude * Float(sin(2 * Double.pi * 440 * Double(i) / 16000))
        }
        if let ch = buf.floatChannelData?[0] {
            for i in 0..<frames { ch[i] = sample(i) }
        } else if let ch = buf.int16ChannelData?[0] {
            for i in 0..<frames { ch[i] = Int16(sample(i) * 32767) }
        }
        return buf
    }
}
