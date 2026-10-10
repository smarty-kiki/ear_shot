import Foundation

/// 抽取链路：把「已有待办清单 + 最近的转写」发给 DeepSeek，拿回增补后的条目。
///
/// 设计上就一个来回、一次全量：**每次请求都带上完整的已有清单**（带序号），
/// 让模型在「看得见上下文」的前提下输出。
/// 这不是为了省事 —— 会上人是照着屏幕上那个序号继续讨论的
/// （「待办 1 的地点改成会议室 B」），转写里根本没有「地点」以外的线索，
/// 清单不进提示词，这句话就落不到任何一条上。见 `ExtractionPrompt`。
enum Extractor {

    // MARK: - 错误

    enum Failure: LocalizedError {
        case noAPIKey
        case badURL(String)
        case http(Int, String)
        case api(String)
        case emptyResponse
        case decode(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "还没配 API Key —— 点下面「去设置」，把 DeepSeek 的 Key 填上"
            case .badURL(let u):
                return "baseURL 不合法：\(u)"
            case .http(let code, let body):
                return "接口返回 HTTP \(code)：\(body)"
            case .api(let m):
                return "接口报错：\(m)"
            case .emptyResponse:
                return "接口返回了空内容"
            case .decode(let m):
                return "返回的内容解析不了：\(m)"
            }
        }
    }

    // MARK: - 请求 / 响应

    private struct Message: Codable { let role: String; let content: String }
    private struct ResponseFormat: Codable { let type: String }
    private struct Thinking: Codable { let type: String }

    private struct ChatRequest: Codable {
        let model: String
        let messages: [Message]
        /// nil = 不设（服务端按默认文本格式回）—— 测试连接的最小请求走这条，
        /// 少一个字段就少一种「通/不通」之外的失败可能
        let response_format: ResponseFormat?
        let thinking: Thinking?
        let temperature: Double
        let max_tokens: Int
        let stream: Bool
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Msg: Decodable { let content: String? }
            let message: Msg
        }
        struct APIError: Decodable { let message: String }
        /// 回包里的 token 用量（OpenAI 兼容口径）。有的端点不给 total，
        /// 缺席时拿分项加起来 —— 面板上那个数字宁可是和的，不能是 0
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
            var total: Int { total_tokens ?? (prompt_tokens ?? 0) + (completion_tokens ?? 0) }
        }
        let choices: [Choice]?
        let error: APIError?
        let usage: Usage?
    }

    private struct Payload: Decodable {
        let todos: [ExtractedTodo]?
    }

    /// 一次抽取的产出。`tokens` 只在**拿到回包**之后才算数 ——
    /// 网络挂了、被拦了，就是没消耗，不该涨
    struct Outcome {
        var items: [ExtractedTodo]
        var tokens: Int
    }

    /// 从一条回包 JSON 里解出 token 用量。抽出自检走同一段解码，
    /// 「自检验的」和「线上跑的」才不是两回事
    static func usageTokens(in data: Data) throws -> Int {
        try JSONDecoder().decode(ChatResponse.self, from: data).usage?.total ?? 0
    }

    // MARK: - 抽取

    /// 一次抽取。
    /// - Parameters:
    ///   - window: 最近的转写（已按 `[我] / [对方]` 标注好说话人）
    ///   - existing: 已经记录下来的待办，带序号
    ///   - today: 「今天」是哪天。时间换算的基准，`--extract --today` 能钉死它
    /// - Returns: 新增或有改动的条目（模型只回这些，见提示词规则 7），
    ///   连同这次回包的 token 用量（面板标题栏那个数字的口粮）
    static func extract(window: String,
                        existing: [TodoItem],
                        config: Config,
                        today: Date = Date(),
                        session: URLSession = .shared) async throws -> Outcome {
        let key = config.resolvedAPIKey
        guard !key.isEmpty else { throw Failure.noAPIKey }
        guard let url = config.chatURL else { throw Failure.badURL(config.baseURL) }

        let body = ChatRequest(
            model: config.model,
            messages: [
                Message(role: "system", content: ExtractionPrompt.system),
                Message(role: "user", content: ExtractionPrompt.user(window: window,
                                                                     existing: existing,
                                                                     today: today,
                                                                     myName: config.resolvedMyName)),
            ],
            response_format: ResponseFormat(type: "json_object"),
            // 关掉思考是「准实时」能成立的前提：开着思考，一次简单抽取要烧
            // 900+ 个 token、耗时翻好几倍。配置里默认就是 disabled。
            thinking: config.thinking.isEmpty ? nil : Thinking(type: config.thinking),
            temperature: 0.2,
            max_tokens: 2048,
            stream: false)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)

        AppDebug.log("[extract] 请求 \(config.model)：已有 \(existing.count) 条，窗口 \(window.count) 字")
        let t0 = Date()

        let (data, resp) = try await session.data(for: req)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)

        guard let http = resp as? HTTPURLResponse else { throw Failure.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            AppDebug.log("[extract] HTTP \(http.statusCode)  \(ms)ms  \(text.prefix(300))")
            throw Failure.http(http.statusCode, String(text.prefix(300)))
        }

        let chat: ChatResponse
        do {
            chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        } catch {
            throw Failure.decode(error.localizedDescription)
        }
        if let e = chat.error { throw Failure.api(e.message) }

        guard let content = chat.choices?.first?.message.content, !content.isEmpty else {
            throw Failure.emptyResponse
        }
        AppDebug.log("[extract] \(ms)ms  回包 \(content.count) 字：\(content.prefix(600))")

        // 模型偶尔会在 json 外面裹一层 ```json ... ```，削掉再解
        let json = stripFence(content)
        guard let jsonData = json.data(using: .utf8) else { throw Failure.decode("不是 utf8") }
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: jsonData)
        } catch {
            AppDebug.log("[extract] 解析失败，原文：\(content.prefix(400))")
            throw Failure.decode(error.localizedDescription)
        }
        let tokens = chat.usage?.total ?? 0
        AppDebug.log("[extract] token：这轮 \(tokens)")
        let items = (payload.todos ?? [])
            .map(\.normalized)
            .map { $0.withExpandedDates(today: today) }
        return Outcome(items: items, tokens: tokens)
    }

    /// 把文本里的相对日期就地展开成具体日子 —— 规则 11 的**本地兜底**。
    ///
    /// 为什么要兜底：2026-10-10 线上实测（用户会话 + 调试日志实锤），模型十次里
    /// 总有一两次只记得换算 action / time，把「要是在**明天**大概晚上7:00出发的票」
    /// 原样塞进 artifactDesc —— 而说明是给人看、给人粘的，离开这场会「明天」
    /// 就没有参照系，用户看到的就是「待办正文里还有明天」。
    ///
    /// **只动确定性能算的**：今天/明天/后天/大后天/明后天。`下周X` 这类星期
    /// 运算交给提示词（本地硬算星期一旦口径差一天，错得还看不出来）。
    /// 「过几天」这种算不出的原样留。同年写「10月11日」，跨年带年份。
    /// **evidence 是原话，绝不碰** —— 调用方只对 action / artifact / artifactDesc 调它。
    static func expandRelativeDates(in text: String, today: Date) -> String {
        guard !text.isEmpty else { return text }
        let cal = Calendar(identifier: .gregorian)
        func day(_ offset: Int) -> String {
            let d = cal.date(byAdding: .day, value: offset, to: today) ?? today
            let c = cal.dateComponents([.year, .month, .day], from: d)
            let md = "\(c.month ?? 1)月\(c.day ?? 1)日"
            return c.year == cal.component(.year, from: today) ? md : "\(c.year ?? 0)年" + md
        }
        var s = text
        // 长的先换：「大后天」不能被「后天」吃掉，「明后天」也不能
        s = s.replacingOccurrences(of: "大后天", with: day(3))
        s = s.replacingOccurrences(of: "明后天", with: "\(day(1))或\(day(2))")
        s = s.replacingOccurrences(of: "明天", with: day(1))
        s = s.replacingOccurrences(of: "后天", with: day(2))
        s = s.replacingOccurrences(of: "今天", with: day(0))
        return s
    }

    /// 设置窗口「测试连接」：用草稿里的 key / 地址 / 模型打一次最小请求。
    ///
    /// 不求抽出任何东西，只为回答「这组配置能不能通」：
    /// 不带 response_format、max_tokens 压到 1、超时收到 15s ——
    /// 把一切能省的东西都省掉，剩下通或不通。
    /// thinking 还是按生产口径发 disabled：省时间，也顺带验证这个字段
    /// 不会把这个地址打挂（抽取时也要发它，这里打挂了那边一样挂）。
    static func testConnection(config: Config, session: URLSession = .shared) async throws -> String {
        let key = config.resolvedAPIKey
        guard !key.isEmpty else { throw Failure.noAPIKey }
        guard let url = config.chatURL else { throw Failure.badURL(config.baseURL) }

        let body = ChatRequest(
            model: config.model,
            messages: [Message(role: "user", content: "ping")],
            response_format: nil,
            thinking: config.thinking.isEmpty ? nil : Thinking(type: config.thinking),
            temperature: 0,
            max_tokens: 1,
            stream: false)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(body)

        AppDebug.log("[test] 测试连接 \(config.model) @ \(config.baseURL)")
        let t0 = Date()
        let (data, resp) = try await session.data(for: req)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)

        guard let http = resp as? HTTPURLResponse else { throw Failure.emptyResponse }
        // 401 单独说人话：这是设置窗口里最常撞上的一种失败，
        // 把「HTTP 401：{一坨 json}」原样糊到用户脸上纯属帮倒忙
        if http.statusCode == 401 {
            throw Failure.api("API Key 无效（401）—— 看看有没有贴全、有没有多余空格")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw Failure.http(http.statusCode, String(text.prefix(200)))
        }
        // 200 也可能裹着 {"error":…}（有的兼容端点这么干）
        if let chat = try? JSONDecoder().decode(ChatResponse.self, from: data),
           let e = chat.error {
            throw Failure.api(e.message)
        }
        return "\(config.model) 响应正常（\(ms)ms）"
    }

    private static func stripFence(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("```") else { return t }
        if let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
        if let r = t.range(of: "```", options: .backwards) { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension ExtractedTodo {
    /// 规则 11 的本地兜底：action / artifact / artifactDesc 里的相对日期就地展开。
    /// **time 交给提示词管**（模型回回都转对，且它有星期口径的上下文，见 expandRelativeDates 的说明）；
    /// **evidence 是原话，一个字都不许动**。
    func withExpandedDates(today: Date) -> ExtractedTodo {
        var t = self
        t.action = Extractor.expandRelativeDates(in: action, today: today)
        t.artifact = artifact.map { Extractor.expandRelativeDates(in: $0, today: today) }
        t.artifactDesc = artifactDesc.map { Extractor.expandRelativeDates(in: $0, today: today) }
        return t
    }
}

// MARK: - 提示词

/// 提示词单独放一个 enum，因为它是这个项目里最需要反复调的东西，
/// 而且 `--extract` 自检要能把它打出来看。
enum ExtractionPrompt {

    static let system = """
    你是会议记录助手。你的工作是从一段会议转写里找出「待办」，
    并把新听到的信息合并到已经记录下来的待办上。

    ## 一条「待办」是什么
    一件**需要有人去做**的事。六个字段：

    - action（待办）：要做什么，一句话说清楚。必填。
    - time（时间）：**这件事什么时候做、什么时候交**（行动时限）——
      **一律换算成具体的日子**，格式 `YYYY-MM-DD HH:MM（周X）`。
      「今天」是哪天见下方用户消息的开头，相对说法以它为准。
      - **一句里出现两个时间时，time 只收行动的那个**：「今天买明天的票」→
        time 是**今天**（`2026-10-10`，买票这件事今天办），**不是明天** ——
        明天是票的日期，那属于 action 的内容。
      - 只说了对象日期、没说哪天办（「买明天的票」）→ 这件事得赶在那天之前办，
        time 填那个日期：`2026-10-11 ?时?分（周六）`。
      - 说到了几点几分 → 写成 24 小时制：「明天下午三点」→ `2026-10-11 15:00（周日）`
      - **没说到具体几点 → 时分槽写 `?时?分`**（永远不留空、不写横杠）：
        「下周五之前」→ `2026-10-16 ?时?分（周五）`
      - 只有时分没有日期（「下午三点前给我」）→ 按最近的那个三点算，
        已经过了就顺延到明天。
      - 相对说法怎么算：「下周X」= 下一个自然周（周一开头）的周X；
        「这周X / 本周X」= 当前自然周；「周X」不带修饰 = 最近的那个周X。
      - 实在定不出具体日子（「尽快」「有空的时候」「回头」）→
        原样留着那几个字（`尽快`），不要硬凑一个日期出来。
      - **话里说到了时间的，这一格必须填。**「周五之前」「明天下午」是这条
        待办的死线，不是可有可无的修饰 —— 漏填等于把会上的决定丢了。
        只有整句确实没有任何时间信息才留空（规则 2 管的是「别编」，
        不是「听到了也不填」）。
    - location（地点）：在哪儿做。线上会议也写「线上」。
    - person（人物）：谁去做、找谁。可以是人名、岗位（法务、运维）、群体（产品同学）。
      听到「我」「你」这类指代时，按用户消息「说话人」一节的口径落到具体的人：
      配了名字就落名字，没配才记 `我`。**两路的「我」不是一个「我」** ——
      那一节讲了怎么判断，照着分，别混。
    - artifact（输出物）：这件事要产出的东西（PPT、表格、文档、代码、报告…）。
      用会上说的那个**完整说法**，别压成光杆名词：「一版 Q3 复盘 PPT」→ `Q3 复盘 PPT`，
      不要只写「PPT」（粘到别处看不出是哪个 PPT）；「客户反馈表」这种本来就完整的原样留着。
    - artifactDesc（说明）：**布置这件事时提到的要求、原则和补充信息**。
      包括两类，都要收：
      1. 对输出物的要求 —— 页数、范围、格式、必须包含什么
         （「12 页左右」「只要华东区的」「要带上个季度的数据」）；
      2. 做这件事要守的原则、约束、注意事项 ——
         （「别铺得太开」「先跟法务确认」「口径要跟上次一致」「时间别超过半小时」）。
      这一条经常是会上最有价值的部分，别漏。

    ## 规则
    1. 只记「需要有人去做的事」。闲聊、已经做完的事、纯陈述、纯提问都不要记。
       半截的转写碎片同样不要记（「嗯，买」这种只有一两个字的残句）——
       action 必须能独立看懂，单独拿给别人看也得知道要干什么。拿不准就不记。
    2. **没听到的字段一律填空字符串 ""，绝对不要编造、不要推测、不要用
       「待定」「未知」「稍后确认」这类占位词。** 宁可空着 ——
       后面听到会补上，编错了会误导人。
    3. **已经记录下来的待办，如果这次听出了新信息，把它的 seq 原样带回**，
       只填这次新听到或更正的字段，序号绝对不能改。
       补充信息经常单独成句（「下周五之前发出来啊」「记得抄送老王」）——
       只要明显是在说刚记下的那件事（紧挨着它，或者带「那个…」「刚才说的」），
       就补到那条上；这句话里没有动词，不代表它不是补充。
    4. **转写里出现「待办 3」「第 3 条」「第三条」这类说法，一律指
       上面清单里序号 3 的那条**，把新信息补到那一条上，不要新建。
       纯靠语义的指代（「那个 PPT 的地点」「刚才说的那个会」）也要能对上已有的那条。
    5. 听出来的其实是已有某条同一件事 → 合并到那一条，不要新增。
    6. 真的是新的一件事 → seq 填 null。
    7. **只返回「新增的」和「有改动的」条目。**
       上面清单里没被提到、也没有变化的条目，不要出现在结果里。
    8. evidence（依据）填转写里支撑这条的那句原话，尽量短，一句话。
    9. **会上明确说某条不做了 / 取消了 / 不用管了**（「第三条不弄了」「PPT 那个
       取消吧」）→ 把那条的 seq 带上，deleted 填 true，其余字段全都留空。
       删除只能用这一个办法表达，别指望「字段全空」能表达删除 ——
       那只会被当成没听到。
    10. **明确说某条里的某个信息作废了**（「时间不用卡了」「地点先不用定」
        「负责人再说吧」）→ 带上 seq，把要作废的字段名放进 clearFields
        （["time"] / ["location"] / ["person"] / ["artifact"] / ["artifactDesc"]）。
        **这和「没听到」是两回事**：没听到就什么都不填，绝不能放进 clearFields ——
        那会把已经记下来的信息白白抹掉。拿不准的时候不填。
    11. **写进 action / artifact / artifactDesc 的相对时间词，就地换算成具体日期**。
        待办是要复制到别处去用的，离开这场会，「明天」就没有参照系了：
        - 「今天买明天的票」→ action 写 `买10月11日的票`（今天 = 2026-10-10）。
        - **说明里嵌着的相对日期一样要换，哪怕整句是转述原话**：
          「要是在明天大概晚上 7:00出发的票」→ 说明写 `10月11日大概晚上7:00出发的票`。
        - 「下周二之后开会」→ 写 `10月13日之后开会`，`下周五之前` 同理。
        - 同年写「10月11日」，跨年写「2027年1月1日」。
        - 算不出确切日子的模糊说法（「过几天」「有空时」）保持原样，别硬凑。
        - evidence 是原话，一个字都不改。
        - **交卷前把 action / artifact / artifactDesc 再逐字扫一遍**：里面出现的
          每一个「今天 / 明天 / 后天 / 下周X」都必须已经落地成具体日期，一个都不许留。

    ## 输出
    只输出 json，不要任何别的文字：
    {"todos":[{"seq":null,"action":"","time":"","location":"","person":"","artifact":"","artifactDesc":"","evidence":"","deleted":false,"clearFields":[]}]}
    （seq 是整数或 null；deleted 和 clearFields 在不需要时省略或留空）
    """

    /// - Parameter myName: 「我」的名字（设置里配的）。空 = 没配。
    static func user(window: String, existing: [TodoItem], today: Date,
                     myName: String = "") -> String {
        let list = existing.isEmpty
            ? "（还没记下任何待办）"
            : existing.map(\.promptLine).joined(separator: "\n")
        return """
        ## 今天
        \(todaySection(today))

        ## 已经记录下来的待办
        \(list)

        ## 说话人
        \(speakerSection(myName))

        ## 最近的转写
        \(window)
        """
    }

    /// 「说话人」那一节：讲清 `[我] / [对方]` 的标注约定，以及「我」该落成什么。
    ///
    /// 关键是这里的**不对称**：两路的「我」不是一个「我」。麦克风那路
    /// （`[我]`）说的「我」是拿这个工具的人；电脑声音那路（`[对方]`）说的
    /// 「我」是对方自己 —— 配了名字之后，前者的「我」落成名字，
    /// 后者的「我」绝不能跟着落成名字，那是张冠李戴。
    /// 没配名字时退回记「我」：不如真名精确，但比空着强。
    static func speakerSection(_ myName: String) -> String {
        let head = "转写每行开头的 `[我]` 是说话人本人 —— 听这个会、用这个工具的人（麦克风那路）；"
            + "`[对方]` 是会上其他人（电脑声音那路）。"
        guard !myName.isEmpty else {
            return head + """

            （说话人没配名字。）判断 person 时：
            - `[我]` 说的「我」（自己揽下的活）→ 填 `我`；
            - 对方对着他说的「你」（没点名别人）→ 也填 `我`；
            - **`[对方]` 说的「我」指对方自己，不等于说话人** ——
              那就是对方揽了自己的活，没报名字就留空，别填「我」；
            - 点名给了具体的人（「老王，你下周五前给我一版 PPT」）→ 填那个名字，
              别被句子里那个「你」带偏。
            """
        }
        return head + """

        说话人的名字是：**\(myName)**。person 里不许出现「我」「你」这种指代，一律落到具体的人：
        - `[我]` 说的「我」（自己揽下的活）→ 填 `\(myName)`；
        - 对方对着他说的「你」（没点名别人）→ 也填 `\(myName)`；
        - **`[对方]` 说的「我」指对方自己，绝不等于说话人** ——
          对方没报名字就留空，别安上 `\(myName)`；
        - `[我]` 对对方说的「你」同理：不知道对方名字就留空；
        - 点名给了具体的人（「老王，你下周五前给我一版 PPT」）→ 填那个名字，
          别被句子里那个「你」带偏。
        """
    }

    /// 「今天」那一节：日期 + 几个高频相对说法**算好**的答案。
    ///
    /// 为什么替模型算：日期加减和星期推算它很容易差一周，而差一周的错
    /// 在结果里几乎看不出来（`2026-10-09` 和 `2026-10-16` 长得一模一样），
    /// 等人发现的时候会已经开完了。锚点给死，它只需要抄。
    static func todaySection(_ now: Date, calendar: Calendar = .current) -> String {
        var cal = calendar
        cal.firstWeekday = 2     // 一周从周一开始，「下周」才是中文里那个下周
        let names = ["日", "一", "二", "三", "四", "五", "六"]

        func label(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month, .day, .weekday], from: d)
            return String(format: "%04d-%02d-%02d（周%@）",
                          c.year ?? 0, c.month ?? 0, c.day ?? 0,
                          names[(c.weekday ?? 1) - 1])
        }

        var lines = [label(now)]
        if let tmr = cal.date(byAdding: .day, value: 1, to: now) {
            lines.append("- 「明天」= \(label(tmr))")
        }
        // 下周的周一 / 周五 —— 只是两个样本，用来说明「下周X」怎么数，
        // 别的星期几让模型照这个口径推
        if let nextWeek = cal.date(byAdding: .weekOfYear, value: 1, to: now) {
            var c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: nextWeek)
            c.weekday = 2
            if let mon = cal.date(from: c) { lines.append("- 「下周一」= \(label(mon))") }
            c.weekday = 6
            if let fri = cal.date(from: c) { lines.append("- 「下周五」= \(label(fri))") }
        }
        lines.append("- 上面没列到的说法，按同样的口径数")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 抽取节奏

/// 决定「什么时候真的去打一次 API」。
///
/// 两个触发条件，缺一不可：
///
/// - **安静触发**（debounce）：最后一句说完之后静了 `debounceSeconds` 就抽。
///   一句话说完了，待办大概率在这时候冒出来。
/// - **滞后触发**（staleness）：有人在连续说话、每句都把 debounce 重置掉，
///   这时候安静触发永远不响，一段没人打断的长发言期间列表会是空的。
///   所以有没抽过的文本拖过 `maxStalenessSeconds` 就强制抽一次。
///
/// 上面两个都可能触发得太密，再加一个 `minIntervalSeconds` 的硬下限兜底。
final class ExtractionScheduler {

    private let config: Config
    /// 真要跑的时候叫这个。调用方负责把结果并进 store。
    var onFire: (() -> Void)?

    private var debounce: DispatchWorkItem?
    private var stale: DispatchWorkItem?
    private var lastRunAt: Date?
    private var running = false

    /// 有没有「进来了但还没抽过」的文本
    private(set) var pending = false

    init(config: Config) { self.config = config }

    /// 来了一条定稿的转写
    func note() {
        dispatchPrecondition(condition: .onQueue(.main))
        pending = true

        debounce?.cancel()
        let d = DispatchWorkItem { [weak self] in self?.attempt() }
        debounce = d
        DispatchQueue.main.asyncAfter(deadline: .now() + config.debounceSeconds, execute: d)

        // 滞后兜底只在「安静触发被反复顶掉」时才有意义，
        // 所以它只挂一次，等真跑过一轮再挂下一次
        if stale == nil {
            let s = DispatchWorkItem { [weak self] in self?.attempt() }
            stale = s
            DispatchQueue.main.asyncAfter(deadline: .now() + config.maxStalenessSeconds, execute: s)
        }
    }

    /// 该不该现在跑。不够间隔就顺延，不丢。
    private func attempt() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard pending, !running else { return }

        if let last = lastRunAt {
            let waited = Date().timeIntervalSince(last)
            let need = config.minIntervalSeconds - waited
            if need > 0 {
                AppDebug.log(String(format: "[sched] 距上次 %.1fs，不到下限，再等 %.1fs", waited, need))
                let w = DispatchWorkItem { [weak self] in self?.attempt() }
                debounce?.cancel()
                debounce = w
                DispatchQueue.main.asyncAfter(deadline: .now() + need + 0.05, execute: w)
                return
            }
        }
        fire()
    }

    private func fire() {
        debounce?.cancel(); debounce = nil
        stale?.cancel();    stale = nil
        running = true
        pending = false
        AppDebug.log("[sched] 开抽")
        onFire?()
    }

    /// 调用方抽完（无论成败）都要叫一声，否则调度会一直以为有请求在飞
    func finished() {
        dispatchPrecondition(condition: .onQueue(.main))
        running = false
        lastRunAt = Date()
        // 抽的这段时间里又来了新文本 → 立刻安排下一轮
        if pending { note() }
    }

    func reset() {
        dispatchPrecondition(condition: .onQueue(.main))
        debounce?.cancel(); debounce = nil
        stale?.cancel();    stale = nil
        pending = false
        lastRunAt = nil
    }
}

