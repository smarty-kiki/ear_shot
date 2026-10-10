import SwiftUI
import AppKit

/// 离屏渲染自检：不需要屏幕录制/麦克风权限，直接把界面渲染成 PNG。
///
/// 用法：
///   EarShot --preview <输出目录>
enum PreviewRunner {

    /// 合成数据。全字段 / 缺字段 / 未读 各有代表，
    /// 这样一张图里就能看出「多行完整 + 缺的显示 — + 未读是橙色」三件事。
    static func demoTodos() -> [TodoItem] {
        let now = Date()
        func t(_ seq: Int, _ action: String,
               time: String? = nil, location: String? = nil, person: String? = nil,
               artifact: String? = nil, desc: String? = nil,
               new: Bool = false, age: TimeInterval = 0) -> TodoItem {
            TodoItem(seq: seq, action: action, time: time, location: location, person: person,
                     artifact: artifact, artifactDesc: desc,
                     evidence: nil, createdAt: now.addingTimeInterval(-age),
                     updatedAt: now.addingTimeInterval(-age), isNew: new, touched: [])
        }
        return [
            t(1, "把 Q3 复盘 PPT 发给老王",
              time: "周五前", location: "会议室 A", person: "老王",
              artifact: "Q3 复盘 PPT", desc: "含数据看板，12 页左右",
              new: false, age: 900),
            t(2, "收齐客户反馈表",
              time: "这周五之前", person: "小李",
              artifact: "客户反馈表", desc: "只要华东区的",
              new: false, age: 600),
            t(3, "约下周一的技术评审",
              time: "下周一 14:00", location: "线上", person: "张工、小陈",
              new: true, age: 40),
            t(4, "确认服务器扩容预算", new: true, age: 12),
        ]
    }

    /// 「刚刚发生了什么」的三种反馈同框：补全的字段亮橙底、作废的字段划红
    /// 删除线、整条删除的整块变红。
    ///
    /// 这几种状态都只活一两秒，靠真人跑一遍去撞太碰运气 —— 离屏渲染能直接把
    /// 它们定格下来看。
    static func demoChangeStates() -> [TodoItem] {
        let now = Date()
        func t(_ seq: Int, _ action: String, time: String? = nil, location: String? = nil,
               person: String? = nil, artifact: String? = nil, desc: String? = nil) -> TodoItem {
            TodoItem(seq: seq, action: action, time: time, location: location, person: person,
                     artifact: artifact, artifactDesc: desc,
                     evidence: nil, createdAt: now, updatedAt: now, isNew: false, touched: [])
        }

        var a = t(1, "把 Q3 复盘 PPT 发给老王", time: "2026-10-16 —（周五）",
                  location: "会议室 A", person: "老王", artifact: "Q3 复盘 PPT")
        a.touched = [.time, .person]            // 刚补上时间、人物 → 值本身亮橙底

        var b = t(2, "收齐客户反馈表", person: "小李", artifact: "客户反馈表")
        b.ghost = [.time: "2026-10-12 —（周一）"]  // 刚被作废，正在演红色删除线

        var c = t(3, "约设计过一遍改版稿", time: "2026-10-14 14:00（周三）", person: "张姐")
        c.deleting = true                        // 整条删除，整块红

        // 新条目：touched 按 TodoStore 的口径算（只亮真的有值的字段），
        // 不然预览会比真实情况多亮出一片橙色 —— 自检图说谎就没意义了
        var d = t(4, "确认服务器扩容预算", time: "2026-10-13 —（周二）", person: "财务")
        d.touched = Set(TodoItem.Field.allCases.filter { d.value($0) != nil })

        return [a, b, c, d]
    }

