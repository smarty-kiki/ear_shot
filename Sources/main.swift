import AppKit
import SwiftUI

let _ = NSApplication.shared

let cliArgs = CommandLine.arguments

/// 取 `--flag` 后面紧跟的值（下一个以 -- 开头就当作没给）
func argValue(after flag: String) -> String? {
    guard let i = cliArgs.firstIndex(of: flag), i + 1 < cliArgs.count else { return nil }
    let v = cliArgs[i + 1]
    return v.hasPrefix("--") ? nil : v
}

/// `--today 2026-10-10` 这种。解析不出来就当成没给。
func dayValue(after flag: String) -> Date? {
    guard let s = argValue(after: flag) else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = .current
    return f.date(from: s)
}

// 离屏渲染预览：EarShot --preview <输出目录>
if cliArgs.contains("--preview") {
    let out = argValue(after: "--preview") ?? "/tmp/earshot-preview"
    MainActor.assumeIsolated { PreviewRunner.run(outDir: out) }
    exit(0)
}

// 逐帧渲染生长动画：EarShot --animframes <输出目录>
if cliArgs.contains("--animframes") {
    let out = argValue(after: "--animframes") ?? "/tmp/earshot-anim"
    MainActor.assumeIsolated { PreviewRunner.animFrames(outDir: out) }
    exit(0)
}

// 命中映射自检：EarShot --hittest <面板内x> <面板内y> [行数] [滚动偏移] [--problem]
//                   [--heights 116,130.5,145,130.5]
//
// 点击是这个工具唯一的手势，所以「点哪儿算点到什么」必须能离屏验。
// 本环境没有合成点击的权限，只能把纯函数单独捞出来打表。
// `--problem` = 中间区在显示故障提示（那颗按钮是这时唯一可点的东西）。
// `--heights` = 逐行行高（不等高列表的命中自检）。
if let idx = cliArgs.firstIndex(of: "--hittest") {
    let a = cliArgs
    let x = idx + 1 < a.count ? (Double(a[idx + 1]) ?? 0) : 0
    let y = idx + 2 < a.count ? (Double(a[idx + 2]) ?? 0) : 0
    let rows = idx + 3 < a.count ? (Int(a[idx + 3]) ?? 4) : 4
    let scroll = idx + 4 < a.count ? (Double(a[idx + 4]) ?? 0) : 0
    let problem = cliArgs.contains("--problem")
    let ui = UIState()
    ui.rows = rows
    ui.scrollOffset = CGFloat(scroll)
    if let hi = cliArgs.firstIndex(of: "--heights"), hi + 1 < a.count {
        ui.rowHeights = a[hi + 1].split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
    }

    let rowsTop = Int(ui.edgeMargin + ui.headerHeight)
    let rowsBottom = Int(ui.edgeMargin + ui.headerHeight + ui.rowsViewportHeight)
    let footerTop = Int(ui.edgeMargin + ui.expandedHeight - ui.footerHeight)
    let bottom = Int(ui.edgeMargin + ui.expandedHeight)

    let heightText = ui.rowHeights.isEmpty
        ? "行高 \(Int(ui.rowHeight))"
        : "逐行行高 " + ui.rowHeights.map { String(format: "%.1f", $0) }.joined(separator: ",")
    print("面板 \(Int(ui.expandedSize.width))×\(Int(ui.expandedSize.height))"
          + "  条数=\(rows)  \(heightText)  滚动 \(Int(ui.scrollOffset))"
          + (problem ? "  故障态" : ""))
    print("高度上限 \(Int(ui.maxShapeHeight))  天然行区高 \(Int(ui.naturalRowsHeight))"
          + "  可视行区高 \(Int(ui.rowsViewportHeight))  滚动=\(ui.scrolls ? "是" : "否")  上限 \(Int(ui.maxScroll))")
    print("形状 x: \(Int(ui.edgeMargin))…\(Int(ui.edgeMargin + ui.panelWidth))  （左侧 \(Int(ui.edgeMargin)) 是光晕留白，点了穿透）")
    print("标题栏 y: \(Int(ui.edgeMargin))…\(rowsTop)")
    print("行区   y: \(rowsTop)…\(rowsBottom)")
    print("底栏   y: \(footerTop)…\(bottom)")
    for z in ui.footerZones {
        print("  底栏按钮\(z.index) x: \(Int(z.range.lowerBound))…\(Int(z.range.upperBound))")
    }
    print("收起态把手 窗口内 rect: \(NSStringFromRect(ui.shapeRect(expanded: false)))")
    if problem {
        print("故障按钮 窗口内 rect: \(NSStringFromRect(ui.problemButtonRect))（命中框外扩 6/4pt）")
    }
    print("输入 (\(Int(x)), \(Int(y))) → "
          + ui.hitTest(CGPoint(x: x, y: y), rowCount: rows, scroll: ui.scrollOffset,
                       showingProblem: problem).description)
    exit(0)
}

