// Renders WheelConvert's app icon at every macOS size: swift scripts/assets/make-icon.swift <AppIcon.appiconset>
import AppKit

func render(_ pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    // Squircle body (Apple's grid: 824pt body inside 1024 canvas).
    let body = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: body, cornerWidth: 186 * s, cornerHeight: 186 * s, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.45, green: 0.33, blue: 1, alpha: 1), CGColor(srgbRed: 0.13, green: 0.62, blue: 1, alpha: 1)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft top light.
    let shine = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(shine, startCenter: CGPoint(x: body.midX, y: body.maxY), startRadius: 0, endCenter: CGPoint(x: body.midX, y: body.maxY), endRadius: 620 * s, options: [])
    // The wheel: six petals around a hub; the top petal is "highlighted".
    let center = CGPoint(x: body.midX, y: body.midY - 6 * s)
    let outer = 300 * s, inner = 132 * s, gap = 0.075
    for i in 0..<6 {
        let mid = CGFloat.pi / 2 - CGFloat(i) * .pi / 3
        let a0 = mid + .pi / 6 - CGFloat(gap), a1 = mid - .pi / 6 + CGFloat(gap)
        let petal = CGMutablePath()
        petal.addArc(center: center, radius: outer, startAngle: a0, endAngle: a1, clockwise: true)
        petal.addArc(center: center, radius: inner, startAngle: a1 + 0.05, endAngle: a0 - 0.05, clockwise: false)
        petal.closeSubpath()
        ctx.addPath(petal)
        if i == 0 {
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.84, blue: 0.36, alpha: 1))
        } else {
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.92))
        }
        ctx.fillPath()
    }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - 84 * s, y: center.y - 84 * s, width: 168 * s, height: 168 * s))
    // Circular arrows in the hub: conversion.
    ctx.setStrokeColor(CGColor(srgbRed: 0.30, green: 0.45, blue: 1, alpha: 1))
    ctx.setLineWidth(22 * s)
    ctx.setLineCap(.round)
    for k in 0..<2 {
        let start = CGFloat(k) * .pi + 0.35, end = start + .pi - 0.7
        ctx.addArc(center: center, radius: 46 * s, startAngle: start, endAngle: end, clockwise: false)
        ctx.strokePath()
        let tip = CGPoint(x: center.x + 46 * s * cos(end), y: center.y + 46 * s * sin(end))
        let dir = end + .pi / 2
        let head = CGMutablePath()
        head.move(to: CGPoint(x: tip.x + 30 * s * cos(dir), y: tip.y + 30 * s * sin(dir)))
        head.addLine(to: CGPoint(x: tip.x + 20 * s * cos(dir + 2.3), y: tip.y + 20 * s * sin(dir + 2.3)))
        head.addLine(to: CGPoint(x: tip.x + 20 * s * cos(dir - 2.3), y: tip.y + 20 * s * sin(dir - 2.3)))
        head.closeSubpath()
        ctx.addPath(head)
        ctx.setFillColor(CGColor(srgbRed: 0.30, green: 0.45, blue: 1, alpha: 1))
        ctx.fillPath()
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(points * scale).write(to: folder.appendingPathComponent(name))
        images.append(["size": "\(points)x\(points)", "idiom": "mac", "filename": name, "scale": "\(scale)x"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("Contents.json"))
