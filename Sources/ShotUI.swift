import SwiftUI
import AppKit

// MARK: - 行几何

/// 不等高行几何：说明（artifactDesc）默认换行、最多 4 行、超出用中间省略号，
/// 行高随说明行数长。
///
/// 行数与高度是两套口径，别混（都是墨迹实测）：
/// - **数行数**用 NSAttributedString 在 `descWrapWidth` 下量（首行 12 + 步进 13.5×(n−1)）
/// - **排高度**按 SwiftUI 渲染口径，行步进 **14.5**（首行 13 + lineSpacing 1.5）。
///   别把 14.5「修正」成 13.5 —— 槽高按 13.5 算会矮一行，SwiftUI 会把
///   最后一行的高度提案当截断依据，文字无声少一行。
enum RowMetrics {
    /// 面板宽：420 收窄 50
    static let panelWidth: CGFloat = 370

    /// 说明 1 行时的行高
    static let baseRowHeight: CGFloat = 116
    static let actionLineHeight: CGFloat = 17
    /// 单行字段槽高：渲染首行 13 + 1pt 余量
    static let fieldLineHeight: CGFloat = 14
    static let lineSpacing: CGFloat = 1.5
    static let descLineLimit = 4

    static let labelWidth: CGFloat = 40
    static let rowPadding: CGFloat = 14
    static let seqColumnWidth: CGFloat = 32
    static let rowSpacing: CGFloat = 8
    /// 字段值外面造高亮底色的 ±3 内衬
    static let valuePadding: CGFloat = 3

    /// SwiftUI 渲染的 10.5pt 行步进（@2x 墨迹带间距恒为 29px）
    static let lineStep: CGFloat = 14.5

    /// 说明正文换行宽度 = 370−14×2−32−8×2−40−3×2 = 248。
    /// 行上给说明加了同宽的 `maxWidth` 上限，让渲染宽度和这里的量宽严格一致
    static var descWrapWidth: CGFloat {
        panelWidth - rowPadding * 2 - seqColumnWidth - rowSpacing * 2
            - labelWidth - valuePadding * 2
    }

    /// 说明文本占几行（1…4）
    static func descLines(of text: String) -> Int {
        guard !text.isEmpty else { return 1 }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.lineBreakMode = .byWordWrapping
        let a = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10.5), .paragraphStyle: style,
        ])
        let h = a.boundingRect(with: NSSize(width: descWrapWidth, height: 1e6),
                               options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return min(max(Int(((h - 12) / 13.5).rounded()) + 1, 1), descLineLimit)
    }

    static func descSlotHeight(_ lines: Int) -> CGFloat {
        fieldLineHeight + lineStep * CGFloat(lines - 1)
    }

    /// 行高按**行上实际显示的**说明算（ghost 的旧值也算 —— 它也在演）
    static func rowHeight(for todo: TodoItem) -> CGFloat {
        let shown = todo.ghost[.artifactDesc] ?? todo.value(.artifactDesc) ?? ""
        return rowHeight(descLines: descLines(of: shown))
    }

    static func rowHeight(descLines lines: Int) -> CGFloat {
        baseRowHeight + lineStep * CGFloat(lines - 1)
    }
}

// MARK: - 尺寸与状态

final class UIState: ObservableObject {
    @Published var expanded = false
    /// 动画进度：0 = 收起，1 = 展开。显式驱动，避免依赖隐式 frame 插值的锚点行为
    @Published var progress: CGFloat = 0
    /// 列表里有几条待办（由控制器按数据同步）。**不限条数**，全在。
    @Published var rows = 4

    /// 逐行行高（不等高）。空 = 还没有数据，一律按单行行高兜底
    @Published var rowHeights: [CGFloat] = []

    /// 行区滚动偏移（pt，0 = 顶）。条数多到装不下时，行区变成内部滚动。
    @Published var scrollOffset: CGFloat = 0

    /// 光标悬停在哪一行（nil = 没落在行上）。由控制器的鼠标监听写入。
    ///
    /// 走 AppKit 层的坐标计算而不是 SwiftUI 的 `.onHover`：这个面板永远不是
    /// key window，SwiftUI 的交互事件在这里不可靠（点击同理，见 FirstMouseHostingView）。
    @Published var hoveredRow: Int?

    /// 形状高度上限，由控制器按当前屏幕算出来写进来。
    /// 超过它就不再长高，改为行区内部滚动 —— 面板不能长到屏幕外面去。
    @Published var maxShapeHeight: CGFloat = 640

    let headerHeight: CGFloat = 34
    let footerHeight: CGFloat = 44
    /// 单行（说明 1 行）的行高，逐行高缺失时的兜底
    var rowHeight: CGFloat { RowMetrics.baseRowHeight }

    /// 面板可见宽度
    let panelWidth: CGFloat = RowMetrics.panelWidth
    /// 收起时把手尺寸
    let tabSize = CGSize(width: 32, height: 68)

    /// 形状外圈留白：给告警光晕和反角留绘制空间。右边缘不留（直接贴屏幕）。
    ///
    /// 必须容得下光晕的完整衰减。`.shadow(radius: 18)` 的可视范围约 38pt，
    /// 留白小于它就会在窗口边界被硬切 —— 表现为光晕最外圈有一道不自然的断口。
    /// 留白靠「光标不在形状内时窗口不接收鼠标事件」来避免白白吞掉点击，
    /// 见 EarShotController.updateMouseEventPolicy()。
    let edgeMargin: CGFloat = 44
    /// 右边缘距屏幕的距离；0 = 贴边（配合反角，视觉上「焊」进屏幕边缘）
    let rightGap: CGFloat = 0

