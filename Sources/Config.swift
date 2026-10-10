import Foundation

/// 用户配置：`~/.config/ear_shot/config.json`。
///
/// 首次启动会把这个文件按默认值写出来（带注释是 JSON 的奢望，所以字段含义
/// 都写在 `--help` 和 README 里）。文件不存在 / 读坏了都不致命 ——
/// 一律回落到默认值，然后在面板上把「为什么没在干活」说出来，不静默失败。
struct Config: Codable, Equatable {

    // MARK: 大模型

    /// 空 = 没配 key。**刻意不回退环境变量** —— 环境里的
    /// DEEPSEEK_API_KEY / ANTHROPIC_AUTH_TOKEN 多半是别的工具在用，
    /// 悄悄借来扣的可能是另一笔账；没配就在面板上明说「没配」
    var apiKey: String = ""
    var baseURL: String = "https://api.deepseek.com"
    var model: String = "deepseek-flash"
    /// "disabled" 是本项目的关键配置，别改成默认的思考模式 ——
    /// 开着思考，一次简单抽取要烧 900+ 个 token、耗时翻几倍，「准实时」就不成立了。
    var thinking: String = "disabled"

    // MARK: 识别

    /// BCP-47，中文用 zh-CN
    var locale: String = "zh-CN"
    var captureMic: Bool = true
    var captureSystem: Bool = true

    // MARK: 人物

    /// 「我」是谁。填了名字之后，待办的人物栏里不再出现「我」：
    /// 麦克风那路（`[我]`，用这个工具的人）说的「我」、以及对方对着他
    /// 说的「你」，都落成这个名字。电脑声音那路（`[对方]`）说的「我」
    /// 是对方**自己**，不会被安上这个名字 —— 提示词里专门讲了怎么分。
    /// 空 = 没配：人物栏继续记「我」，不如真名精确，但比空着强。
    var myName: String = ""

    // MARK: 抽取节奏

    /// 每次送给模型的转写窗口大小（字符）
    var windowChars: Int = 1200
    /// 「弱断句」（逗号/省略号收尾）之后再静这么久就发。
    /// 句号/问号/叹号收尾的定稿（刚性）是直接发的，不走这个数（见 `SentenceGate`）；
    /// 2 秒内等来一个句号，就直接按刚性走 —— 时钟随新定稿清零重记
    var debounceSeconds: Double = 2.0
    /// 两次抽取之间的硬下限，防止话说得密时把 API 打爆。
    /// 顺带把「识别器把一句话拆成好几条定稿」的连发合并成一轮 ——
    /// 抽取循环本身是串行的，这里管的是节奏
    var minIntervalSeconds: Double = 2.0
    /// 两条用：没有标点的定稿等这么久就发（判断不了说没说全，只能等）；
    /// 以及「拖着没抽」的上限 —— 有没抽过的文本拖过这么久就强行抽一次，
    /// 没有它，一段没有标点的长发言期间列表会是空的。
    var maxStalenessSeconds: Double = 5.0

    // MARK: 界面

    var notifySound: Bool = true

    // MARK: - 解码

    init() {}

    private enum CodingKeys: String, CodingKey {
        case apiKey, baseURL, model, thinking
        case locale, captureMic, captureSystem
        case myName
        case windowChars, debounceSeconds, minIntervalSeconds, maxStalenessSeconds
        case notifySound
    }

    /// 手写解码：**字段缺了落默认值**，不抛错。
    ///
    /// 合成的 Codable 不是这个行为 —— 老配置文件里没有后来新加的字段，
    /// 合成解码直接 keyNotFound，然后 `load()` 整个回落默认：**apiKey
    /// 一起丢**，表现成「昨天还能用，今天说没配 key」（加 myName 时真踩到，
    /// 靠 --extract 实测当场逮住）。加字段从此不是破坏性变更。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        thinking = try c.decodeIfPresent(String.self, forKey: .thinking) ?? d.thinking
        locale = try c.decodeIfPresent(String.self, forKey: .locale) ?? d.locale
        captureMic = try c.decodeIfPresent(Bool.self, forKey: .captureMic) ?? d.captureMic
        captureSystem = try c.decodeIfPresent(Bool.self, forKey: .captureSystem) ?? d.captureSystem
        myName = try c.decodeIfPresent(String.self, forKey: .myName) ?? d.myName
        windowChars = try c.decodeIfPresent(Int.self, forKey: .windowChars) ?? d.windowChars
        debounceSeconds = try c.decodeIfPresent(Double.self, forKey: .debounceSeconds)
            ?? d.debounceSeconds
        minIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .minIntervalSeconds)
            ?? d.minIntervalSeconds
        maxStalenessSeconds = try c.decodeIfPresent(Double.self, forKey: .maxStalenessSeconds)
            ?? d.maxStalenessSeconds
        notifySound = try c.decodeIfPresent(Bool.self, forKey: .notifySound) ?? d.notifySound
    }

    // MARK: - 存读

    static var path: String {
        (UserHome.path as NSString).appendingPathComponent(".config/ear_shot/config.json")
    }

    /// 读配置。文件不在就写一份模板出来（这样用户知道该改哪儿）。
    static func load() -> Config {
        let p = path
        guard let data = FileManager.default.contents(atPath: p) else {
            let c = Config()
            c.save()          // 顺手给用户生成一份可以照着改的模板
            AppDebug.log("[config] 没找到配置，已生成模板 \(p)")
            return c
        }
        do {
            var c = try JSONDecoder().decode(Config.self, from: data)
            // 空字符串当「没配」，回落到默认，免得手写配置漏一个字段就把功能关掉了
            let d = Config()
            if c.baseURL.isEmpty { c.baseURL = d.baseURL }
            if c.model.isEmpty { c.model = d.model }
            if c.thinking.isEmpty { c.thinking = d.thinking }
            if c.locale.isEmpty { c.locale = d.locale }
            if c.windowChars <= 0 { c.windowChars = d.windowChars }
            if c.debounceSeconds <= 0 { c.debounceSeconds = d.debounceSeconds }
            if c.minIntervalSeconds <= 0 { c.minIntervalSeconds = d.minIntervalSeconds }
            if c.maxStalenessSeconds <= 0 { c.maxStalenessSeconds = d.maxStalenessSeconds }
            return c
        } catch {
            AppDebug.log("[config] 解析失败（\(error.localizedDescription)），用默认值")
            return Config()
        }
    }

    func save() {
        let p = Config.path
        let dir = (p as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: p))
    }

    /// 实际用的 key：只认配置里的这一个来源。
    /// 以前没配时会去读 DEEPSEEK_API_KEY / ANTHROPIC_AUTH_TOKEN 兜底，
    /// 已去掉 —— 那些环境变量属于别的工具，被这里悄悄借走不是用户的本意。
    /// 没配就是没配，面板上明说，让用户去设置里填。
    var resolvedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 实际用的名字：去掉空白。空 = 没配。
    var resolvedMyName: String {
        myName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var chatURL: URL? {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: base + "/chat/completions")
    }
}
