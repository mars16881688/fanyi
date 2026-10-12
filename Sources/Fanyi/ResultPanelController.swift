import AppKit

/// The floating result card: header (direction · app), scrollable body,
/// action buttons. Streams translate output into an NSTextView; for rewrite
/// it streams raw text, then swaps in three sections once parsed.
@MainActor
final class ResultPanelController: NSObject {
    var onReplace: (@MainActor (String) -> Void)?
    var onClose: (@MainActor () -> Void)?

    private static let panelWidth: CGFloat = 420
    private static let maxPanelHeight: CGFloat = 360
    private static let inset: CGFloat = 12
    private static var bodyWidth: CGFloat { panelWidth - inset * 2 }

    private let panel: FloatingPanel
    private let background: NSVisualEffectView
    private let mainStack: NSStackView
    private let headerLabel: NSTextField
    private let spinner: NSProgressIndicator
    private let bodyHolder: NSView
    private let footer: NSStackView
    private var bodyHeight: NSLayoutConstraint?

    private var textView: NSTextView?
    private var rewriteDoc: NSView?
    private var variants: [RewriteVariant] = []
    private var rawText = ""
    private var kind: ActionKind = .translate
    private var editable = false
    private var shortPhrase = false
    private var showingError = false
    private var streaming = false
    private var topLeft = NSPoint.zero
    private var reference = NSPoint.zero
    private var noticeTask: Task<Void, Never>?

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
    }

    override init() {
        panel = FloatingPanel.make(size: NSSize(width: 420, height: 120), allowsKey: true)
        background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
        mainStack = NSStackView()
        headerLabel = NSTextField(labelWithString: "")
        spinner = NSProgressIndicator()
        bodyHolder = NSView()
        footer = NSStackView()
        super.init()
        buildUI()
    }

    // MARK: - Construction

    private func buildUI() {
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background
        panel.isMovableByWindowBackground = true

        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 8
        mainStack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset,
                                            bottom: Self.inset - 2, right: Self.inset)
        mainStack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(mainStack)

        headerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.maximumNumberOfLines = 1
        headerLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        let headerRow = NSStackView(views: [headerLabel, spinner])
        headerRow.orientation = .horizontal
        headerRow.distribution = .fill
        headerRow.alignment = .centerY
        headerRow.spacing = 6
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        bodyHolder.translatesAutoresizingMaskIntoConstraints = false

        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false

        mainStack.addArrangedSubview(headerRow)
        mainStack.addArrangedSubview(bodyHolder)
        mainStack.addArrangedSubview(footer)

        let height = bodyHolder.heightAnchor.constraint(equalToConstant: 40)
        bodyHeight = height
        NSLayoutConstraint.activate([
            mainStack.topAnchor.constraint(equalTo: background.topAnchor),
            mainStack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            mainStack.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            headerRow.widthAnchor.constraint(equalToConstant: Self.bodyWidth),
            bodyHolder.widthAnchor.constraint(equalToConstant: Self.bodyWidth),
            footer.widthAnchor.constraint(equalToConstant: Self.bodyWidth),
            height,
        ])
    }

    private func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.bodyWidth, height: 40))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        return scroll
    }

    private func installTextBody() {
        clearBody()
        let scroll = makeScrollView()
        let tv = NSTextView(usingTextLayoutManager: false)
        tv.frame = NSRect(x: 0, y: 0, width: Self.bodyWidth, height: 40)
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: 14)
        tv.textColor = .labelColor
        tv.textContainerInset = NSSize(width: 0, height: 2)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: Self.bodyWidth, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 2
        scroll.documentView = tv
        embed(scroll)
        textView = tv
    }

    private func installRewriteBody(_ items: [RewriteVariant]) {
        clearBody()
        let scroll = makeScrollView()
        let contentWidth = Self.bodyWidth - 4

        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 100))
        doc.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        for (index, item) in items.enumerated() {
            stack.addArrangedSubview(makeSection(index: index, variant: item, width: contentWidth))
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalToConstant: contentWidth),
        ])

        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        embed(scroll)
        rewriteDoc = doc
    }

    private func makeSection(index: Int, variant: RewriteVariant, width: CGFloat) -> NSView {
        let title = NSTextField(labelWithString: variant.title)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let body = NSTextField(wrappingLabelWithString: variant.text)
        body.font = .systemFont(ofSize: 14)
        body.textColor = .labelColor
        body.isSelectable = true
        body.preferredMaxLayoutWidth = width
        body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalToConstant: width).isActive = true

        var buttons: [NSView] = [makeButton("复制", #selector(copyVariant(_:)), tag: index, small: true)]
        if editable {
            buttons.append(makeButton("替换", #selector(replaceVariant(_:)), tag: index, small: true))
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 6

        let section = NSStackView(views: [title, body, row])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        return section
    }

    private func makeButton(_ title: String, _ action: Selector, tag: Int = 0, small: Bool = false) -> NSButton {
        let button = FirstMouseButton(title: title, target: self, action: action)
        button.tag = tag
        if small {
            button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        return button
    }

    private func embed(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        bodyHolder.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: bodyHolder.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: bodyHolder.trailingAnchor),
            view.topAnchor.constraint(equalTo: bodyHolder.topAnchor),
            view.bottomAnchor.constraint(equalTo: bodyHolder.bottomAnchor),
        ])
    }

    private func clearBody() {
        for view in bodyHolder.subviews {
            view.removeFromSuperview()
        }
        textView = nil
        rewriteDoc = nil
    }

    private func rebuildFooter(withActions: Bool) {
        var views: [NSView] = []
        if withActions {
            views.append(makeButton("复制", #selector(copyAll(_:))))
            if editable && !showingError {
                views.append(makeButton("替换", #selector(replaceAll(_:))))
            }
        }
        views.append(makeButton("关闭", #selector(closeClicked(_:))))
        footer.setViews(views, in: .trailing)
    }

    // MARK: - Public API

    func present(kind: ActionKind, header: String, editable: Bool, shortPhrase: Bool, at point: NSPoint) {
        noticeTask?.cancel()
        self.kind = kind
        self.editable = editable
        self.shortPhrase = shortPhrase
        rawText = ""
        variants = []
        showingError = false
        streaming = true
        headerLabel.stringValue = header
        spinner.startAnimation(nil)
        installTextBody()
        rebuildFooter(withActions: false)
        reference = point
        topLeft = NSPoint(x: point.x + 4, y: point.y - 12)
        relayout(keepPosition: false)
        panel.orderFrontRegardless()
    }

    func append(_ delta: String) {
        guard streaming, let tv = textView else { return }
        rawText += delta
        tv.textStorage?.append(NSAttributedString(string: delta, attributes: bodyAttributes))
        relayout(keepPosition: true)
    }

    func finish() {
        streaming = false
        spinner.stopAnimation(nil)
        if kind == .rewrite, let parsed = RewriteParser.parse(rawText) {
            variants = parsed
            installRewriteBody(parsed)
            rebuildFooter(withActions: false)
        } else {
            rebuildFooter(withActions: !rawText.trimmed.isEmpty)
        }
        relayout(keepPosition: true)
    }

    func showError(_ message: String) {
        streaming = false
        showingError = true
        spinner.stopAnimation(nil)
        if textView == nil { installTextBody() }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.systemRed,
        ]
        let prefix = rawText.isEmpty ? "" : "\n\n"
        textView?.textStorage?.append(NSAttributedString(string: prefix + "⚠︎ " + message, attributes: attributes))
        rebuildFooter(withActions: !rawText.trimmed.isEmpty)
        relayout(keepPosition: true)
    }

    /// A short message that disappears by itself.
    func showNotice(_ message: String, at point: NSPoint) {
        present(kind: .translate, header: "Fanyi", editable: false, shortPhrase: false, at: point)
        showError(message)
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.hide()
        }
    }

    func hide() {
        noticeTask?.cancel()
        streaming = false
        spinner.stopAnimation(nil)
        panel.orderOut(nil)
    }

    // MARK: - Layout

    private func contentHeight() -> CGFloat {
        if let doc = rewriteDoc {
            doc.layoutSubtreeIfNeeded()
            return ceil(doc.fittingSize.height)
        }
        guard let tv = textView, let layoutManager = tv.layoutManager,
              let container = tv.textContainer else { return 24 }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return ceil(used.height + tv.textContainerInset.height * 2) + 2
    }

    private func relayout(keepPosition: Bool) {
        guard let bodyHeight = bodyHeight else { return }
        mainStack.layoutSubtreeIfNeeded()
        let chrome = mainStack.fittingSize.height - bodyHeight.constant
        let maxBody = max(80, Self.maxPanelHeight - chrome)
        let wanted = contentHeight()
        bodyHeight.constant = min(max(wanted, 22), maxBody)
        mainStack.layoutSubtreeIfNeeded()
        let size = mainStack.fittingSize

        if keepPosition && panel.isVisible {
            topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        }
        let rect = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        panel.setFrame(ScreenGeometry.fit(rect, reference: reference), display: true)

        if streaming, wanted > maxBody, let tv = textView {
            let end = (tv.string as NSString).length
            tv.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    // MARK: - Actions

    /// For a short term the model returns "translation \n note"; copy/replace
    /// use just the first line.
    private func outputText() -> String {
        let text = rawText.trimmed
        if kind == .translate, shortPhrase,
           let first = text.split(separator: "\n", omittingEmptySubsequences: true).first {
            return String(first).trimmed
        }
        return text
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func flashCopied(_ button: NSButton) {
        let done = "已复制"
        guard button.title != done else { return }
        let original = button.title
        button.title = done
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            button.title = original
        }
    }

    @objc private func copyAll(_ sender: NSButton) {
        copyToPasteboard(outputText())
        flashCopied(sender)
    }

    @objc private func replaceAll(_ sender: NSButton) {
        onReplace?(outputText())
    }

    @objc private func copyVariant(_ sender: NSButton) {
        guard variants.indices.contains(sender.tag) else { return }
        copyToPasteboard(variants[sender.tag].text)
        flashCopied(sender)
    }

    @objc private func replaceVariant(_ sender: NSButton) {
        guard variants.indices.contains(sender.tag) else { return }
        onReplace?(variants[sender.tag].text)
    }

    @objc private func closeClicked(_ sender: NSButton) {
        onClose?()
    }
}
