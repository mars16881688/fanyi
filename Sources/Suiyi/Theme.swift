import AppKit

/// Frosted-glass surface: behind-window vibrant blur, continuous rounded
/// corners (via maskImage so the blur itself is clipped), a bright hairline
/// inner border and a soft top highlight. Adapts to light and dark.
@MainActor
final class RoundedMaterialView: NSVisualEffectView {
    var radius: CGFloat = 20 { didSet { applyShape() } }

    private let rim = CAShapeLayer()
    private let tint = CALayer()
    private let sheen = CAGradientLayer()
    private var appliedMaskRadius: CGFloat = -1
    private static var maskCache: [CGFloat: NSImage] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        rim.fillColor = nil
        rim.lineWidth = 1
        sheen.startPoint = CGPoint(x: 0.5, y: 1)
        sheen.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(tint)
        layer?.addSublayer(sheen)
        layer?.addSublayer(rim)
        applyShape()
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    override func layout() {
        super.layout()
        applyShape()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyShape()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyShape()
    }

    private func applyShape() {
        let r = min(radius, min(bounds.width, bounds.height) / 2)
        if r != appliedMaskRadius {   // 0.2.1.k.11: the mask only depends on the radius
            appliedMaskRadius = r
            maskImage = Self.mask(radius: r)
        }
        guard let layer else { return }
        layer.cornerRadius = r
        if #available(macOS 11.0, *) { layer.cornerCurve = .continuous }
        layer.masksToBounds = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let inset = bounds.insetBy(dx: 0.5, dy: 0.5)
        rim.frame = bounds
        rim.path = CGPath(roundedRect: inset, cornerWidth: max(0, r - 0.5), cornerHeight: max(0, r - 0.5), transform: nil)
        rim.strokeColor = NSColor.white.withAlphaComponent(isDark ? 0.16 : 0.55).cgColor
        // A faint base tint keeps text readable over saturated backdrops.
        tint.frame = bounds
        tint.backgroundColor = (isDark ? NSColor.black.withAlphaComponent(0.18)
                                       : NSColor.white.withAlphaComponent(0.28)).cgColor
        sheen.frame = bounds
        sheen.colors = [NSColor.white.withAlphaComponent(isDark ? 0.07 : 0.22).cgColor,
                        NSColor.white.withAlphaComponent(0).cgColor]
        sheen.locations = [0, 0.45]
        CATransaction.commit()
    }

    /// Resizable rounded-rect mask; clips the behind-window blur itself.
    private static func mask(radius: CGFloat) -> NSImage {
        if let cached = maskCache[radius] { return cached }
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        maskCache[radius] = image
        return image
    }
}

/// Very light translucent inner card that sits on the glass.
@MainActor
final class RoundedSurfaceView: NSView {
    var radius: CGFloat = 12
    var accent = false

    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: radius, yRadius: radius)
        if accent {
            NSColor.controlAccentColor.setFill()
        } else {
            (dark ? NSColor.white.withAlphaComponent(0.07) : NSColor.white.withAlphaComponent(0.38)).setFill()
        }
        path.fill()
        (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.white.withAlphaComponent(0.7)).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
enum SuiyiStyle {
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
