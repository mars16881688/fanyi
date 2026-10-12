import AppKit
import ApplicationServices

struct Capture {
    let selection: CapturedSelection
    let context: AppContext
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Strong reference; NSApplication.delegate is weak.
    static var retained: AppDelegate?

    /// Apps where a synthetic ⌘C after a mouse drag would copy files, not text.
    private static let noClipboardFallbackOnMouse: Set<String> = ["com.apple.finder"]
    private static let escapeKeyCode: UInt16 = 53

    private var statusItem: NSStatusItem?
    private var pauseItem: NSMenuItem?
    private var accessibilityItem: NSMenuItem?

    private var reader: SelectionReader!
    private var monitor: SelectionMonitor!
    private var anchor: AnchorController!
    private var result: ResultPanelController!
    private var settingsWindow: SettingsWindowController!

    private var paused = false
    private var pendingCapture: Capture?
    private var lastCapture: Capture?
    private var selectionGeneration = 0
    private var requestGeneration = 0
    private var replyGeneration = 0
    private var replyTask: Task<Void, Never>?
    private var replyContext: AppContext?
    private var requestTask: Task<Void, Never>?
    private var keyMonitors: [Any] = []
    private var trustPollTask: Task<Void, Never>?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        paused = AppSettings.paused

        reader = SelectionReader()
        monitor = SelectionMonitor()
        anchor = AnchorController()
        result = ResultPanelController()
        settingsWindow = SettingsWindowController()

        anchor.onPick = { [weak self] kind in self?.anchorPicked(kind) }
        result.onReplyTranslate = { [weak self] text in self?.translateReply(text) }
        result.onClose = { [weak self] in self?.closeResult() }
        result.onReplace = { [weak self] text in self?.replaceSelection(with: text) }
        monitor.onMouseDown = { [weak self] point in self?.mouseDown(at: point) }
        monitor.onSelection = { [weak self] gesture in self?.selectionGesture(gesture) }

