import AppKit

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Borderless, non-activating floating panel shared by the anchor button and
/// the result card. Clicking it never activates Suiyi, so the app the user is
/// working in keeps focus.
final class FloatingPanel: NSPanel {
    /// The anchor never needs key status; the result card does (so text in it
    /// can be selected and copied).
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    /// Set by tests: panels lay out and render but never appear on screen or take focus.
    nonisolated(unsafe) static var isHeadless = false

    override func orderFrontRegardless() {
        if !Self.isHeadless { super.orderFrontRegardless() }
    }

    override func makeKey() {
        if !Self.isHeadless { super.makeKey() }
    }

    static func make(size: NSSize, allowsKey: Bool) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.allowsKey = allowsKey
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        return panel
    }
}

/// A button that reacts to the very first click even though its window is not
/// key and the app is not active.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Plain view reporting hover enter/exit, even while the app is inactive.
final class HoverView: NSView {
    var onEnter: (@MainActor () -> Void)?
    var onExit: (@MainActor () -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let old = trackingArea {
            removeTrackingArea(old)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Top-to-bottom coordinate system, used as a scroll view document.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
enum ScreenGeometry {
    static func screen(containing point: NSPoint) -> NSScreen? {
        if let hit = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    /// Moves `rect` so it is fully inside the visible frame of the screen that
    /// contains `reference`. If it would fall off the bottom, it is flipped
    /// above the reference point first.
    static func fit(_ rect: NSRect, reference: NSPoint) -> NSRect {
        guard let screen = screen(containing: reference) else { return rect }
        let visible = screen.visibleFrame.insetBy(dx: 6, dy: 6)
        var r = rect
        if r.minY < visible.minY {
            let above = reference.y + 16
            if above + r.height <= visible.maxY {
                r.origin.y = above
            } else {
                r.origin.y = visible.minY
            }
        }
        if r.maxY > visible.maxY { r.origin.y = visible.maxY - r.height }
        if r.minY < visible.minY { r.origin.y = visible.minY }
        if r.maxX > visible.maxX { r.origin.x = visible.maxX - r.width }
        if r.minX < visible.minX { r.origin.x = visible.minX }
        return r
    }

    /// Height of the primary (menu-bar) screen; AX uses a top-left origin on it.
    static var primaryScreenHeight: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }
}
