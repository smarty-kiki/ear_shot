import Foundation

/// 说话人。采集那边麦克风与系统音频天然分成两路，所以这个是白送的，
/// 不需要做说话人分离。
enum Speaker: String {
    /// 麦克风进来的 = 我
    case me = "我"
    /// 系统声音进来的 = 会议里别人
    case other = "对方"

    var label: String { rawValue }
}

/// 转写缓冲：给抽取器提供「最近一段、带说话人」的文本。
///
/// **只留最近一小段，不攒全文。** 抽出来的待办本身就是记忆 —— 每一轮都会把
/// 整个待办列表送回模型，旧转写只用来发现新信息，留着纯属浪费。顺带也贴合
/// 「不落盘」的定位：转写全文从头到尾就没存在过。
///
/// 线程约定：只在主线程访问（识别回调里先跳回主线程再进这里）。
final class TranscriptLog {

    struct Segment {
        let speaker: Speaker
        let text: String
        let at: Date
    }

    /// 定稿段，按时间顺序
    private(set) var segments: [Segment] = []

    /// 定稿计数。抽取调度器盯这个数：变了就说明有新内容可抽。
    private(set) var finalizedCount = 0

    /// 保留的字符总量上限，超出就从最旧的段开始丢
    private let keepChars: Int

    init(keepChars: Int = 8000) {
        self.keepChars = keepChars
    }

    /// 收一段定稿。返回是否真的新增了（空段 / 紧跟的重复段会被丢掉）。
    ///
    /// （未定稿的「正在说」不再经过这里 —— 面板中间不再显示实时文字，
    /// 那路的动静改由标题栏声纹表达，见 `AudioMeters`。）
    @discardableResult
    func finalize(_ speaker: Speaker, text: String, at: Date = Date()) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        // 有些 preset 会把同一句话连着定稿两次，去个重
        if let last = segments.last, last.speaker == speaker, last.text == t { return false }
        segments.append(Segment(speaker: speaker, text: t, at: at))
        finalizedCount += 1
        trim()
        return true
    }

    /// 最近 `chars` 个字符的定稿文本，`[我] …` / `[对方] …` 每段一行。
    /// 从最旧往新排 —— 模型读起来顺，和人的阅读顺序一致。
    func recentWindow(chars: Int) -> String {
        guard chars > 0 else { return "" }
        var picked: [Segment] = []
        var budget = chars
        for s in segments.reversed() {
            if budget <= 0 { break }
            picked.append(s)
            budget -= s.text.count
        }
        return picked.reversed()
            .map { "[\($0.speaker.label)] \($0.text)" }
            .joined(separator: "\n")
    }

    /// 最新一段定稿的原文 —— 抽取节奏的断句分级看它收在什么标点上（见 `SentenceGate`）
    var newestText: String? { segments.last?.text }

    /// 最近一段时间的总字数（自检和界面计时用）
    var totalChars: Int { segments.reduce(0) { $0 + $1.text.count } }

    /// 时间窗内最近一段来自 `speaker` 的定稿 —— 回声过滤用。
    /// segments 是按时间追加的，从新往旧找，出窗就停。
    func mostRecentFinal(from speaker: Speaker, within seconds: TimeInterval,
                         now: Date = Date()) -> Segment? {
        let floor = now.addingTimeInterval(-seconds)
        for s in segments.reversed() {
            if s.at < floor { break }
            if s.speaker == speaker { return s }
        }
        return nil
    }

    func clear() {
        segments.removeAll()
        finalizedCount = 0
    }

    /// 从头丢到 keepChars 以内。至少留一段 —— 单段超长（识别器很久才定稿
    /// 一次）时也得把这一段留着。
    private func trim() {
        var total = segments.reduce(0) { $0 + $1.text.count }
        var drop = 0
        while total > keepChars, drop < segments.count - 1 {
            total -= segments[drop].text.count
            drop += 1
        }
        if drop > 0 { segments.removeFirst(drop) }
    }
}

// MARK: - 回声过滤

/// 不用耳机时，喇叭放出来的声音会被麦克风再从空气里听一遍 —— 同一句话在
/// 「对方」（系统声音，干净）和「我」（麦克风，隔着空气听岔一点）两路各定稿
/// 一份，谁先谁后还不固定（实测两种顺序都出现过）。两份都进窗口的话，模型
/// 眼里就成了「两个人分别说了几乎一样的话」，轻则重复、重则把对方的话记成
/// 我说的。
///
/// 判定 = 归一化后的编辑距离比。真实回声对的相似度实测 0.82～1.0（「房东」
/// 被听成「皇公」这种听岔都还在区间里）。代价说清楚：两边真的在 15 秒内说了
/// 高度相近的长句，会少掉后到的那份 —— 罕见，且丢的只是转写窗口里的一段，
/// 已经抽出来的待办不受影响。
///
/// 这是文本层的缓解，不是声学回声消除。戴耳机可以从源头避免。
enum EchoGuard {

