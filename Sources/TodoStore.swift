import Foundation
import AppKit

/// 大模型吐出来的一条待办。
///
/// 与 `TodoItem` 的区别只有一个：`seq` 可空。
/// **非空 = 这一条是现有列表里的第 N 条，把它补全；空 = 这是新听出来的一条。**
/// 这个约定是「念序号改字段」能成立的全部基础。
struct ExtractedTodo: Codable, Equatable {
    var seq: Int?
    var action: String
    var time: String?
    var location: String?
    var person: String?
    var artifact: String?
    var artifactDesc: String?
    var evidence: String?

    /// 整条作废（「第 3 条不做了」）。删除只有这一条路 ——
    /// 「字段全空」不算，那是模型没听到。
    var deleted: Bool?
    /// 明确作废的字段（「时间不用卡了」→ `["time"]`）。
    /// 和「没听到」是两回事，提示词里专门分了条讲。
    var clearFields: [String]?

    enum CodingKeys: String, CodingKey {
        case seq, action, time, location, person, artifact, artifactDesc, evidence
        case deleted, clearFields
    }

    /// `clearFields` 里认得出的字段。认不出的丢掉（模型偶尔写中文名或写错）。
    var clears: Set<TodoItem.Field> {
        Set((clearFields ?? []).compactMap { raw in
            if let f = TodoItem.Field(rawValue: raw) { return f }
            return TodoItem.Field.allCases.first { $0.label == raw }
        })
    }

    /// 空串一律归一成 nil —— 模型经常用 "" 表示「没听到」，别让它覆盖掉旧值
    var normalized: ExtractedTodo {
        func n(_ s: String?) -> String? {
            guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // 模型偶尔会用这些占位符表示「空」，同 "" 处理
            //（「?时?分」光杆一个没有日期，也等于没听到时间）
            if t == "—" || t == "-" || t == "?时?分" || t == "N/A" || t == "无" || t == "未知" || t == "null" {
                return nil
            }
            return t
        }
        return ExtractedTodo(seq: seq, action: n(action) ?? action,
                             time: n(time).map(Self.timeSlotFixed),
                             location: n(location), person: n(person),
                             artifact: n(artifact), artifactDesc: n(artifactDesc),
                             evidence: n(evidence),
                             deleted: deleted, clearFields: clearFields)
    }

    /// 时分槽的本地护栏：**没有具体时刻 → 写占位 `?时?分`**，不留空、不写横杠。
    ///
    /// 提示词已经这么要求了，这里是兜底 —— 模型的老习惯是写全角横杠，
    /// 或者干脆把时分槽省掉。「?时?分」是给眼睛看的「待补时刻」：
    /// 横杠和空白都会被读成「这条没有时间」，而它其实是**时刻没定的待办**，
    /// 两回事。定不出日子、原样留的说法（「尽快」）不碰。
    static func timeSlotFixed(_ t: String) -> String {
        var s = t
        // 旧口径的全角横杠 → 占位符（带空格、不带空格都收）
        s = s.replacingOccurrences(of: " —", with: " ?时?分")
        s = s.replacingOccurrences(of: "—", with: "?时?分")
        // 已经有占位符，或说到了几点几分（含「:」）→ 不动
        if s.contains("?时?分") || s.contains(":") { return s }
        // 开头是日期（YYYY-MM-DD）却缺时分槽 → 在日期后补上占位
        if let r = s.range(of: #"^\d{4}-\d{1,2}-\d{1,2}"#, options: .regularExpression) {
            s = String(s[..<r.upperBound]) + " ?时?分" + s[r.upperBound...]
        }
        return s
    }

}