// 状态映射自检：EarShot --states
//
// 把「监听 / 未读 / 条目情况」→「把手长什么样 + 外框什么颜色」整张表打出来。
// 时间相关的分档和动画效果只有靠它才能离线核对。
if cliArgs.contains("--states") {
    func hex(_ c: Color) -> String {
        guard let s = NSColor(c).usingColorSpace(.sRGB) else { return "?" }
        return String(format: "#%02X%02X%02X",
                      Int((s.redComponent * 255).rounded()),
                      Int((s.greenComponent * 255).rounded()),
                      Int((s.blueComponent * 255).rounded()))
    }
    func row(_ name: String, _ s: TodoStore) {
        let level = s.alertLevel
        let dot = s.listening ? "红点慢闪" : "灰点常亮"
        let glow = level >= .new ? "外框脉冲 \(hex(level.color))" : "—"
        let badge = s.newCount > 0 ? "角标 \(min(s.newCount, 99))" : "—"
        print(String(format: "%-22@ 级别=%-8@ 把手: %-10@ %-8@ %@",
                     name as NSString, level.label as NSString,
                     dot as NSString, badge as NSString, glow as NSString))
    }
    let demo = PreviewRunner.demoTodos

    let a = TodoStore(); a.seed(demo()); a.acknowledge()
    let b = TodoStore(); b.seed(demo()); b.acknowledge(); b.listening = true
    let c = TodoStore(); c.seed(demo())
    let d = TodoStore(); d.seed(demo()); d.listening = true
    let e = TodoStore(); e.listening = true

    print(String(format: "%-22@ %-12@ %-20@ %-9@ %@",
                 "场景" as NSString, "级别" as NSString, "把手" as NSString,
                 "角标" as NSString, "外框" as NSString))
    row("未监听、无未读", a)
    row("监听中、无未读", b)
    row("未监听、有未读", c)
    row("监听中、有未读", d)
    row("刚开听、一条没有", e)
    exit(0)
}

// 无 GUI 自检：EarShot --dump  打印当前待办列表（复制用的文本）后退出
if cliArgs.contains("--dump") {
    let store = TodoStore()
    store.seed(PreviewRunner.demoTodos())
    print("待办    : \(store.todos.count) 条（其中 \(store.newCount) 条未读）")
    print("监听    : \(store.listening ? "是" : "否")")
    print("提醒级别: \(store.alertLevel.label)")
    print("条数: \(store.todos.count)（不限）")
    print(String(repeating: "-", count: 78))
    for t in store.todos {
        let flag = t.isNew ? "●" : "○"
        print("\(flag) \(t.seqLabel)  \(t.action)")
        for f in TodoItem.Field.allCases.dropFirst() {
            print("      \(f.label): \(t.value(f) ?? "—")")
        }
        print("      依据: \(t.evidence ?? "—")")
        print(String(repeating: "-", count: 78))
    }
    print("点击复制到的文本（第 1 条）：")
    print(store.todos.first?.copyText ?? "(空)")
    exit(0)
}

// 抽取链路自检：EarShot --extract <文本文件> [--today 2026-10-10] [--myName 王小明]
//
// 文件里以 `==` 开头的行分轮，一轮 = 一次 API 调用 = 真实使用中「转写攒够
// 一批抽一次」。不碰音频、不起窗口，是把提示词和合并逻辑调满意的最快路子。
// 断言语法见 Extractor.swift 里的 ExtractSelfCheck。
//
// `--today` 钉死「今天」，否则文件里的日期断言过一天就失效了。
// `--myName` 给「说话人叫什么」；不给 = 按**没配名字**跑（不借用户真配置里的
// 名字，断言才是死的。要验配了名字的路径用 testdata/sample-myname.txt）。
if let path = argValue(after: "--extract") {
    let code = await ExtractSelfCheck.run(path: path,
                                          today: dayValue(after: "--today") ?? Date(),
                                          myName: argValue(after: "--myName"))
    exit(code)
}