    /// 把手 32 宽配 16 圆角 = 胶囊
    let tabCornerRadius: CGFloat = 16
    /// 展开态的圆角，比按比例算出来的大一些，否则在 370 宽上看着像直角
    let panelCornerRadius: CGFloat = 26

    /// 右边缘与屏幕上/下边交界处的反角（凹角）半径。
    /// 形状的边缘不是被切断，而是用一段凹曲线向上/向下翘起融进屏幕边缘。
    /// 必须 ≤ edgeMargin，否则翘出的部分会被窗口裁掉。
    let tabNotchRadius: CGFloat = 8
    let panelNotchRadius: CGFloat = 14

    /// 把手形状顶边距屏幕顶部。
    var shapeTopOffset: CGFloat = 204

    /// 面板长到屏幕底部往上留的余量：留出 Dock 和一点呼吸空间，
    /// 超过它就不再长高，改行区内部滚动。
    let bottomMargin: CGFloat = 56

    // MARK: 底栏按钮（固定宽度，好让点击命中可以精确算出来）

    let footerPadding: CGFloat = 12
    let footerSpacing: CGFloat = 6
    /// 底栏左起四个按钮宽度：开始监听 / 清空 / 复制全部 / 设置。
    /// 面板 370 宽下要能塞下四个 + 退出：左四块到 290 结束，退出从 300 起
    ///
    /// 宽度是死数，因为命中区是纯坐标算的（见 `footerZones`）——
    /// 加按钮必须连宽度一起加在这里，只改视图不改这里 = 点了没反应
    let footerLeftWidths: [CGFloat] = [80, 54, 72, 54]
    /// 最右「退出」按钮宽度
    let footerQuitWidth: CGFloat = 58

    /// 底栏各按钮在「形状内」的 x 区间（0 = 形状左边缘）
    var footerZones: [(index: Int, range: ClosedRange<CGFloat>)] {
        var out: [(Int, ClosedRange<CGFloat>)] = []
        var x = footerPadding
        for (i, w) in footerLeftWidths.enumerated() {
            out.append((i, x...(x + w)))
            x += w + footerSpacing
        }
        let qx = panelWidth - footerPadding - footerQuitWidth
        out.append((footerLeftWidths.count, qx...(qx + footerQuitWidth)))
        return out
    }

    // MARK: 故障提示按钮（故障态里唯一一个可点的东西）

    /// 和 `PanelBody.emptyState` 里那颗按钮的尺寸、贴底距离一一对应。
    /// **改一边必须改另一边** —— 命中是纯坐标算的，对不上就是「点了没反应」
    let problemButtonSize = CGSize(width: 116, height: 26)
    let problemButtonBottomInset: CGFloat = 18

    /// 故障按钮在窗口坐标（左上原点）里的矩形。故障态之外它不显示，值没意义。
    var problemButtonRect: CGRect {
        CGRect(x: edgeMargin + (panelWidth - problemButtonSize.width) / 2,
               y: edgeMargin + expandedHeight - footerHeight
                  - problemButtonBottomInset - problemButtonSize.height,
               width: problemButtonSize.width,
               height: problemButtonSize.height)
    }

    /// 前 n 行的总高（超出逐行数据的按单行高算：空列表撑出的占位行）
    func totalHeight(ofRows n: Int) -> CGFloat {
        let k = min(n, rowHeights.count)
        return rowHeights[0..<k].reduce(0, +) + CGFloat(max(0, n - k)) * rowHeight
    }

    /// 第 i 行的行高
    func height(ofRow i: Int) -> CGFloat {
        i >= 0 && i < rowHeights.count ? rowHeights[i] : rowHeight
    }

    /// 按数据同步行数与逐行行高（控制器在 todos 变化时调）
    func syncRows(_ todos: [TodoItem]) {
        let n = max(2, todos.count)
        if rows != n { rows = n }
        let heights = todos.map(RowMetrics.rowHeight(for:))
        if rowHeights != heights { rowHeights = heights }
    }

    /// 行区「天然」高度：有几条就有多高（说明换行的行更高），不限。
    /// 列表至少要留两行，空列表也是有话要说的时候
    var naturalRowsHeight: CGFloat { totalHeight(ofRows: max(rows, 2)) }

    /// 行区可视高度。条数不多就贴合内容（面板随条数长高），
    /// 长到面板上限就停住 —— 再多的部分靠内部滚动看。
    var rowsViewportHeight: CGFloat {
        let avail = maxShapeHeight - headerHeight - footerHeight
        return min(naturalRowsHeight, max(avail, rowHeight))
    }

    /// 装不下了，行区要滚动
    var scrolls: Bool { naturalRowsHeight > rowsViewportHeight + 0.5 }

    /// 滚动偏移的上限
    var maxScroll: CGFloat { max(0, naturalRowsHeight - rowsViewportHeight) }

    /// 在 [0, maxScroll] 里夹一下。行数变化后必须夹，否则会滚出内容外露出空白。
    func clampScroll() {
        let c = min(max(scrollOffset, 0), maxScroll)
        if c != scrollOffset { scrollOffset = c }
    }

    func scroll(by delta: CGFloat) {
        scrollOffset = min(max(scrollOffset + delta, 0), maxScroll)
    }