/// 自己写解码：JSON 里的值大部分可缺。
///
/// 最要紧的是 `action` —— 它本该是必填，但「整条删除」的条目模型常常只给
/// `seq` 和 `deleted`，连 `action` 键都不给（实测跑出来过）。缺一个键就让
/// **整包**结果解析失败的话，这一轮听到的东西全丢，代价太大。
///
/// 放在 extension 里是有意的：写在 struct 体里会把逐成员初始化器顶掉，
/// 而 `normalized` 正靠它重建条目。
extension ExtractedTodo {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        /// 读不出来（缺键 / null / 类型不对）一律给 nil
        func opt<T: Decodable>(_ t: T.Type, _ k: CodingKeys) -> T? {
            guard let v = try? c.decodeIfPresent(t, forKey: k) else { return nil }
            return v
        }

        seq          = opt(Int.self, .seq) ?? opt(String.self, .seq).flatMap(Int.init)
        action       = opt(String.self, .action) ?? ""
        time         = opt(String.self, .time)
        location     = opt(String.self, .location)
        person       = opt(String.self, .person)
        artifact     = opt(String.self, .artifact)
        artifactDesc = opt(String.self, .artifactDesc)
        evidence     = opt(String.self, .evidence)
        // 布尔偶尔会被写成字符串
        deleted      = opt(Bool.self, .deleted)
            ?? opt(String.self, .deleted).map { $0 == "true" || $0 == "是" }
        clearFields  = opt([String].self, .clearFields)
    }
}

/// 一轮抽取动过什么。控制器靠它决定「视口滚到哪一条、哪几条整行闪一下」。
struct ApplyResult: Equatable {
    /// 新增条目在 `TodoStore.todos` 里的下标（升序）
    var added: [Int] = []
    /// 被补全的条目下标（升序）
    var updated: [Int] = []
    /// 被标为删除的条目下标（升序）。
    ///
    /// 这些条目**这会儿还在列表里** —— 要整块红一下再走（见 `TodoItem.deleting`），
    /// 所以不算「动过」：不参与整行闪和聚焦滚动，删除的红块本身就是它的反馈。
    var deleted: [Int] = []

    /// 这一轮动过的全部条目，按列表顺序。
    /// **聚焦取第一个**：一次抽取新增的条目必然连在列表末尾，锚在第一个上，
    /// 往下读就是这一批的全部；而单条补全（「待办 1 的地点改成会议室 B」）
    /// 也只会有它自己。
    var changed: [Int] { (added + updated).sorted() }
    var isEmpty: Bool { added.isEmpty && updated.isEmpty && deleted.isEmpty }
}

/// 故障提示底下那颗按钮要干的事。
///
/// 提示如果只说「没有权限」，用户下一步必然是去猜怎么给 ——
/// 有按钮的故障才算真的指了条路。
enum ProblemAction: Equatable {
    /// 打开设置窗口（没配 API Key 时）—— 填 key 的正路是设置框，
    /// 配置文件还留着，但降级成逃生舱，不再是按钮指向的地方
    case openSettings
    /// 打开系统设置里「录制电脑音频」的开关页（没授权时）
    case grantAudioCapture

    var title: String {
        switch self {
        case .openSettings:        return "去设置"
        case .grantAudioCapture:   return "去授权"
        }
    }
}

/// 待办仓库。**纯内存，不落盘**——关掉工具就清空，下次启动从空列表开始。
///
/// 序号分配策略是这里最要紧的一条：**单调递增，分配后不回收、不重排**。
/// 合并掉一条会留下号段缺口，这是刻意接受的——序号一旦被人在会上说出口，
/// 就不能再变。只有「清空」才让它归零重来。
final class TodoStore: ObservableObject {

    @Published private(set) var todos: [TodoItem] = []

    /// 是否正在监听（驱动把手上的红点慢闪）
    @Published var listening = false

    /// **这次打开 app 以来**大模型回包的累计 token（标题栏「大脑 + 数字」）。
    /// 涨的时机只有一处：抽取真的拿到了回包（Listener 里 `addTokens`）。
    /// 「清空」不清它 —— 它记的是本轮运行烧掉的量，不是清单的属性；重启才归零
    @Published private(set) var totalTokens = 0

    func addTokens(_ n: Int) {
        guard n > 0 else { return }
        totalTokens += n
    }

    /// 标题栏右侧那行字：监听计时 / 模型下载进度 / 报错。
    /// 空字符串 = 不显示。
    @Published var statusText = ""
    @Published var statusIsWarning = false