// MARK: - 自检

/// `EarShot --extract <文件>`。
///
/// 把一份脚本化的「会议转写」按轮次喂进真实抽取链路（真打 API、真合并），
/// 打印每轮模型回了什么、以及合并后的清单。
///
/// 这是调提示词的唯一快路：不碰音频、不起窗口，几秒一轮。
/// 提示词是这个项目里最脆的地方 —— 模型换版本、改一个字，行为都可能变，
/// 所以文件里还能写断言（见 `check`），改完提示词跑一遍就知道有没有退化。
enum ExtractSelfCheck {

    struct Round {
        var lines: [String] = []    // 这一轮的转写
        var checks: [String] = []   // `!` 开头的断言，这一轮合并完之后核
    }

    /// - Parameter today: 钉死「今天」。文件里的日期断言（`! #1.time 2026-10-16`）
    ///   是死数，不钉的话过一天就跑不过了。命令行给 `--today 2026-10-10`。
    /// - Parameter myName: 说话人叫什么。nil = 按「没配名字」跑 ——
    ///   **刻意不借用户真配置里的名字**：断言是死数，用户往设置里填了
    ///   自己的名字之后，这份文件还得照样过。要验「配了名字」的路径就
    ///   显式给一个（`--myName 王小明`）或跑带名字断言的样例文件。
    static func run(path: String, today: Date = Date(), myName: String? = nil) async -> Int32 {
        // 不联网的几条先跑：没配 key 也该能验「面板上那个数字从哪来」——
        // 解码错了它会一直说谎，而说谎的数字比没有数字更糟。
        // 后面几组同样离线跑：碎片护栏、时分占位、相对日期展开、未读角标
        // 都是本地兜底，和模型听没听劝无关，自己就得钉死
        let offline = usageChecks()
        let guardrails = fragmentChecks()
        let slots = timeSlotChecks()
        let dates = relativeDateChecks()
        let unread = unreadChecks()
        guard offline.failed == 0, guardrails.failed == 0, slots.failed == 0,
              dates.failed == 0, unread.failed == 0 else { return 1 }
        print("")

        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("读不到文件：\(path)")
            return 2
        }
        var config = Config.load()
        guard !config.resolvedAPIKey.isEmpty else {
            print("没有 API Key。填进 \(Config.path) 的 apiKey（面板底栏「设置」里也能填）。")
            print("（不再从环境变量兜底 —— key 只认配置文件里这一个来源。）")
            return 3
        }
        config.myName = myName ?? ""

