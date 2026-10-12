import AppKit

/// Layer colors must be resolved again when the system appearance changes.
@MainActor
final class RoundedMaterialView: NSVisualEffectView {
    var radius: CGFloat = 14

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.cornerRadius = radius
            layer?.borderWidth = 0.5
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

@MainActor
final class RoundedSurfaceView: NSView {
    var radius: CGFloat = 10
    var accent = false

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        (accent ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor)
            .withAlphaComponent(accent ? 1 : 0.07).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
enum FanyiStyle {
    static func symbol(_ name: String, description: String, size: CGFloat = 12) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        return image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .medium)) ?? image
    }

    static var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        return style
    }
}