    /// 两段定稿相隔多久之内，才可能是「同一句话的两次听写」
    static let window: TimeInterval = 15

    /// 短于这个长度的一律不判：「对」「好」这种两路都出现是常态，
    /// 而且短句听着像也不能说明是同一句
    static let minChars = 6

    /// 相似度阈值。真实回声对里最糊的一份（隔空气 + 听岔两个词）实测约 0.82
    static let threshold = 0.8

    /// 归一化：小写 + 只留字/字母/数字。主要收掉标点与空白的差异
    /// （如「我们现在又不是猫。」vs「我们现在又不是猫」）
    static func normalized(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// a、b 像不像「同一句话被两路各听了一遍」
    static func looksLikeEcho(_ a: String, _ b: String) -> Bool {
        let x = Array(normalized(a))
        let y = Array(normalized(b))
        guard x.count >= minChars, y.count >= minChars else { return false }
        let ratio = 1 - Double(editDistance(x, y)) / Double(max(x.count, y.count))
        return ratio >= threshold
    }

    /// 标准 Levenshtein 距离，两个一维数组滚动着算
    static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

// MARK: - 断句闸门

// MARK: - 断句分级

/// 「句子收到哪儿了」→「这句之后还要等多久才发」的分级闸门。
///
/// ASR 的未定稿（正在滚动的那半句）本来就进不了窗口，但**定稿不保证说完了**：
/// 识别器会在停顿处定稿，一条定稿可以收在逗号、省略号上 —— 2026-10-10 的
/// 实测日志里「这个呢一级代码有好像我现看啊 ，我就我…」就是原样发给过模型的。
/// 「等它完整再发」和「反应快」曾经像是一根绳的两头，分级把绳解开：
/// 能判定的（刚性）零等待，判不了的（弱/无标点）才等。
///
/// 分级（刚性信号 / 弱信号 / 兜底）：
///  - **刚性**：句号、问号、叹号收尾 = 说完了 → 直接发，不等。
///    真实会议里绝大多数待办收在刚性断句上，这是感知延迟的主路径
///  - **弱**：逗号、顿号、分号、冒号、省略号收尾 = 还在说 → 等
///    `commaWait`（默认 2 秒）。2 秒内没等来新定稿（多半就是句号）就发 ——
///    能等到期，说明说话人确实停在那儿了，断尾也一起发出去
///  - **无标点**：判断不了 → 等 `plainWait`（默认 5 秒）
///
/// 等待时钟从「最后一条定稿」起算，**任何**新定稿都清零重记 ——
/// 弱断句等来一句刚性断句，就直接按刚性走（这就是「遇到刚性就重置重记」，
/// 而且更强：逗号后面又来了个逗号，也说明还在说）
enum SentenceGate {

    enum Tier {
        /// 句号/问号/叹号收尾：说完了
        case rigid
        /// 逗号/顿号/分号/冒号/省略号收尾：还在说
        case comma
        /// 没有标点：判断不了
        case plain

        var label: String {
            switch self {
            case .rigid: "刚性"
            case .comma: "弱"
            case .plain: "无标点"
            }
        }
    }

    /// 这条定稿收在哪一级上。收尾的引号/括号不参与判断（「……了。」」「……走了”」）
    static func tier(of text: String?) -> Tier {
        guard var t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return .plain
        }
        let closers: Set<Character> = ["」", "』", "”", "\"", "）", ")", "》", "】"]
        while let last = t.last, closers.contains(last) { t.removeLast() }
        guard let last = t.last else { return .plain }
        if "。！？!?.".contains(last) { return .rigid }
        if "，,、；;：:…".contains(last) { return .comma }
        return .plain
    }

    /// 最后一条定稿之后还要静多久才发
    static func wait(forNewest newest: String?,
                     commaWait: TimeInterval,
                     plainWait: TimeInterval) -> TimeInterval {
        switch tier(of: newest) {
        case .rigid: 0
        case .comma: commaWait
        case .plain: plainWait
        }
    }
}

// MARK: - 回声过滤自检

/// 回声过滤自检：`EarShot --echotest`
///
/// 用例全是真实运行日志里成对的「我 / 对方」原话（2026-10-10 那次）——
/// 喇叭外放、麦克风隔空气听岔，两路定稿就是这么成对的。
enum EchoSelfCheck {

