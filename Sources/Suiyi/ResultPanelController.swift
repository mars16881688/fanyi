import AppKit

/// The floating result card: header (direction · app), scrollable body,
/// action buttons. Streams translate output into an NSTextView; for rewrite
/// it streams raw text, then swaps in three sections once parsed.
@MainActor
final class ResultPanelController: NSObject {
    var onReplace: (@MainActor (String) -> Void)?
    var onReplyTranslate: (@MainActor (String) -> Void)?
    var onClose: (@MainActor () -> Void)?
    /// 0.2.1.k.11: called after the card appears or goes (the global key monitor follows it).
    var onVisibilityChange: (@MainActor () -> Void)?
    /// The 翻译 / 改写 tabs ask for the same selection in the other mode.
    var onSwitchKind: (@MainActor (ActionKind) -> Void)?

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

    /// Set when the card offers a reply: from the user's language back to the sender's.
    private var reply: TranslationDirection?
    private var offersReply: Bool { reply != nil }
    private var replyExpanded = false
    private var replyInput: ReplyTextView?
    private var replyOutput: NSTextField?
    private var replyButton: NSButton?
    private var replyCopyButton: NSButton?
    private let closeButton = GlassButton(title: "", symbol: "xmark", style: .plain, size: .small,
                                          target: nil, action: nil)
    private let translateTab = GlassButton(title: L("翻译", "Translate", "翻訳"), symbol: "character.book.closed",
                                           style: .plain, size: .small, target: nil, action: nil)
    private let rewriteTab = GlassButton(title: L("改写", "Rewrite", "書き換え"), symbol: "pencil.line",
                                         style: .plain, size: .small, target: nil, action: nil)
    private lazy var tabs: NSStackView = {
        let stack = NSStackView(views: [translateTab, rewriteTab])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }()
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
    /// 0.2.1.k.11: streamed deltas are laid out at most ~30 times a second, not once per token.
    private var relayoutScheduled = false
    private var replyOutputDirty = false

    var isVisible: Bool { panel.isVisible }
    var frame: NSRect { panel.frame }
    /// For snapshot tests.
    var contentView: NSView? { panel.contentView }

