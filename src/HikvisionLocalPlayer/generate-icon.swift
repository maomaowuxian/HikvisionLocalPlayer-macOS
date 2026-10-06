import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon <output.png>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    exit(3)
}

bitmap.size = NSSize(width: size, height: size)

NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    exit(4)
}
NSGraphicsContext.current = context
context.shouldAntialias = true
context.imageInterpolation = .high

NSColor.clear.setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

let outer = NSBezierPath(
    roundedRect: NSRect(x: 32, y: 32, width: 960, height: 960),
    xRadius: 216,
    yRadius: 216
)
let gradient = NSGradient(
    starting: NSColor(calibratedRed: 242/255, green: 59/255, blue: 72/255, alpha: 1),
    ending: NSColor(calibratedRed: 189/255, green: 23/255, blue: 35/255, alpha: 1)
)!
gradient.draw(in: outer, angle: -45)

let border = NSBezierPath(
    roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904),
    xRadius: 188,
    yRadius: 188
)
border.lineWidth = 16
NSColor(calibratedRed: 1, green: 119/255, blue: 128/255, alpha: 0.72).setStroke()
border.stroke()

let h = NSBezierPath()
h.move(to: NSPoint(x: 312, y: 288))
h.line(to: NSPoint(x: 432, y: 288))
h.line(to: NSPoint(x: 432, y: 448))
h.line(to: NSPoint(x: 592, y: 448))
h.line(to: NSPoint(x: 592, y: 288))
h.line(to: NSPoint(x: 712, y: 288))
h.line(to: NSPoint(x: 712, y: 736))
h.line(to: NSPoint(x: 592, y: 736))
h.line(to: NSPoint(x: 592, y: 576))
h.line(to: NSPoint(x: 432, y: 576))
h.line(to: NSPoint(x: 432, y: 736))
h.line(to: NSPoint(x: 312, y: 736))
h.close()
NSColor.white.setFill()
h.fill()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    exit(5)
}
try png.write(to: output)