        let rounds = split(raw)
        print("模型 \(config.model)｜思考 \(config.thinking)｜窗口 \(config.windowChars) 字"
              + "｜\(rounds.count) 轮")
        print("说话人名字："
              + (config.resolvedMyName.isEmpty ? "没配（person 里记「我」）" : config.resolvedMyName))
        print("今天是 \(ExtractionPrompt.todaySection(today).replacingOccurrences(of: "\n", with: "  "))")
        print("")

        let store = TodoStore()
        var transcript: [String] = []
        var apiFailures = 0
        var checkFailures = 0
        var checkCount = 0

        for (n, round) in rounds.enumerated() {
            transcript += round.lines
            let window = tail(transcript.joined(separator: "\n"), chars: config.windowChars)

            print("── 第 \(n + 1) 轮 " + String(repeating: "─", count: 52))
            for l in round.lines { print("   \(l)") }

            do {
                let t0 = Date()
                let out = try await Extractor.extract(window: window,
                                                      existing: store.todos,
                                                      config: config,
                                                      today: today)
                let items = out.items
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                store.addTokens(out.tokens)
                if items.isEmpty { print("   ← 没抽出东西") }
                for it in items { print("   ← " + describe(it)) }
                let result = store.apply(items)
                print("   合并：新增 \(result.added.count)，补全 \(result.updated.count)"
                      + "，删除 \(result.deleted.count)，现有 \(store.todos.count) 条  (\(ms)ms)")
                print("   token：这轮 +\(out.tokens)，累计 \(store.totalTokens)")
                // 无头环境跑不到「红色删除线演一下再消失」那些定时器，
                // 手动落定：删除的条目真移走、划掉的字段真抹掉。
                // 断言盯的是落定之后的状态
                store.settle()
            } catch {
                apiFailures += 1
                print("   ✗ \(error.localizedDescription)")
            }

            for spec in round.checks {
                checkCount += 1
                if !check(spec, store: store) { checkFailures += 1 }
            }
            print("")
        }