    /// 刚复制过的条目 id，整行短暂变绿 + 浮出「已复制」徽章
    @Published var copiedID: String?

    /// 刚被抽取动过（新增或被补全）的条目 id，整行短暂高亮。
    /// 与 `copiedID` 同一路数，由控制器在面板展开时通过 `flash(_:)` 触发。
    @Published private(set) var highlighted: Set<String> = []

    /// 最近一轮抽取的结果。控制器订阅它来「滚过去 + 闪一下」——
    /// 做成 store 的状态而不是让调用方自己处理，是为了**谁调 apply 都一样**：
    /// 抽取链路还没接上，将来从哪儿触发都自动带上这个反馈。
    @Published private(set) var lastApply = ApplyResult()

    /// 面板中间的故障提示（没配 API Key、没权限、识别器起不来…）。
    /// 与 statusText 的分工：statusText 是「现在在干什么」，problem 是「干不了了」。
    @Published var problem: String?
    /// 故障提示底下的按钮（有些故障有明确的下一步，有些只能靠人自己处理）
    @Published var problemAction: ProblemAction?

    private var nextSeq = 1
    private var copyClearWork: DispatchWorkItem?
    private var touchedClearWork: DispatchWorkItem?
    private var highlightClearWork: DispatchWorkItem?
    private var ghostSweep: DispatchWorkItem?
    private var removalWork: DispatchWorkItem?

    /// 「划掉的字段 / 删掉的条目」在屏幕上停留多久。
    /// 太长会让人以为操作没生效，太短看不清 —— 一秒半左右刚好够读一行字。
    static let removalSeconds: TimeInterval = 1.4

    init() {}

    // MARK: - 派生状态

    var newCount: Int { todos.filter(\.isNew).count }

    /// 把手/外框的提醒级别
    var alertLevel: AlertLevel {
        if newCount > 0 { return .new }
        return listening ? .listening : .idle
    }

    /// 面板高度要跟着行数走（不限条数，装不下时由 UI 层转成内部滚动）
    var rowCount: Int { max(2, todos.count) }

    // MARK: - 展开即已读

    func acknowledge() {
        guard newCount > 0 else { return }
        for i in todos.indices { todos[i].isNew = false }
    }

    // MARK: - 增删

    /// 清空列表。序号归零，重新从 1 开始。
    func clear() {
        todos.removeAll()
        nextSeq = 1
        copiedID = nil
        highlighted = []
        lastApply = ApplyResult()
        touchedClearWork?.cancel()
        highlightClearWork?.cancel()
        ghostSweep?.cancel()
        removalWork?.cancel()
    }

    /// 仅供 `--preview` 与自检使用：直接塞入假数据，绕过抽取链路。
    func seed(_ items: [TodoItem]) {
        todos = items
        nextSeq = (items.map(\.seq).max() ?? 0) + 1
    }

