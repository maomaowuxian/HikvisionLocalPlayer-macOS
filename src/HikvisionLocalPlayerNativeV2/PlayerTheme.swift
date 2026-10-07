import AppKit

enum PlayerTheme {
    static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
    static let canvas = color(0x080b0f)
    static let panel = color(0x10161f)
    static let toolbar = color(0x141c26)
    static let input = color(0x0b1118)
    static let border = color(0x293747)
    static let text = color(0xf2f4f8)
    static let secondary = color(0xb1bac7)
    static let muted = color(0x718299)
    static let red = color(0xec293d)
    static let green = color(0x30cf83)
}

// Native controls retain their targets, keyboard handling and accessibility.
// Drawing is static: the theme introduces no timers or continuous animations.
final class PlayerButton: NSButton {
    var primary = false { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize {
        let size = (title as NSString).size(withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium)])
        return NSSize(width: ceil(size.width) + 24, height: 32)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if primary && isEnabled {
            let gradient = NSGradient(starting: PlayerTheme.red,
                                      ending: PlayerTheme.color(0xc91c2f))!
            gradient.draw(in: path, angle: -90)
        } else {
            (isHighlighted ? PlayerTheme.color(0x283646) :
                PlayerTheme.toolbar).setFill()
            path.fill()
        }
        (primary && isEnabled ? PlayerTheme.color(0xff4b5c) : PlayerTheme.border).setStroke()
        path.lineWidth = 1
        path.stroke()
        if isHighlighted && primary {
            NSColor.black.withAlphaComponent(0.13).setFill()
            path.fill()
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isEnabled ? PlayerTheme.text : PlayerTheme.muted
        ]
        let label = NSAttributedString(string: title, attributes: attributes)
        let size = label.size()
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                               y: (bounds.height - size.height) / 2))
        if window?.firstResponder === self {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let focus = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2),
                                     xRadius: 7, yRadius: 7)
            focus.lineWidth = 2
            focus.stroke()
        }
    }
}

final class PlayerSegmentedControl: NSSegmentedControl {
    var usesRedSelection = false { didSet { needsDisplay = true } }

    override var selectedSegment: Int {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard segmentCount > 0 else { return }
        let width = bounds.width / CGFloat(segmentCount)
        for index in 0..<segmentCount {
            let rect = NSRect(x: CGFloat(index) * width + 2, y: 1,
                              width: width - 4, height: bounds.height - 2)
            let selected = isSelected(forSegment: index)
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            (selected ? (usesRedSelection ? PlayerTheme.color(0x2b1923) :
                            PlayerTheme.color(0x1b2736)) : PlayerTheme.input).setFill()
            path.fill()
            (selected ? (usesRedSelection ? PlayerTheme.red :
                            PlayerTheme.color(0x667e98)) : PlayerTheme.border).setStroke()
            path.lineWidth = 1
            path.stroke()
            let label = NSAttributedString(string: label(forSegment: index) ?? "",
                attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: isEnabled ? PlayerTheme.text : PlayerTheme.muted])
            let size = label.size()
            label.draw(at: NSPoint(x: rect.midX - size.width / 2,
                                   y: rect.midY - size.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, segmentCount > 0 else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = min(segmentCount - 1, max(0,
            Int(point.x / max(1, bounds.width / CGFloat(segmentCount)))))
        selectedSegment = index
        for i in 0..<segmentCount { setSelected(i == index, forSegment: i) }
        needsDisplay = true
        sendAction(action, to: target)
    }
}

final class PlayerTextFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let height = min(rect.height, ceil((font?.ascender ?? 13) - (font?.descender ?? -3)) + 3)
        return NSRect(x: rect.minX + 10, y: rect.midY - height / 2,
                      width: max(0, rect.width - 20), height: height)
    }
}

final class PlayerSecureTextFieldCell: NSSecureTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let height = min(rect.height, ceil((font?.ascender ?? 13) - (font?.descender ?? -3)) + 3)
        return NSRect(x: rect.minX + 10, y: rect.midY - height / 2,
                      width: max(0, rect.width - 20), height: height)
    }
}
