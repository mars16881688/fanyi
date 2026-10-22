import AppKit

/// Self-drawn button for the glass panels. System bezels placed on an
/// NSVisualEffectView pick up vibrancy and are dimmed while the non-key panel
/// is inactive, which made labels look washed out. This draws opaque, crisp
/// colours in every window state.
@MainActor
final class GlassButton: NSButton {
    enum Style {
        case primary    // accent fill, white label
        case secondary  // light translucent fill, primary label colour
        case plain      // no fill until hovered; icon-only controls
    }

    enum Size {
        case regular
        case small

        var height: CGFloat { self == .regular ? 30 : 24 }
        var padding: CGFloat { self == .regular ? 12 : 9 }
        var font: NSFont {
            self == .regular ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12, weight: .medium)
        }
        var iconPointSize: CGFloat { self == .regular ? 13 : 11 }
    }

    var style: Style = .secondary { didSet { needsDisplay = true } }
    var size: Size = .regular { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var symbolName: String? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    /// Overrides the label/icon colour (used for the accent-coloured bubble).
    var tint: NSColor? { didSet { needsDisplay = true } }
    var iconPointSize: CGFloat? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    private var hovering = false { didSet { needsDisplay = true } }
    private var hoverArea: NSTrackingArea?
    private static let gap: CGFloat = 5

    convenience init(title: String, symbol: String?, style: Style = .secondary, size: Size = .regular,
                     target: AnyObject?, action: Selector?) {
        self.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryPushIn)
        self.title = title
        self.symbolName = symbol
        self.style = style
        self.size = size
        self.target = target
        self.action = action
    }

    override class var cellClass: AnyClass? {
        get { GlassButtonCell.self }
        set {}
    }

    override var allowsVibrancy: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var title: String { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    override var isHighlighted: Bool { didSet { needsDisplay = true } }

    // MARK: Metrics

    private func symbolImage(color: NSColor) -> NSImage? {
        guard let symbolName,
              let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: iconPointSize ?? size.iconPointSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return base.withSymbolConfiguration(config)
    }

    private var titleAttributes: [NSAttributedString.Key: Any] { [.font: size.font] }

    override var intrinsicContentSize: NSSize {
        let textWidth = title.isEmpty ? 0 : ceil((title as NSString).size(withAttributes: titleAttributes).width)
        let iconWidth = symbolImage(color: .labelColor)?.size.width ?? 0
        let gap = (textWidth > 0 && iconWidth > 0) ? Self.gap : 0
        if textWidth == 0 {
            return NSSize(width: size.height, height: size.height)
        }
        return NSSize(width: ceil(size.padding * 2 + iconWidth + gap + textWidth), height: size.height)
    }

    override func sizeToFit() {
        setFrameSize(intrinsicContentSize)
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    // MARK: Secondary click

    /// 0.2.1.k.06: when set, a right-click, a two-finger trackpad click or a Control-click calls this
    /// instead of the button's action.
    var onSecondaryClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        guard let onSecondaryClick else { return super.rightMouseDown(with: event) }
        onSecondaryClick()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let onSecondaryClick { return onSecondaryClick() }
        super.mouseDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Drawing

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func colors() -> (fill: NSColor?, stroke: NSColor?, foreground: NSColor) {
        let active = hovering || isHighlighted
        switch style {
        case .primary:
            let fraction: CGFloat = isHighlighted ? 0.22 : (hovering ? 0.1 : 0)
            let fill = NSColor.controlAccentColor.blended(withFraction: fraction, of: .black) ?? .controlAccentColor
            return (fill, nil, tint ?? .white)
        case .secondary:
            let fill = isDark ? NSColor.white.withAlphaComponent(active ? 0.2 : 0.12)
                              : NSColor.white.withAlphaComponent(active ? 0.98 : 0.78)
            let stroke = isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)
            return (fill, stroke, tint ?? .labelColor)
        case .plain:
            let fill: NSColor? = active ? (isDark ? NSColor.white.withAlphaComponent(0.14)
                                                  : NSColor.black.withAlphaComponent(0.07)) : nil
            return (fill, nil, tint ?? .secondaryLabelColor)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(isEnabled ? 1 : 0.4)

        let (fill, stroke, foreground) = colors()
        let radius = bounds.height / 2
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        if let fill {
            fill.setFill()
            shape.fill()
        }
        if let stroke {
            stroke.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }

        let icon = symbolImage(color: foreground)
        var attributes = titleAttributes
        attributes[.foregroundColor] = foreground
        let text = NSAttributedString(string: title, attributes: attributes)
        let textSize = title.isEmpty ? .zero : text.size()
        let iconSize = icon?.size ?? .zero
        let gap = (textSize.width > 0 && iconSize.width > 0) ? Self.gap : 0
        var x = bounds.midX - (iconSize.width + gap + textSize.width) / 2
        if let icon {
            icon.draw(in: NSRect(x: x, y: bounds.midY - iconSize.height / 2,
                                 width: iconSize.width, height: iconSize.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += iconSize.width + gap
        }
        if textSize.width > 0 {
            text.draw(at: NSPoint(x: x, y: bounds.midY - textSize.height / 2))
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// Keeps the system cell from painting its own title/bezel over the custom
/// drawing while the mouse is down; only the pressed state is forwarded.
final class GlassButtonCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        isHighlighted = flag
        controlView.needsDisplay = true
    }

    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {}
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {}
}