    /// 把某一行滚到看得见的地方（抽取刚动过它的时候用）。
    ///
    /// 已经在视口里就什么都不做：为一条本来就看得到的条目挪视口，
    /// 只会把用户正在看的东西推走，反而找不着刚才看的是哪条。
    /// 真要滚的时候在它上面留半行 —— 看得出来是「滚过来的、上面还有」，
    /// 而不是列表突然从这一条开始。
    func scrollToFocus(row i: Int) {
        guard scrolls, i >= 0 else { return }
        let top = totalHeight(ofRows: i)
        let h = height(ofRow: i)
        guard top < naturalRowsHeight else { return }
        if top >= scrollOffset, top + h <= scrollOffset + rowsViewportHeight { return }
        scrollOffset = min(max(top - h / 2, 0), maxScroll)
    }

    /// 面板形状高度：跟着条数长，长到上限就不长了
    var expandedHeight: CGFloat {
        headerHeight + rowsViewportHeight + footerHeight
    }

    /// 形状尺寸（不含留白）
    var collapsedShape: CGSize { tabSize }
    var expandedShape: CGSize { CGSize(width: panelWidth, height: expandedHeight) }

    /// 窗口 / 容器尺寸 = 形状 + 左留白 + 右留白
    var collapsedSize: CGSize {
        CGSize(width: tabSize.width + edgeMargin + rightGap,
               height: tabSize.height + edgeMargin * 2)
    }
    var expandedSize: CGSize {
        CGSize(width: panelWidth + edgeMargin + rightGap,
               height: expandedHeight + edgeMargin * 2)
    }

    /// 当前形态下窗口的尺寸
    var windowSize: CGSize { expanded ? expandedSize : collapsedSize }

    /// 窗口顶边距屏幕顶部（留白会把形状往下推，所以要减掉）
    var windowTopOffset: CGFloat { shapeTopOffset - edgeMargin }

    /// 形状在窗口坐标里的位置（左上角原点）。窗口坐标 = 形状 + 左侧 edgeMargin 留白。
    func shapeRect(expanded: Bool) -> CGRect {
        let s = expanded ? expandedShape : collapsedShape
        let win = expanded ? expandedSize : collapsedSize
        return CGRect(x: win.width - rightGap - s.width,
                      y: edgeMargin,
                      width: s.width,
                      height: s.height)
    }
}

/// 右侧贴屏幕、带反角的形状。
///
/// 左 / 上 / 下用普通圆角；右边缘**直接贴屏幕**，
/// 并在与上、下边交界处用一段**反角（凹曲线）**向上 / 向下翘起融进屏幕边缘。
/// 这样形状看上去是从屏幕边缘「长出来」的，而不是被一刀切断。
struct DockShape: Shape {
    var cornerRadius: CGFloat
    var notchRadius: CGFloat
    /// false = 只画上、左、下三条边（用于告警描边）：
    /// 右边缘贴着屏幕，画上去会被窗口裁掉，看着很劣质
    var closed: Bool = true

    func path(in rect: CGRect) -> Path {
        let r  = min(cornerRadius, rect.height / 2, rect.width / 2)
        let nr = min(notchRadius, rect.width / 3, rect.height / 3)
        var p = Path()

        if !closed {
            // 只排除贴屏的那段直边，反角本身要描：
            // 从右上反角贴屏幕的一端起笔，绕上/左/下，收在右下反角贴屏幕的一端。
            // 反角描出来光晕会顺着曲线收进屏幕边缘，是「长出来」的感觉；
            // 而右边缘那条直线描上去就只是屏幕边上多了一道线，很劣质。
            if nr > 0 {
                p.move(to: CGPoint(x: rect.maxX, y: rect.minY - nr))
                p.addQuadCurve(to: CGPoint(x: rect.maxX - nr, y: rect.minY),
                               control: CGPoint(x: rect.maxX, y: rect.minY))
            } else {
                p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            }
            p.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
            p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + r),
                           control: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
            p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.maxY),
                           control: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX - nr, y: rect.maxY))
            if nr > 0 {
                p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY + nr),
                               control: CGPoint(x: rect.maxX, y: rect.maxY))
            }
            return p
        }

        p.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - nr, y: rect.minY))

        if nr > 0 {
            // 右上反角：控制点放在直角处 → 起笔水平、收笔垂直，收进屏幕边缘
            p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY - nr),
                           control: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + nr))
            p.addQuadCurve(to: CGPoint(x: rect.maxX - nr, y: rect.maxY),
                           control: CGPoint(x: rect.maxX, y: rect.maxY))
        } else {
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        }

        p.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        p.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// 面板内的点击目标。
///
/// 这个工具是**点击**展开/收起（不是 notch 的悬停展开、移开收回），
/// 所以「点到面板空白处」是一个有意义的动作 —— 它表示「收起」。
/// `.outside` 和 `.panel` 必须分开：留白区（光晕铺开的那 44pt）的点击
/// 要透给下面的 app，不能被当成收起。
enum PanelHit: Equatable {
    case row(Int)      // 待办行 → 复制
    case footer(Int)   // 底栏按钮 → 执行
    case problemButton // 故障提示底下那颗按钮 → 执行（去授权 / 去设置）
    case panel         // 面板内、但不是行也不是按钮（标题栏 / 空白）→ 收起
    case outside       // 形状之外 → 什么都不做

    var description: String {
        switch self {
        case .row(let i):    return "行 \(i + 1)（复制）"
        case .footer(let i): return "底栏按钮 \(i)"
        case .problemButton: return "故障按钮（去授权 / 去设置）"
        case .panel:         return "面板空白（收起）"
        case .outside:       return "形状之外（穿透）"
        }
    }
}

