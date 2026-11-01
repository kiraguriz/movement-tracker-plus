#!/usr/bin/env swift
import AppKit
import Foundation

// Original vector artwork. No external assets or image packages. Run from the repository root.
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
NSColor(srgbRed: 0.035, green: 0.075, blue: 0.12, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

let glow = NSBezierPath(ovalIn: NSRect(x: 150, y: 150, width: 724, height: 724))
NSGradient(starting: NSColor(srgbRed: 0.06, green: 0.22, blue: 0.27, alpha: 1),
           ending: NSColor(srgbRed: 0.035, green: 0.075, blue: 0.12, alpha: 1))!
    .draw(in: glow, relativeCenterPosition: NSPoint(x: 0.3, y: 0.5))

let movement = NSBezierPath()
movement.move(to: NSPoint(x: 222, y: 317))
movement.line(to: NSPoint(x: 373, y: 650))
movement.line(to: NSPoint(x: 513, y: 416))
movement.line(to: NSPoint(x: 653, y: 650))
movement.line(to: NSPoint(x: 802, y: 317))
movement.lineWidth = 84
movement.lineJoinStyle = .round
movement.lineCapStyle = .round
NSColor(srgbRed: 0.2, green: 0.89, blue: 0.77, alpha: 1).setStroke()
movement.stroke()

NSColor(srgbRed: 0.7, green: 1, blue: 0.84, alpha: 1).setFill()
for point in [NSPoint(x: 373, y: 650), NSPoint(x: 513, y: 416), NSPoint(x: 653, y: 650)] {
    NSBezierPath(ovalIn: NSRect(x: point.x - 22, y: point.y - 22, width: 44, height: 44)).fill()
}
let plus = NSBezierPath()
plus.move(to: NSPoint(x: 764, y: 735)); plus.line(to: NSPoint(x: 764, y: 855))
plus.move(to: NSPoint(x: 704, y: 795)); plus.line(to: NSPoint(x: 824, y: 795))
plus.lineWidth = 30; plus.lineCapStyle = .round
NSColor(srgbRed: 0.7, green: 1, blue: 0.84, alpha: 1).setStroke(); plus.stroke()
NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
try bitmap.representation(using: .png, properties: [:])!.write(to: output)
print(output.path)