    /// 条数多到装不下时的样子：面板长到上限就不再长，行区自己滚
    static func manyTodos(_ n: Int) -> [TodoItem] {
        let verbs = ["对齐", "评审", "发出", "补齐", "确认", "归档", "排期", "回收"]
        let things = ["Q3 复盘 PPT", "客户反馈表", "预算表", "接口文档", "排期表",
                      "测试报告", "合同扫描件", "上线checklist"]
        let people = ["老王", "小李", "张工", "小陈", "产品同学", "运维", "法务", "HR"]
        let now = Date()
        return (1...n).map { i in
            let k = (i - 1) % 8
            return TodoItem(seq: i,
                            action: "\(verbs[k])\(things[k])",
                            time: i % 3 == 0 ? nil : "周\(["一", "二", "三", "四", "五"][i % 5])前",
                            location: i % 4 == 0 ? "线上" : nil,
                            person: people[k],
                            artifact: i % 2 == 0 ? nil : things[k],
                            artifactDesc: i % 5 == 0 ? "含数据看板" : nil,
                            evidence: nil,
                            createdAt: now, updatedAt: now,
                            isNew: i > n - 3, touched: [])
        }
    }

    /// 给声纹塞一段演示波形：两路各自起伏，看着像真在听。
    /// 走的就是 `AudioMeters.push` 那条真路（快起慢落一起吃），
    /// 所以渲染出来的形态和真实监听时是同一个东西。
    static func pushDemoBars(_ meters: AudioMeters) {
        for i in 0..<AudioMeters.barCount {
            let mi = 0.15 + 0.75 * abs(sin(Double(i) * 1.9))
            let sy = 0.10 + 0.60 * abs(sin(Double(i) * 1.3 + 2.1))
            meters.push(CGFloat(mi), speaker: .me)
            meters.push(CGFloat(sy), speaker: .other)
        }
    }

    @MainActor
    static func run(outDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let prefs = Preferences()
        let ui = UIState()
        let store = TodoStore()
        let meters = AudioMeters()

        func sync() { ui.rows = store.rowCount }

        // 预览画布 = 真实窗口尺寸：收起时是「把手 + 光晕留白」，展开时是「面板 + 留白」。
        // 动画中间帧的窗口已经撑到展开尺寸，所以那里统一用 expandedSize。
        func canvas() -> CGSize { ui.expanded ? ui.expandedSize : ui.collapsedSize }
        func animCanvas() -> CGSize { ui.expandedSize }

        // ---- 收起三态：未监听 / 监听中 / 有新待办 ----
        store.seed(demoTodos())
        store.addTokens(18_642)          // 演示：这轮打开已经抽过几轮，大脑徽章亮着
        store.listening = false
        store.acknowledge()
        ui.expanded = false; ui.progress = 0; sync()
        render(name: "01-收起-未监听.png", size: canvas(), store: store, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)

        store.listening = true
        pushDemoBars(meters)             // 监听中 → 标题栏两条声纹有波形
        render(name: "02-收起-监听中.png", size: canvas(), store: store, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)

        store.seed(demoTodos())          // 未读回来，外框亮
        ui.expanded = false; ui.progress = 0; sync()
        render(name: "03-收起-未读.png", size: canvas(), store: store, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)

        // ---- 展开：条目齐全的样子 ----
        ui.expanded = true; ui.progress = 1; sync()
        render(name: "04-展开.png", size: canvas(), store: store, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)

        // ---- 展开 + 刚复制了第 3 条 ----
        store.copy(store.todos[2])
        render(name: "05-展开-已复制.png", size: canvas(), store: store, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)
        store.copiedID = nil

        // ---- 展开 + 空列表（刚点开始监听，还没听到东西）----
        // 「有没有在听」由标题栏两条声纹表达：波形是活的，列表空着也安心
        let empty = TodoStore()
        empty.listening = true
        ui.rows = empty.rowCount
        pushDemoBars(meters)
        render(name: "06-展开-空.png", size: canvas(), store: empty, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)

        // ---- 展开 + 故障（没配 API Key）：带「去设置」按钮 ----
        // 故障态没在听 → 声纹先压平，图上不该出现「还在收声音」的假象
        meters.reset()
        let broken = TodoStore()
        broken.problem = "还没配 API Key —— 点下面「去设置」，把 DeepSeek 的 Key 填上"
        broken.problemAction = .openSettings
        ui.rows = broken.rowCount
        render(name: "07-展开-故障.png", size: canvas(), store: broken, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)

        // ---- 展开 + 故障（没屏幕录制权限）：带「去授权」按钮 ----
        let noPerm = TodoStore()
        noPerm.problem = """
            还没有屏幕录制权限（声音采集也要它）。
            点「去授权」打开，然后重启耳录。
            """
        noPerm.problemAction = .grantScreenRecording
        ui.rows = noPerm.rowCount
        render(name: "13-展开-故障-去授权.png", size: canvas(),
               store: noPerm, ui: ui, prefs: prefs, meters: meters, outDir: outDir)

        // ---- 展开 + 三种「刚发生变化」的反馈（补全 / 作废字段 / 整条删除）----
        let changed = TodoStore()
        changed.seed(demoChangeStates())
        changed.addTokens(18_642)        // 刚发生过抽取 → 大脑徽章亮着
        ui.rows = changed.rowCount
        ui.scrollOffset = 0
        render(name: "12-展开-变化反馈.png", size: animCanvas(),
               store: changed, ui: ui, prefs: prefs, meters: meters, outDir: outDir)

        // ---- 条数不限：多到装不下时面板不再长高，行区内部滚动 ----
        let many = TodoStore()
        many.seed(manyTodos(9))
        many.addTokens(18_642)
        ui.rows = many.rowCount
        ui.scrollOffset = 0
        render(name: "09-展开-多条-顶.png", size: animCanvas(), store: many, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)
        ui.scrollOffset = ui.maxScroll
        render(name: "10-展开-多条-底.png", size: animCanvas(), store: many, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)
        ui.scrollOffset = ui.maxScroll / 2
        render(name: "11-展开-多条-中.png", size: animCanvas(), store: many, ui: ui, prefs: prefs,
               meters: meters, outDir: outDir)
        ui.scrollOffset = 0

        // ---- 生长动画关键帧 ----
        ui.rows = store.rowCount
        pushDemoBars(meters)             // 回到监听中的主场景，声纹恢复波形
        for (i, p) in [CGFloat(0.35), 0.7].enumerated() {
            ui.expanded = p > 0.01
            ui.progress = p
            render(name: String(format: "08-展开中-%d-%.2f.png", i, Double(p)), size: animCanvas(),
                   store: store, ui: ui, prefs: prefs, meters: meters, outDir: outDir)
        }

        print("已输出到 \(outDir)")
    }