        installMainMenu()
        installStatusItem()
        monitor.start()
        registerHotKeys()
        installKeyMonitors()

        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            startTrustPolling()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        for m in keyMonitors { NSEvent.removeMonitor(m) }
        keyMonitors.removeAll()
    }

    /// Once the user grants Accessibility, re-install the key monitors (global
    /// key monitors registered before trust may stay silent).
    private func startTrustPolling() {
        trustPollTask?.cancel()
        trustPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if AXIsProcessTrusted() {
                    self?.installKeyMonitors()
                    return
                }
            }
        }
    }

    // MARK: - Menus

    /// Accessory apps have no visible menu bar, but key equivalents such as
    /// ⌘V in the Settings text fields still need an Edit menu to exist.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Fanyi")
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "退出 Fanyi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "",
                          modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = self
        return item
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Fanyi") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "译"
            }
            button.toolTip = "Fanyi"
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(makeItem("翻译选中文字", #selector(menuTranslate(_:)), key: "t", modifiers: [.command, .option]))
        menu.addItem(makeItem("改写选中文字", #selector(menuRewrite(_:)), key: "r", modifiers: [.command, .option]))
        menu.addItem(.separator())
        let pause = makeItem(paused ? "恢复划词" : "暂停划词", #selector(togglePause(_:)))
        menu.addItem(pause)
        pauseItem = pause
        let access = makeItem("授予辅助功能权限…", #selector(openAccessibilitySettings(_:)))
        access.isHidden = AXIsProcessTrusted()
        menu.addItem(access)
        accessibilityItem = access
        menu.addItem(.separator())
        menu.addItem(makeItem("设置…", #selector(openSettings(_:)), key: ","))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem?.title = paused ? "恢复划词" : "暂停划词"
        accessibilityItem?.isHidden = AXIsProcessTrusted()
    }

    @objc private func menuTranslate(_ sender: Any?) {
        // Let the menu close and focus settle back on the user's app first.
        triggerDirect(.translate, delayNanos: 250_000_000)
    }

    @objc private func menuRewrite(_ sender: Any?) {
        triggerDirect(.rewrite, delayNanos: 250_000_000)
    }

    @objc private func togglePause(_ sender: Any?) {
        paused.toggle()
        AppSettings.paused = paused
        if paused { anchor.hide() }
        pauseItem?.title = paused ? "恢复划词" : "暂停划词"
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startTrustPolling()
    }

    // MARK: - Hot keys & key monitors

    private func registerHotKeys() {
        let center = HotKeyCenter.shared
        let okT = center.register(id: 1, keyCode: HotKeyCenter.keyT, modifiers: HotKeyCenter.optionCommand) { [weak self] in
            self?.triggerDirect(.translate, delayNanos: 0)
        }
        let okR = center.register(id: 2, keyCode: HotKeyCenter.keyR, modifiers: HotKeyCenter.optionCommand) { [weak self] in
            self?.triggerDirect(.rewrite, delayNanos: 0)
        }
        if !okT || !okR {
            NSLog("Fanyi: some global hot keys could not be registered (already in use?)")
        }
    }

    private func installKeyMonitors() {
        for m in keyMonitors { NSEvent.removeMonitor(m) }
        keyMonitors.removeAll()

        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let code = event.keyCode
            MainActor.assumeIsolated {
                guard let delegate = self else { return }
                _ = delegate.handleKeyDown(code: code, global: true)
            }
        }) {
            keyMonitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let code = event.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let delegate = self else { return false }
                return delegate.handleKeyDown(code: code, global: false)
            }
            return handled ? nil : event
        }) {
            keyMonitors.append(local)
        }
    }

    /// Esc hides our panels. Any other key typed elsewhere hides the anchor.
    private func handleKeyDown(code: UInt16, global: Bool) -> Bool {
        if code == Self.escapeKeyCode {
            var handled = false
            if anchor.isVisible {
                anchor.hide()
                handled = true
            }
            if result.isVisible {
                closeResult()
                handled = true
            }
            return handled
        }
        if global && anchor.isVisible {
            anchor.hide()
        }
        return false
    }

    // MARK: - Mouse flow

    private func mouseDown(at point: NSPoint) {
        selectionGeneration += 1
        if anchor.isVisible && !anchor.frame.insetBy(dx: -2, dy: -2).contains(point) {
            anchor.hide()
        }
        if result.isVisible && !result.frame.contains(point) {
            closeResult()
        }
    }

    private func frontmostForeignApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    private func selectionGesture(_ gesture: SelectionGesture) {
        guard !paused, AppSettings.showAnchor, AXIsProcessTrusted() else { return }
        guard let app = frontmostForeignApp() else { return }
        if AppSettings.isExcluded(bundleID: app.bundleIdentifier) { return }
        // Selecting text inside our own result card (e.g. the reply box) is not
        // a selection in the foreign app.
        if result.isVisible && result.frame.contains(gesture.up) { return }

        // Clipboard fallback only for real drags (not double-clicks), and never
        // in apps where ⌘C would copy something other than text.
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        let allowClipboard = gesture.kind == .drag && !Self.noClipboardFallbackOnMouse.contains(bundle)

        selectionGeneration += 1
        let generation = selectionGeneration
        Task { @MainActor in
            guard let selection = await self.reader.read(allowClipboard: allowClipboard,
                                                         gesturePoints: [gesture.down, gesture.up]) else { return }
            guard generation == self.selectionGeneration, !self.paused else { return }
            let context = ContextCollector.collect(for: selection)
            self.pendingCapture = Capture(selection: selection, context: context)
            self.anchor.show(at: gesture.up)
        }
    }

    private func anchorPicked(_ kind: ActionKind) {
        guard let capture = pendingCapture else { return }
        run(kind, capture: capture, at: anchor.referencePoint)
    }

    // MARK: - Hot key / menu flow

    private func triggerDirect(_ kind: ActionKind, delayNanos: UInt64) {
        anchor.hide()
        let point = NSEvent.mouseLocation
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            startTrustPolling()
            result.showNotice("需要辅助功能权限：系统设置 › 隐私与安全性 › 辅助功能，打开 Fanyi。", at: point)
            return
        }
        selectionGeneration += 1
        Task { @MainActor in
            if delayNanos > 0 {
                try? await Task.sleep(nanoseconds: delayNanos)
            }
            guard let app = self.frontmostForeignApp() else { return }
            if AppSettings.isExcluded(bundleID: app.bundleIdentifier) {
                self.result.showNotice("当前应用在排除列表中，未读取选中文字。", at: point)
                return
            }
            guard let selection = await self.reader.read(allowClipboard: true, gesturePoints: nil) else {
                self.result.showNotice("没有检测到选中的文字。", at: point)
                return
            }
            let context = ContextCollector.collect(for: selection)
            self.run(kind, capture: Capture(selection: selection, context: context), at: point)
        }
    }

    // MARK: - Running a request

    private func run(_ kind: ActionKind, capture: Capture, at point: NSPoint) {
        cancelReply()
        requestTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        lastCapture = capture
        anchor.hide()

        let text = capture.selection.text
        let context = capture.context
        let header: String
        let messages: [ChatMessage]
        let temperature: Double
        var shortPhrase = false
        var replyOriginal: String?

        switch kind {
        case .translate:
            let direction = LanguageDetector.direction(for: text, preference: AppSettings.targetLanguage)
            if direction.target == .simplifiedChinese {
                replyOriginal = text
                replyContext = context
            }
            shortPhrase = Prompts.isShortPhrase(text)
            header = "\(direction.sourceLabel) → \(direction.target.shortLabel)  ·  \(context.appName)"
            messages = Prompts.translate(text: text, direction: direction, context: context, shortPhrase: shortPhrase)
            temperature = 0.3
        case .rewrite:
            header = "改写（保持原语言）  ·  \(context.appName)"
            messages = Prompts.rewrite(text: text, context: context)
            temperature = 0.7
        }

        result.present(kind: kind, header: header, editable: capture.selection.editable,
                       shortPhrase: shortPhrase, at: point, originalText: replyOriginal)

        guard let key = Keychain.apiKey(), !key.isEmpty else {
            result.showError(LLMError.missingKey.errorDescription ?? "Missing API key")
            return
        }
        let config = LLMConfig(baseURL: AppSettings.baseURL, apiKey: key, model: AppSettings.model)

        requestTask = Task { @MainActor in
            do {
                try await LLMClient.streamChat(config: config, messages: messages, temperature: temperature) { [weak self] delta in
                    guard let self, self.requestGeneration == generation else { return }
                    self.result.append(delta)
                }
                guard self.requestGeneration == generation, !Task.isCancelled else { return }
                self.result.finish()
            } catch {
                guard self.requestGeneration == generation, !Task.isCancelled else { return }
                if error is CancellationError { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                self.result.showError(error.localizedDescription)
            }
        }
    }

    private func cancelReply() {
        replyTask?.cancel()
        replyTask = nil
        replyGeneration += 1
        replyContext = nil
    }

    private func translateReply(_ text: String) {
        guard let context = replyContext, result.isVisible, !text.trimmed.isEmpty else { return }
        replyTask?.cancel()
        replyGeneration += 1
        let generation = replyGeneration
        guard let key = Keychain.apiKey(), !key.trimmed.isEmpty else {
            result.showReplyError(LLMError.missingKey.errorDescription ?? "Missing API key")
            return
        }
        let config = LLMConfig(baseURL: AppSettings.baseURL, apiKey: key, model: AppSettings.model)
        let messages = Prompts.translate(
            text: text, direction: TranslationDirection(sourceLabel: "中文", target: .english),
            context: context, shortPhrase: false)
        replyTask = Task { @MainActor in
            do {
                try await LLMClient.streamChat(config: config, messages: messages, temperature: 0.3) { [weak self] delta in
                    guard let self, self.replyGeneration == generation else { return }
                    self.result.appendReply(delta)
                }
                guard self.replyGeneration == generation, !Task.isCancelled else { return }
                self.result.finishReply()
            } catch {
                guard self.replyGeneration == generation, !Task.isCancelled else { return }
                if error is CancellationError { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                self.result.showReplyError(error.localizedDescription)
            }
        }
    }

    private func closeResult() {
        cancelReply()
        requestTask?.cancel()
        requestTask = nil
        requestGeneration += 1
        result.hide()
    }

    // MARK: - Replace

    private func replaceSelection(with text: String) {
        guard let capture = lastCapture, !text.isEmpty else { return }
        closeResult()
        let selection = capture.selection
        let scene = capture.context.scene
        Task { @MainActor in
            // Native document/e-mail editors: write the AX attribute directly.
            // Browsers, chat and code apps often accept the write but ignore
            // it, so paste there instead.
            if selection.viaAX, selection.editable, let element = selection.element,
               scene == .document || scene == .email {
                let error = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
                if error == .success { return }
            }
            if let app = NSRunningApplication(processIdentifier: selection.pid), !app.isActive {
                app.activate(options: [])
                try? await Task.sleep(nanoseconds: 150_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            await Clipboard.paste(text)
        }
    }
}
