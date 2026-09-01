#!/usr/bin/env swift
// 生成 App 图标（Packaging/AppIcon.icns）。
// 视觉语言与应用内保持一致：强调色渐变圆角方形 + 白色像素波形柱。
// 用法：swift Packaging/make-icon.swift  （输出到 Packaging/AppIcon.icns）

import AppKit

/// macOS 图标网格：1024 画布中，圆角方形约占 824，四周留出投影余量。
let canvasRatio: CGFloat = 824.0 / 1024.0
/// Big Sur 之后的圆角比例。
let cornerRatio: CGFloat = 0.2237

/// 波形柱高度权重（对称，中间最高），与菜单栏像素波形的形态呼应。
let barWeights: [CGFloat] = [0.34, 0.62, 1.0, 0.62, 0.34]

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.shouldAntialias = true
    ctx.imageInterpolation = .high

    let plate = size * canvasRatio
    let originX = (size - plate) / 2
    let originY = (size - plate) / 2
    let rect = NSRect(x: originX, y: originY, width: plate, height: plate)
    let radius = plate * cornerRatio
    let plateePath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // 底板渐变（上浅下深，模拟自然光）
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.29, green: 0.62, blue: 1.00, alpha: 1),
        NSColor(srgbRed: 0.04, green: 0.35, blue: 0.86, alpha: 1),
    ])!
    plateePath.addClip()
    gradient.draw(in: rect, angle: -90)

    // 顶部高光，避免大色块显得扁平
    let sheen = NSGradient(colors: [
        NSColor(white: 1, alpha: 0.20),
        NSColor(white: 1, alpha: 0.0),
    ])!
    sheen.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

    // 白色波形柱
    let barWidth = plate * 0.108
    let gap = plate * 0.074
    let totalWidth = barWidth * CGFloat(barWeights.count) + gap * CGFloat(barWeights.count - 1)
    let maxBarHeight = plate * 0.52
    var x = rect.midX - totalWidth / 2
    NSColor.white.setFill()
    for weight in barWeights {
        let h = maxBarHeight * weight
        let bar = NSRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
        let r = barWidth * 0.3
        NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).fill()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// —— 输出 iconset 并交给 iconutil 打包 ——
let packagingDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = packagingDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (基准尺寸, 是否 @2x)
let variants: [(Int, Bool)] = [(16, false), (16, true), (32, false), (32, true),
                               (128, false), (128, true), (256, false), (256, true),
                               (512, false), (512, true)]
for (base, isRetina) in variants {
    let pixels = isRetina ? base * 2 : base
    let rep = drawIcon(size: CGFloat(pixels))
    let data = rep.representation(using: .png, properties: [:])!
    let suffix = isRetina ? "@2x" : ""
    let url = iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png")
    try! data.write(to: url)
}

let icns = packagingDir.appendingPathComponent("AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("iconutil 失败") }
try? FileManager.default.removeItem(at: iconset)
print("已生成 \(icns.path)")