    /// 把大模型这一轮的结果并进来。
    ///
    /// 只增不删：模型没提到的条目原样留着。让它「全量回写」是为了补全字段，
    /// 不是让它当删除指令——它偶尔漏掉一条，不该等于把人家听来的待办抹掉。
    @discardableResult
    func apply(_ incoming: [ExtractedTodo]) -> ApplyResult {
        var result = ApplyResult()
        var claimed = Set<Int>()          // 本轮已经被认领的现有条目（按数组下标）

        for raw in incoming {
            let item = raw.normalized
            AppDebug.log("[merge] 收到 seq=\(item.seq.map(String.init) ?? "nil")  \(item.action)")

            // 1) 明确带了序号 → 落到那一条上
            if let seq = item.seq {
                if let idx = todos.firstIndex(where: { $0.seq == seq }) {
                    claimed.insert(idx)
                    if item.deleted == true {
                        markDeleting(idx)
                        result.deleted.append(idx)
                    } else if merge(item, into: idx) {
                        result.updated.append(idx)
                    }
                    continue
                }
                // 序号对不上（模型编的 / 列表已清空）→ 当新条目处理，别丢
                AppDebug.log("[merge]   序号 \(seq) 对不上任何现有条目，按新条目处理")
            }

            // 删除必须指名道姓（规则 9）：指不到任何现有条目的 deleted 条目 ——
            // 序号编的、列表已清空、或者干脆没带 seq —— 落到「新条目」分支会
            // 凭空建出一条「幽灵待办」（实测还会把后面所有序号整体顶偏）。
            // 删除是破坏性的，指不准就不动：宁可多留，不能建错
            if item.deleted == true {
                AppDebug.log("[merge]   deleted 但没有可落点的 seq，丢弃")
                continue
            }

            // 2) 新条目 → 先跟现有条目比一遍，够像就并入而不是新增
            if let idx = bestMatch(for: item, excluding: claimed) {
                claimed.insert(idx)
                AppDebug.log("[merge]   与 #\(todos[idx].seq) 判为同一条，并入")
                if merge(item, into: idx) { result.updated.append(idx) }
                continue
            }

            // 3) 真的是新的一条。但两种「不像一条待办」的都要拦掉：
            //    没有内容的新条目（模型偶尔会把一句纯补充当成新条目吐出来），
            //    以及只有一个字的残句 —— 线上真跑出来过 action 就一个「买」的
            //    条目：半句话被转写定稿，模型照着抽了一条。
            //    判据收得很窄（归一化后不足两个字才拦）：「发版」「回款」这类
            //    短动作在中文里本来就是完整的，宁可漏拦，不可误杀真待办
            guard !item.action.isEmpty, TodoItem.normalize(item.action).count >= 2 else {
                AppDebug.log("[merge]   不成条的条目（「\(item.action)」），丢弃")
                continue
            }
            var t = TodoItem(seq: nextSeq,
                             action: item.action,
                             time: item.time,
                             location: item.location,
                             person: item.person,
                             artifact: item.artifact,
                             artifactDesc: item.artifactDesc,
                             evidence: item.evidence,
                             createdAt: Date(),
                             updatedAt: Date(),
                             isNew: true,
                             touched: [])
            t.touched = Set(TodoItem.Field.allCases.filter { t.value($0) != nil })
            nextSeq += 1
            todos.append(t)
            result.added.append(todos.count - 1)
        }

        // 去重：同一条被同一个包里的两条结果先后改过（模型偶尔会这么干）时，
        // updated 里会出现两次同一个下标
        result.updated = Array(Set(result.updated)).sorted()
        result.deleted = Array(Set(result.deleted)).sorted()
        // 新增的条目也带 touched（六项字段全亮），不排清理的话会一直亮着
        if !result.isEmpty { scheduleTouchedClear() }
        // 这一轮有没有划掉字段（merge 在里头留了「尸体」）→ 排一次清扫。
        // 扫全表而不是让 merge 逐个回报，是因为清扫本身幂等，多扫一眼不值几个字
        if todos.contains(where: { !$0.ghost.isEmpty }) { scheduleGhostSweep() }
        lastApply = result
        return result
    }