        print("══ 最终清单（\(store.todos.count) 条）" + String(repeating: "═", count: 44))
        for t in store.todos {
            print("\(t.seqLabel)  \(t.action)")
            for f in TodoItem.Field.allCases.dropFirst() {
                print("      \(f.label)：\(t.value(f) ?? "—")")
            }
        }
        print("")
        if apiFailures == 0 && checkFailures == 0 {
            print("✓ 全过（\(checkCount) 条断言 + \(offline.ran + guardrails.ran + slots.ran + dates.ran + unread.ran) 条离线断言）")
            return 0
        }
        print("✗ 接口失败 \(apiFailures) 处，断言失败 \(checkFailures)/\(checkCount)")
        return 1
    }

    // MARK: 文件格式

    /// 一行一条：
    /// - `==` 开头 → 新一轮（一轮 = 一次 API 调用，对应真实使用中「转写攒一批抽一次」）
    /// - `!`  开头 → 断言，这一轮合并完之后核
    /// - 其他非空行 → 这一轮的转写，`[我]` / `[对方]` 前缀原样送给模型
    static func split(_ text: String) -> [Round] {
        var rounds = [Round()]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("==") {
                rounds.append(Round())
            } else if t.hasPrefix("!") {
                rounds[rounds.count - 1].checks.append(
                    String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if !t.isEmpty {
                rounds[rounds.count - 1].lines.append(String(t))
            }
        }
        return rounds.filter { !$0.lines.isEmpty || !$0.checks.isEmpty }
    }

    /// 断言语法：
    /// ```
    /// ! count 2                 清单共 2 条
    /// ! #1.location 会议室B      序号 1 那条的「地点」里有「会议室B」（比之前先归一化，
    ///                            所以「会议室 B」「会议室B」算同一个）
    /// ! #1.location             序号 1 那条的「地点」是空的
    /// ```
    /// 字段名用 json schema 里的英文名：action / time / location / person
    /// / artifact / artifactDesc
    static func check(_ spec: String, store: TodoStore) -> Bool {
        if spec.hasPrefix("count") {
            let n = Int(spec.dropFirst("count".count).trimmingCharacters(in: .whitespaces)) ?? -1
            return report(store.todos.count == n, spec, "现有 \(store.todos.count) 条")
        }
        guard spec.hasPrefix("#") else {
            return report(false, spec, "看不懂的断言")
        }
        let head = spec.dropFirst().split(separator: " ", maxSplits: 1,
                                          omittingEmptySubsequences: false)
        let key = String(head[0])
        let want = head.count > 1 ? head[1].trimmingCharacters(in: .whitespaces) : ""
        let kv = key.split(separator: ".")
        guard kv.count == 2, let seq = Int(kv[0]), let f = field(named: String(kv[1])) else {
            return report(false, spec, "断言格式不对（应该像 #1.location 值）")
        }
        guard let item = store.todos.first(where: { $0.seq == seq }) else {
            return report(false, spec, "没有序号 \(seq) 的条目")
        }
        let got = item.value(f) ?? ""
        // 归一化之后再比「包含」：模型的措辞会飘（「会议室 B」多一个空格、
        // 「下周五前」和「下周五之前」），断言盯的是**信息在不在**，不是措辞
        let ok = want.isEmpty
            ? got.isEmpty
            : TodoItem.normalize(got).contains(TodoItem.normalize(want))
        return report(ok, spec, "实际是「\(got)」")
    }

    /// 不联网的 token 解码断言（标题栏那个「大脑 + 数字」的口粮）。
    /// 解错了数字会一直说谎，而说谎的数字比没有数字更糟 —— 拿合成回包钉死。
    /// 返回（失败数，断言总数）：总数用在最后的总结里，省得手维护一个数字
    private static func usageChecks() -> (failed: Int, ran: Int) {
        var failed = 0
        var ran = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            ran += 1
            print("\(ok ? "✓" : "✗") \(name)\(ok ? "" : "   ← \(detail)")")
            if !ok { failed += 1 }
        }
        func tokens(_ json: String) -> Int? {
            try? Extractor.usageTokens(in: Data(json.utf8))
        }

        let full = #"{"choices":[{"message":{"content":"{}"}}],"# +
                   #""usage":{"prompt_tokens":812,"completion_tokens":96,"total_tokens":908}}"#
        check(tokens(full) == 908, "usage.total_tokens 直读",
              tokens(full).map(String.init) ?? "解不动")
        let parts = #"{"choices":[],"usage":{"prompt_tokens":812,"completion_tokens":96}}"#
        check(tokens(parts) == 908, "没有 total 时按分项相加",
              tokens(parts).map(String.init) ?? "解不动")
        check(tokens(#"{"choices":[]}"#) == 0, "整个没有 usage → 0",
              tokens(#"{"choices":[]}"#).map(String.init) ?? "解不动")
        return (failed, ran)
    }

    /// 不联网的合并护栏断言，两条：
    /// **碎片绝不能变成一条待办** —— 线上真跑出来过 action 就一个「买」字的
    /// 条目：半句话被转写定稿、模型照着抽了一条。提示词已经加了「残句不记」，
    /// 这里再钉一道本地兜底；边界也钉死：两个字的短动作是完整的事，
    /// 必须照常建条，护栏不许拦过界。
    /// **幽灵删除也不能变成条目** —— deleted 但序号指不到任何现有条目的
    /// （序号编的 / 没带 seq），落到建条分支会凭空多出空壳、把下游序号顶偏
    private static func fragmentChecks() -> (failed: Int, ran: Int) {
        var failed = 0
        var ran = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            ran += 1
            print("\(ok ? "✓" : "✗") \(name)\(ok ? "" : "   ← \(detail)")")
            if !ok { failed += 1 }
        }

        let json = #"[{"action":"买","time":"2026-10-11"},{"action":"发版"},{"action":"把客户反馈表收齐"}]"#
        let incoming = (try? JSONDecoder().decode([ExtractedTodo].self, from: Data(json.utf8))) ?? []
        check(incoming.count == 3, "护栏用例能解码", "解出 \(incoming.count) 条")

        let store = TodoStore()
        let result = store.apply(incoming)
        check(result.added.count == 2 && store.todos.count == 2, "碎片「买」不建条",
              "新增 \(result.added.count)，清单 \(store.todos.count) 条")
        check(store.todos.first?.action == "发版", "两字短动作照常建条",
              store.todos.first?.action ?? "—")
        check(store.todos.last?.action == "把客户反馈表收齐", "整句照常建条",
              store.todos.last?.action ?? "—")

        // 幽灵删除：deleted 但序号落不到任何现有条目上（没带 seq / seq 是编的）
        // —— 一条都不许建出来
        let ghostJSON = #"[{"action":"改版稿那事","deleted":true},{"seq":99,"action":"取消的事","deleted":true}]"#
        let ghosts = (try? JSONDecoder().decode([ExtractedTodo].self, from: Data(ghostJSON.utf8))) ?? []
        let ghostStore = TodoStore()
        _ = ghostStore.apply(ghosts)
        check(ghostStore.todos.isEmpty, "指不到人的伪删除不建幽灵条目",
              "清单 \(ghostStore.todos.count) 条：\(ghostStore.todos.map(\.action).joined(separator: "、"))")
        return (failed, ran)
    }

    /// 不联网的未读/角标语义断言：**补全和修改也算「没看过」**。
    /// 面板收着的时候，会上改过哪条要从角标数字上看得出（用户点名要的）；
    /// 同值重发不许诈尸 —— 抽取每几秒一轮、每轮全量重发，复读能把已读
    /// 条目顶回未读的话，角标就永远清不掉了
    private static func unreadChecks() -> (failed: Int, ran: Int) {
        var failed = 0
        var ran = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            ran += 1
            print("\(ok ? "✓" : "✗") \(name)\(ok ? "" : "   ← \(detail)")")
            if !ok { failed += 1 }
        }
        func payload(_ json: String) -> [ExtractedTodo] {
            (try? JSONDecoder().decode([ExtractedTodo].self, from: Data(json.utf8))) ?? []
        }

        let store = TodoStore()
        _ = store.apply(payload(#"[{"action":"把季度复盘 PPT 发给老王"}]"#))
        check(store.newCount == 1, "新建条目计未读", "newCount=\(store.newCount)")
        store.acknowledge()
        check(store.newCount == 0, "展开即已读清零", "newCount=\(store.newCount)")

        _ = store.apply(payload(#"[{"seq":1,"action":"","location":"会议室 B"}]"#))
        check(store.newCount == 1, "补全已有条目也计未读（收起来时角标会涨）",
              "newCount=\(store.newCount)")
        store.acknowledge()

        let again = store.apply(payload(
            #"[{"seq":1,"action":"把季度复盘 PPT 发给老王","location":"会议室 B"}]"#))
        check(again.isEmpty && store.newCount == 0, "同值重发不诈尸（无 churn）",
              "newCount=\(store.newCount)，updated=\(again.updated.count)")
        return (failed, ran)
    }

    /// 不联网的时分占位断言：**没有具体时刻的 time 显示 `?时?分`，不是横杠**。
    /// 横杠和空白都会被读成「这条没有时间」，而那是**时刻还没定**的待办，
    /// 两回事。旧口径的横杠、模型偷懒省的时分槽，两种都在这里钉死；
    /// 「整格就是横杠 = 没听到时间」的留空口径也钉住，别让占位符反噬
    private static func timeSlotChecks() -> (failed: Int, ran: Int) {
        var failed = 0
        var ran = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            ran += 1
            print("\(ok ? "✓" : "✗") \(name)\(ok ? "" : "   ← \(detail)")")
            if !ok { failed += 1 }
        }
        /// 拿一条 time 走完整解码 + 归一化 —— 和线上进仓库的是同一条路
        func slot(_ raw: String?) -> String? {
            let value = raw.map { "\"\($0)\"" } ?? "null"
            let json = #"[{"action":"占位用例","time":\#(value)}]"#
            let items = (try? JSONDecoder().decode([ExtractedTodo].self, from: Data(json.utf8))) ?? []
            return items.first?.normalized.time
        }

        check(slot("2026-10-16 —（周五）") == "2026-10-16 ?时?分（周五）",
              "旧横杠占位纠成 ?时?分", slot("2026-10-16 —（周五）") ?? "nil")
        check(slot("2026-10-16（周五）") == "2026-10-16 ?时?分（周五）",
              "省掉的时分槽补上占位", slot("2026-10-16（周五）") ?? "nil")
        check(slot("2026-10-16") == "2026-10-16 ?时?分",
              "光杆日期也补占位", slot("2026-10-16") ?? "nil")
        check(slot("2026-10-14 14:00（周三）") == "2026-10-14 14:00（周三）",
              "说到点的原样不动", slot("2026-10-14 14:00（周三）") ?? "nil")
        check(slot("尽快") == "尽快", "定不出日子的说法不动", slot("尽快") ?? "nil")
        check(slot("—") == nil, "整格横杠 = 没听到时间，留空", slot("—") ?? "nil")
        return (failed, ran)
    }

    /// 不联网的相对日期展开断言（规则 11 的本地兜底）。
    /// 线上实测（2026-10-10 用户会话 + 调试日志）：模型把「要是在**明天**大概
    /// 晚上7:00出发的票」原样塞进 artifactDesc —— action / time 都换对了，就说明里
    /// 这个「明天」跟着条目复读了一整场，用户看到的就是「待办正文里还有明天」。
    /// 提示词补了例子，这里再钉一道本地防线：只认算得准的（今天/明天/后天/
    /// 大后天/明后天），换算结果、幂等、跨年带年份、算不出的不动，全钉死
    private static func relativeDateChecks() -> (failed: Int, ran: Int) {
        var failed = 0
        var ran = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            ran += 1
            print("\(ok ? "✓" : "✗") \(name)\(ok ? "" : "   ← \(detail)")")
            if !ok { failed += 1 }
        }
        /// 「今天是哪天」——和 --extract --today 同一个口径（本地时区的整日）
        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            var c = DateComponents()
            c.year = y; c.month = m; c.day = d
            return Calendar(identifier: .gregorian).date(from: c) ?? Date()
        }
        func expand(_ s: String, from today: Date) -> String {
            Extractor.expandRelativeDates(in: s, today: today)
        }
        let today = day(2026, 10, 10)

        // 根因用例：说明是转述原话，嵌在里面的相对日期也得落地
        let desc = "要是在明天大概晚上7:00出发的票"
        check(expand(desc, from: today) == "要是在10月11日大概晚上7:00出发的票",
              "说明里嵌的「明天」落地", expand(desc, from: today))
        // 一句里多个相对日期，全部落地
        let sentence = "今天提醒我一下买明天到长沙的票"
        check(expand(sentence, from: today) == "10月10日提醒我一下买10月11日到长沙的票",
              "一句里「今天」「明天」都落地", expand(sentence, from: today))
        // 长词不能被短词吃掉
        check(expand("大后天交，明后天都行", from: today) == "10月13日交，10月11日或10月12日都行",
              "「大后天」「明后天」不被吃", expand("大后天交，明后天都行", from: today))
        check(expand("后天提醒我", from: today) == "10月12日提醒我",
              "「后天」落地", expand("后天提醒我", from: today))
        // 幂等：已经换算过的再走一遍不许变
        check(expand("买10月11日的票", from: today) == "买10月11日的票",
              "已换算的幂等", expand("买10月11日的票", from: today))
        // 算不出的不硬凑
        check(expand("尽快", from: today) == "尽快", "算不出的不动", expand("尽快", from: today))
        // 跨年：2026-12-31 的「明天」是 2027-01-01，得带年份
        let nye = day(2026, 12, 31)
        check(expand("明天交", from: nye) == "2027年1月1日交",
              "跨年带年份", expand("明天交", from: nye))
        return (failed, ran)
    }

    private static func field(named s: String) -> TodoItem.Field? {
        switch s {
        case "action":       return .action
        case "time":         return .time
        case "location":     return .location
        case "person":       return .person
        case "artifact":     return .artifact
        case "artifactDesc": return .artifactDesc
        default:             return nil
        }
    }

    @discardableResult
    private static func report(_ ok: Bool, _ spec: String, _ actual: String) -> Bool {
        print("   \(ok ? "✓" : "✗") \(spec)" + (ok ? "" : "   ← \(actual)"))
        return ok
    }

    /// 一行式摘要，够看出模型这一轮回了什么就够
    private static func describe(_ t: ExtractedTodo) -> String {
        var parts = ["seq=\(t.seq.map(String.init) ?? "新")"]
        if t.deleted == true { parts.append("**整条删除**") }
        if let c = t.clearFields, !c.isEmpty { parts.append("**作废 \(c.joined(separator: ","))**") }
        parts.append("待办=\(t.action)")
        for (k, v) in [("时间", t.time), ("地点", t.location), ("人物", t.person),
                       ("输出物", t.artifact), ("说明", t.artifactDesc)] {
            if let v, !v.isEmpty { parts.append("\(k)=\(v)") }
        }
        return parts.joined(separator: " ｜ ")
    }

    /// 窗口 = 最近 N 个字，和真实链路里 `recentWindow(chars:)` 一个口径
    private static func tail(_ s: String, chars: Int) -> String {
        guard chars > 0, s.count > chars else { return s }
        return String(s.suffix(chars))
    }
}
