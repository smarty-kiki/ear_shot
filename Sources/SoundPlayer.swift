import AVFoundation
import AppKit

/// 提醒音。听到新待办时响一下。
///
/// 直接用系统原版音效（`/System/Library/Sounds`），不做放大版——
/// notch_tasks 那份放大 +9.6 dB 的 `Resources/Sounds/` 是给「必须穿透注意力」的
/// 任务告警用的；耳录是常驻会议场景，响太亮反而烦人。
/// 有自带音效就优先用（`Resources/Sounds/`），没有就退回系统原版。
final class SoundPlayer {

    static let shared = SoundPlayer()

    /// 新待办提示音。Bottle = 短短一声空心「嘟」，像拨瓶塞，轻快不扎人 ——
    /// 用户实测嫌原来的 Glass（玻璃铃，音头亮、带拖尾）「硬、吓人」，
    /// 候选挨个放过让用户挑的。想再换：`/System/Library/Sounds` 里挑一个
    /// 改这里，记得 `afplay -v 0.6 /System/Library/Sounds/X.aiff` 试听
    static let notifySound = "Bottle"

    private var cache: [String: NSSound] = [:]

    private init() {}

    func play(_ name: String) {
        guard let s = sound(name) else { return }
        s.stop()          // 提醒密集时打断上一条，别叠在一起
        s.play()
    }

    /// 预热：首次播放要把音频读进内存，先做掉免得第一声有延迟
    func warmUp() {
        _ = sound(Self.notifySound)
    }

    private func sound(_ name: String) -> NSSound? {
        if let s = cache[name] { return s }
        guard let url = Self.url(for: name),
              // byReference: false —— 把音频读进内存，之后文件动过也不影响
              let s = NSSound(contentsOf: url, byReference: false) else {
            AppDebug.log("[sound] 找不到音效 \(name)")
            return nil
        }
        s.volume = 1.0
        cache[name] = s
        return s
    }

    /// 自带的那份优先，其次系统原版
    private static func url(for name: String) -> URL? {
        if let bundled = bundledURL(name) { return bundled }
        let system = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        return FileManager.default.fileExists(atPath: system.path) ? system : nil
    }

    /// app 自带的音效。装在 .app 里时走 `Bundle.main`；
    /// 以裸二进制（`build/EarShot`）跑自检时，回退到源码树里的 Resources/Sounds。
    private static func bundledURL(_ name: String) -> URL? {
        if let u = Bundle.main.url(forResource: name, withExtension: "aiff",
                                   subdirectory: "Sounds") {
            return u
        }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            exe.appendingPathComponent("../Resources/Sounds/\(name).aiff"),
            URL(fileURLWithPath: "Resources/Sounds/\(name).aiff"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
