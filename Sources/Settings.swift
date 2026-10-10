import AppKit
import SwiftUI

// MARK: - 草稿模型

/// 设置窗口的数据：一份**草稿**拷贝 + 测试连接状态。
///
/// 打开窗口时从磁盘读一份配置填进草稿，改完点「保存」才写回去；
/// 取消 / Esc / 关窗口都是把草稿丢掉，磁盘上的东西纹丝不动。
/// 这样「试一下这个地址通不通」不需要先落盘。
///
/// `thinking` 刻意不在界面上：关掉思考是「准实时」成立的前提
/// （开着要烧几百个 reasoning token），它是配置但不是一个选项。
/// `buildConfig(from:)` 从磁盘配置起拷贝，非界面字段原样保留。
@MainActor
final class SettingsModel: ObservableObject {

    enum TestState: Equatable {
        case idle, running
        case ok(String)
        case failed(String)
    }

    // DeepSeek
    @Published var apiKey = ""
    @Published var showKey = false
    @Published var model = ""
    @Published var baseURL = ""

    // 提醒与采集
    @Published var notifySound = true
    @Published var captureMic = true
    @Published var captureSystem = true

    // 高级
    @Published var myName = ""
    @Published var locale = "zh-CN"
    @Published var debounceSeconds = 2.0
    @Published var minIntervalSeconds = 2.0
    @Published var maxStalenessSeconds = 6.0
    @Published var windowChars = 1200

    @Published var testState: TestState = .idle

    init() {}

    /// 打开窗口时刷新草稿。
    /// - Parameter notifySound: 声音提醒的真身在 `Preferences`（UserDefaults）里，
    ///   不在配置文件中，所以要单独传。
    func reload(from c: Config, notifySound: Bool) {
        apiKey = c.apiKey
        model = c.model
        baseURL = c.baseURL
        self.notifySound = notifySound
        captureMic = c.captureMic
        captureSystem = c.captureSystem
        locale = c.locale
        myName = c.myName
        debounceSeconds = c.debounceSeconds
        minIntervalSeconds = c.minIntervalSeconds
        maxStalenessSeconds = c.maxStalenessSeconds
        windowChars = c.windowChars
        testState = .idle
    }