    /// (我这一路, 对方那一路, 期望是否判为回声)
    private static let cases: [(String, String, Bool)] = [
        // 真实回声对：判「是」
        ("我不是你爸你把我捡回来的给我吃的还给我铲屎。最后一句不用说那就是爸爸",
         "我不是你爸你把我捡回来的给我吃的还给我铲屎。最后一句不用说了那就是爸爸", true),
        ("陈宇开门那两只猫送走没有俩先别出声为什么皇公不让养我",
         "陈宇开门那两只猫送走没有你们俩先别出声为什么房东不让养猫", true),
        ("我们现在又不是猫。", "我们现在又不是猫", true),
        // 不是回声：各说各的
        ("这个季度的复盘就定在下周五之前", "好我发给老王", false),
        // 太短不动：「对」「好」两边都说是常态
        ("对", "对", false),
        // 已知代价：两边真的说了只差一个词的两句，也会算回声。换的是
        // 「不用耳机时每句话都双份」这个常态问题，这个取舍认了
        ("把Q3复盘PPT发给老王", "把Q3复盘PPT发给老李", true),
    ]

    static func run() -> Int32 {
        var failed = 0
        for (i, c) in cases.enumerated() {
            let nx = EchoGuard.normalized(c.0)
            let ny = EchoGuard.normalized(c.1)
            let d = EchoGuard.editDistance(Array(nx), Array(ny))
            let ratio = 1 - Double(d) / Double(max(nx.count, ny.count))
            let got = EchoGuard.looksLikeEcho(c.0, c.1)
            let ok = got == c.2
            if !ok { failed += 1 }
            print(String(format: "%@ 用例 %d  相似度 %.2f  判=%@  期望=%@",
                         ok ? "✓" : "✗", i + 1, ratio,
                         got ? "回声" : "不是", c.2 ? "回声" : "不是"))
        }
        print(failed == 0 ? "回声过滤自检全部通过" : "回声过滤自检有 \(failed) 项没过")
        return failed == 0 ? 0 : 1
    }
}

// MARK: - 断句闸门自检

/// 断句闸门自检：`EarShot --senttest`
///
/// 闸门 = 「收在哪儿」（`tier(of:)`）→「等多久」（`wait(forNewest:commaWait:plainWait:)`）。
/// 分级用例取自真实运行日志里的定稿原文（2026-10-10 那次实跑）——
/// ASR 的「定稿」不等于「说完了」，逗号收尾、省略号收尾的半句是日志里真实出现过的。
enum SentenceGateSelfCheck {

    /// (定稿原文, 期望分级)
    private static let cases: [(String?, SentenceGate.Tier)] = [
        // 刚性：句号 / 问号 / 叹号收尾
        ("好的好的你你收听完你发我一下。", .rigid),
        ("这个我我想确认一下这个灯类是过去已经在用的吗 ？", .rigid),
        ("就按这个来吧！", .rigid),
        // 收尾的引号/括号不参与判断
        ("他说「明天再说。」", .rigid),
        ("行吧，先这样。”", .rigid),
        // 弱：逗号 / 省略号收尾（日志原话）
        ("这个呢一级代码有好像我现看啊 ，我就我…", .comma),
        ("还有那个改版稿的时间 ，", .comma),
        // 无标点：判断不了（日志原话 + 常见短应声）
        ("啊 ，好的好的 ，你是你收集完", .plain),
        ("明白", .plain),
        ("", .plain),
        (nil, .plain),
    ]

    /// (最后一条定稿, comma/plain 两个旋钮, 期望等待秒数)
    private static let waits: [(String?, TimeInterval, TimeInterval, TimeInterval)] = [
        ("说完了。", 2, 5, 0),          // 刚性不等
        ("还没说完啊 ，", 2, 5, 2),      // 弱：等 commaWait
        ("啊 ，好的好的 ，你是你收集完", 2, 5, 5),  // 无标点：等 plainWait
        (nil, 2, 5, 5),
        ("还没说完啊 ，", 3, 8, 3),      // 旋钮接了配置
        ("明白", 3, 8, 8),
    ]

    static func run() -> Int32 {
        var failed = 0
        for (i, c) in cases.enumerated() {
            let got = SentenceGate.tier(of: c.0)
            let ok = got == c.1
            if !ok { failed += 1 }
            print("\(ok ? "✓" : "✗") 用例 \(i + 1)  分级=\(got.label)  期望=\(c.1.label)  「\(c.0?.prefix(18) ?? "")」")
        }
        for (i, w) in waits.enumerated() {
            let got = SentenceGate.wait(forNewest: w.0, commaWait: w.1, plainWait: w.2)
            let ok = got == w.3
            if !ok { failed += 1 }
            print("\(ok ? "✓" : "✗") 等待 \(i + 1)  「\(w.0?.prefix(14) ?? "")」（弱 \(w.1)s / 无标点 \(w.2)s）→ \(got)s  期望 \(w.3)s")
        }
        print(failed == 0 ? "断句闸门自检全部通过" : "断句闸门自检有 \(failed) 项没过")
        return failed == 0 ? 0 : 1
    }
}
