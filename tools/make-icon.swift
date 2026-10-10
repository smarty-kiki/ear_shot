#!/usr/bin/env swift
//
// 生成耳录的应用图标 —— 全部用代码画，不依赖设计稿
//
//   swift tools/make-icon.swift                 # 候选图渲染到 /tmp/earshot-icon
//   swift tools/make-icon.swift --variant ear   # 只渲染某个方案（ear / ear-badge / waves）
//   swift tools/make-icon.swift --sizes 1024,128,32,16
//   swift tools/make-icon.swift --install       # 按 iconset 出 Resources/AppIcon.icns
//
// 设计：macOS 惯例的深色圆角方块 + 手绘耳朵曲线 + 红点（正在听）。
// 每个尺寸单独渲染（不是把大图缩小），小尺寸把线条加粗。

import AppKit

var outDir = "/tmp/earshot-icon"
var variants = ["ear", "ear-fill", "ear-badge", "waves"]
var sizes = [1024, 128, 64, 32, 16]
var install = false

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--out": i += 1; outDir = args[i]
    case "--variant":
        i += 1
        variants = args[i] == "all" ? ["ear", "ear-fill", "ear-badge", "waves"]
                                    : args[i].split(separator: ",").map(String.init)
    case "--sizes": i += 1; sizes = args[i].split(separator: ",").compactMap { Int($0) }
    case "--install": install = true
    default:
        FileHandle.standardError.write("未知参数：\(args[i])\n".data(using: .utf8)!)
        exit(2)
    }
    i += 1
}

let red = NSColor(srgbRed: 1.00, green: 0.29, blue: 0.24, alpha: 1)     // 和面板红点同色
let orange = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.04, alpha: 1)  // 未读角标橙

// 在 1024 设计空间里画一张（坐标 y 向上），px 决定实际像素尺寸
func renderPixels(_ px: Int, variant: String) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gctx
    draw(variant: variant, px: px)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func draw(variant: String, px: Int) {
    let S = 1024.0
    let small = px <= 32

    // ---- 深色圆角方块（macOS 图标惯例：824 内容区、四周留 ~100 边距）----
    let inset = 0.098 * S
    let side = S - 2 * inset
    let rect = NSRect(x: inset, y: inset, width: side, height: side)
    let squircle = NSBezierPath(roundedRect: rect,
                                xRadius: 0.2237 * side, yRadius: 0.2237 * side)
    let g = NSGradient(starting: NSColor(srgbRed: 0.075, green: 0.075, blue: 0.085, alpha: 1),
                       ending: NSColor(srgbRed: 0.185, green: 0.185, blue: 0.205, alpha: 1))!
    g.draw(in: squircle, angle: 90)

    switch variant {
    case "waves":    drawWaves(small: small)
    case "ear-fill": drawEarFill(small: small)
    default:         drawEar(small: small, badge: variant == "ear-badge")
    }
}

// 红点：正在听。三个方案共用
func drawRedDot(small: Bool) {
    let S = 1024.0
    let dotR = (small ? 0.092 : 0.078) * S
    let dotC = NSPoint(x: 0.735 * S, y: 0.285 * S)
    let dot = NSBezierPath(ovalIn: NSRect(x: dotC.x - dotR, y: dotC.y - dotR,
                                          width: 2 * dotR, height: 2 * dotR))
    let sh = NSShadow()
    sh.shadowColor = red.withAlphaComponent(0.8)
    sh.shadowBlurRadius = small ? 0 : 0.05 * S
    sh.shadowOffset = .zero
    NSGraphicsContext.saveGraphicsState()
    sh.set()
    red.setFill()
    dot.fill()
    NSGraphicsContext.restoreGraphicsState()
}

// 实心剪影方案：白色耳朵剪影 + 深色耳甲腔（空洞），小尺寸下比描线稳
func drawEarFill(small: Bool) {
    let S = 1024.0
    let pt = { (x: Double, y: Double) in NSPoint(x: x * S, y: y * S) }
    let p = NSBezierPath()
    p.windingRule = .evenOdd
    // 外轮廓
    p.move(to: pt(0.435, 0.245))                                        // 耳垂底
    p.curve(to: pt(0.585, 0.330), controlPoint1: pt(0.500, 0.215), controlPoint2: pt(0.590, 0.255))
    p.curve(to: pt(0.615, 0.470), controlPoint1: pt(0.622, 0.380), controlPoint2: pt(0.628, 0.430))
    p.curve(to: pt(0.585, 0.545), controlPoint1: pt(0.615, 0.515), controlPoint2: pt(0.605, 0.535)) // 耳道口的凹陷
    p.curve(to: pt(0.645, 0.655), controlPoint1: pt(0.625, 0.575), controlPoint2: pt(0.655, 0.605))
    p.curve(to: pt(0.525, 0.760), controlPoint1: pt(0.625, 0.720), controlPoint2: pt(0.590, 0.760))
    p.curve(to: pt(0.385, 0.635), controlPoint1: pt(0.455, 0.760), controlPoint2: pt(0.385, 0.715))
    p.curve(to: pt(0.395, 0.490), controlPoint1: pt(0.385, 0.575), controlPoint2: pt(0.385, 0.530))
    p.curve(to: pt(0.435, 0.245), controlPoint1: pt(0.405, 0.430), controlPoint2: pt(0.415, 0.310))
    p.close()
    // 耳甲腔（空洞，带一条朝下的尾巴）
    p.move(to: pt(0.462, 0.385))
    p.curve(to: pt(0.585, 0.500), controlPoint1: pt(0.520, 0.400), controlPoint2: pt(0.565, 0.440))
    p.curve(to: pt(0.565, 0.625), controlPoint1: pt(0.600, 0.550), controlPoint2: pt(0.610, 0.590))
    p.curve(to: pt(0.462, 0.605), controlPoint1: pt(0.525, 0.655), controlPoint2: pt(0.487, 0.650))
    p.curve(to: pt(0.462, 0.385), controlPoint1: pt(0.425, 0.550), controlPoint2: pt(0.432, 0.460))
    p.close()
    NSColor.white.setFill()
    p.fill()
    drawRedDot(small: small)
}