    /// 逐帧渲染生长动画：progress 是显式插值的，所以可以离屏精确复现中间帧，
    /// 用来验证形状确实是从把手那一点长出来的（右上角坐标全程不变）
    @MainActor
    static func animFrames(outDir: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let prefs = Preferences()
        let ui = UIState()
        let store = TodoStore()
        // 这组帧看的是形状生长，场景里没在监听 → 声纹平着，也是真实形态
        let meters = AudioMeters()
        store.seed(demoTodos())
        ui.rows = store.rowCount

        let steps: [CGFloat] = [0, 0.2, 0.4, 0.6, 0.8, 1.0]
        for (i, p) in steps.enumerated() {
            ui.progress = p
            ui.expanded = p > 0.01
            let name = String(format: "帧-%02d-progress-%.1f.png", i, Double(p))
            render(name: name, size: ui.expandedSize,
                   store: store, ui: ui, prefs: prefs, meters: meters, outDir: outDir)
        }
        print("已输出到 \(outDir)")
    }

    @MainActor
    private static func render(name: String, size: CGSize,
                               store: TodoStore, ui: UIState, prefs: Preferences,
                               meters: AudioMeters, outDir: String) {
        let root = DockRootView(store: store, ui: ui, prefs: prefs, meters: meters)

        // 深色幕布，方便看清黑色面板
        let stage = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)],
                           startPoint: .top, endPoint: .bottom)
            root
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: stage)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("渲染失败: \(name)")
            return
        }
        let path = (outDir as NSString).appendingPathComponent(name)
        try? png.write(to: URL(fileURLWithPath: path))
        print("✓ \(name)  \(Int(size.width))×\(Int(size.height))")
    }
}
