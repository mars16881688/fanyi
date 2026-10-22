import AppKit

/// The floating result card: header (direction · app), scrollable body,
/// action buttons. Streams translate output into an NSTextView; for rewrite
/// it streams raw text, then swaps in three sections once parsed.
@MainActor
final class ResultPanelController: NSObject {
    var onReplace: (@MainActor (String) -> Void)?
    var onReplyTranslate: (@MainActor (String) -> Void)?
    var onClose: (@MainActor () -> Void)?

    private static let panelWidth: CGFloat = 420
    private static let maxPanelHeight: CGFloat = 360
    private static let inset: CGFloat = 16
    private static var bodyWidth: CGFloat { panelWidth - inset * 2 }

    private let panel: FloatingPanel
    private let background: NSVisualEffectView
    private let mainStack: NSStackView
    private let modeLabel = NSTextField(labelWithString: "")
    private let modeIcon = NSImageView()
    private let headerLabel: NSTextField
    private let spinner: NSProgressIndicator
    private let bodyHolder: NSView
    private let footer: NSStackView
    private var bodyHeight: NSLayoutConstraint?

    private var originalText: String?
    private var replyInput: ReplyTextView?
    private var replyOutput: NSTextField?
    private var replyButton: NSButton?
    private var replyCopyButton: NSButton?
    private var replyText = ""
    private var replyStreaming = false
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
        [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
         .paragraphStyle: FanyiStyle.paragraph]
    }

    override init() {
        panel = FloatingPanel.make(size: NSSize(width: 420, height: 120), allowsKey: true)
        background = RoundedMaterialView(frame: NSRect(x: 0, y: 0, width: 420, height: 120))
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
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]
        panel.contentView = background
        panel.isMovableByWindowBackground = true

        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 12
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

        modeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        modeLabel.textColor = .controlAccentColor
        modeIcon.contentTintColor = .controlAccentColor
        modeIcon.setContentHuggingPriority(.required, for: .horizontal)
        let headerRow = NSStackView(views: [modeIcon, modeLabel, headerLabel, spinner])
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
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.defaultParagraphStyle = FanyiStyle.paragraph
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

    private func sectionLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .controlAccentColor
        return label
    }

    private func replyBodyLabel(_ value: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value)
        label.attributedStringValue = NSAttributedString(string: value, attributes: bodyAttributes)
        label.isSelectable = true
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: width).isActive = true
        return label
    }

    private func installReplyBody(original: String) {
        clearBody()
        let scroll = makeScrollView()
        let width = Self.bodyWidth - 4
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        doc.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        let source = replyBodyLabel(original, width: width)
        var sourceAttributes = bodyAttributes
        sourceAttributes[.font] = NSFont.systemFont(ofSize: 12)
        sourceAttributes[.foregroundColor] = NSColor.secondaryLabelColor
        source.attributedStringValue = NSAttributedString(string: original, attributes: sourceAttributes)
        source.maximumNumberOfLines = 3
        source.lineBreakMode = .byTruncatingTail
        stack.addArrangedSubview(sectionLabel("对方原文"))
        stack.addArrangedSubview(source)
        stack.addArrangedSubview(sectionLabel("中文译文"))
        stack.addArrangedSubview(replyBodyLabel(rawText, width: width))
        stack.addArrangedSubview(sectionLabel("我的中文回复"))

        let inputScroll = makeScrollView()
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        let input = ReplyTextView(usingTextLayoutManager: false)
        input.frame = NSRect(x: 0, y: 0, width: width - 16, height: 76)
        input.isRichText = false
        input.allowsUndo = true
        input.font = .systemFont(ofSize: 14)
        input.textColor = .labelColor
        input.insertionPointColor = .labelColor
        input.drawsBackground = false
        input.textContainerInset = NSSize(width: 4, height: 6)
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.minSize = NSSize(width: 0, height: 76)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = NSSize(width: width - 24, height: CGFloat.greatestFiniteMagnitude)
        input.onSubmit = { [weak self] in self?.submitReply() }
        inputScroll.documentView = input
        let surface = RoundedSurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(inputScroll)
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalToConstant: width),
            surface.heightAnchor.constraint(equalToConstant: 88),
            inputScroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8),
            inputScroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8),
            inputScroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6),
            inputScroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6),
        ])
        stack.addArrangedSubview(surface)
        let translate = makeButton("翻译成英文", #selector(replyClicked(_:)))
        translate.image = FanyiStyle.symbol("arrow.turn.up.right", description: "翻译成英文")
        translate.toolTip = "⌘↩ 翻译；Return 换行"
        stack.addArrangedSubview(translate)

        let copy = makeButton("复制", #selector(copyReply(_:)), small: true)
        copy.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [sectionLabel("英文回复"), spacer, copy])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(heading)
        let output = replyBodyLabel("输入中文回复后，点击「翻译成英文」。", width: width)
        var emptyAttributes = bodyAttributes
        emptyAttributes[.foregroundColor] = NSColor.secondaryLabelColor
        output.attributedStringValue = NSAttributedString(
            string: "输入中文回复后，点击「翻译成英文」。", attributes: emptyAttributes)
        stack.addArrangedSubview(output)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            doc.widthAnchor.constraint(equalToConstant: width),
        ])
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        embed(scroll)
        rewriteDoc = doc
        replyInput = input
        replyOutput = output
        replyButton = translate
        replyCopyButton = copy
    }

    private func submitReply() {
        guard !replyStreaming, let input = replyInput, !input.hasMarkedText(),
              !input.string.trimmed.isEmpty, let onReplyTranslate else { return }
        replyText = ""
        replyStreaming = true
        replyButton?.isEnabled = false
        replyCopyButton?.isEnabled = false
        setReplyOutput("正在翻译成英文…", color: .secondaryLabelColor)
        onReplyTranslate(input.string.trimmed)
    }

    private func setReplyOutput(_ value: String, color: NSColor) {
        var attributes = bodyAttributes
        attributes[.foregroundColor] = color
        replyOutput?.attributedStringValue = NSAttributedString(string: value, attributes: attributes)
        relayout(keepPosition: true)
    }

    func appendReply(_ delta: String) {
        guard replyStreaming, replyOutput != nil else { return }
        replyText += delta
        setReplyOutput(replyText, color: .labelColor)
    }

    func finishReply() {
        guard replyStreaming else { return }
        replyStreaming = false
        replyButton?.isEnabled = true
        replyCopyButton?.isEnabled = !replyText.trimmed.isEmpty
        if replyText.trimmed.isEmpty {
            setReplyOutput("服务没有返回任何内容。", color: .secondaryLabelColor)
        }
    }

    func showReplyError(_ message: String) {
        replyStreaming = false
        replyButton?.isEnabled = true
        replyCopyButton?.isEnabled = false
        let prefix = replyText.isEmpty ? "" : replyText + "\n\n"
        setReplyOutput(prefix + "⚠︎ " + message, color: .systemRed)
    }

    @objc private func replyClicked(_ sender: NSButton) { submitReply() }

    @objc private func copyReply(_ sender: NSButton) {
        guard !replyStreaming, !replyText.trimmed.isEmpty else { return }
        copyToPasteboard(replyText.trimmed)
        flashCopied(sender)
    }

    private func makeSection(index: Int, variant: RewriteVariant, width: CGFloat) -> NSView {
        let title = NSTextField(labelWithString: variant.title)
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .controlAccentColor

        let body = NSTextField(wrappingLabelWithString: variant.text)
        body.font = .systemFont(ofSize: 14)
        body.textColor = .labelColor
        body.isSelectable = true
        body.attributedStringValue = NSAttributedString(string: variant.text, attributes: bodyAttributes)
        body.preferredMaxLayoutWidth = width - 24
        body.translatesAutoresizingMaskIntoConstraints = false
        body.widthAnchor.constraint(equalToConstant: width - 24).isActive = true

        var buttons: [NSView] = [makeButton("复制", #selector(copyVariant(_:)), tag: index, small: true)]
        if editable {
            buttons.append(makeButton("替换", #selector(replaceVariant(_:)), tag: index, small: true))
        }
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 6

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [title, spacer, row])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.widthAnchor.constraint(equalToConstant: width - 24).isActive = true
        let section = NSStackView(views: [heading, body])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 8
        section.translatesAutoresizingMaskIntoConstraints = false
        let card = RoundedSurfaceView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(section)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: width),
            section.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            section.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
            section.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            section.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
        ])
        return card
    }

    private func makeButton(_ title: String, _ action: Selector, tag: Int = 0, small: Bool = false) -> NSButton {
        let button = FirstMouseButton(title: title, target: self, action: action)
        button.tag = tag
        button.bezelStyle = .rounded
        let symbol = title == "复制" ? "doc.on.doc" : title == "替换" ? "arrow.turn.down.left" : "xmark"
        button.image = FanyiStyle.symbol(symbol, description: title)
        button.imagePosition = .imageLeading
        button.imageHugsTitle = true
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
        replyInput = nil
        replyOutput = nil
        replyButton = nil
        replyCopyButton = nil
        replyText = ""
        replyStreaming = false
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
        if withActions, let primary = views.dropLast().last as? NSButton {
            primary.bezelColor = .controlAccentColor
            primary.contentTintColor = .selectedMenuItemTextColor
        }
        footer.setViews(views, in: .trailing)
    }

    // MARK: - Public API

    func present(kind: ActionKind, header: String, editable: Bool, shortPhrase: Bool, at point: NSPoint, originalText: String? = nil) {
        noticeTask?.cancel()
        self.originalText = originalText
        self.kind = kind
        self.editable = editable
        self.shortPhrase = shortPhrase
        rawText = ""
        variants = []
        showingError = false
        streaming = true
        modeLabel.textColor = .controlAccentColor
        modeIcon.contentTintColor = .controlAccentColor
        modeLabel.stringValue = kind == .translate ? "翻译" : "改写"
        modeIcon.image = FanyiStyle.symbol(kind == .translate ? "character.book.closed" : "pencil.line",
                                          description: modeLabel.stringValue)
        headerLabel.stringValue = header
        spinner.startAnimation(nil)
        installTextBody()
        textView?.textStorage?.setAttributedString(NSAttributedString(
            string: kind == .translate ? "正在翻译…" : "正在改写…",
            attributes: [.font: NSFont.systemFont(ofSize: 14),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: FanyiStyle.paragraph]))
        rebuildFooter(withActions: false)
        reference = point
        topLeft = NSPoint(x: point.x + 4, y: point.y - 12)
        relayout(keepPosition: false)
        panel.orderFrontRegardless()
    }

    func append(_ delta: String) {
        guard streaming, let tv = textView else { return }
        if rawText.isEmpty { tv.textStorage?.setAttributedString(NSAttributedString(string: "")) }
        rawText += delta
        tv.textStorage?.append(NSAttributedString(string: delta, attributes: bodyAttributes))
        relayout(keepPosition: true)
    }

    func finish() {
        if rawText.isEmpty { textView?.textStorage?.setAttributedString(NSAttributedString(string: "")) }
        streaming = false
        spinner.stopAnimation(nil)
        if kind == .rewrite, let parsed = RewriteParser.parse(rawText) {
            variants = parsed
            installRewriteBody(parsed)
            rebuildFooter(withActions: false)
        } else {
            if kind == .translate, !showingError, !rawText.trimmed.isEmpty,
               let originalText {
                installReplyBody(original: originalText)
            }
            rebuildFooter(withActions: !rawText.trimmed.isEmpty)
        }
        relayout(keepPosition: true)
    }

    func showError(_ message: String) {
        streaming = false
        showingError = true
        modeIcon.image = FanyiStyle.symbol("exclamationmark.triangle.fill", description: message)
        modeIcon.contentTintColor = .systemRed
        modeLabel.textColor = .systemRed
        spinner.stopAnimation(nil)
        if textView == nil { installTextBody() }
        if rawText.isEmpty { textView?.textStorage?.setAttributedString(NSAttributedString(string: "")) }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.systemRed,
            .paragraphStyle: FanyiStyle.paragraph,
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
        modeIcon.image = FanyiStyle.symbol("info.circle.fill", description: message)
        modeIcon.contentTintColor = .secondaryLabelColor
        modeLabel.textColor = .secondaryLabelColor
        textView?.textStorage?.setAttributedString(NSAttributedString(string: message, attributes: bodyAttributes))
        relayout(keepPosition: true)
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.hide()
        }
    }

    func hide() {
        noticeTask?.cancel()
        streaming = false
        replyStreaming = false
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
        let limit: CGFloat = replyInput == nil ? Self.maxPanelHeight : 520
        let screenHeight = ScreenGeometry.screen(containing: reference)?.visibleFrame.height ?? limit
        let maxBody = max(22, min(limit, screenHeight - 12) - chrome)
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

/// Command-Return submits; ordinary Return remains available for multiline replies.
@MainActor
private final class ReplyTextView: NSTextView {
    var onSubmit: (@MainActor () -> Void)?

    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    private func isSubmit(_ event: NSEvent) -> Bool {
        !hasMarkedText() && (event.keyCode == 36 || event.keyCode == 76)
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isSubmit(event) { onSubmit?(); return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isSubmit(event) { onSubmit?(); return }
        super.keyDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        ("在这里输入你的中文回复…" as NSString).draw(
            at: NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14),
                             .foregroundColor: NSColor.placeholderTextColor])
    }
}