extension UIState {
    /// 把面板窗口内的点（左上角原点）映射成命中目标。
    /// 抽成纯函数是为了能离屏验证——本环境没有合成点击的权限。
    /// `--hittest` 打的就是它。
    /// - Parameter scroll: 当前行区滚动偏移。行区滚起来之后，屏幕上第 i 行
    ///   对应的是内容里更靠后的某行 —— 命中判定必须减掉它，
    ///   否则滚过之后「点到的那条」和「复制走的那条」就对不上了。
    /// - Parameter showingProblem: 中间区这会儿显示的是故障提示（不是列表）。
    ///   必须传对：行区被提示盖住时若还按行算，点一下会「复制到一条看不见的待办」。
    func hitTest(_ p: CGPoint, rowCount: Int, scroll: CGFloat = 0,
                 showingProblem: Bool = false) -> PanelHit {
        let leading = edgeMargin
        let shapeTop = edgeMargin
        let shapeBottom = edgeMargin + expandedHeight

        guard p.x >= leading, p.x <= leading + panelWidth,
              p.y >= shapeTop, p.y <= shapeBottom else { return .outside }

        let sx = p.x - leading

        // 底栏必须在故障判定**之前**：故障态下底栏照样得能用 ——
        // 拿到权限之后就是靠「开始监听」回到正常的，按钮点不着就死锁在这儿了
        let footerTop = shapeBottom - footerHeight
        if p.y >= footerTop {
            for z in footerZones where z.range.contains(sx) { return .footer(z.index) }
            return .panel
        }

        // 故障态：中间区只有那颗按钮可点，其余都当「面板空白」。
        // 命中框比画出来的大一圈 —— 26pt 高的目标，手抖几个点也该点中
        if showingProblem {
            return problemButtonRect.insetBy(dx: -6, dy: -4).contains(p) ? .problemButton : .panel
        }

        let rowsTop = edgeMargin + headerHeight
        let rowsBottom = rowsTop + rowsViewportHeight
        guard p.y >= rowsTop, p.y < rowsBottom, rowCount > 0 else { return .panel }
        // 行不等高，逐行累加找落在哪条上
        var y = p.y - rowsTop + scroll
        for i in 0..<rowCount {
            let h = height(ofRow: i)
            if y < h { return .row(i) }
            y -= h
        }
        return .panel
    }
}

/// 会「长出来」的背景形状。
///
/// 关键点：**锚点写在路径计算里**，不依赖 SwiftUI 的布局对齐或隐式 frame 插值。
/// 尺寸与圆角、反角都由 `progress` 线性插值，形状的右上角永远钉在容器的同一个位置，
/// 所以视觉上必然是从把手那一点往左下长出来。
/// 同一个形状同时用于背景填充、内容裁剪和告警描边，三者的几何天然一致。
struct MorphPath: Shape {
    var progress: CGFloat
    var collapsedShape: CGSize
    var expandedShape: CGSize
    var collapsedRadius: CGFloat
    var expandedRadius: CGFloat
    var collapsedNotch: CGFloat
    var expandedNotch: CGFloat
    var topInset: CGFloat
    var trailingInset: CGFloat
    /// 见 DockShape.closed
    var closed: Bool = true

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(max(progress, 0), 1)
        let w  = collapsedShape.width  + (expandedShape.width  - collapsedShape.width)  * t
        let h  = collapsedShape.height + (expandedShape.height - collapsedShape.height) * t
        let r  = collapsedRadius + (expandedRadius - collapsedRadius) * t
        let nr = collapsedNotch  + (expandedNotch  - collapsedNotch)  * t
        let box = CGRect(x: rect.maxX - trailingInset - w,
                         y: rect.minY + topInset,
                         width: w,
                         height: h)
        return DockShape(cornerRadius: r, notchRadius: nr, closed: closed).path(in: box)
    }
}

// MARK: - 根视图

