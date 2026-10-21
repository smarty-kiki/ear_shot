import Foundation
import AppKit
import Combine
import SwiftUI
import Sparkle

// MARK: - 控制器

/// 贴屏幕右侧那层的窗口 / 点击 / 几何。
///
/// 与 notch_tasks 最大的行为差异：**这里是点击展开、再点击收起，
/// 不是鼠标悬浮就展开、离开就收起**。所以整套「悬停 → 展开 / 离开 → 倒计时收起」
/// 的逻辑都不存在，面板开着就一直开着，直到你再点一下。
///
/// 由此带来一个必须处理的连带问题，见 `updateMouseEventPolicy()`。
final class EarShotController {

    let store = TodoStore()
    let ui = UIState()
    let prefs = Preferences()
    /// 标题栏两条声纹的电平。归属控制器而不是 store：它和窗口/界面同寿命
    let meters = AudioMeters()

    private var panel: DockPanel!
    private var hosting: FirstMouseHostingView<DockRootView>!
    private var shrinkWork: DispatchWorkItem?
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var globalClickMonitor: Any?
    private var lastClickAt: Date = .distantPast
    /// 光标最后已知的位置（屏幕坐标，左下原点）。滚动、增删条目这些
    /// 「光标没动但底下的行换了」的时刻，都得靠它重算悬停的是哪一行。
    private var lastMouseScreen: CGPoint?
    private var screenObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()

    /// 监听开关真正的动作由这个闭包注入（音频链路在 AppDelegate 里接）
    var onToggleListening: (() -> Void)?
    /// 菜单里的「打开配置文件」「重新加载配置」
    var onOpenConfig: (() -> Void)?
    var onReloadConfig: (() -> Void)?
    /// 底栏「设置」和菜单「设置…」：弹独立设置窗口
    var onOpenSettings: (() -> Void)?
    /// 故障提示底下那颗按钮（去授权 / 去设置）
    var onProblemAction: ((ProblemAction) -> Void)?

    // MARK: 启动

    func start() {
        setupPanel()
        updateMaxShapeHeight()

        // 面板高度跟随条数走，条数不限：少则贴合内容，多则长到屏幕上限后转内部滚动。
        // 条目一变就要同步窗口，否则会留一片空白或者裁掉几行。
        store.$todos
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                guard let self else { return }
                // 先看滚动条原本在不在底部 —— 在底部就继续跟着最新的走，
                // 用户翻上去看历史了就别把他拽下来
                let wasAtBottom = self.ui.scrollOffset >= self.ui.maxScroll - 1
                self.ui.syncRows(items)
                if wasAtBottom {
                    self.ui.scrollOffset = self.ui.maxScroll
                } else {
                    self.ui.clampScroll()
                }
                self.syncFrame()
                // 条数变了（面板长高/缩短），光标底下的行也跟着换
                self.refreshHover()
            }
            .store(in: &cancellables)

