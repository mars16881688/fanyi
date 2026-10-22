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

    private static let bubbleSize: CGFloat = 30
    private static let autoHideSeconds: UInt64 = 4
    private static let hoverDelay: UInt64 = 350_000_000

    private let panel: FloatingPanel
    private let root: HoverView
    private let circle: NSView
    private let bubble: GlassButton
    private let choices: NSVisualEffectView
    private let translateButton: GlassButton
    private let rewriteButton: GlassButton

    private var expanded = false
    private var topLeft = NSPoint.zero
    private var hideTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    /// For snapshot tests.
    var contentView: NSView? { panel.contentView }

    override init() {
        let size: CGFloat = 30
        let square = NSRect(x: 0, y: 0, width: size, height: size)
        panel = FloatingPanel.make(size: square.size, allowsKey: false)
        root = HoverView(frame: square)
        circle = RoundedMaterialView(frame: square)
        bubble = GlassButton(title: "", symbol: "character.bubble", style: .plain, target: nil, action: nil)
        choices = RoundedMaterialView(frame: .zero)
        translateButton = GlassButton(title: "翻译", symbol: "character.book.closed", target: nil, action: nil)
        rewriteButton = GlassButton(title: "改写", symbol: "pencil.line", target: nil, action: nil)
        super.init()
        configure()
    }

    private func configure() {
        let size = AnchorController.bubbleSize
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        (circle as? RoundedMaterialView)?.radius = size / 2
        root.addSubview(circle)

        bubble.frame = NSRect(x: 0, y: 0, width: size, height: size)
        bubble.tint = .controlAccentColor
        bubble.iconPointSize = 15
        bubble.setAccessibilityLabel("随译")
        bubble.toolTip = "随译：翻译 / 改写"
        bubble.target = self
        bubble.action = #selector(bubbleClicked(_:))
        circle.addSubview(bubble)

        (choices as? RoundedMaterialView)?.radius = 20
        choices.isHidden = true
        root.addSubview(choices)

        translateButton.target = self
        translateButton.action = #selector(pickTranslate(_:))
        rewriteButton.target = self
        rewriteButton.action = #selector(pickRewrite(_:))
        translateButton.toolTip = "翻译（⌥⌘T）"
        rewriteButton.toolTip = "改写（⌥⌘R）"
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
        panel.invalidateShadow()
    }

    func expand() {
        guard !expanded, panel.isVisible else { return }
        expanded = true
        hoverTask?.cancel()
        hideTask?.cancel()

        let pad: CGFloat = 5
        let height = GlassButton.Size.regular.height
        let w1 = max(76, translateButton.intrinsicContentSize.width)
        let w2 = max(76, rewriteButton.intrinsicContentSize.width)
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