struct DockRootView: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var ui: UIState
    @ObservedObject var prefs: Preferences
    /// 两路声音的电平（标题栏那两条声纹）。不放进 store：它不是待办的仓库
    @ObservedObject var meters: AudioMeters

    @State private var pulse = false

    private var level: AlertLevel { store.alertLevel }

    var body: some View {
        // 必须用 GeometryReader 拿真实容器尺寸，并给每个形状显式定尺寸：
        // 直接让形状去 fill 的话，ZStack 会按「形状路径的包围盒」收缩，
        // 于是动画中 path(in:) 收到的 rect 是形状自己的尺寸而不是容器尺寸，
        // rect.maxX - w 就恒等于左侧留白 —— 形状看起来从左上角长出来。
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                morphPath.fill(Color.black)
                    .frame(width: size.width, height: size.height)
                    // 只有有新待办时才发光。不给黑色投影——面板外圈会多出一圈灰，
                    // 在浅色壁纸上尤其明显
                    .shadow(color: level >= .new ? level.color.opacity(pulse ? 0.95 : 0.45) : .clear,
                            radius: ui.expanded ? 0 : 18)

                // 内容按同一形状裁剪：动画中内容不会溢出还在变小的背景
                contentLayer
                    .frame(width: size.width, height: size.height)
                    .clipShape(morphPath)

                // 告警描边画在最上层，否则展开后会被面板盖住。
                // 用不闭合路径：右边缘贴屏幕不描边，只描上/左/下
                if level >= .new {
                    outlinePath
                        .stroke(level.color.opacity(pulse ? 1.0 : 0.40),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: level.color.opacity(pulse ? 0.95 : 0.35), radius: 7)
                        .frame(width: size.width, height: size.height)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .animation(.easeInOut(duration: 0.25), value: level)
        .onAppear {
            // 同一个脉冲同时驱动「录制中红点」和「未读光晕」，节奏一致
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    /// 唯一的几何来源：背景填充与内容裁剪用它（闭合）
    private var morphPath: MorphPath { makeMorph(closed: true) }

    /// 告警描边用它（只上/左/下三条边，右侧贴屏幕不画）
    private var outlinePath: MorphPath { makeMorph(closed: false) }

    private func makeMorph(closed: Bool) -> MorphPath {
        MorphPath(progress: ui.progress,
                  collapsedShape: ui.collapsedShape,
                  expandedShape: ui.expandedShape,
                  collapsedRadius: ui.tabCornerRadius,
                  expandedRadius: ui.panelCornerRadius,
                  collapsedNotch: ui.tabNotchRadius,
                  expandedNotch: ui.panelNotchRadius,
                  topInset: ui.edgeMargin,
                  trailingInset: ui.rightGap,
                  closed: closed)
    }

    /// 内容层：加一圈和形状相同的留白，于是内容正好落在形状内部
    private var contentLayer: some View {
        Group {
            if ui.expanded {
                PanelBody(store: store, ui: ui, prefs: prefs, meters: meters)
                    .frame(width: ui.panelWidth, height: ui.expandedHeight, alignment: .top)
                    .transition(.opacity)
            } else {
                SideTab(level: level, count: store.newCount, listening: store.listening, pulsing: pulse)
                    .frame(width: ui.tabSize.width, height: ui.tabSize.height)
            }
        }
        .padding(EdgeInsets(top: ui.edgeMargin, leading: ui.edgeMargin,
                            bottom: ui.edgeMargin, trailing: ui.rightGap))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

// MARK: - 收起时的把手

private struct SideTab: View {
    var level: AlertLevel
    var count: Int
    var listening: Bool
    var pulsing: Bool

    var body: some View {
        VStack(spacing: 8) {
            // 录制指示：监听中红点慢闪，停下来是白点常亮
            Circle()
                .fill(listening ? AlertLevel.listening.color : Color.white)
                .frame(width: 8, height: 8)
                .opacity(listening ? (pulsing ? 1.0 : 0.25) : 1.0)

            if level >= .new {
                AlertDot(level: level, count: count, pulsing: pulsing)
            } else {
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3.5, height: 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 未读角标：比原来大一圈，并带同色光晕
private struct AlertDot: View {
    var level: AlertLevel
    var count: Int
    var pulsing: Bool

    private var text: String { count > 0 ? "\(min(count, 99))" : "!" }

    var body: some View {
        Text(text)
            .font(.system(size: count > 9 ? 10 : 13, weight: .heavy))
            .foregroundStyle(.black)
            .frame(width: 22, height: 22)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(level.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(0.55), lineWidth: 1)
            )
            // 光晕半径收小：把手只有 32 宽、右侧还贴着屏幕，
            // 半径大了会溢到贴屏的那条边上，看着像边缘在闪
            .shadow(color: level.color.opacity(pulsing ? 1.0 : 0.5), radius: 3)
            .shadow(color: level.color.opacity(pulsing ? 0.75 : 0.25), radius: 6)
            .scaleEffect(pulsing ? 1.0 : 0.88)
    }
}

// MARK: - 展开面板

struct PanelBody: View {
    @ObservedObject var store: TodoStore
    @ObservedObject var ui: UIState
    @ObservedObject var prefs: Preferences
    @ObservedObject var meters: AudioMeters

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.10))
            content
            Divider().overlay(Color.white.opacity(0.10))
            footer
        }
        .background(Color.black)
    }

    /// 中间区域：正常时是待办行，异常/空时是提示。
    ///
    /// 故障提示压过列表是有意的：故障态下最该读的是「怎么恢复」，
    /// 而列表本身没丢（在 store 里躺着），恢复之后原样回来。
    @ViewBuilder
    private var content: some View {
        if let problem = store.problem {
            emptyState(text: problem, icon: "exclamationmark.triangle")
        } else if store.todos.isEmpty {
            emptyState(text: store.listening ? "在听了…听到待办就会出现在这里"
                                             : "点下面的「开始监听」，把会上的待办听下来",
                       icon: store.listening ? "waveform" : "ear")
        } else {
            rowsArea
        }
    }

    /// 行区：条数少时贴合内容，条数多时在固定高度的窗口里滚动。
    ///
    /// 滚动是手写的（`.offset` + `.clipped`），没用 `ScrollView` ——
    /// 因为点击命中是在 AppKit 层按 `UIState.hitTest` 算的，
    /// 偏移量必须是**我们自己知道的数**，不能藏在 SwiftUI 的滚动视图里。
    private var rowsArea: some View {
        let content = VStack(spacing: 0) {
            ForEach(Array(store.todos.enumerated()), id: \.element.id) { i, todo in
                TodoRow(todo: todo,
                        hovered: ui.hoveredRow == i,
                        highlighted: store.highlighted.contains(todo.id),
                        copied: store.copiedID == todo.id)
                if i != store.todos.count - 1 {
                    Divider().overlay(Color.white.opacity(0.07)).padding(.leading, 44)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)

        return ZStack(alignment: .top) {
            content.offset(y: -ui.scrollOffset)
            if ui.scrolls { scrollBar }
        }
        .frame(maxWidth: .infinity)
        .frame(height: ui.rowsViewportHeight, alignment: .top)
        .clipped()
    }

    /// 滚动条：不显示的话，被截断的最后一行会被当成「列表就这些」
    private var scrollBar: some View {
        let track = ui.rowsViewportHeight
        let knob = max(track * (track / ui.naturalRowsHeight), 24)
        let travel = track - knob
        let t = ui.maxScroll > 0 ? ui.scrollOffset / ui.maxScroll : 0
        return Capsule()
            .fill(Color.white.opacity(0.22))
            .frame(width: 3, height: knob)
            .offset(y: t * travel)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 3)
            .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("耳录")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize()
            // 两条声纹：前面是图标（麦克风 = 我，喇叭 = 电脑自己），后面跟一串
            // 电平柱。中间那行实时转写文字拿掉之后，「它在听、现在有动静」
            // 就靠它们表达 —— 不用读字，扫一眼就知道哪路在说话
            WaveBadge(icon: "mic.fill", bars: meters.micBars, active: store.listening)
            WaveBadge(icon: "speaker.wave.2.fill", bars: meters.systemBars, active: store.listening)
            // 大脑 + 数字：这次打开以来大模型回包一共烧了多少 token。
            // 有回包就涨 —— 「它在花钱」扫一眼可见，不用翻日志
            TokenBadge(tokens: store.totalTokens)
            Spacer(minLength: 6)
            // 右侧状态：监听计时 / 报错原因 / 模型下载进度。绝不静默失败。
            if !store.statusText.isEmpty {
                Text(store.statusText)
                    .font(.system(size: 9))
                    .foregroundStyle(store.statusIsWarning
                                     ? Color(red: 1.0, green: 0.62, blue: 0.04)
                                     : Color(white: 0.4))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // 收起用的着力点。点标题栏任何地方都能收起，这个只是让人看得见。
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color(white: 0.42))
        }
        .padding(.horizontal, 14)
        .frame(height: ui.headerHeight)
    }

    /// 空/故障态。内容就一图一句话，加一个可选的故障按钮。
    ///
    /// （以前这里还会显示「正在说」的实时转写，已拿掉 —— 刚开听有没有在收
    /// 声音，看标题栏那两条声纹就行，不用读字。）
    ///
    /// 按钮**贴底**摆，不跟内容挤在一起：位置上和 `UIState.problemButtonRect`
    /// 精确对应，点击命中才有得算（面板不是 key window，用不了 SwiftUI 的按钮）。
    private func emptyState(text: String, icon: String) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Color(white: 0.4))
            Text(text).font(.system(size: 11)).foregroundStyle(Color(white: 0.55))
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
            if let action = store.problemAction {
                Text(action.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: ui.problemButtonSize.width,
                           height: ui.problemButtonSize.height)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(AlertLevel.new.color))
                    .padding(.bottom, ui.problemButtonBottomInset)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 底栏只负责「长什么样」，点击由控制器按 footerZones 精确命中——
    /// 本 app 从不成为活跃 app，SwiftUI 的 Button / onTapGesture 在这种面板里收不到点击
    private var footer: some View {
        HStack(spacing: ui.footerSpacing) {
            FooterChip(icon: store.listening ? "stop.fill" : "record.circle",
                       title: store.listening ? "停止监听" : "开始监听",
                       width: ui.footerLeftWidths[0],
                       on: store.listening,
                       tint: store.listening ? AlertLevel.listening.color : nil)
            FooterChip(icon: "trash", title: "清空",
                       width: ui.footerLeftWidths[1],
                       enabled: !store.todos.isEmpty)
            FooterChip(icon: "doc.on.doc", title: "复制全部",
                       width: ui.footerLeftWidths[2],
                       enabled: !store.todos.isEmpty)
            FooterChip(icon: "gearshape", title: "设置",
                       width: ui.footerLeftWidths[3])
            Spacer(minLength: 0)
            FooterChip(icon: "power", title: "退出", width: ui.footerQuitWidth)
        }
        .padding(.horizontal, ui.footerPadding)
        .frame(height: ui.footerHeight - 1)
        .background(Color.white.opacity(0.03))
    }
}

/// 标题栏的一条「声纹」：来源图标 + 一串电平柱（`AudioMeters` 推来的 0…1）。
///
/// 柱高对称着从中线长出去，越新的电平越靠右 —— 和录音软件里的波形一个读法。
/// 柱的深浅跟着高度走（矮=淡），安安静静的时候就是一排小点。
///
/// 不用 SwiftUI 动画：数据本身就是 20Hz 送上来的，天然在动；
/// 再加一层隐式动画只会和数据打架，看着发钝。
private struct WaveBadge: View {
    /// SF Symbol 名：麦克风 / 喇叭
    var icon: String
    var bars: [CGFloat]
    /// 没在监听时整条压暗，别让人误以为「它还在听」
    var active: Bool

    private let barWidth: CGFloat = 2
    /// 相邻两根柱的中心距（柱 2 + 缝 1.2）
    private let pitch: CGFloat = 3.2
    /// 柱的最大高度（即整条声纹的高度）
    private let track: CGFloat = 14

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Color.white.opacity(active ? 0.78 : 0.34))
            HStack(spacing: pitch - barWidth) {
                ForEach(bars.indices, id: \.self) { i in
                    let level = min(max(bars[i], 0), 1)
                    Capsule()
                        .fill(Color.white.opacity(active ? 0.30 + 0.56 * level : 0.22))
                        .frame(width: barWidth, height: max(2, level * track))
                }
            }
            .frame(height: track)
        }
    }
}