func drawEar(small: Bool, badge: Bool) {
    let S = 1024.0
    let p = NSBezierPath()
    p.lineWidth = (small ? 0.100 : 0.080) * S
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    let pt = { (x: Double, y: Double) in NSPoint(x: x * S, y: y * S) }
    p.move(to: pt(0.420, 0.245))                                              // 耳垂起点
    p.curve(to: pt(0.545, 0.295), controlPoint1: pt(0.490, 0.225), controlPoint2: pt(0.545, 0.245))
    p.curve(to: pt(0.625, 0.460), controlPoint1: pt(0.625, 0.365), controlPoint2: pt(0.640, 0.410))
    p.curve(to: pt(0.595, 0.630), controlPoint1: pt(0.615, 0.530), controlPoint2: pt(0.625, 0.590))
    p.curve(to: pt(0.490, 0.730), controlPoint1: pt(0.570, 0.685), controlPoint2: pt(0.535, 0.730))
    p.curve(to: pt(0.380, 0.645), controlPoint1: pt(0.430, 0.730), controlPoint2: pt(0.380, 0.705))
    p.curve(to: pt(0.440, 0.505), controlPoint1: pt(0.380, 0.575), controlPoint2: pt(0.405, 0.530))
    p.curve(to: pt(0.560, 0.450), controlPoint1: pt(0.480, 0.478), controlPoint2: pt(0.530, 0.488))
    p.curve(to: pt(0.492, 0.340), controlPoint1: pt(0.585, 0.410), controlPoint2: pt(0.540, 0.340))
    NSColor.white.setStroke()
    p.stroke()

    drawRedDot(small: small)

    // 橙点：有没看过的新待办（可选方案）
    if badge && !small {
        let bR = 0.055 * S
        let bC = pt(0.760, 0.760)
        let b = NSBezierPath(ovalIn: NSRect(x: bC.x - bR, y: bC.y - bR,
                                            width: 2 * bR, height: 2 * bR))
        let sh2 = NSShadow()
        sh2.shadowColor = orange.withAlphaComponent(0.7)
        sh2.shadowBlurRadius = 0.035 * S
        sh2.shadowOffset = .zero
        NSGraphicsContext.saveGraphicsState()
        sh2.set()
        orange.setFill()
        b.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

func drawWaves(small: Bool) {
    let S = 1024.0
    let c = NSPoint(x: 0.335 * S, y: 0.50 * S)
    let r = (small ? 0.085 : 0.070) * S
    let dot = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    red.setFill()
    dot.fill()
    NSColor.white.setStroke()
    for (rad, lw) in [(0.180, 0.052), (0.285, 0.052), (0.390, 0.052)] {
        let p = NSBezierPath()
        p.lineWidth = lw * S * (small ? 1.3 : 1.0)
        p.lineCapStyle = .round
        p.appendArc(withCenter: c, radius: rad * S, startAngle: -52, endAngle: 52)
        p.stroke()
    }
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("PNG 编码失败：\(path)\n".data(using: .utf8)!)
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

// ---------- 执行 ----------
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

if install {
    // iconset → Resources/AppIcon.icns
    let iconset = "\(outDir)/EarShot.iconset"
    try? FileManager.default.removeItem(atPath: iconset)
    try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
    var cache: [Int: NSBitmapImageRep] = [:]
    for n in [16, 32, 64, 128, 256, 512, 1024] { cache[n] = renderPixels(n, variant: "ear") }
    let names: [(Int, String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for (n, name) in names { writePNG(cache[n]!, to: "\(iconset)/\(name)") }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
    try! task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        FileHandle.standardError.write("iconutil 失败\n".data(using: .utf8)!)
        exit(1)
    }
    print("已写入 Resources/AppIcon.icns")
} else {
    for v in variants {
        for n in sizes {
            let rep = renderPixels(n, variant: v)
            writePNG(rep, to: "\(outDir)/\(v)-\(n).png")
            print("\(outDir)/\(v)-\(n).png")
        }
    }
}
