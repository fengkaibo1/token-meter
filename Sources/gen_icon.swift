import AppKit
import CoreGraphics

// 生成 TokenMeter 图标：渐变圆角方块 + 白色仪表盘（余额/用量仪）
func render(_ px: Int) -> Data? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext

    let s = CGFloat(px)
    cg.setAllowsAntialiasing(true)
    cg.setShouldAntialias(true)

    // 背景：渐变圆角方块
    let inset = s * 0.06
    let rr = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = (s - 2 * inset) * 0.24
    cg.addPath(CGPath(roundedRect: rr, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let grad = CGGradient(colorsSpace: space,
                          colors: [NSColor.systemIndigo.cgColor, NSColor.systemTeal.cgColor] as CFArray,
                          locations: [0, 1])!
    cg.drawLinearGradient(grad, start: CGPoint(x: rr.minX, y: rr.minY),
                          end: CGPoint(x: rr.maxX, y: rr.maxY), options: [])

    // 白色仪表盘弧（270°，底部留缝）
    let center = CGPoint(x: s * 0.5, y: s * 0.5)
    let r = s * 0.29
    let a0 = CGFloat(135) * .pi / 180
    let a1 = CGFloat(405) * .pi / 180
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(s * 0.075)
    cg.setLineCap(.round)
    cg.addArc(center: center, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
    cg.strokePath()

    // 指针（指向右上，表示"余量"）
    let nA = CGFloat(55) * .pi / 180
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(s * 0.10)
    cg.move(to: center)
    cg.addLine(to: CGPoint(x: center.x + cos(nA) * r * 0.95, y: center.y + sin(nA) * r * 0.95))
    cg.strokePath()

    // 中心圆点
    cg.setFillColor(NSColor.white.cgColor)
    let hub = s * 0.07
    cg.fillEllipse(in: CGRect(x: center.x - hub / 2, y: center.y - hub / 2, width: hub, height: hub))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outDir = "assets"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let menuBar: Data? = render(44)      // 菜单栏：22pt @2x
let master: Data? = render(1024)     // 主图标
if let d = menuBar { try? d.write(to: URL(fileURLWithPath: "\(outDir)/icon.png")) }
if let d = master { try? d.write(to: URL(fileURLWithPath: "\(outDir)/icon_1024.png")) }
print("生成完成: assets/icon.png (44px), assets/icon_1024.png (1024px)")