    /// 把一条抽取结果补进第 idx 条。返回是否真的改动了什么。
    /// 规则：**新值非空才覆盖旧值**，空值一律不动（模型没听到 ≠ 原来记的错了）。
    private func merge(_ item: ExtractedTodo, into idx: Int) -> Bool {
        // 先在副本上改，最后一次性写回 —— 避免一路 `&todos[idx].xxx` 撞上独占访问检查
        var t = todos[idx]
        var changed = false
        var touched = t.touched
        var ghost = t.ghost

        // 又被提起来了（「第三条不做了」之后又接着说它）→ 把「正在删」撤回。
        // 撤错只是多留一条，删错是把人家的事弄丢了 —— 宁可多留
        let wasDeleting = t.deleting
        t.deleting = false

        /// 非空才覆盖。返回该字段的新值。
        func put(_ f: TodoItem.Field, _ new: String?, _ current: String?) -> String? {
            guard let new, new != current else { return current }
            touched.insert(f)
            changed = true
            ghost[f] = nil          // 新值来了，正在演的「划掉」作废
            return new
        }
        /// action 是非可空的（一条待办至少得有事要做）
        func putAction(_ new: String, _ current: String) -> String {
            guard new != current else { return current }
            touched.insert(.action)
            changed = true
            return new
        }

        // action 是非可空的，但模型的「补丁条目」不重述待办内容时会给 ""——
        // 那不是「把待办清空」，是「这条的待办没变」。
        // 不挡住的话，「待办 1 的地点改成会议室 B」会把第 1 条的事由一起抹掉。
        if !item.action.isEmpty {
            t.action = putAction(item.action, t.action)
        }
        t.time         = put(.time,         item.time,         t.time)
        t.location     = put(.location,     item.location,     t.location)
        t.person       = put(.person,       item.person,       t.person)
        t.artifact     = put(.artifact,     item.artifact,     t.artifact)
        t.artifactDesc = put(.artifactDesc, item.artifactDesc, t.artifactDesc)
        if let e = item.evidence, !e.isEmpty { t.evidence = e }

        // 明确作废的字段（「时间不用卡了」）：旧值留进 ghost 演一下红色删除线，
        // 模型里立刻清掉。action 不在其列 —— 「这条的事由作废」就是整条删除，
        // 不靠清字段表达，否则会剩一条没有事由的空壳
        for f in item.clears where f != .action {
            guard let old = t.value(f) else { continue }
            ghost[f] = old
            touched.remove(f)           // 划掉的不该同时亮「刚补全」的橙
            switch f {
            case .action:       break
            case .time:         t.time = nil
            case .location:     t.location = nil
            case .person:       t.person = nil
            case .artifact:     t.artifact = nil
            case .artifactDesc: t.artifactDesc = nil
            }
            changed = true
        }

        // 撤回「正在删」本身也是一次可见的变化（红块收回去），要报出去
        guard changed || wasDeleting else { return false }
        t.touched = touched
        t.ghost = ghost
        // 补全/修改也算「没看过」：面板收着的时候，角标数字也要跟着涨 ——
        // 会上改过哪条，回来一眼看得出。**同值重发到不了这里**（上面
        // changed 挡了），抽取每几秒一轮的全量复读不会把已读条目顶回未读
        t.isNew = true
        t.updatedAt = Date()
        todos[idx] = t
        return true
    }

    /// 跟现有条目做相似度比对，找最像的那条（够像才算）
    private func bestMatch(for item: ExtractedTodo, excluding claimed: Set<Int>) -> Int? {
        let key = TodoItem.normalize([item.action, item.time, item.location,
                                      item.person, item.artifact, item.artifactDesc]
            .compactMap { $0 }.joined(separator: " "))
        guard !key.isEmpty else { return nil }

        var best: (idx: Int, score: Double)?
        for (i, t) in todos.enumerated() where !claimed.contains(i) {
            let s = TodoStore.similarity(key, t.normalizedKey)
            if s > (best?.score ?? 0) { best = (i, s) }
        }
        guard let b = best, b.score >= TodoStore.mergeThreshold else { return nil }
        return b.idx
    }

    /// 够像就算同一件事。0.82 是保守值：宁可多出一条重复的让人自己删，
    /// 也不要把两件不同的事悄悄焊成一条。
    static let mergeThreshold = 0.82