    /// 草稿 → 配置对象。
    /// - Parameter base: 磁盘上现在那份。界面上没有的字段（thinking 等）以它为准。
    ///
    /// 空的模型名 / 地址 / 语言在这里直接回落到默认值，和 `Config.load` 的
    /// 「空字符串当没配」一个口径 —— 设置窗口不该允许把配置存成残缺状态。
    func buildConfig(from base: Config) -> Config {
        let d = Config()
        func trimmed(_ s: String) -> String {
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var c = base
        c.apiKey = trimmed(apiKey)
        c.model = trimmed(model).isEmpty ? d.model : trimmed(model)
        c.baseURL = trimmed(baseURL).isEmpty ? d.baseURL : trimmed(baseURL)
        c.locale = trimmed(locale).isEmpty ? d.locale : trimmed(locale)
        // 名字跟别的空值不一样：空是**有意义的**（= 没配，人物栏记「我」），
        // 不回落任何默认 —— 默认本来就是空
        c.myName = trimmed(myName)
        c.notifySound = notifySound
        c.captureMic = captureMic
        c.captureSystem = captureSystem
        c.debounceSeconds = debounceSeconds
        c.minIntervalSeconds = minIntervalSeconds
        c.maxStalenessSeconds = maxStalenessSeconds
        c.windowChars = windowChars
        return c
    }

    /// 保存前的校验。返回空 = 可以存。
    /// 拦的是「填了但填错了」；留空由 `buildConfig` 回落默认，不算错。
    func problems() -> [String] {
        var out: [String] = []
        let u = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !u.isEmpty {
            let ok = URL(string: u).map {
                ($0.scheme == "http" || $0.scheme == "https") && $0.host != nil
            } ?? false
            if !ok { out.append("接口地址要形如 https://api.deepseek.com") }
        }
        if debounceSeconds <= 0 || debounceSeconds > 60 {
            out.append("抽取静默要在 0～60 秒之间")
        }
        if minIntervalSeconds < 0 || minIntervalSeconds > 300 {
            out.append("最小间隔要在 0～300 秒之间")
        }
        if maxStalenessSeconds <= 0 || maxStalenessSeconds > 600 {
            out.append("兜底滞后要在 0～600 秒之间")
        }
        if windowChars < 100 || windowChars > 20000 {
            out.append("窗口字数要在 100～20000 之间")
        }
        return out
    }

    /// 用**草稿里**的值打一次最小请求（没保存的改动也算数）
    func testConnection(base: Config) {
        guard testState != .running else { return }
        testState = .running
        let cfg = buildConfig(from: base)
        Task { [weak self] in
            do {
                let msg = try await Extractor.testConnection(config: cfg)
                self?.testState = .ok(msg)
            } catch {
                self?.testState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - 表单

/// 设置表单。深色面板是「贴在屏幕边的层」，这里是一个正经的窗口，
/// 所以用系统标准外观、标准控件 —— 打字、粘贴、Tab 走焦点都应该和别的 app 一样。
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// 磁盘上现在那份配置：测试连接和保存都以它为底
    let base: Config
    var onCancel: () -> Void = {}
    var onSave: (Config) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("DeepSeek") {
                    // 内层输入框一律空 label：Form 会把 TextField 自带的
                    // label 渲染成第二列标签（离屏截图里每个值都出现两遍
                    // 就是这么来的），行的标签由外面的 LabeledContent 出。
                    //
                    // 两条「灰字说明」曾经各占一行（每行 ~24pt）—— 加「我是谁」
                    // 一行时表单撑出可视区 43pt，就把它俩挪进了 .help 悬停。
                    // 信息一个字没丢，只是不再常显。
                    keyRow
                        .help("必填。留空 = 没配 key：抽取会停住，面板上会提示。")
                    LabeledContent("模型") {
                        TextField("", text: $model.model)
                    }
                    LabeledContent("接口地址") {
                        TextField("", text: $model.baseURL)
                    }
                    testRow
                }

                Section("提醒与采集") {
                    Toggle("声音提醒（新待办响一声）", isOn: $model.notifySound)
                    Toggle("麦克风 —— 听到「我」说的话", isOn: $model.captureMic)
                    Toggle("系统声音 —— 听到会议里「对方」", isOn: $model.captureSystem)
                }

                // 高级不折叠：一共就五行，折起来只让人多点一下，还挡住一眼扫完
                Section("高级") {
                    advRow("我是谁", "「我」在人物栏里落成的名字。") {
                        TextField("", text: $model.myName)
                            .frame(width: 110)
                            .help("填你的名字：会上你（麦克风那路）说「我」揽下的活、"
                                  + "对方对着你说「你」，人物栏都落成这个名字，不再出现「我」。"
                                  + "电脑声音里的「我」是对方自己，不会被安上。"
                                  + "留空 = 没配，人物栏继续记「我」。")
                    }
                    advRow("识别语言", "中文填 zh-CN；换语言要重下模型。") {
                        TextField("", text: $model.locale)
                            .frame(width: 110)
                            .help("首次用新语言会重新下载一次语音模型")
                    }
                    advRow("抽取静默", "逗号收尾等这么久就发；句号收尾直接发。") {
                        secondsField($model.debounceSeconds)
                    }
                    advRow("最小间隔", "两次抽取的硬下限，防打爆 API，也合并连发。") {
                        secondsField($model.minIntervalSeconds)
                    }
                    advRow("兜底滞后", "没有标点的长句最多等这么久。") {
                        secondsField($model.maxStalenessSeconds)
                    }
                    advRow("窗口字数", "每次送给模型的最近转写长度。") {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            TextField("", value: $model.windowChars,
                                      format: .number.grouping(.never))
                                .frame(width: 70)
                            Text("字")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            bottomBar
        }
        .frame(minWidth: 430, minHeight: 480)
        // ⌘W 由隐藏主菜单接（见 AppDelegate.installHiddenMainMenu），这里兜 Esc
        .onExitCommand { onCancel() }
    }

    /// API Key 单独一行：藏/看切换放在输入框右侧，眼睛图标比一句话省地方
    private var keyRow: some View {
        LabeledContent("API Key") {
            HStack(spacing: 6) {
                Group {
                    if model.showKey {
                        TextField("", text: $model.apiKey)
                    } else {
                        SecureField("", text: $model.apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                Button {
                    model.showKey.toggle()
                } label: {
                    Image(systemName: model.showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(model.showKey ? "藏起来" : "看一眼")
            }
        }
    }

    private var testRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button("测试连接") { model.testConnection(base: base) }
                .disabled(model.testState == .running)
            Group {
                switch model.testState {
                case .idle:
                    Text("用当前填的内容打一次最小请求，验 key 和地址。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .running:
                    Text("测试中…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                case .ok(let m):
                    Label(m, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                case .failed(let m):
                    Label(m, systemImage: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bottomBar: some View {
        let problems = model.problems()
        return HStack(spacing: 10) {
            if let first = problems.first {
                Label(first, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("取消") { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("保存") { onSave(model.buildConfig(from: base)) }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty)
                .help("改完点「保存」才生效；监听中改的，下一次开听用新值。")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 高级区一行：标题 + 一句灰字说明（**同行**），值在右。
    ///
    /// 说明不压在标题底下。两行标签会把行高从 ~48pt 撑到 ~66pt，五行多出
    /// 90pt —— 整张表单就装不进窗口（屏幕可用高度 870 减去上下留白，
    /// 见 `SettingsWindowController.targetHeight`），「打开全看得见」当场破产。
    /// 说明因此要短；更长的补充信息放 `.help` 悬停提示里。
    ///
    /// 行本身必须用 LabeledContent：换裸 HStack 表单会按控件行再撑高一截
    /// （试过，五行多出 75pt）。值内部的数字/单位对齐靠 `secondsField`。
    private func advRow<C: View>(_ title: String, _ note: String,
                                 @ViewBuilder content: () -> C) -> some View {
        LabeledContent {
            content()
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                Text(note)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// 数字 + 单位。基线对齐是关键：输入框比「秒」字高，默认的居中对齐
    /// 会让单位看着往下掉半行（用户报「数字高，单位低」）。
    private func secondsField(_ value: Binding<Double>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("", value: value, format: .number)
                .frame(width: 60)
            Text("秒")
        }
    }
}

// MARK: - 窗口

/// 设置窗口的持有者。
///
/// 应用是 accessory（无 Dock 图标、面板永不成为活跃窗口），所以打开时要
/// `NSApp.activate()` 把前台要过来，窗口才收得到键盘；关掉时再还回去，
/// 别让用户的输入法焦点悬在一个看不见的进程上。
///
/// 窗口里要能 ⌘V 粘 key —— 键位等价物走主菜单分发，所以 AppDelegate 里
/// 装了一条**隐藏主菜单**，见 `installHiddenMainMenu()`。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let model = SettingsModel()
    /// 保存回调：落盘 + 应用到运行中的链路（AppDelegate 注入）
    var onSave: ((Config) -> Void)?

    /// 设置窗口的目标高度 = 表单内容（自检量出来 ~765）+ 底栏（~49）+ 余量。
    /// 自检渲染时每次都重量一遍表单真实内容高度，并对着「可视高度」把关
    /// （`--settingstest --render`），谁把表单改高了当场就能看见。
    /// 加「我是谁」那行时靠把两条常显灰字挪进 .help 才腾出来（各占 ~37pt），
    /// 现在余 ~31pt —— 再加行先看自检报的高度。
    static let targetHeight: CGFloat = 845

    /// 界面上没有的字段（thinking 等）从这里带
    private var base = Config()

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                          styleMask: [.titled, .closable],
                          backing: .buffered,
                          defer: false)
        super.init()
        window.title = "耳录设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
    }

    /// 打开：每次从磁盘鲜读一份配置 —— 文件是权威，别拿启动时的旧值糊弄
    func show(notifySound: Bool) {
        base = Config.load()
        model.reload(from: base, notifySound: notifySound)

        let view = SettingsView(
            model: model,
            base: base,
            onCancel: { [weak self] in self?.window.performClose(nil) },
            onSave: { [weak self] cfg in
                guard let self else { return }
                self.onSave?(cfg)
                self.window.performClose(nil)
            })
        window.contentView = NSHostingView(rootView: view)

        // 高级不折叠 → 按整张表单摊开的高度给（targetHeight）；
        // 屏幕矮的机器顶到可用高度，表单自己滚。缩放保持左下角不动，
        // 所以要重新居中，不然窗口会往屏幕顶上长
        let cap = (NSScreen.main?.visibleFrame.height ?? 820) - 24
        window.setContentSize(NSSize(width: 440, height: min(Self.targetHeight, cap)))
        window.center()

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        AppDebug.log("[settings] 打开设置窗口（底座配置来自 \(Config.path)）")
    }

    func windowWillClose(_ notification: Notification) {
        // 窗口关了就没什么能收键盘的地方了，把前台还给用户刚才在用的 app
        NSApp.deactivate()
        AppDebug.log("[settings] 设置窗口已关")
    }
}

// MARK: - 自检

/// 设置自检：`EarShot --settingstest [--render 目录]`
///
/// 设置窗口的「打字、粘贴、点保存」没法离屏合成，但「填的东西会存成什么、
/// 什么该拦」必须能验 —— 存的可是配置文件。`--render` 再把两种状态的
/// 表单离屏渲染成 PNG，版式不用跑真窗口就能看。
enum SettingsSelfCheck {

    static func run(renderDir: String?) -> Int32 {
        var failed = MainActor.assumeIsolated { logic() }
        if let dir = renderDir {
            failed += MainActor.assumeIsolated { render(to: dir) }
        }
        print(failed == 0 ? "✓ 设置自检全部通过" : "✗ 设置自检有 \(failed) 项没过")
        return failed == 0 ? 0 : 1
    }

    @MainActor
    private static func logic() -> Int {
        var failed = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            print("\(ok ? "✓" : "✗") \(name)\(ok ? "" : "   ← \(detail)")")
            if !ok { failed += 1 }
        }

        let d = Config()
        var base = d
        base.myName = "王小明"   // 磁盘上已经配了名字

        let m = SettingsModel()
        m.reload(from: base, notifySound: false)
        check(m.model == d.model && m.baseURL == d.baseURL && m.apiKey == d.apiKey,
              "打开时草稿 = 磁盘配置")
        check(m.myName == "王小明", "我是谁带入草稿", m.myName)

        // 1. 改动 → 配置：改过的都落到位
        m.apiKey = "  sk-test-xyz  "
        m.model = "deepseek-v4-pro"
        m.myName = "  张小明  "
        m.notifySound = true
        m.captureMic = false
        m.debounceSeconds = 3.0
        m.windowChars = 888
        let c = m.buildConfig(from: base)
        check(c.apiKey == "sk-test-xyz", "apiKey 去空白带入", c.apiKey)
        check(c.model == "deepseek-v4-pro", "模型带入", c.model)
        check(c.myName == "张小明", "名字去空白带入", c.myName)
        check(c.notifySound, "声音提醒带入")
        check(!c.captureMic, "麦克风开关带入")
        check(c.debounceSeconds == 3.0, "抽取静默带入")
        check(c.windowChars == 888, "窗口字数带入")
        check(c.thinking == base.thinking, "thinking 原样保留（界面上没有）", c.thinking)

        // 2. 空值回落默认，别把配置存成残缺状态
        m.model = "   "; m.baseURL = ""; m.locale = ""
        let c2 = m.buildConfig(from: base)
        check(c2.model == d.model, "空模型回落默认", c2.model)
        check(c2.baseURL == d.baseURL, "空地址回落默认", c2.baseURL)
        check(c2.locale == d.locale, "空语言回落默认", c2.locale)

        // 3. 校验：坏值拦住、好值放行
        m.model = "deepseek-flash"; m.baseURL = "https://api.deepseek.com"
        m.locale = "zh-CN"; m.debounceSeconds = 2.5
        m.minIntervalSeconds = 4; m.maxStalenessSeconds = 6; m.windowChars = 1200
        check(m.problems().isEmpty, "正常值无告警", m.problems().joined(separator: "；"))
        m.baseURL = "不是网址"
        check(!m.problems().isEmpty, "坏地址被拦")
        m.baseURL = "https://api.deepseek.com"
        m.debounceSeconds = -1
        check(!m.problems().isEmpty, "负静默被拦")
        m.debounceSeconds = 2.5
        m.windowChars = 0
        check(!m.problems().isEmpty, "零窗口被拦")
        m.windowChars = 1200

        // 4. 编解码往返。**直接编解码，不调 save()** —— 自检绝不动用户的真配置
        do {
            let data = try JSONEncoder().encode(c)
            let back = try JSONDecoder().decode(Config.self, from: data)
            check(back == c, "编解码往返一致")
        } catch {
            check(false, "编解码往返", "\(error)")
        }

        // 5. 缺字段的老配置也要**整体**读出来。合成的 Codable 对缺失字段
        //    直接 keyNotFound，然后 load() 整个回落默认 —— apiKey 一起丢，
        //    表现成「昨天还能用，今天说没配 key」（加 myName 时真踩到过一次）。
        //    加字段不该是破坏性变更，这条守着它。
        let old = #"{"apiKey":"sk-老配置","model":"deepseek-v4-pro"}"#
        if let back = try? JSONDecoder().decode(Config.self, from: Data(old.utf8)) {
            check(back.resolvedAPIKey == "sk-老配置" && back.myName.isEmpty
                  && back.baseURL == d.baseURL && back.notifySound,
                  "缺字段的老配置整体能读", "apiKey \(back.resolvedAPIKey.isEmpty ? "丢了" : "在")")
        } else {
            check(false, "缺字段的老配置整体能读", "解码直接抛错")
        }
        return failed
    }

    // MARK: 离屏渲染

    @MainActor
    private static func demoModel(failing: Bool) -> SettingsModel {
        let m = SettingsModel()
        m.reload(from: Config(), notifySound: true)
        m.apiKey = "sk-1234567890abcdef"
        m.myName = "王小明"
        // 失败态用真文案（Extractor 对 401 的「说人话」版）：截图里看到的
        // 就应该是最常撞上的那种失败长什么样，不是构造出来的长 JSON
        m.testState = failing
            ? .failed("API Key 无效（401）—— 看看有没有贴全、有没有多余空格")
            : .ok("deepseek-flash 响应正常（312ms）")
        return m
    }

    @MainActor
    private static func render(to dir: String) -> Int {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var failed = 0

        func shoot(failing: Bool, name: String, height: CGFloat) {
            let view = SettingsView(model: demoModel(failing: failing),
                                    base: Config())
                .frame(width: 440, height: height)

            // Form（grouped 样式）底下是 NSTableView，ImageRenderer 画不出来 ——
            // 出来是一整片空白，只有自己拼的底栏在。所以走真 AppKit 绘制：
            // 把视图挂进一个**搁在屏幕外**、从不露脸的窗口，让它走正常 display
            // 流程，再抓成位图。进程是 CLI 自检，窗口一闪而过都看不见，何况在屏外。
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 440, height: height)
            let win = NSWindow(contentRect: host.frame,
                               styleMask: [.borderless],
                               backing: .buffered,
                               defer: false)
            win.contentView = host
            win.setFrameOrigin(NSPoint(x: -30000, y: -30000))
            win.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            host.display()

            // 量一下表单的真实内容高度。Form 底下是 NSScrollView + NSTableView，
            // documentView 的高度就是全部内容摊开的总高。它高过可视区（clipView）
            // 就有行要被挡在可视区外，「打开就是全的」当场破产 —— 在这把关。
            if let sv = firstScrollView(in: host) {
                let content = sv.documentView?.frame.height ?? -1
                let viewport = sv.contentView.bounds.height
                let screen = NSScreen.main?.visibleFrame.height ?? -1
                print("  表单内容 \(Int(content.rounded()))pt ／ 可视 \(Int(viewport.rounded()))pt ／ 窗口 \(Int(height))pt ／ 屏可用 \(Int(screen))pt")
                // 失败态的报错文案长短不可控（API 说多长就多长，lineLimit 4），
                // 允许它多出两行 —— 真超了也只是多滚一点，不算版式破了
                let slack: CGFloat = failing ? 30 : 0
                if content > viewport + slack {
                    print("✗ \(name)：表单内容装不下可视区，有行会被挡在可视区外")
                    failed += 1
                }
            }

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                print("✗ 渲染失败（拿不到位图）：\(name)")
                failed += 1
                win.orderOut(nil)
                return
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            win.orderOut(nil)

            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("✗ 渲染失败（编码不了）：\(name)")
                failed += 1
                return
            }
            let path = (dir as NSString).appendingPathComponent(name)
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("已渲染 \(path)  (\(rep.pixelsWide)×\(rep.pixelsHigh))")
            } catch {
                print("✗ 写不出去：\(path)")
                failed += 1
            }
        }

        // 高级不折叠 → 两种状态都按窗口真实高度（targetHeight）出图，
        // 图上看的 == 用户打开窗口看到的。渲染时会重量表单内容高度并把关。
        shoot(failing: false, name: "settings.png",
              height: SettingsWindowController.targetHeight)
        shoot(failing: true, name: "settings-failed.png",
              height: SettingsWindowController.targetHeight)
        return failed
    }

    /// Form 底下的 NSScrollView（拿它的 documentView 量内容高度）
    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let sv = view as? NSScrollView { return sv }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }
}
