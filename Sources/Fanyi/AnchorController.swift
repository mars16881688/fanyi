import AppKit

enum ActionKind {
    case translate
    case rewrite
}

/// The small round button shown after a mouse selection. Click it (or hover
/// for ~350 ms) and it turns into two buttons: 翻译 / 改写.
@MainActor
final class AnchorController: NSObject {
    var onPick: (@MainActor (ActionKind) -> Void)?
    private(set) var referencePoint = NSPoint.zero

    private static let bubbleSize: CGFloat = 26
    private static let autoHideSeconds: UInt64 = 4
    private static let hoverDelay: UInt64 = 350_000_000

    private let panel: FloatingPanel
    private let root: HoverView
    private let circle: NSView
    private let bubble: FirstMouseButton
    private let choices: NSVisualEffectView
    private let translateButton: FirstMouseButton
    private let rewriteButton: FirstMouseButton

    private var expanded = false
    private var topLeft = NSPoint.zero
    private var hideTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    override init() {
        let size: CGFloat = 26
        let square = NSRect(x: 0, y: 0, width: size, height: size)
        panel = FloatingPanel.make(size: square.size, allowsKey: false)
        root = HoverView(frame: square)
        circle = NSView(frame: square)
        bubble = FirstMouseButton(frame: square)
        choices = NSVisualEffectView(frame: .zero)
        translateButton = FirstMouseButton(title: "翻译", target: nil, action: nil)
        rewriteButton = FirstMouseButton(title: "改写", target: nil, action: nil)
        super.init()
        configure()
    }

    private func configure() {
        let size = AnchorController.bubbleSize
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        circle.wantsLayer = true
        circle.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        circle.layer?.cornerRadius = size / 2
        circle.layer?.borderWidth = 1
        circle.layer?.borderColor = NSColor.white.withAlphaComponent(0.55).cgColor
        root.addSubview(circle)

        bubble.isBordered = false
        bubble.title = ""
        bubble.imagePosition = .imageOnly
        bubble.imageScaling = .scaleProportionallyDown
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        if let symbol = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Fanyi") {
            bubble.image = symbol.withSymbolConfiguration(config) ?? symbol
        } else {
            bubble.title = "译"
        }
        bubble.contentTintColor = .white
        bubble.toolTip = "Fanyi：翻译 / 改写"
        bubble.target = self
        bubble.action = #selector(bubbleClicked(_:))
        circle.addSubview(bubble)

        choices.material = .popover
        choices.blendingMode = .behindWindow
        choices.state = .active
        choices.wantsLayer = true
        choices.layer?.cornerRadius = 8
        choices.layer?.masksToBounds = true
        choices.isHidden = true
        root.addSubview(choices)

        translateButton.target = self
        translateButton.action = #selector(pickTranslate(_:))
        rewriteButton.target = self
        rewriteButton.action = #selector(pickRewrite(_:))
        choices.addSubview(translateButton)
        choices.addSubview(rewriteButton)

        root.onEnter = { [weak self] in self?.pointerEntered() }
        root.onExit = { [weak self] in self?.pointerExited() }
    }

    func show(at point: NSPoint) {
        cancelTimers()
        referencePoint = point
        expanded = false
        choices.isHidden = true
        circle.isHidden = false
        topLeft = NSPoint(x: point.x + 8, y: point.y - 8)
        let size = AnchorController.bubbleSize
        applySize(NSSize(width: size, height: size))
        panel.orderFrontRegardless()
        scheduleHide()
    }

    func hide() {
        cancelTimers()
        expanded = false
        panel.orderOut(nil)
    }

    private func cancelTimers() {
        hideTask?.cancel()
        hideTask = nil
        hoverTask?.cancel()
        hoverTask = nil
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AnchorController.autoHideSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.hide()
        }
    }

    private func applySize(_ size: NSSize) {
        let rect = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        panel.setFrame(ScreenGeometry.fit(rect, reference: referencePoint), display: true)
    }

    private func expand() {
        guard !expanded, panel.isVisible else { return }
        expanded = true
        hoverTask?.cancel()
        hideTask?.cancel()

        translateButton.sizeToFit()
        rewriteButton.sizeToFit()
        let pad: CGFloat = 5
        let height = max(translateButton.frame.height, rewriteButton.frame.height)
        let w1 = max(58, translateButton.frame.width)
        let w2 = max(58, rewriteButton.frame.width)
        let size = NSSize(width: pad * 3 + w1 + w2, height: height + pad * 2)
        translateButton.frame = NSRect(x: pad, y: pad, width: w1, height: height)
        rewriteButton.frame = NSRect(x: pad * 2 + w1, y: pad, width: w2, height: height)
        choices.frame = NSRect(origin: .zero, size: size)

        circle.isHidden = true
        choices.isHidden = false
        applySize(size)
    }

    private func pointerEntered() {
        hideTask?.cancel()
        guard !expanded else { return }
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: AnchorController.hoverDelay)
            guard !Task.isCancelled, let self else { return }
            self.expand()
        }
    }

    private func pointerExited() {
        hoverTask?.cancel()
        if panel.isVisible { scheduleHide() }
    }

    @objc private func bubbleClicked(_ sender: Any?) {
        expand()
    }

    @objc private func pickTranslate(_ sender: Any?) {
        hide()
        onPick?(.translate)
    }

    @objc private func pickRewrite(_ sender: Any?) {
        hide()
        onPick?(.rewrite)
    }
}