/// 标题栏第三个徽章：大脑 + **这次打开以来的累计 token**（`TodoStore.totalTokens`）。
///
/// 涨的时机只有一处：抽取真的拿到了回包。所以这个数字同时也是「它还在不在
/// 干活」的信号 —— 开了很久还是 0，多半是没听清或没配 key。
/// 数字走紧凑写法（12.4K / 1.2万），配合等宽数字，涨的时候宽度不跳。
/// 没用紧凑写法之前的原值在悬停提示里。
private struct TokenBadge: View {
    var tokens: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "brain")
                .font(.system(size: 8.5, weight: .semibold))
            Text(tokens.formatted(.number.notation(.compactName)))
                .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                .lineLimit(1)
        }
        .foregroundStyle(Color.white.opacity(tokens > 0 ? 0.78 : 0.34))
        // 不加 fixedSize 会被 HStack 压成两行；minWidth 给「1.9万」留余量
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 46, alignment: .leading)
        .help("这次打开以来大模型共消耗 \(tokens) token")
    }
}

private struct FooterChip: View {
    var icon: String
    var title: String
    var width: CGFloat
    var on: Bool = false
    var tint: Color? = nil
    var enabled: Bool = true

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(title).font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(tint ?? (on ? Color(white: 0.95) : Color(white: enabled ? 0.62 : 0.28)))
        .frame(width: width, height: 24)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(on ? 0.13 : 0.07)))
    }
}