        // 有新待办时，如果面板正开着，就当已经看过了 —— 光晕不该在盯着它的时候一直闪
        store.$todos
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.ui.expanded else { return }
                self.store.acknowledge()
            }
            .store(in: &cancellables)

        // 提醒级别是算出来的（由 todos + listening 决定），没有自己的 publisher，
        // 所以盯这两个源头。级别一变可能要改窗口收不收鼠标事件。
        Publishers.CombineLatest(store.$todos, store.$listening)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateMouseEventPolicy() }
            .store(in: &cancellables)

        // 抽取动过某条（新增或补全）→ 面板开着就把视口滚过去、整行闪一下，
        // 让眼睛立刻落到「刚才那句话落在了哪一条上」。
        // 收起时不做：列表根本看不见，那是外框光晕的活儿。
        //
        // 这条 sink 排在 $todos 那条之后，所以跑起来时行数、滚动位置都已经是
        // 新的了（先「贴底」，再由这里把视口拽到刚动过的那条）。
        store.$lastApply
            .receive(on: RunLoop.main)
            .sink { [weak self] change in
                guard let self, !change.isEmpty else { return }
                // 新待办响一声。**排在 expanded 判断之前**：面板收着的时候
                // 光晕看不见、列表也看不见，这一声是唯一的提醒。
                // 补全/修改刻意不响（角标和光晕会管）—— 抽取几秒一轮，
                // 每轮补个字段就叮一下的话会变成连珠炮
                if !change.added.isEmpty, self.prefs.notifySound {
                    SoundPlayer.shared.play(SoundPlayer.notifySound)
                }
                guard self.ui.expanded else { return }
                self.store.flash(change.changed)
                guard let target = change.changed.first else { return }
                AppDebug.log("[focus] 第 \(target + 1) 行 → 滚过去并高亮")
                withAnimation(.easeOut(duration: 0.30)) {
                    self.ui.scrollToFocus(row: target)
                }
                self.refreshHover()
            }
            .store(in: &cancellables)

        SoundPlayer.shared.warmUp()
        installMonitors()
        updateMouseEventPolicy()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                // 换了屏幕 / 改了分辨率 → 高度上限和窗口几何都得跟着重算
                self.updateMaxShapeHeight()
                self.applyFrame(expanded: self.ui.expanded)
                self.ui.objectWillChange.send()
            }
    }

    func stop() {
        for m in [globalMoveMonitor, localMoveMonitor, globalClickMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(m)
        }
        if let o = screenObserver { NotificationCenter.default.removeObserver(o) }
    }

    /// 退出前清空剪贴板里的待办？不清 —— 粘的还在粘。
    /// 但内存里的东西随进程一起消失，这是「不落盘」的题中之义。

    // MARK: 窗口

    private func setupPanel() {
        let f = frame(expanded: false)
        let p = DockPanel(contentRect: f,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        p.isMovable = false
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        // 光标在我们窗口上方时也要能收到 mouseMoved，否则
        // 「光标离开形状 → 把窗口切成点击穿透」这一步永远不会触发，留白就变成死区了。
        p.acceptsMouseMovedEvents = true
        // 起始按「不接收」来：光标大概率不在把手上，先让开。
        // 光标一贴上去，handleMouseMoved() 会立刻放开。
        p.ignoresMouseEvents = true

        let host = FirstMouseHostingView(rootView: DockRootView(store: store, ui: ui, prefs: prefs,
                                                               meters: meters))
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.onClickPoint = { [weak self] point, screen in
            self?.handlePanelClick(at: point, screen: screen, source: "window")
        }
        host.onScroll = { [weak self] delta in
            guard let self, self.ui.expanded else { return }
            let before = self.ui.scrollOffset
            self.ui.scroll(by: -delta)   // delta > 0 是往内容开头滚 → 偏移变小
            AppDebug.log("[scroll] Δ\(Int(delta)) → \(Int(before))…\(Int(self.ui.scrollOffset))"
                         + "/\(Int(self.ui.maxScroll))（可视 \(Int(self.ui.rowsViewportHeight))）")
            // 行在光标底下走，但光标没动 —— 没有 mouseMoved 可依，只能按老位置重算
            self.refreshHover()
        }
        p.contentView = host
        self.panel = p
        self.hosting = host

        applyFrame(expanded: false)
        p.orderFrontRegardless()
    }

    private func targetScreen() -> NSScreen {
        NSScreen.screens.first ?? NSScreen.main ?? NSScreen.screens.last!
    }

    /// 面板能长到多高：形状顶边已经在屏顶下方 shapeTopOffset 处，
    /// 底下再留一段不压到 Dock。超过这个高度就不长了，改行区内部滚动。
    private func updateMaxShapeHeight() {
        let h = targetScreen().frame.height
        let floor = ui.rowHeight * 2 + ui.headerHeight + ui.footerHeight
        let limit = max(floor, h - ui.shapeTopOffset - ui.bottomMargin)
        if ui.maxShapeHeight != limit {
            ui.maxShapeHeight = limit
            AppDebug.log("[geom] 面板高度上限 \(Int(limit))（屏幕高 \(Int(h))）")
        }
        ui.clampScroll()
    }

    // MARK: 几何
    //
    // 形状四周留了一圈 edgeMargin：既让面板不贴屏幕右边缘，也给告警光晕留出空间。
    // 窗口尺寸跟着当前形态走，而「形状的右上角」在两种状态下都落在同一个屏幕坐标
    // （s.maxX - rightGap, 屏顶 + shapeTopOffset），所以动画参考系恒定，
    // 视觉上必然是从把手本身长出来。

    /// 窗口在当前形态下应有的位置与大小
    private func frame(expanded: Bool) -> NSRect {
        let s = targetScreen().frame
        let size = expanded ? ui.expandedSize : ui.collapsedSize
        let top = s.maxY - ui.windowTopOffset
        return NSRect(x: s.maxX - size.width,
                      y: top - size.height,
                      width: size.width,
                      height: size.height)
    }

    /// 形状在屏幕上的矩形（不含留白）。
    /// 点击 / 光标判定都用它 —— 这样留白加多大都不会顺带把感应区撑大。
    private func shapeFrame(expanded: Bool) -> NSRect {
        let w = frame(expanded: expanded)
        let size = expanded ? ui.expandedShape : ui.collapsedShape
        return NSRect(x: w.maxX - ui.rightGap - size.width,
                      y: w.maxY - ui.edgeMargin - size.height,
                      width: size.width,
                      height: size.height)
    }

    /// 窗口要不要接收鼠标事件。
    ///
    /// notch 收起且空闲时一律 `ignoresMouseEvents = true`，正是靠这个，
    /// 给光晕留的 44pt 留白才没变成一块吞掉点击的死区。
    /// 但耳录的把手**必须能接收点击**（点它展开），所以不能一律让开，
    /// 改成跟着光标走：光标在**形状范围内**才收事件，落在留白里就让穿。
    ///
    /// 这个函数由全局/本地 mouseMoved 监听持续调用，见 `handleMouseMoved()`。
    ///
    /// 用事件自带的坐标，不用 `NSEvent.mouseLocation`：后者是「去问窗口服务器现在光标在哪」，
    /// 而事件回调是异步的，两者对不齐 —— 表现为光标明明停着不动，策略却在反复横跳。
    private func updateMouseEventPolicy(at point: CGPoint) {
        let inside = shapeFrame(expanded: ui.expanded).contains(point)
        let ignore = !inside
        guard panel.ignoresMouseEvents != ignore else { return }
        panel.ignoresMouseEvents = ignore
        AppDebug.log("[geom] 窗口接收鼠标事件 = \(!ignore)（expanded=\(ui.expanded)"
                     + " 光标=\(Int(point.x)),\(Int(point.y)))")
    }

    /// 非鼠标事件驱动的调用点（展开/收起收尾、监听流变化）没有事件可依，
    /// 只能现问一次光标在哪。这些点都不在 mouseMoved 的热路径上，那点迟滞无所谓。
    private func updateMouseEventPolicy() {
        updateMouseEventPolicy(at: NSEvent.mouseLocation)
    }

    /// 同步窗口与内容视图的几何；所有位置变化都走这里
    private func applyFrame(expanded: Bool) {
        let f = frame(expanded: expanded)
        panel.setFrame(f, display: true)
        hosting.frame = NSRect(origin: .zero, size: f.size)
    }

    /// 内容尺寸变化后同步几何；动画进行中不缩窗口，避免把动画裁掉
    private func syncFrame() {
        if ui.expanded {
            applyFrame(expanded: true)
        } else if ui.progress == 0 {
            applyFrame(expanded: false)
        }
    }

    func moveToScreen(index: Int) {
        guard index >= 0, index < NSScreen.screens.count else { return }
        UserDefaults.standard.set(index, forKey: "screenIndex")
        applyFrame(expanded: ui.expanded)
    }

    // MARK: 展开 / 收起

    private let collapseAnimationDuration: TimeInterval = 0.22

    /// - Parameter screenPoint: 触发这次展开的点击落在哪（屏幕坐标，左下原点）。
    ///   刚撑开的面板要立刻按这个点决定收不收鼠标事件 —— 用 `NSEvent.mouseLocation`
    ///   在这里问到的常常是别处的旧值，会让刚点开的面板变成点击穿透。
    func expand(at screenPoint: CGPoint? = nil) {
        shrinkWork?.cancel()
        shrinkWork = nil
        // 已经完整展开就没事可做；但「收到一半又点回来」要能反向播回去，
        // 所以判据是 progress 而不是 expanded（后者在收回动画播完前一直是 true）
        guard !(ui.expanded && ui.progress >= 0.999) else { return }

        // 顺序很关键：
        // 1. 窗口先撑到展开尺寸，生长动画才不会被窗口边界裁掉
        // 2. ui.expanded 必须在 withAnimation **之外**翻转 —— 它一变，容器尺寸就从
        //    76×156 变成 464×682。若这一步进了动画事务，SwiftUI 会把容器尺寸也一起插值，
        //    于是 path(in:) 收到的 rect 变成「形状自己的尺寸」，rect.maxX - w 退化成
        //    左侧留白，看起来就是从左上角长出来
        // 3. 只让 progress 进动画
        applyFrame(expanded: true)
        ui.expanded = true
        // 展开后形状变大了，刚才那个点大概率还在形状里（点击点就在把手上，
        // 而把手整个被展开后的面板盖住）—— 所以要按这个点重算，不能用别处的旧值
        updateMouseEventPolicy(at: screenPoint ?? NSEvent.mouseLocation)
        withAnimation(.spring(response: 0.34, dampingFraction: 0.85)) {
            ui.progress = 1
        }

        // 展开即已读：光晕立刻恢复正常，跟点在哪里无关
        store.acknowledge()
        // 光标这会儿大概率就在刚点的地方，把悬停的行直接点亮（不用等它挪一下）
        refreshHover()
    }

    func collapse() {
        guard ui.expanded else { return }
        // 收回去的过程中行就不该再亮着了
        ui.hoveredRow = nil

        // 顺序和展开时一样讲究：
        // 1. **只**把 progress 放进动画事务，先把形状收回去。
        //    `ui.expanded` 与内容层这一拍都不动 —— 面板留在原地被越来越小的形状裁掉，
        //    这才是「收回去」。一进门就把 expanded 翻成 false 的话，
        //    内容层瞬间从面板换成把手，屏幕上是「一块满尺寸的黑色空面板僵在那儿
        //    0.22 秒，然后啪地收掉」，看着就是卡顿。
        // 2. 动画播完再切内容、缩窗口。
        withAnimation(.easeInOut(duration: collapseAnimationDuration)) {
            ui.progress = 0
        }

        shrinkWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // 动画期间又被点开就别收尾（expand() 会把这条 cancel 掉）
            guard self.ui.progress < 0.001 else { return }
            self.finishCollapse()
        }
        shrinkWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseAnimationDuration + 0.02, execute: w)
    }

    /// 收回动画播完后的收尾：切内容层、更新鼠标策略、把窗口缩回把手尺寸
    private func finishCollapse() {
        ui.expanded = false
        updateMouseEventPolicy()
        applyFrame(expanded: false)
    }

    func toggleExpand() { ui.expanded ? collapse() : expand() }

    // MARK: 鼠标监听

    /// 全局 + 本地两套监听都要装：
    ///
    /// - **全局**监听只收「发给别的 app」的事件。光标在留白里时窗口是点击穿透的，
    ///   事件归下面的 app，所以只有全局监听看得到 —— 这正是「光标贴上把手」那一步。
    /// - 光标一旦进入形状，窗口开始收事件，事件就归我们了，此时**只有本地**监听看得到。
    ///   只有全局监听的话，「光标离开形状」永远感知不到，窗口会一直收事件。
    ///
    /// 点击同理：一次点击可能被窗口和全局监听各收到一次，靠 `lastClickAt` 去重。
    private func installMonitors() {
        let move: (NSEvent) -> Void = { [weak self] e in self?.handleMouseMoved(e) }
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved], handler: move)
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { e in
            move(e); return e
        }

        let click: (NSEvent) -> Void = { [weak self] e in self?.handleGlobalClick(e) }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: click)
    }

    /// 事件的屏幕坐标（左下原点）。
    ///
    /// 全局监听收到的 `locationInWindow` 本来就是屏幕坐标（没有窗口可依附）；
    /// 本地监听收到的则是窗口坐标，要自己换算。
    private func screenLocation(of event: NSEvent) -> CGPoint {
        if let w = event.window { return w.convertPoint(toScreen: event.locationInWindow) }
        return event.locationInWindow
    }

    private func handleMouseMoved(_ event: NSEvent) {
        let loc = screenLocation(of: event)
        lastMouseScreen = loc
        // 光标进出形状 → 决定窗口收不收事件。留白区继续点击穿透给下面的 app。
        updateMouseEventPolicy(at: loc)
        updateHover(at: loc)
    }

    /// 光标悬停在哪一行。整行的悬停反馈靠它（见 TodoRow.block）。
    ///
    /// 这个函数在 mouseMoved 的热路径上，每挪一个像素都会进来一次，
    /// 所以只在**值真的变了**的时候才写 `ui.hoveredRow` ——
    /// @Published 每写一次就是一轮 SwiftUI 更新，跟着鼠标抖就是白烧 CPU。
    private func updateHover(at screenPoint: CGPoint) {
        var row: Int?
        if ui.expanded {
            let f = panel.frame
            let p = CGPoint(x: screenPoint.x - f.minX, y: f.maxY - screenPoint.y)
            // 故障态下中间区不是列表，行悬停自然不作数
            if case .row(let i) = ui.hitTest(p, rowCount: store.todos.count,
                                             scroll: ui.scrollOffset,
                                             showingProblem: store.problem != nil) {
                row = i
            }
        }
        guard ui.hoveredRow != row else { return }
        ui.hoveredRow = row
    }

    /// 没有鼠标事件可依时（滚动、增删条目、展开收尾）用光标最后已知的位置重算。
    private func refreshHover() {
        updateHover(at: lastMouseScreen ?? NSEvent.mouseLocation)
    }

    /// 全局监听收到的点击：自己把屏幕坐标换算成窗口内坐标（左上原点）
    private func handleGlobalClick(_ event: NSEvent) {
        let loc = screenLocation(of: event)
        // 收起态窗口只有把手那么大，展开态大得多，两种都要认
        let f = panel.frame
        guard f.contains(loc) else { return }
        let p = CGPoint(x: loc.x - f.minX, y: f.maxY - loc.y)
        handlePanelClick(at: p, screen: loc, source: "global")
    }

    // MARK: 点击

    /// 点哪里干什么：
    ///
    /// | 点什么 | 干什么 |
    /// |---|---|
    /// | 收起态的把手 | 展开 |
    /// | 面板里的待办行 | 复制该条 |
    /// | 面板里的底栏按钮 | 执行该按钮 |
    /// | 面板其他区域（标题栏、空白） | 收起 |
    /// | 形状之外的留白 | 什么都不做（本来就穿透给下面的 app） |
    /// - Parameters:
    ///   - p: 窗口内坐标（左上原点），用来算点了哪一行
    ///   - screen: 同一个点的屏幕坐标（左下原点），展开时把它交给策略更新
    private func handlePanelClick(at p: CGPoint, screen: CGPoint, source: String) {
        // 去重必须排在最前面：窗口监听和全局监听可能对同一次点击各触发一次，
        // 而展开会把窗口撑大、坐标含义跟着变 —— 第二次进来时算出来的点已经不一样了。
        // 若去重排在切换判断之后，一次点击会「展开又立刻收起」。
        guard Date().timeIntervalSince(lastClickAt) > 0.25 else { return }

        if !ui.expanded {
            guard ui.shapeRect(expanded: false).contains(p) else { return }
            lastClickAt = Date()
            AppDebug.log("[click/\(source)] 把手 (\(Int(p.x)), \(Int(p.y))) → 展开")
            expand(at: screen)
            return
        }

        let rows = store.todos.count
        switch ui.hitTest(p, rowCount: rows, scroll: ui.scrollOffset,
                          showingProblem: store.problem != nil) {
        case .row(let i):
            lastClickAt = Date()
            let todo = store.todos[i]
            // 正在删的那一行不给复制：一秒多之后它就不在了，
            // 拷走一份马上作废的文本没有意义
            guard !todo.deleting else {
                AppDebug.log("[click/\(source)] 第 \(i + 1) 行正在删除，忽略")
                return
            }
            AppDebug.log("[click/\(source)] 第 \(i + 1) 行 #\(todo.seq) → 复制")
            store.copy(todo)
        case .footer(let i):
            lastClickAt = Date()
            runFooterAction(i, source: source)
        case .problemButton:
            lastClickAt = Date()
            guard let action = store.problemAction else { return }
            AppDebug.log("[click/\(source)] 故障按钮：\(action.title)")
            onProblemAction?(action)
        case .panel:
            lastClickAt = Date()
            AppDebug.log("[click/\(source)] 面板空白 (\(Int(p.x)), \(Int(p.y))) → 收起")
            collapse()
        case .outside:
            // 留白区。窗口本该是穿透的，能走到这里说明策略还没跟上，什么都不做。
            AppDebug.log("[click/\(source)] 留白区 (\(Int(p.x)), \(Int(p.y))) → 不理会")
        }
    }

    private func runFooterAction(_ index: Int, source: String) {
        switch index {
        case 0:
            AppDebug.log("[click/\(source)] 底栏：\(store.listening ? "停止" : "开始")监听")
            toggleListening()
        case 1:
            AppDebug.log("[click/\(source)] 底栏：清空 \(store.todos.count) 条")
            store.clear()
        case 2:
            AppDebug.log("[click/\(source)] 底栏：复制全部")
            store.copyAll()
        case 3:
            AppDebug.log("[click/\(source)] 底栏：设置")
            onOpenSettings?()
        default:
            AppDebug.log("[click/\(source)] 底栏：退出")
            NSApp.terminate(nil)
        }
    }

    func toggleListening() {
        if let action = onToggleListening {
            action()
        } else {
            // 音频链路还没接上时的降级：至少开关状态和红点是对的
            store.listening.toggle()
        }
    }
}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var controller: EarShotController!
    private var listener: Listener!
    private var statusItem: NSStatusItem?
    private var settingsWindow: SettingsWindowController!
    private var updaterController: SPUStandardUpdaterController?

    /// `--seed N`：塞 N 条假待办，用来在真窗口里验滚动和点击命中（见 main.swift）
    private let seedCount: Int?

    init(seedCount: Int? = nil) {
        self.seedCount = seedCount
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动时读一次配置：没配 API Key 之类的问题，要等真去开监听时
        // 才在面板上说（启动就弹一脸提示是种骚扰）
        let config = Config.load()
        controller = EarShotController()
        listener = Listener(store: controller.store, meters: controller.meters, config: config)

        // 界面上的每个「动作」在这里落到真东西上
        controller.onToggleListening = { [weak self] in self?.listener.toggle() }
        controller.onOpenConfig = { [weak self] in self?.openConfigFile() }
        controller.onReloadConfig = { [weak self] in self?.reloadConfigFromDisk() }
        controller.onOpenSettings = { [weak self] in self?.openSettings() }
        controller.onProblemAction = { [weak self] action in self?.runProblemAction(action) }

        // 设置窗口：保存 = 落盘 + 立刻生效（不用重启，下一轮抽取/下次开听就是新值）
        settingsWindow = SettingsWindowController()
        settingsWindow.onSave = { [weak self] cfg in
            guard let self else { return }
            cfg.save()
            self.listener.reload(config: cfg)
            self.controller.prefs.notifySound = cfg.notifySound
            // 之前挂在「没配 API Key」上、现在 key 补上了 → 把提示收掉。
            // 不然用户填完 key 回来，面板还写着没配，会以为没保存上
            if self.controller.store.problemAction == .openSettings,
               !cfg.resolvedAPIKey.isEmpty {
                self.controller.store.problem = nil
                self.controller.store.problemAction = nil
            }
            self.flashStatus("设置已保存 ✓")
            AppDebug.log("[settings] 已保存（key \(cfg.resolvedAPIKey.isEmpty ? "缺" : "有")，模型 \(cfg.model)）")
        }

        // --seed 是界面自检，不启动更新器（免得测试时弹更新窗）
        if seedCount == nil {
            updaterController = SPUStandardUpdaterController(startingUpdater: true,
                                                             updaterDelegate: nil,
                                                             userDriverDelegate: nil)
        }

        installHiddenMainMenu()
        controller.start()
        if let n = seedCount {
            controller.store.seed(PreviewRunner.manyTodos(n))
            controller.store.listening = true
            AppDebug.log("[seed] 塞了 \(n) 条假待办")
        }
        setupStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        // 马上要退出了：把采集和识别收掉就行，不用再补抽一轮
        // （抽出来也没人看得到 —— 反正不落盘）
        Task { [weak self] in await self?.listener?.stop(finalExtract: false) }
    }

    // MARK: 配置
    //
    // 菜单里的 @objc 动作（本文件底部）和面板里的故障按钮都流到这几个方法上。
    // 标 @MainActor 是因为它们要碰 Listener —— 协议方法自动带 MainActor，
    // 自己起的这几个不带，不标就是「同步上下文里调主线程方法」的硬错误。

    @MainActor
    private func openConfigFile() {
        let p = Config.path
        if !FileManager.default.fileExists(atPath: p) { _ = Config.load() }  // 顺带生成模板
        let url = URL(fileURLWithPath: p)
        // 明确用文本编辑器打开：.json 的默认关联可能落在 Xcode 上，
        // 为了改一行 key 启一个 IDE 就太重了
        if let te = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: te,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            NSWorkspace.shared.open(url)
        }
        AppDebug.log("[config] 打开 \(p)")
    }

    @MainActor
    private func openSettings() {
        settingsWindow.show(notifySound: controller.prefs.notifySound)
    }

    /// 面板标题栏 / 菜单栏头部的一句短反馈（保存成功、配置重载这种），2.5 秒后收掉。
    /// 监听中的话下个整秒计时就把它顶掉了 —— 和原来「配置已重新加载」一个寿命口径。
    @MainActor
    private func flashStatus(_ text: String) {
        let store = controller.store
        store.statusIsWarning = false
        store.statusText = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.controller.store.statusText == text else { return }
            self.controller.store.statusText = ""
        }
    }

    @MainActor
    private func reloadConfigFromDisk() {
        let fresh = Config.load()
        listener.reload(config: fresh)
        AppDebug.log("[config] 已重新加载（key \(fresh.resolvedAPIKey.isEmpty ? "缺" : "有")）")
        flashStatus("配置已重新加载 ✓")
    }

    /// 设置窗口里要能 ⌘V 粘 key、⌘C/⌘A 编辑、⌘Z 撤销、⌘W 关窗。
    ///
    /// 这些键位等价物是由**主菜单**分发的：文本输入框里按 ⌘V，Field Editor
    /// 是顺着响应链找「哪条菜单项挂着 ⌘V 的 paste:」才决定粘贴的 ——
    /// 没有主菜单就没有粘贴，和窗口是不是 key 无关。
    /// accessory 应用平时不显示菜单栏，但这条菜单照样在背后参与键位分发；
    /// 设置窗口激活前台时它会露出来，正好也符合「设置窗口是个正经窗口」的预期。
    private func installHiddenMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于耳录",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        if let check = makeCheckForUpdatesItem() {
            appMenu.addItem(check)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏耳录", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出耳录", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "编辑")
        // undo:/redo: 没有可引用的 Swift 符号，标准做法就是字符串选择器
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = win

        NSApp.mainMenu = main
    }

    @MainActor
    private func runProblemAction(_ action: ProblemAction) {
        switch action {
        case .openSettings:
            openSettings()
        case .grantAudioCapture:
            listener.requestAudioCapture()
        }
    }

    // MARK: 菜单栏图标

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "ear",
                                   accessibilityDescription: "耳录")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let store = controller.store
        let prefs = controller.prefs

        // 有故障时头部说故障 —— 这时 statusText 是空的，光显示「耳录」
        // 会让人以为一切正常
        let headTitle: String
        if let problem = store.problem {
            let first = problem.split(separator: "\n").first.map(String.init) ?? problem
            headTitle = "⚠︎ " + (first.count > 38 ? String(first.prefix(38)) + "…" : first)
        } else {
            headTitle = store.statusText.isEmpty ? "耳录" : store.statusText
        }
        let head = NSMenuItem(title: headTitle, action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        // 没授权时，菜单里也给一条 —— 面板可能正收着，菜单是另一条路
        if store.problemAction == .grantAudioCapture {
            menu.addItem(makeItem("授予录制电脑音频权限…", #selector(grantAudioCapture), ""))
            menu.addItem(.separator())
        }

        menu.addItem(makeItem("显示 / 收起面板", #selector(togglePanel), "t"))
        menu.addItem(makeItem(store.listening ? "停止监听" : "开始监听",
                              #selector(toggleListeningItem), "l"))
        menu.addItem(.separator())

        let copyItem = makeItem("复制全部待办（\(store.todos.count) 条）", #selector(copyAll), "c")
        copyItem.isEnabled = !store.todos.isEmpty
        menu.addItem(copyItem)
        let clearItem = makeItem("清空待办", #selector(clearTodos), "")
        clearItem.isEnabled = !store.todos.isEmpty
        menu.addItem(clearItem)
        menu.addItem(.separator())

        menu.addItem(makeToggle("声音提醒", prefs.notifySound, #selector(toggleSound)))
        menu.addItem(makeItem("设置…", #selector(openSettingsItem), ","))
        if let check = makeCheckForUpdatesItem() {
            menu.addItem(check)
        }
        menu.addItem(makeItem("打开配置文件", #selector(openConfig), ""))
        menu.addItem(makeItem("重新加载配置", #selector(reloadConfig), ""))
        menu.addItem(.separator())

        // 显示条数不再设上限：面板随条数长高，长到屏幕上限就转内部滚动。
        // 所以原来那个「最多 N 条」的子菜单去掉了。
        if NSScreen.screens.count > 1 {
            let scrParent = NSMenuItem(title: "显示屏幕", action: nil, keyEquivalent: "")
            let scrMenu = NSMenu()
            let current = UserDefaults.standard.integer(forKey: "screenIndex")
            for (i, s) in NSScreen.screens.enumerated() {
                let it = NSMenuItem(title: "屏幕 \(i + 1)（\(Int(s.frame.width))×\(Int(s.frame.height))）",
                                    action: #selector(setScreen(_:)), keyEquivalent: "")
                it.target = self
                it.tag = i
                it.state = (i == current) ? .on : .off
                scrMenu.addItem(it)
            }
            scrParent.submenu = scrMenu
            menu.addItem(scrParent)
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("退出耳录", #selector(quit), "q"))
    }

    private func makeItem(_ title: String, _ sel: Selector, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        it.target = self
        return it
    }

    private func makeToggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        it.target = self
        it.state = on ? .on : .off
        return it
    }

    /// target 必须是 Sparkle 的 controller：它自己负责检查中/不可用时的置灰
    private func makeCheckForUpdatesItem() -> NSMenuItem? {
        guard let updaterController else { return nil }
        let it = NSMenuItem(title: "检查更新…",
                            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                            keyEquivalent: "")
        it.target = updaterController
        return it
    }

    // MARK: 动作

    @objc private func togglePanel() { controller.toggleExpand() }
    @objc private func toggleListeningItem() { controller.toggleListening() }
    @objc private func grantAudioCapture() { controller.onProblemAction?(.grantAudioCapture) }
    @objc private func copyAll() { controller.store.copyAll() }
    @objc private func clearTodos() { controller.store.clear() }
    @objc private func openSettingsItem() { controller.onOpenSettings?() }
    @objc private func openConfig() { controller.onOpenConfig?() }
    @objc private func reloadConfig() { controller.onReloadConfig?() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleSound() { controller.prefs.notifySound.toggle() }

    @objc private func setScreen(_ sender: NSMenuItem) {
        controller.moveToScreen(index: sender.tag)
    }
}