    /// 字符二元组的 Dice 系数。中文按字符切就够用，不需要分词。
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        let A = bigrams(a), B = bigrams(b)
        guard !A.isEmpty, !B.isEmpty else { return 0 }
        let inter = A.intersection(B).count
        return 2.0 * Double(inter) / Double(A.count + B.count)
    }

    private static func bigrams(_ s: String) -> Set<String> {
        let chars = Array(s)
        guard chars.count >= 2 else { return Set(chars.map(String.init)) }
        var out = Set<String>()
        for i in 0..<(chars.count - 1) { out.insert(String(chars[i...i + 1])) }
        return out
    }

    // MARK: - 高亮淡出

    /// 让这几条整行闪一下。控制器在面板展开时收到变更后叫它。
    ///
    /// 和 `touched`（逐字段变色）分工不同：touched 回答「补了什么」，
    /// 整行高亮回答「刚才那句话落在哪一条上」—— 视口滚过之后尤其需要它，
    /// 否则一屏全是长得差不多的六行字段，根本认不出刚动的是哪条。
    func flash(_ indices: [Int]) {
        let ids = indices.compactMap { todos.indices.contains($0) ? todos[$0].id : nil }
        guard !ids.isEmpty else { return }
        highlighted.formUnion(ids)
        highlightClearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.highlighted = [] }
        highlightClearWork = w
        // 比 touched 的 2 秒稍长：字段色淡下去之后整行再收，有层「慢慢退开」的层次
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: w)
    }

    // MARK: - 删除的演出

    /// 标成「正在删」：整块先红一下，`removalSeconds` 之后真移走。
    /// **不立刻移走**，就是为了让「变化」被看见 —— 列表无声无息少一条，
    /// 开会的人是察觉不到的。
    private func markDeleting(_ idx: Int) {
        guard !todos[idx].deleting else { return }
        AppDebug.log("[merge]   #\(todos[idx].seq) 标为删除，\(Self.removalSeconds)s 后移走")
        todos[idx].deleting = true
        todos[idx].updatedAt = Date()
        scheduleRemoval()
    }

    /// 到点把所有标了删除的条目移走。
    ///
    /// 每次新标记都**取消重排**：这样每一条都保证红满 `removalSeconds`，
    /// 不会出现「刚标上就赶上上一轮的定时器」而被瞬间抹掉。代价是早标的那条
    /// 会多红一会儿 —— 比「动画没看见」划算。
    private func scheduleRemoval() {
        removalWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let n = self.todos.filter(\.deleting).count
            self.todos.removeAll { $0.deleting }
            AppDebug.log("[merge]   移走 \(n) 条")
        }
        removalWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.removalSeconds, execute: w)
    }

    /// 划掉的字段演完红色删除线，到点真正消失（`ghost` 清空）。重排逻辑同上。
    private func scheduleGhostSweep() {
        ghostSweep?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for i in self.todos.indices where !self.todos[i].ghost.isEmpty {
                self.todos[i].ghost = [:]
            }
        }
        ghostSweep = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.removalSeconds, execute: w)
    }

    /// 把进行中的变化反馈一次性落定：划掉的字段真抹掉、删掉的条目真移走。
    ///
    /// 自检里每轮合并完都叫一次 —— 那是个无头环境，`asyncAfter` 排的动画
    /// 永远不会到点，而断言盯的是**落定之后**的状态（「删完还剩几条」）。
    func settle() {
        ghostSweep?.cancel(); ghostSweep = nil
        removalWork?.cancel(); removalWork = nil
        for i in todos.indices where !todos[i].ghost.isEmpty { todos[i].ghost = [:] }
        todos.removeAll { $0.deleting }
    }

    /// 「刚被补全的字段」亮 2 秒就够了，亮久了反而看不出哪条是新的
    private func scheduleTouchedClear() {
        touchedClearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            for i in self.todos.indices where !self.todos[i].touched.isEmpty {
                self.todos[i].touched = []
            }
        }
        touchedClearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: w)
    }

    // MARK: - 复制

    /// 点击一行 = 复制这一条的六字段多行文本
    func copy(_ todo: TodoItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(todo.copyText, forType: .string)
        AppDebug.log("[copy] #\(todo.seq) → \(todo.copyText.replacingOccurrences(of: "\n", with: " / "))")

        copiedID = todo.id
        copyClearWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.copiedID = nil }
        copyClearWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }

    /// 全部复制：每条之间空一行，方便直接粘进微信/飞书
    func copyAll() {
        guard !todos.isEmpty else { return }
        let text = todos.map(\.copyText).joined(separator: "\n\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        AppDebug.log("[copy] 全部 \(todos.count) 条")
    }
}
