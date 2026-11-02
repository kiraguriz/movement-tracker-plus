#!/usr/bin/env swift
import AppKit
import Foundation

// Trace artwork from the redesign, drawn natively. Run from the repository root.
let size = 1024
let variants: [(filename: String, background: UInt32, trace: UInt32, plus: UInt32)] = [
    ("AppIcon.png", 0x2B4BFF, 0xFFFFFF, 0xFFB020),
    ("AppIcon-Dark.png", 0x0B0D12, 0x8C9DFF, 0xFFB020),
    ("AppIcon-Tinted.png", 0x25272D, 0xDADDE5, 0xDADDE5)
]

func color(_ hex: UInt32) -> CGColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: 1).cgColor
}

for variant in variants {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(color(variant.background))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 112, y: -CGFloat(size) / 112)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    context.move(to: CGPoint(x: 14, y: 40))
    context.addLine(to: CGPoint(x: 30, y: 40))
    context.addCurve(to: CGPoint(x: 56, y: 82),
        control1: CGPoint(x: 40, y: 40), control2: CGPoint(x: 42, y: 82))
    context.addCurve(to: CGPoint(x: 82, y: 40),
        control1: CGPoint(x: 70, y: 82), control2: CGPoint(x: 72, y: 40))
    context.addLine(to: CGPoint(x: 98, y: 40))
    context.setLineWidth(9)
    context.setStrokeColor(color(variant.trace))
    context.strokePath()

    context.move(to: CGPoint(x: 92, y: 13))
    context.addLine(to: CGPoint(x: 92, y: 27))
    context.move(to: CGPoint(x: 85, y: 20))
    context.addLine(to: CGPoint(x: 99, y: 20))
    context.setLineWidth(5)
    context.setStrokeColor(color(variant.plus))
    context.strokePath()

    // Leave corners square so the system applies the current app icon mask.
    let output = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/\(variant.filename)")
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    try bitmap.representation(using: .png, properties: [:])!.write(to: output)
    print(output.path)
}