// MARK: - 待办行

/// 多行完整样式：六行「字段名 + 值」，缺失字段显示灰色 `—`。
///
/// 行高随说明行数变（见 `RowMetrics`，「哪些字段还没补全」一眼可见，
/// 正好对应增量补全的产品感）。
///
/// **所有状态反馈都是整块的**（悬停、刚被抽取动过、已复制、正在删除），
/// 不做成某一行字变色：一行里塞着六行字，在里头找「已复制」三个小字
/// 太费劲；整块变色等于直接说「你碰的就是这一块」，不用找。
///
/// 唯一往字段里钻的是两处：**刚补上的值自己亮一块底**（回答「补了什么」），
/// 以及**作废的字段划一道红删除线**（回答「刚去掉了什么」）。
/// 这两种变化小到只有指到具体那一行字才看得见。
private struct TodoRow: View {
    var todo: TodoItem
    /// 光标正悬在这一行上
    var hovered: Bool
    /// 刚被抽取动过（新增或补全）→ 整行闪一下
    var highlighted: Bool
    /// 刚点过这一行复制 → 整行变绿 + 浮出徽章
    var copied: Bool

    /// 删除相关的红。比「录制中」的红亮一点，深色底上读得清。
    static let removalRed = Color(red: 0.98, green: 0.38, blue: 0.36)

    /// 整块底色。优先级 正在删 > 已复制 > 刚动过 > 悬停。
    private var block: (color: Color, opacity: Double) {
        // 正在删除压过一切：这一行马上就不在了，别的状态都没有意义
        if todo.deleting { return (Self.removalRed, 0.16) }
        if copied { return (Color(red: 0.20, green: 0.80, blue: 0.36), 0.14) }
        if highlighted { return (AlertLevel.new.color, 0.11) }
        if hovered { return (Color.white, 0.055) }
        return (.clear, 0)
    }

    private static let actionLineHeight = RowMetrics.actionLineHeight
    private static let fieldLineHeight = RowMetrics.fieldLineHeight
    private static let lineSpacing = RowMetrics.lineSpacing

    /// 行上实际显示的说明（ghost 的旧值也在演，算它）
    private var descShown: String {
        todo.ghost[.artifactDesc] ?? todo.value(.artifactDesc) ?? ""
    }
    private var descLines: Int { RowMetrics.descLines(of: descShown) }
    private var descSlotHeight: CGFloat { RowMetrics.descSlotHeight(descLines) }

    /// 必须**精确**等于 `UIState.rowHeights`（即 RowMetrics.rowHeight），
    /// 差一点 hitTest 算出的行号就和眼睛看到的行错位
    private var rowHeight: CGFloat { RowMetrics.rowHeight(descLines: descLines) }
    /// 六行字段的总高：动作行 + 4 个单行字段 + 说明槽
    private var contentHeight: CGFloat {
        Self.actionLineHeight + Self.fieldLineHeight * 4 + descSlotHeight + Self.lineSpacing * 5
    }

    var body: some View {
        HStack(alignment: .top, spacing: RowMetrics.rowSpacing) {
            seqColumn
            VStack(alignment: .leading, spacing: Self.lineSpacing) {
                ForEach(TodoItem.Field.allCases, id: \.self) { f in
                    fieldLine(f)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RowMetrics.rowPadding)
        // 上下留白对称，内容在行高里居中
        .padding(.top, (rowHeight - contentHeight) / 2)
        .frame(height: rowHeight, alignment: .top)
        .background(block.color.opacity(block.opacity))
        .overlay(alignment: .trailing) {
            if copied { copiedBadge } else if todo.deleting { deletingBadge }
        }
        .animation(.easeOut(duration: 0.22), value: copied)
        .animation(.easeOut(duration: 0.22), value: highlighted)
        .animation(.easeOut(duration: 0.22), value: todo.deleting)
        // 划掉的字段演完收走时淡出去，别「啪」地变成 —
        .animation(.easeOut(duration: 0.25), value: todo.ghost)
        // 悬停要跟手，比另外几个都快
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    /// 行首标识：[状态圆点] / [序号]。
    ///
    /// 序号做得比字段文字还显眼（更大、更亮、等宽、还给了一块底），是刻意的：
    /// 会上人是**照着这个号说话**的（「待办 3 的地点改一下」），
    /// 念号的人得能一眼扫到、不念错。所以它不是装饰性的小角标。
    private var seqColumn: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(todo.isNew ? AlertLevel.new.color : Color(white: 0.34))
                .frame(width: 6, height: 6)
                .padding(.top, 2)
            Text(todo.seqLabel)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(todo.isNew ? AlertLevel.new.color : Color(white: 0.88))
                .frame(width: 27, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(todo.isNew ? 0.12 : 0.08))
                )
        }
        .frame(width: RowMetrics.seqColumnWidth)
    }

