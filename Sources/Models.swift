import Foundation
import SwiftUI

/// 用户 home 目录。
///
/// 优先读 `HOME` 环境变量，而不是 `NSHomeDirectory()` —— 后者在 macOS 上走
/// getpwuid，**不认 HOME**。冒烟测试靠 `HOME=<临时目录>` 把配置指开，
/// 用 NSHomeDirectory() 的话那个隔离是假的（会去读真实配置）。
enum UserHome {
    static let path: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
}

/// 统一日志：`--verbose` 或 `EARSHOT_DEBUG=1` 打开，走 stderr 不污染自检输出。
/// 行首带毫秒时间戳 —— 「说一句到面板冒出来」到底几秒，靠它量
enum AppDebug {
    static let on: Bool =
        ProcessInfo.processInfo.environment["EARSHOT_DEBUG"] == "1"
        || CommandLine.arguments.contains("--verbose")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    /// 日志会从采集、识别这些非主线程上调，DateFormatter 不是处处线程安全，锁上
    private static let stampLock = NSLock()

    static func log(_ s: String) {
        guard on else { return }
        stampLock.lock()
        let ts = stamp.string(from: Date())
        stampLock.unlock()
        FileHandle.standardError.write(("[earshot \(ts)] " + s + "\n").data(using: .utf8)!)
    }
}

// MARK: - 提醒级别

/// 把手的状态。决定圆点长什么样、要不要发光。
///
/// | 级别 | 含义 | 把手 |
/// |---|---|---|
/// | `idle` | 没在听 | 灰点，无光 |
/// | `listening` | 正在听，没有未读 | **红点慢闪**（录制中），无光 |
/// | `new` | 有新待办或有补全没看过 | 红点慢闪 + **外框橙光脉冲** |
///
/// 注意「监听中」和「有未读」是两个正交的事：一边听着录音，
/// 一边可能随时冒出新的未读。所以这里用「越大越优先」的单一序列表达，
/// 上位状态把下位的视觉包含进去即可。
enum AlertLevel: Int, Comparable {
    case idle = 0
    case listening = 1
    case new = 2

    static func < (l: AlertLevel, r: AlertLevel) -> Bool { l.rawValue < r.rawValue }

    var color: Color {
        switch self {
        case .idle:      return Color(white: 0.35)
        case .listening: return Color(red: 1.00, green: 0.29, blue: 0.24)  // 录制红
        case .new:       return Color(red: 1.00, green: 0.62, blue: 0.04)  // 未读橙
        }
    }

    var label: String {
        switch self {
        case .idle:      return "未监听"
        case .listening: return "监听中"
        case .new:       return "有未读"
        }
    }
}

// MARK: - 待办条目

/// 一条待办。
///
/// `seq` 不只是列表里的装饰序号 —— 会上人是**照着屏幕念号**继续讨论的
/// （「待办 1 的地点改成会议室 B」），所以这个号会原样送进大模型的提示词里，
/// 作为把口头指代落到具体某条上的唯一锚点。因此：
/// **分配后不回收、不重排、不因合并而重新编号**。缺口是刻意接受的。
struct TodoItem: Identifiable, Equatable {

    /// 六项字段。顺序就是显示顺序、复制顺序。
    enum Field: String, CaseIterable, Hashable {
        case action, time, location, person, artifact, artifactDesc

        var label: String {
            switch self {
            case .action:       return "待办"
            case .time:         return "时间"
            case .location:     return "地点"
            case .person:       return "人物"
            case .artifact:     return "输出物"
            case .artifactDesc: return "说明"
            }
        }
    }

    /// 序号。显示 + 送模型，见类型注释。
    var seq: Int
    var id: String { String(seq) }

    var action: String
    var time: String?
    var location: String?
    var person: String?
    var artifact: String?
    var artifactDesc: String?

    /// 抽取依据的原话。行内小字，便于核对「它凭什么记这条」。
    var evidence: String?

    var createdAt: Date
    var updatedAt: Date

    /// 未读 → 驱动外框光晕。展开面板即清掉。
    var isNew: Bool = true

    /// 刚刚被补全的字段（UI 上短暂高亮，就是「持续补全」的体感来源）
    var touched: Set<Field> = []

    /// 正在被划掉的字段 → 被划掉的旧值。
    ///
    /// **值在模型里已经清掉了**，这里留的纯粹是给眼睛看的「尸体」：字段渲染成
    /// 红色删除线，停一会儿再真正消失（见 `TodoStore.scheduleGhostSweep`）。
    /// 之所以不在模型里留住旧值、等动画演完再清 —— 复制走的文本和送回模型的
    /// 清单都不能带着一个已经作废的值。
    var ghost: [Field: String] = [:]

    /// 整条正在被删除：整块变红，到点由 `TodoStore` 真正移走。
    var deleting: Bool = false

    /// 两位补零，保证多条之间左边缘对齐
    var seqLabel: String { String(format: "%02d", seq) }

    func value(_ f: Field) -> String? {
        let v: String?
        switch f {
        case .action:       v = action
        case .time:         v = time
        case .location:     v = location
        case .person:       v = person
        case .artifact:     v = artifact
        case .artifactDesc: v = artifactDesc
        }
        guard let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return v
    }

    /// 点击复制的文本：六字段多行，空字段整行省略。
    ///
    /// **不带序号**——序号是当场对着屏幕讨论用的定位符，粘到别处没有意义，
    /// 反而多一行噪音。
    var copyText: String {
        Field.allCases
            .compactMap { f in value(f).map { "\(f.label)：\($0)" } }
            .joined(separator: "\n")
    }

    /// 拼给大模型看的「一行式清单」，六项字段全带上（空字段写 —）。
    /// 见 Extractor.swift 的提示词。
    var promptLine: String {
        let fields = Field.allCases
            .map { "\($0.label)：\(value($0) ?? "—")" }
            .joined(separator: " ｜")
        return "\(seq). \(fields)"
    }

    /// 归一化后的文本，用于新项跟已有项做相似度比对（判重）
    var normalizedKey: String {
        TodoItem.normalize([action, time, location, person, artifact, artifactDesc]
            .compactMap { $0 }.joined(separator: " "))
    }

    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.widthInsensitive, .caseInsensitive], locale: nil)
        return String(folded.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        })
    }
}