// 识别链路自检：EarShot --transcribe <音频文件> [--locale zh-CN] [--verbose]
//
// 拿音频文件跑一遍真识别（不碰采集、不用权限），顺带打印「送给抽取器的
// 窗口」。首次会下载中文模型。
if let path = argValue(after: "--transcribe") {
    let code = await TranscribeSelfCheck.run(path: path,
                                             locale: argValue(after: "--locale") ?? "zh-CN",
                                             verbose: cliArgs.contains("--verbose"))
    exit(code)
}

// PCM 转换自检：EarShot --pcmtest
//
// 合成和 Core Audio tap 送出来形状一致的音频块（48k · 立体声 · Float32，
// 交织/非交织各一）跑一遍转换函数，逐字节比对。不用权限、不用真人 ——
// 采集链路上唯一不能靠音频文件自检覆盖的一段，只能先把字节级的路验死。
if cliArgs.contains("--pcmtest") {
    exit(PcmSelfCheck.run())
}

// 回声过滤自检：EarShot --echotest
//
// 不用耳机时，喇叭放出来的声音会被麦克风再听一遍 —— 同一句在两路各定稿一份。
// 「是不是同一句的两次听写」靠相似度判定，用例取自真实运行日志里成对的原话。
if cliArgs.contains("--echotest") {
    exit(EchoSelfCheck.run())
}

// 断句闸门自检：EarShot --senttest
//
// ASR 的「定稿」不等于「说完了」—— 一条定稿可以收在逗号、省略号上（半句）。
// 闸门 = 「收在哪儿」（刚性/弱/无标点）→「等多久」（0 / 2 秒 / 5 秒），
// 这段长在「授权后说话才看得到」的路上，用例全取自真实运行日志里的定稿原文。
if cliArgs.contains("--senttest") {
    exit(SentenceGateSelfCheck.run())
}

// 声纹电平自检：EarShot --wavetest
//
// 标题栏两条声纹的电平换算和历史。这段也长在「授权后说话才看得到」的路上，
// 走合成 buffer 打表：静音/满幅/正弦/Int16 各算一遍，快起慢落各验一条。
if cliArgs.contains("--wavetest") {
    exit(WaveSelfCheck.run())
}

// 设置窗口自检：EarShot --settingstest [--render 目录]
//
// 「填进设置框的东西会存成什么、什么该拦」必须能离线验 —— 存的是真配置文件，
// 存歪了用户下次开 app 就哑了。--render 再把两种状态的表单渲染成 PNG，
// 版式不开真窗口就能看。
if cliArgs.contains("--settingstest") {
    exit(SettingsSelfCheck.run(renderDir: argValue(after: "--render")))
}

// 采集联跑自检：EarShot --capture [秒数] [--verbose]
//
// 采集 + 识别一起跑，要权限才听得到东西，不弹窗。系统声音那路从终端直跑
// 测不到（TCC 把责任进程算在终端头上），要验它用 `make taptest` 或真 app。
if cliArgs.contains("--capture") {
    let secs = argValue(after: "--capture").flatMap(Double.init) ?? 20
    let code = await CaptureSelfCheck.run(seconds: secs, verbose: cliArgs.contains("--verbose"))
    exit(code)
}

// 锁屏收音探针：EarShot --taptest [秒数]
//
// 生产的系统声音采集就是这套 tap（AudioCapture.startSystemTap 与这里同源），
// 探针留着做回归：动过 tap 配置、换过系统/机器之后，锁屏断不断用它验。
// 要音频录制权限 + 真人锁一次屏，不是离线自检，别进 `make test`。（`make taptest`）
if cliArgs.contains("--taptest") {
    let secs = argValue(after: "--taptest").flatMap(Double.init) ?? 120
    exit(await TapProbe.run(seconds: secs, logPath: argValue(after: "--log")))
}

// 入口：无 Dock 图标的后台常驻应用
//
// `--seed N` 往列表里塞 N 条假待办后正常启动 —— 音频链路接上之前，
// 这是唯一能在真窗口里验「条数不限 / 长到上限 / 内部滚动 / 点击命中」的办法。
let seedCount: Int? = {
    guard let i = cliArgs.firstIndex(of: "--seed"), i + 1 < cliArgs.count else { return nil }
    return Int(cliArgs[i + 1])
}()
let delegate = AppDelegate(seedCount: seedCount)
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