    @ViewBuilder
    private func fieldLine(_ f: TodoItem.Field) -> some View {
        // ghost：这一格刚被作废。模型里其实已经清掉了，演的是「刚发生了什么」——
        // 不然字段会无声无息地变回 —，看着像抽风
        let ghost = todo.ghost[f]
        let v = todo.value(f)
        let shown = ghost ?? v
        let touched = todo.touched.contains(f) && ghost == nil
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(f.label)
                .font(.system(size: 10.5))
                .foregroundStyle(ghost != nil ? Self.removalRed.opacity(0.75)
                                 : touched ? AlertLevel.new.color.opacity(0.9)
                                 : Color(white: 0.42))
                .frame(width: RowMetrics.labelWidth, alignment: .leading)
            Text(shown ?? "—")
                .font(.system(size: f == .action ? 12 : 10.5,
                              weight: f == .action ? .medium : .regular))
                .foregroundStyle(ghost != nil ? Self.removalRed
                                 : shown == nil ? Color(white: 0.30)
                                 : touched ? AlertLevel.new.color
                                 : Color(white: 0.92))
                .strikethrough(ghost != nil, color: Self.removalRed)
                .lineLimit(f == .artifactDesc ? RowMetrics.descLineLimit : 1)
                .truncationMode(f == .artifactDesc ? .middle : .tail)
                .lineSpacing(f == .artifactDesc ? RowMetrics.lineSpacing : 0)
                // 说明按固定宽度换行，宽度和 descLines 的量宽严格一致
                .frame(maxWidth: f == .artifactDesc ? RowMetrics.descWrapWidth : nil,
                       alignment: .leading)
                // 刚补上的值自己亮一块底：一行六行字里只让「时间」这种小标签
                // 变色太容易滑过去。正的 padding 造出底色、负的 padding 把
                // 版式抵回去，加不加底色值都在同一个位置
                .padding(.horizontal, RowMetrics.valuePadding).padding(.vertical, 0.5)
                .background(RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(AlertLevel.new.color.opacity(touched ? 0.16 : 0)))
                .padding(.horizontal, -RowMetrics.valuePadding).padding(.vertical, -0.5)
            Spacer(minLength: 0)
        }
        .frame(height: f == .action ? Self.actionLineHeight
                      : f == .artifactDesc ? descSlotHeight
                      : Self.fieldLineHeight)
    }

    /// 「已删除」徽章：压在整块变红的这一行右边。和「已复制」同一个路数，
    /// 给红色一个明确的意思 —— 不然看着像报错。
    private var deletingBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "trash")
                .font(.system(size: 9, weight: .bold))
            Text("已删除")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Self.removalRed)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .overlay(Capsule().stroke(Self.removalRed.opacity(0.45), lineWidth: 1))
        .padding(.trailing, 12)
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    /// 「已复制」徽章：压在整块变绿的这一行右边。
    /// 底下垫一层黑，免得盖住字段文字时糊成一片。
    private var copiedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
            Text("已复制")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color(red: 0.20, green: 0.80, blue: 0.36))
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.78)))
        .overlay(Capsule().stroke(Color(red: 0.20, green: 0.80, blue: 0.36).opacity(0.45),
                                  lineWidth: 1))
        .padding(.trailing, 12)
        .transition(.opacity)
        .allowsHitTesting(false)
    }
}

// MARK: - 用户偏好

final class Preferences: ObservableObject {
    @Published var notifySound: Bool {
        didSet { UserDefaults.standard.set(notifySound, forKey: "notifySound") }
    }

    init() {
        let d = UserDefaults.standard
        notifySound = d.object(forKey: "notifySound") as? Bool ?? true
    }
}

// MARK: - 窗口

final class DockPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// 面板窗口默认不是 key，而且本 app 是 accessory、永远不会变成活跃 app，
/// SwiftUI 的 onTapGesture / Button 在这种窗口里收不到点击，所以在 AppKit 层自己算坐标。
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    /// 回调带两个坐标：视图内坐标（左上原点，用来算点了哪一行）和屏幕坐标
    /// （左下原点，用来更新「窗口收不收鼠标事件」的策略 —— 展开刚结束那一刻
    /// 再去问 `NSEvent.mouseLocation` 是问不准的，只有事件自己知道光标在哪）。
    var onClickPoint: ((_ viewPoint: CGPoint, _ screenPoint: CGPoint) -> Void)?
    /// 滚轮：正数 = 往内容开头滚（向上），和 NSScrollView 一致
    var onScroll: ((CGFloat) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 面板永远不是 key window，SwiftUI 的 ScrollView 在这种窗口里滚不起来；
    /// 而且命中判定要知道精确偏移，所以滚动自己做。
    override func scrollWheel(with event: NSEvent) {
        var d = event.scrollingDeltaY
        // 触控板给的是精确点数，鼠标滚轮给的是「行」。一格当 13pt 走，
        // 大约八九格才滚过一行，滚快了根本看不清看了哪条。
        if !event.hasPreciseScrollingDeltas { d *= 13 }
        if d != 0 { onScroll?(d) }
        super.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if let w = window, !w.isKeyWindow, w.canBecomeKey { w.makeKey() }
        let p = convert(event.locationInWindow, from: nil)
        let screen = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        AppDebug.log("[hit] mouseDown 视图内坐标=(\(Int(p.x)), \(Int(p.y))) flipped=\(isFlipped)")
        onClickPoint?(p, screen)
        super.mouseDown(with: event)
    }
}