    private var bodyAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor,
         .paragraphStyle: SuiyiStyle.paragraph]
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
        (background as? RoundedMaterialView)?.radius = 20
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
        closeButton.target = self
        closeButton.action = #selector(closeClicked(_:))
        closeButton.toolTip = L("关闭（Esc）", "Close (Esc)", "閉じる（Esc）")
        closeButton.setAccessibilityLabel(L("关闭", "Close", "閉じる"))
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        translateTab.target = self
        translateTab.action = #selector(tabClicked(_:))
        translateTab.toolTip = L("翻译（⌥⌘T）", "Translate (⌥⌘T)", "翻訳（⌥⌘T）")
        rewriteTab.target = self
        rewriteTab.action = #selector(tabClicked(_:))
        rewriteTab.toolTip = L("改写（⌥⌘R）", "Rewrite (⌥⌘R)", "書き換え（⌥⌘R）")
        let headerRow = NSStackView(views: [modeIcon, modeLabel, tabs, headerLabel, spinner, closeButton])
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
        tv.defaultParagraphStyle = SuiyiStyle.paragraph
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

    /// Translation into Chinese: the translation, then an optional reply
    /// composer. The composer stays collapsed behind one button so a plain
    /// lookup keeps a compact card.
    private func installReplyBody() {
        clearBody()
        let scroll = makeScrollView()
        let width = Self.bodyWidth - 4
        let doc = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        doc.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)

        stack.addArrangedSubview(translationRow(width: width))
        if replyExpanded {
            addReplyComposer(to: stack, width: width)
        } else {
            let (mine, target) = replyNames
            let start = makeButton(L("用\(mine)回复", "Reply in \(mine)", "\(mine)で返信"), #selector(expandReply(_:)),
                                   symbol: "arrowshape.turn.up.left", small: true)
            start.toolTip = L("用\(mine)写回复，随译译成\(target)",
                              "Write in \(mine); Suiyi translates it into \(target)",
                              "\(mine)で書くと、Suiyi が\(target)に翻訳します")
            stack.setCustomSpacing(12, after: stack.arrangedSubviews[0])
            stack.addArrangedSubview(start)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -2),
            doc.widthAnchor.constraint(equalToConstant: width),
        ])
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
        ])
        embed(scroll)
        rewriteDoc = doc
    }

    /// The translation with its own small Copy (and Replace) icons beside it;
    /// in reply mode the card has no footer, so these are the only copy actions.
    private func translationRow(width: CGFloat) -> NSView {
        var icons: [GlassButton] = [iconButton("doc.on.doc", L("复制译文", "Copy translation", "訳文をコピー"),
                                               #selector(copyAll(_:)))]
        if editable {
            icons.append(iconButton("arrow.turn.down.left", L("用译文替换原文", "Replace the original", "原文を訳文で置き換え"),
                                    #selector(replaceAll(_:))))
        }
        let iconStack = NSStackView(views: icons)
        iconStack.orientation = .horizontal
        iconStack.spacing = 2
        iconStack.alignment = .top
        let iconsWidth = CGFloat(icons.count) * GlassButton.Size.small.height + CGFloat(icons.count - 1) * 2
        let text = replyBodyLabel(rawText, width: width - iconsWidth - 8)
        let row = NSStackView(views: [text, iconStack])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    private func iconButton(_ symbol: String, _ label: String, _ action: Selector) -> GlassButton {
        let button = GlassButton(title: "", symbol: symbol, style: .plain, size: .small, target: self, action: action)
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func addReplyComposer(to stack: NSStackView, width: CGFloat) {
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[0])
        let (mine, target) = replyNames
        stack.addArrangedSubview(sectionLabel(L("我的回复（\(mine)）", "My reply (\(mine))", "返信（\(mine)）")))

        let inputScroll = makeScrollView()
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        let input = ReplyTextView(usingTextLayoutManager: false)
        input.frame = NSRect(x: 0, y: 0, width: width - 16, height: 64)
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
        input.minSize = NSSize(width: 0, height: 64)
        input.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        input.textContainer?.widthTracksTextView = true
        input.textContainer?.containerSize = NSSize(width: width - 24, height: CGFloat.greatestFiniteMagnitude)
        input.placeholder = L("在这里用\(mine)写回复…", "Write your reply in \(mine)…", "\(mine)で返信を入力…")
        input.onSubmit = { [weak self] in self?.submitReply() }
        inputScroll.documentView = input
        let surface = RoundedSurfaceView()
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(inputScroll)
        NSLayoutConstraint.activate([
            surface.widthAnchor.constraint(equalToConstant: width),
            surface.heightAnchor.constraint(equalToConstant: 76),
            inputScroll.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 8),
            inputScroll.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -8),
            inputScroll.topAnchor.constraint(equalTo: surface.topAnchor, constant: 6),
            inputScroll.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -6),
        ])
        stack.addArrangedSubview(surface)

        let generate = makeButton(L("生成\(target)", "Translate to \(target)", "\(target)に翻訳"),
                                  #selector(replyClicked(_:)), symbol: "arrow.turn.down.right",
                                  style: .primary, small: true)
        generate.toolTip = L("⌘↩ 生成；Return 换行", "⌘↩ to translate, Return for a new line", "⌘↩ で翻訳、Return で改行")
        let hint = NSTextField(labelWithString: "⌘↩")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        let actionRow = NSStackView(views: [generate, hint])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 8
        stack.addArrangedSubview(actionRow)
        stack.setCustomSpacing(16, after: actionRow)

        let copy = makeButton(L("复制\(target)", "Copy \(target)", "\(target)をコピー"), #selector(copyReply(_:)),
                              symbol: "doc.on.doc", small: true)
        copy.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let heading = NSStackView(views: [sectionLabel(L("\(target)回复", "Reply in \(target)", "\(target)の返信")), spacer, copy])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(heading)
        let placeholder = L("写好后按 ⌘↩，\(target)会出现在这里。",
                            "Press ⌘↩ when ready; the \(target) text appears here.",
                            "書き終えたら ⌘↩。\(target)がここに表示されます。")
        let output = replyBodyLabel(placeholder, width: width)
        var emptyAttributes = bodyAttributes
        emptyAttributes[.foregroundColor] = NSColor.secondaryLabelColor
        output.attributedStringValue = NSAttributedString(string: placeholder, attributes: emptyAttributes)
        stack.addArrangedSubview(output)

        replyInput = input
        replyOutput = output
        replyButton = generate
        replyCopyButton = copy
    }

    /// Interface names of (my language, the sender's language) for the reply composer.
    private var replyNames: (mine: String, target: String) {
        (reply?.source?.uiName ?? Language.chinese.uiName, reply?.target.uiName ?? Language.english.uiName)
    }

    @objc func expandReply(_ sender: NSButton?) {
        replyExpanded = true
        installReplyBody()
        rebuildFooter(withActions: true)
        relayout(keepPosition: true)
        if let input = replyInput {
            panel.makeKey()
            panel.makeFirstResponder(input)
        }
    }

    private func submitReply() {
        guard !replyStreaming, let input = replyInput, !input.hasMarkedText(),
              !input.string.trimmed.isEmpty, let onReplyTranslate else { return }
        replyText = ""
        replyStreaming = true
        replyButton?.isEnabled = false
        replyCopyButton?.isEnabled = false
        (replyCopyButton as? GlassButton)?.style = .secondary
        let target = replyNames.target
        setReplyOutput(L("正在生成\(target)…", "Translating to \(target)…", "\(target)に翻訳中…"),
                       color: .secondaryLabelColor)
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
        replyOutputDirty = true
        scheduleRelayout()
    }

    func finishReply() {
        guard replyStreaming else { return }
        replyOutputDirty = false
        replyStreaming = false
        replyButton?.isEnabled = true
        replyCopyButton?.isEnabled = !replyText.trimmed.isEmpty
        // The finished reply is what gets sent, so copying it becomes the primary action.
        (replyCopyButton as? GlassButton)?.style = replyText.trimmed.isEmpty ? .secondary : .primary
        if replyText.trimmed.isEmpty {
            setReplyOutput(LLMError.emptyResponse.errorDescription ?? "", color: .secondaryLabelColor)
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

        var buttons: [NSView] = [makeButton(L("复制", "Copy", "コピー"), #selector(copyVariant(_:)),
                                            symbol: "doc.on.doc", tag: index, small: true)]
        if editable {
            buttons.append(makeButton(L("替换", "Replace", "置き換え"), #selector(replaceVariant(_:)),
                                      symbol: "arrow.turn.down.left", tag: index, small: true))
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

    private func makeButton(_ title: String, _ action: Selector, symbol: String? = nil, tag: Int = 0,
                            style: GlassButton.Style = .secondary, small: Bool = false) -> GlassButton {
        let button = GlassButton(title: title, symbol: symbol, style: style,
                                 size: small ? .small : .regular, target: self, action: action)
        button.tag = tag
        button.setContentHuggingPriority(.required, for: .horizontal)
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

    /// Copy (and Replace when the source is editable). The last button is the
    /// primary action. Closing lives in the header and on Esc.
    /// With a reply on offer the translation carries its own copy icon, so the
    /// footer stays empty and replying is the next step.
    private func rebuildFooter(withActions: Bool) {
        var views: [NSView] = []
        if withActions && !(offersReply && !showingError) {
            let canReplace = editable && !showingError
            views.append(makeButton(L("复制", "Copy", "コピー"), #selector(copyAll(_:)), symbol: "doc.on.doc",
                                    style: canReplace ? .secondary : .primary))
            if canReplace {
                views.append(makeButton(L("替换", "Replace", "置き換え"), #selector(replaceAll(_:)),
                                        symbol: "arrow.turn.down.left", style: .primary))
            }
        }
        footer.setViews(views, in: .trailing)
        footer.isHidden = views.isEmpty
    }

    // MARK: - Public API

    /// `keepPosition`: `point` is the card's current top-left (switching tabs).
    /// `showsTabs`: false for one-off notices.
    func present(kind: ActionKind, header: String, editable: Bool, shortPhrase: Bool, at point: NSPoint,
                 reply: TranslationDirection? = nil, keepPosition: Bool = false, showsTabs: Bool = true) {
        noticeTask?.cancel()
        self.reply = reply
        replyExpanded = false
        self.kind = kind
        self.editable = editable
        self.shortPhrase = shortPhrase
        rawText = ""
        variants = []
        showingError = false
        streaming = true
        modeLabel.textColor = .controlAccentColor
        modeIcon.contentTintColor = .controlAccentColor
        modeLabel.stringValue = kind == .translate ? L("翻译", "Translate", "翻訳") : L("改写", "Rewrite", "書き換え")
        modeIcon.image = SuiyiStyle.symbol(kind == .translate ? "character.book.closed" : "pencil.line",
                                          description: modeLabel.stringValue)
        headerLabel.stringValue = header
        tabs.isHidden = !showsTabs
        modeIcon.isHidden = showsTabs
        modeLabel.isHidden = showsTabs
        selectTab(kind)
        spinner.startAnimation(nil)
        installTextBody()
        textView?.textStorage?.setAttributedString(NSAttributedString(
            string: kind == .translate ? L("正在翻译…", "Translating…", "翻訳中…") : L("正在改写…", "Rewriting…", "書き換え中…"),
            attributes: [.font: NSFont.systemFont(ofSize: 14),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: SuiyiStyle.paragraph]))
        rebuildFooter(withActions: false)
        reference = point
        topLeft = keepPosition ? point : NSPoint(x: point.x + 4, y: point.y - 12)
        relayout(keepPosition: false)
        panel.orderFrontRegardless()
        onVisibilityChange?()
    }

    func append(_ delta: String) {
        guard streaming, let tv = textView else { return }
        if rawText.isEmpty { tv.textStorage?.setAttributedString(NSAttributedString(string: "")) }
        rawText += delta
        tv.textStorage?.append(NSAttributedString(string: delta, attributes: bodyAttributes))
        scheduleRelayout()
    }

    private func scheduleRelayout() {
        guard !relayoutScheduled else { return }
        relayoutScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            guard let self else { return }
            self.relayoutScheduled = false
            guard self.panel.isVisible else { return }
            if self.replyOutputDirty {
                self.replyOutputDirty = false
                self.setReplyOutput(self.replyText, color: .labelColor)   // relayouts
            } else {
                self.relayout(keepPosition: true)
            }
        }
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
            if kind == .translate, offersReply, !showingError, !rawText.trimmed.isEmpty {
                installReplyBody()
            }
            rebuildFooter(withActions: !rawText.trimmed.isEmpty)
        }
        relayout(keepPosition: true)
    }

    func showError(_ message: String) {
        streaming = false
        showingError = true
        modeIcon.image = SuiyiStyle.symbol("exclamationmark.triangle.fill", description: message)
        modeIcon.contentTintColor = .systemRed
        modeLabel.textColor = .systemRed
        spinner.stopAnimation(nil)
        if textView == nil { installTextBody() }
        if rawText.isEmpty { textView?.textStorage?.setAttributedString(NSAttributedString(string: "")) }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.systemRed,
            .paragraphStyle: SuiyiStyle.paragraph,
        ]
        let prefix = rawText.isEmpty ? "" : "\n\n"
        textView?.textStorage?.append(NSAttributedString(string: prefix + "⚠︎ " + message, attributes: attributes))
        rebuildFooter(withActions: !rawText.trimmed.isEmpty)
        relayout(keepPosition: true)
    }

    /// A short message that disappears by itself. 0.2.1.k.13: if a translation or reply is still
    /// streaming into this card, it is cancelled first (the notice replaces the card).
    func showNotice(_ message: String, at point: NSPoint) {
        if streaming || replyStreaming { onClose?() }
        present(kind: .translate, header: L("随译", "Suiyi", "Suiyi"), editable: false, shortPhrase: false, at: point,
                showsTabs: false)
        showError(message)
        modeIcon.image = SuiyiStyle.symbol("info.circle.fill", description: message)
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
        let wasVisible = panel.isVisible
        panel.orderOut(nil)
        if wasVisible { onVisibilityChange?() }
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
        let fitted = ScreenGeometry.fit(rect, reference: reference)
        if fitted != panel.frame {   // a window resize and a shadow recomputation only when something moved
            panel.setFrame(fitted, display: true)
            panel.invalidateShadow()
        }

        if streaming, wanted > maxBody, let tv = textView {
            let end = (tv.string as NSString).length
            tv.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    // MARK: - Actions

    /// For a short term the model returns "translation \n note"; copy/replace
    /// use just the first line.
    private func outputText() -> String {
        TranslationOutput.primary(rawText, isTranslation: kind == .translate, shortPhrase: shortPhrase)
    }

    /// 0.2.1.k.01: set for results the user sent after confirming a SensitiveGuard block. Copies are
    /// then marked so clipboard managers skip them and Universal Clipboard does not hand them off.
    var copiesAreSensitive = false

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        guard copiesAreSensitive else {
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            return
        }
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: SensitiveGuard.ownPasteboardType)
        pasteboard.writeObjects([item])
    }

    private func flashCopied(_ button: NSButton) {
        // Icon-only buttons flash a checkmark instead of a label.
        if let glass = button as? GlassButton, glass.title.isEmpty {
            guard glass.symbolName != "checkmark" else { return }
            let original = glass.symbolName
            glass.symbolName = "checkmark"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                glass.symbolName = original
            }
            return
        }
        let done = L("已复制", "Copied", "コピーしました")
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

    private func selectTab(_ kind: ActionKind) {
        for (tab, tabKind) in [(translateTab, ActionKind.translate), (rewriteTab, .rewrite)] {
            let selected = tabKind == kind
            tab.style = selected ? .secondary : .plain
            tab.setAccessibilitySelected(selected)
        }
    }

    @objc func tabClicked(_ sender: NSButton) {
        let picked: ActionKind = sender === rewriteTab ? .rewrite : .translate
        guard picked != kind else { return }
        onSwitchKind?(picked)
    }

    @objc private func closeClicked(_ sender: NSButton) {
        onClose?()
    }
}

/// Command-Return submits; ordinary Return remains available for multiline replies.
@MainActor
private final class ReplyTextView: NSTextView {
    var onSubmit: (@MainActor () -> Void)?
    var placeholder = ""

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
        (placeholder as NSString).draw(
            at: NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height),
            withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14),
                             .foregroundColor: NSColor.placeholderTextColor])
    }
}
