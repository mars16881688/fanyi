import AppKit
import ApplicationServices

struct Capture {
    var selection: CapturedSelection
    let context: AppContext
    /// The user confirmed a SensitiveGuard block by triggering again; never saved to history.
    var overridden = false
}

/// 0.2.1.k.10: a mouse selection that could not be read without the clipboard. The button is
/// shown anyway, and ⌘C is sent only when the user clicks it.
struct UnreadSelection {
    let target: SelectionReader.FocusTarget
    let points: [NSPoint]
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
    private var excludeItem: NSMenuItem?
    private var excludeTarget: (id: String, name: String)?
    private var accessibilityItem: NSMenuItem?
    /// 0.2.1.k.02: why the last mouse selection did or did not get a button (no selected text).
    private var diagnosisItem: NSMenuItem?
    private var lastSelectionNote = ""
    private var lastSelectionDate: Date?

    private var reader: SelectionReader!
    private var monitor: SelectionMonitor!
    private var anchor: AnchorController!
    private var result: ResultPanelController!
    private var settingsWindow: SettingsWindowController!

    private var paused = false
    private var pendingCapture: Capture?
    private var pendingUnread: UnreadSelection?
    private var lastCapture: Capture?
    private var selectionGeneration = 0
    private var requestGeneration = 0
    private var replyGeneration = 0
    private var replyTask: Task<Void, Never>?
    private var replyContext: AppContext?
    private var replyDirection: TranslationDirection?
    /// SensitiveGuard blocks (other than password apps and pages) are confirmed by triggering again
    /// on the same app, window and text, 1–10 seconds after the notice.
    private var confirmGate = SensitiveGuard.ConfirmGate()
    private var completedTranslation: String?
    /// Finished outputs for the current selection, so switching tabs back and forth does not re-request.
    private var cachedOutputs: [ActionKind: String] = [:]
    private var streamedText = ""
    private var streamedReply = ""
    private var requestTask: Task<Void, Never>?
    private var localKeyMonitor: Any?
    /// 0.2.1.k.11: installed only while the button or the card is on screen.
    private var globalKeyMonitor: Any?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        LegacyMigration.runIfNeeded()
        AppSettings.registerDefaults()
        AppSettings.applyK02Defaults()
        AppSettings.applyK09Defaults()
        paused = AppSettings.paused

        reader = SelectionReader()
        monitor = SelectionMonitor()
        anchor = AnchorController()
        result = ResultPanelController()
        settingsWindow = SettingsWindowController()

        anchor.onPick = { [weak self] kind in self?.anchorPicked(kind) }
        anchor.onCopy = { [weak self] in self?.copyPendingSelection() }
        anchor.onVisibilityChange = { [weak self] in self?.updateGlobalKeyMonitor() }
        result.onVisibilityChange = { [weak self] in self?.updateGlobalKeyMonitor() }
        monitor.wantsWindowSnapshot = { [weak self] in
            guard let self else { return false }
            return !self.paused && AppSettings.showAnchor && AppSettings.mouseClipboardFallback && AXIsProcessTrusted()
        }
        result.onReplyTranslate = { [weak self] text in self?.translateReply(text) }
        result.onSwitchKind = { [weak self] kind in self?.switchKind(kind) }
        result.onClose = { [weak self] in self?.closeResult() }
        result.onReplace = { [weak self] text in self?.replaceSelection(with: text) }
        monitor.onMouseDown = { [weak self] point in self?.mouseDown(at: point) }
        monitor.onSelection = { [weak self] gesture in self?.selectionGesture(gesture) }

        installMainMenu()
        installStatusItem()
        monitor.start()
        registerHotKeys()
        installLocalKeyMonitor()
        UpdateChecker.startAutomaticChecks()

        if !AXIsProcessTrusted() {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
    }


    // MARK: - Menus

    /// Accessory apps have no visible menu bar, but key equivalents such as
    /// ⌘V in the Settings text fields still need an Edit menu to exist.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: L("关闭窗口", "Close Window", "ウインドウを閉じる", "윈도우 닫기"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("编辑", "Edit", "編集", "편집"))
        editMenu.addItem(withTitle: L("撤销", "Undo", "取り消す", "실행 취소"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("重做", "Redo", "やり直す", "실행 복귀"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪切", "Cut", "カット", "오려두기"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷贝", "Copy", "コピー", "복사"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴", "Paste", "ペースト", "붙여넣기"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("全选", "Select All", "すべてを選択", "전체 선택"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    private let appName = L("随译", "Suiyi", "Suiyi", "Suiyi")
    private let quitTitle = L("退出随译", "Quit Suiyi", "Suiyi を終了", "Suiyi 종료")
    private var pauseTitle: String {
        paused ? L("恢复划词", "Resume Selection Button", "選択ボタンを再開", "선택 버튼 다시 켜기") : L("暂停划词", "Pause Selection Button", "選択ボタンを一時停止", "선택 버튼 일시 정지")
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
            if let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: appName) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "译"
            }
            button.toolTip = appName
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(makeItem(L("翻译选中文字", "Translate Selection", "選択テキストを翻訳", "선택한 텍스트 번역"), #selector(menuTranslate(_:)), key: "t", modifiers: [.command, .option]))
        menu.addItem(makeItem(L("改写选中文字", "Rewrite Selection", "選択テキストを書き換え", "선택한 텍스트 다시 쓰기"), #selector(menuRewrite(_:)), key: "r", modifiers: [.command, .option]))
        menu.addItem(.separator())
        let pause = makeItem(pauseTitle, #selector(togglePause(_:)))
        menu.addItem(pause)
        pauseItem = pause
        let exclude = makeItem("", #selector(toggleExcludeFrontApp(_:)))
        exclude.isHidden = true
        menu.addItem(exclude)
        excludeItem = exclude
        let access = makeItem(L("授予辅助功能权限…", "Grant Accessibility Access…", "アクセシビリティを許可…", "손쉬운 사용 권한 허용…"), #selector(openAccessibilitySettings(_:)))
        access.isHidden = AXIsProcessTrusted()
        menu.addItem(access)
        accessibilityItem = access
        let diagnosis = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        diagnosis.isEnabled = false
        diagnosis.isHidden = true
        menu.addItem(diagnosis)
        diagnosisItem = diagnosis
        menu.addItem(.separator())
        menu.addItem(makeItem(L("设置…", "Settings…", "設定…", "설정…"), #selector(openSettings(_:)), key: ","))
        menu.addItem(makeItem(L("关于随译", "About Suiyi", "Suiyi について", "Suiyi에 관하여"), #selector(showAbout(_:))))
        menu.addItem(makeItem(L("检查更新…", "Check for Updates…", "アップデートを確認…", "업데이트 확인…"), #selector(checkForUpdates(_:))))
        menu.addItem(makeItem(L("反馈…", "Send Feedback…", "フィードバックを送信…", "피드백 보내기…"), #selector(sendFeedback(_:))))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: quitTitle, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem?.title = pauseTitle
        accessibilityItem?.isHidden = AXIsProcessTrusted()
        let time = lastSelectionDate.map { " · " + DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .medium) } ?? ""
        diagnosisItem?.title = L("最近一次划词：", "Last selection: ", "直近の選択：", "최근 선택: ") + lastSelectionNote + time
        diagnosisItem?.isHidden = lastSelectionNote.isEmpty
        // 0.2.1.k.09: the app in front when the menu opens (opening the menu does not activate Suiyi).
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier, let id = front.bundleIdentifier {
            let name = front.localizedName ?? id
            excludeTarget = (id, name)
            excludeItem?.title = L("在「\(name)」中停用随译", "Turn Off Suiyi in \(name)", "「\(name)」で Suiyi をオフ", "「\(name)」에서 Suiyi 끄기")
            excludeItem?.state = AppSettings.isExcluded(bundleID: id) ? .on : .off
            excludeItem?.isHidden = false
        } else {
            excludeTarget = nil
            excludeItem?.isHidden = true
        }
    }

    /// Records the outcome of a mouse selection for the menu's diagnosis line; never the text itself.
    /// The time is formatted when the menu opens, not on every gesture (0.2.1.k.13).
    private func noteSelection(_ message: String, app: NSRunningApplication? = nil) {
        lastSelectionNote = [message, app?.localizedName].compactMap { $0 }.joined(separator: " · ")
        lastSelectionDate = Date()
    }

    private func note(for reason: SensitiveGuard.Reason) -> String {
        switch reason {
        case .passwordApp: return L("密码类应用，不读取", "password app, not read", "パスワード管理アプリのため読み取らず", "비밀번호 앱이라 읽지 않음")
        case .passwordPage: return L("密码管理页面，不读取", "password-manager page, not read", "パスワード管理ページのため読み取らず", "비밀번호 관리자 페이지라 읽지 않음")
        case .extensionPage: return L("浏览器扩展页面，不读取", "browser extension page, not read", "拡張機能のページのため読み取らず", "브라우저 확장 페이지라 읽지 않음")
        case .codeApp: return L("终端或代码编辑器，默认不读取（设置 › 安全）", "terminal or code editor, off by default (Settings › Security)", "ターミナル／エディタは既定で読み取らず（設定 › セキュリティ）", "터미널 또는 코드 편집기, 기본값 꺼짐 (설정 › 보안)")
        case .sensitiveWindow: return L("窗口标题像密码或密钥页面，不读取", "window title looks like passwords or keys, not read", "ウィンドウタイトルがパスワード等のため読み取らず", "윈도우 제목이 비밀번호나 키처럼 보여 읽지 않음")
        case .sensitiveText: return L("选中内容像密码或密钥，不出按钮", "selection looks like a password or key, no button", "選択がパスワード等のためボタンなし", "선택한 내용이 비밀번호나 키처럼 보여 버튼을 표시하지 않음")
        }
    }

    private func note(for miss: SelectionReader.Miss?) -> String {
        switch miss {
        case .secureInput: return L("正在安全输入（如密码框），不读取", "secure input is on (e.g. a password field), not read", "セキュア入力中のため読み取らず", "보안 입력이 켜져 있어(예: 비밀번호 칸) 읽지 않음")
        case .focusChanged: return L("焦点已切到其他应用", "focus moved to another app", "フォーカスが別のアプリに移動", "포커스가 다른 앱으로 이동함")
        case .secureField: return L("选中的是密码框", "the selection is in a password field", "パスワード欄の選択", "선택한 내용이 비밀번호 칸에 있음")
        case .notAtPointer: return L("读到的选区不在鼠标位置", "the selection found is not where the pointer is", "選択範囲がポインタの位置にない", "찾은 선택 영역이 포인터 위치와 다름")
        case .unreadableWithoutCopy: return L("读不到选中文字：可在 设置 › 安全 打开「读不到时也显示按钮」，或按 ⌥⌘T", "couldn't read the selection: turn on the button for unreadable text in Settings › Security, or press ⌥⌘T", "選択を読み取れず：設定 › セキュリティで「読めないときもボタンを表示」をオン、または ⌥⌘T", "선택한 내용을 읽지 못함: 설정 › 보안에서 「읽을 수 없을 때도 버튼 표시」를 켜거나 ⌥⌘T를 누르세요")
        case .copyFailed: return L("模拟 ⌘C 没有拿到文字", "⌘C returned no text", "⌘C でテキストを取得できず", "⌘C로 텍스트를 가져오지 못함")
        case nil: return L("没有读到文字", "no text read", "テキストを読み取れず", "읽은 텍스트 없음")
        }
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
        pauseItem?.title = pauseTitle
    }

    /// Adds the app to the exclusion list, or takes it off again (same list as Settings › 排除的应用).
    @objc private func toggleExcludeFrontApp(_ sender: Any?) {
        guard let target = excludeTarget else { return }
        let exclude = !AppSettings.isExcluded(bundleID: target.id)
        AppSettings.setExcluded(target.id, exclude)
        if exclude { anchor.hide() }
    }

    @objc private func openSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    @objc private func sendFeedback(_ sender: Any?) {
        FeedbackPrompt.show()
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        UpdateChecker.checkInteractively()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName,
            .credits: NSAttributedString(string: L("Mac 全局翻译助手 · 无遥测，请求只发往你配置的接口。",
                                                           "Translate anything on your Mac · No telemetry; requests go only to the API you configure.",
                                                           "Mac のどこでも翻訳 · テレメトリなし。リクエストは設定した API にだけ送られます。", "Mac 어디서나 번역 · 원격 분석 없음. 요청은 설정한 API로만 전송됩니다."),
                                         attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                      .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc private func openAccessibilitySettings(_ sender: Any?) {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
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
            NSLog("Suiyi: some global hot keys could not be registered (already in use?)")
        }
    }

    private func installLocalKeyMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            let code = event.keyCode
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let delegate = self else { return false }
                return delegate.handleKeyDown(code: code, global: false)
            }
            return handled ? nil : event
        })
    }

    /// The global key monitor (Esc closes, any key hides the button) is only needed while something
    /// of ours is on screen. 0.2.1.k.11: before, every keystroke in every app woke Suiyi all day.
    private func updateGlobalKeyMonitor() {
        let wanted = anchor.isVisible || result.isVisible
        if wanted, globalKeyMonitor == nil {
            globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
                let code = event.keyCode
                MainActor.assumeIsolated {
                    guard let delegate = self else { return }
                    _ = delegate.handleKeyDown(code: code, global: true)
                }
            })
        } else if !wanted, let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
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

    /// What the checks before any read found. 0.2.1.k.13: the mouse, the button click and the hot key
    /// all run these same checks in the same order (before, the click path skipped the exclusion
    /// list); each entry point only decides how to tell the user.
    private enum PreRead {
        case ok(title: String?)
        case excluded
        case blocked(SensitiveGuard.Reason, title: String?)
    }

    /// Exclusion list, then password apps and pages, terminals and editors, and secret-looking titles.
    private func preReadCheck(_ target: SelectionReader.FocusTarget) -> PreRead {
        if target.bundleIDs.contains(where: { AppSettings.isExcluded(bundleID: $0) }) { return .excluded }
        let title = ContextCollector.windowTitle(pid: target.pid)
        if let reason = SensitiveGuard.blockReason(bundleIDs: target.bundleIDs, windowTitle: title, pageURL: target.pageURL,
                                                   allowCodeApps: AppSettings.allowInCodeApps) {
            return .blocked(reason, title: title)
        }
        return .ok(title: title)
    }

    private static var excludedNotice: String {
        L("当前应用在排除列表中，未读取选中文字。", "This app is excluded; the selection was not read.", "このアプリは除外リストにあるため、選択テキストを読み取りませんでした。", "제외된 앱이라 선택한 내용을 읽지 않았습니다.")
    }

    /// The process that really has keyboard focus (never Suiyi itself).
    private func foreignFocus() -> SelectionReader.FocusTarget? {
        let own = ProcessInfo.processInfo.processIdentifier
        guard let target = reader.focusTarget(), target.pid != own, target.focusPID != own else { return nil }
        return target
    }

    private func selectionGesture(_ gesture: SelectionGesture) {
        guard !paused, AppSettings.showAnchor, AXIsProcessTrusted() else {
            noteSelection(paused ? L("划词已暂停", "selection button paused", "選択ボタンは一時停止中", "선택 버튼 일시 정지됨")
                : !AppSettings.showAnchor ? L("设置里关闭了「划词后显示按钮」", "the button is turned off in Settings", "設定でボタンがオフ", "설정에서 버튼이 꺼져 있음")
                : L("没有辅助功能权限", "no Accessibility access", "アクセシビリティの許可なし", "손쉬운 사용 권한 없음"))
            return
        }
        // Selecting text inside our own result card (e.g. the reply box) is not
        // a selection in the foreign app.
        if result.isVisible && result.frame.contains(gesture.up) { return }
        // 0.2.1.k.12: the checks that need no Accessibility call come first. A moved or resized
        // window, an excluded app or a password app gets no AX traffic at all.
        if WindowProbe.moved(gesture.startWindow, gesture.startWindow.flatMap(WindowProbe.current)) {
            noteSelection(L("拖动的是窗口，不出按钮", "a window was moved, no button", "ウィンドウの移動のためボタンなし", "윈도우를 옮긴 것이라 버튼 없음"))
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        if let frontID = front?.bundleIdentifier, front?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            if AppSettings.isExcluded(bundleID: frontID) {
                noteSelection(L("应用在排除名单里", "app is in the excluded list", "除外リストのアプリ", "제외 목록에 있는 앱"), app: front)
                return
            }
            if SensitiveGuard.isPasswordApp(frontID) {
                noteSelection(note(for: .passwordApp), app: front)
                return
            }
        }
        guard let target = foreignFocus() else {
            noteSelection(L("没有找到有输入焦点的应用", "no app with keyboard focus found", "フォーカスのあるアプリが見つからず", "키보드 포커스를 가진 앱을 찾지 못함"))
            return
        }
        let bundleID = target.app?.bundleIdentifier
        // 0.2.1.k.01: password apps and pages, terminals/editors (unless allowed) and windows whose
        // title suggests credentials get no button, and nothing is read from them.
        let title: String?
        switch preReadCheck(target) {
        case .excluded:
            noteSelection(L("应用在排除名单里", "app is in the excluded list", "除外リストのアプリ", "제외 목록에 있는 앱"), app: target.app)
            return
        case .blocked(let reason, _):
            noteSelection(note(for: reason), app: target.app)
            return
        case .ok(let windowTitle):
            title = windowTitle
        }

        // 0.2.1.k.10: a mouse gesture never sends keys. The selection is read through Accessibility
        // only; where that finds nothing (WeChat, Telegram), a drag may still get the button, and
        // ⌘C is sent when the user clicks it. Never in apps where ⌘C would copy files, not text.
        let bundle = bundleID?.lowercased() ?? ""
        let mayReadOnClick = AppSettings.mouseClipboardFallback && gesture.kind == .drag
            && !Self.noClipboardFallbackOnMouse.contains(bundle) && !SelectionReader.sendsNoSyntheticKeys(bundle)

        selectionGeneration += 1
        let generation = selectionGeneration
        Task { @MainActor in
            guard let selection = await self.reader.read(allowClipboard: false,
                                                         gesturePoints: [gesture.down, gesture.up],
                                                         target: target) else {
                guard generation == self.selectionGeneration, !self.paused else { return }
                guard mayReadOnClick, self.reader.lastMiss == .unreadableWithoutCopy else {
                    self.noteSelection(self.note(for: self.reader.lastMiss), app: target.app)
                    return
                }
                if self.reader.isNonTextControl(at: gesture.down, pid: target.pid) {
                    self.noteSelection(L("拖动的是滚动条或滑块，不出按钮", "a scroll bar or slider was dragged, no button",
                                         "スクロールバー等の操作のためボタンなし", "스크롤 막대나 슬라이더를 끈 것이라 버튼 없음"), app: target.app)
                    return
                }
                self.noteSelection(L("读不到文字，已弹出按钮，点了才读取", "text not readable; button shown, read on click",
                                     "読み取れず：ボタンを表示（クリック時に読み取り）", "읽지 못함: 버튼 표시(누르면 읽음)"), app: target.app)
                self.pendingCapture = nil
                self.pendingUnread = UnreadSelection(target: target, points: [gesture.down, gesture.up])
                self.anchor.show(at: gesture.up)
                return
            }
            guard generation == self.selectionGeneration, !self.paused else { return }
            // A password-looking selection gets no button: one stray click must not send it.
            if SensitiveGuard.looksSensitive(selection.text) {
                self.noteSelection(self.note(for: .sensitiveText), app: target.app)
                return
            }
            self.noteSelection(L("已弹出按钮", "button shown", "ボタンを表示", "버튼 표시됨"), app: target.app)
            let context = ContextCollector.collect(for: selection, windowTitle: title)
            self.pendingUnread = nil
            self.pendingCapture = Capture(selection: selection, context: context)
            self.anchor.show(at: gesture.up)
        }
    }

    /// 0.2.1.k.10: the user clicked a button shown without text. Only now is ⌘C sent, to the same app
    /// as before; the window check runs again, and the content check comes before anything is sent.
    private func readOnClick(_ unread: UnreadSelection, kind: ActionKind, at point: NSPoint) {
        pendingUnread = nil
        selectionGeneration += 1
        let generation = selectionGeneration
        Task { @MainActor in
            guard let target = self.foreignFocus(), target.pid == unread.target.pid else {
                self.result.showNotice(L("焦点已切到其他应用，没有读取。", "The focus moved to another app; nothing was read.",
                                         "フォーカスが別のアプリに移ったため、読み取りませんでした。", "포커스가 다른 앱으로 옮겨져 읽지 않았습니다."), at: point)
                return
            }
            let title: String?
            switch self.preReadCheck(target) {
            case .excluded:
                self.result.showNotice(Self.excludedNotice, at: point)
                return
            case .blocked(let reason, let blockedTitle):
                self.block(SensitiveGuard.ConfirmGate.Key(reason: reason, pid: target.pid, title: blockedTitle, text: nil), at: point)
                return
            case .ok(let windowTitle):
                title = windowTitle
            }
            let selection = await self.reader.read(allowClipboard: true, gesturePoints: unread.points, target: target)
            guard generation == self.selectionGeneration else { return }   // the user moved on during the ⌘C wait
            guard let selection else {
                self.result.showNotice(L("没有检测到选中的文字。", "No selected text found.", "選択されたテキストが見つかりません。", "선택한 텍스트를 찾지 못했습니다."), at: point)
                return
            }
            if SensitiveGuard.looksSensitive(selection.text) {
                self.block(SensitiveGuard.ConfirmGate.Key(reason: .sensitiveText, pid: target.pid, title: title,
                                                          text: selection.text), at: point)
                return
            }
            let context = ContextCollector.collect(for: selection, windowTitle: title)
            self.run(kind, capture: Capture(selection: selection, context: context), at: point)
        }
    }

    /// Shows the notice and arms the gate, so the same trigger 1–10 s later may continue.
    private func block(_ key: SensitiveGuard.ConfirmGate.Key, at point: NSPoint) {
        confirmGate.arm(key)
        result.showNotice(SensitiveGuard.notice(for: key.reason), at: point)
    }

    /// 0.2.1.k.06: right-click / two-finger click on the button copies the selection, exactly like
    /// ⌘C in the app (full text and formatting). If the app has lost focus meanwhile, the text Suiyi
    /// read is copied instead (trimmed, at most 4,000 characters). Nothing is sent to the model.
    private func copyPendingSelection() {
        if let unread = pendingUnread {
            // Nothing was read: the app's own ⌘C is the only copy there is.
            Task { @MainActor in
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == unread.target.pid {
                    _ = await Clipboard.copyForUser()
                }
            }
            return
        }
        guard let capture = pendingCapture else { return }
        Task { @MainActor in
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == capture.selection.pid,
               await Clipboard.copyForUser() { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(capture.selection.text, forType: .string)
        }
    }

    private func anchorPicked(_ kind: ActionKind) {
        if let unread = pendingUnread {
            readOnClick(unread, kind: kind, at: anchor.referencePoint)
            return
        }
        guard let capture = pendingCapture else { return }
        run(kind, capture: capture, at: anchor.referencePoint)
    }

    /// The card's 翻译 / 改写 tabs: same selection, same card position.
    private func switchKind(_ kind: ActionKind) {
        guard let capture = lastCapture, result.isVisible else { return }
        run(kind, capture: capture, at: NSPoint(x: result.frame.minX, y: result.frame.maxY), sameSelection: true)
    }

    // MARK: - Hot key / menu flow

    private func triggerDirect(_ kind: ActionKind, delayNanos: UInt64) {
        anchor.hide()
        let point = NSEvent.mouseLocation
        guard AXIsProcessTrusted() else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            result.showNotice(L("需要辅助功能权限：系统设置 › 隐私与安全性 › 辅助功能，打开随译。",
                                 "Accessibility access is needed: System Settings › Privacy & Security › Accessibility, turn on Suiyi.",
                                 "アクセシビリティの許可が必要です：システム設定 › プライバシーとセキュリティ › アクセシビリティ で Suiyi をオンにしてください。", "손쉬운 사용 권한이 필요합니다: 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 Suiyi를 켜세요."), at: point)
            return
        }
        selectionGeneration += 1
        Task { @MainActor in
            if delayNanos > 0 {
                try? await Task.sleep(nanoseconds: delayNanos)
            }
            guard let target = self.foreignFocus() else { return }
            // 0.2.1.k.01: app, page and window checks come before any read (and before any ⌘C);
            // the content check comes after the read and before anything is sent. Each block needs
            // its own confirmation, and a window-level confirmation never skips the content check.
            let pid = target.pid
            let title: String?
            var overridden = false
            switch self.preReadCheck(target) {
            case .excluded:
                self.result.showNotice(Self.excludedNotice, at: point)
                return
            case .blocked(let reason, let blockedTitle):
                let key = SensitiveGuard.ConfirmGate.Key(reason: reason, pid: pid, title: blockedTitle, text: nil)
                guard self.confirmGate.isConfirmed(key) else { self.block(key, at: point); return }
                overridden = true
                title = blockedTitle
            case .ok(let windowTitle):
                title = windowTitle
            }
            let noKeys = SelectionReader.sendsNoSyntheticKeys(target.app?.bundleIdentifier)
            var selection = await self.reader.read(allowClipboard: !noKeys, gesturePoints: nil, target: target)
            if selection == nil, noKeys, self.reader.lastMiss == .unreadableWithoutCopy {
                // 0.2.1.k.12: the guest got no ⌘C; what the user copied inside it is on the clipboard.
                selection = self.clipboardSelection(target: target)
                guard selection != nil else {
                    self.result.showNotice(L("虚拟机或远程桌面里不模拟按键。先在里面复制（⌘C 或 Ctrl+C），再按 ⌥⌘T 翻译剪贴板里的文字。",
                                             "No synthetic keys in a VM or remote desktop. Copy inside it first (⌘C or Ctrl+C), then press ⌥⌘T to translate the clipboard.",
                                             "仮想マシンやリモートデスクトップにはキーを送りません。先に中でコピー（⌘C か Ctrl+C）してから ⌥⌘T を押すと、クリップボードの文字を翻訳します。", "가상 머신이나 원격 데스크톱에는 키를 보내지 않습니다. 먼저 그 안에서 복사(⌘C 또는 Ctrl+C)한 뒤 ⌥⌘T를 누르면 클립보드의 텍스트를 번역합니다."), at: point)
                    return
                }
            }
            guard let selection else {
                self.result.showNotice(L("没有检测到选中的文字。", "No selected text found.", "選択されたテキストが見つかりません。", "선택한 텍스트를 찾지 못했습니다."), at: point)
                return
            }
            if SensitiveGuard.looksSensitive(selection.text) {
                let key = SensitiveGuard.ConfirmGate.Key(reason: .sensitiveText, pid: pid, title: title, text: selection.text)
                guard self.confirmGate.isConfirmed(key) else { self.block(key, at: point); return }
                overridden = true
            }
            self.confirmGate.reset()
            let context = ContextCollector.collect(for: selection, windowTitle: title)
            self.run(kind, capture: Capture(selection: selection, context: context, overridden: overridden), at: point)
        }
    }

    /// The clipboard's text as a selection of `target` (VMs and remote desktops only). A password
    /// manager's item is never used.
    private func clipboardSelection(target: SelectionReader.FocusTarget) -> CapturedSelection? {
        let pasteboard = NSPasteboard.general
        guard !SensitiveGuard.isSensitivePasteboard(types: (pasteboard.types ?? []).map(\.rawValue)),
              let app = target.app, let text = pasteboard.string(forType: .string)?.trimmed, !text.isEmpty else { return nil }
        return CapturedSelection(text: String(text.prefix(SelectionReader.maxLength)), element: nil, pid: target.pid,
                                 bundleID: app.bundleIdentifier, appName: app.localizedName ?? app.bundleIdentifier ?? "App",
                                 viaAX: false, editable: false)
    }

    // MARK: - Running a request

    private func run(_ kind: ActionKind, capture: Capture, at point: NSPoint, sameSelection: Bool = false) {
        cancelReply()
        if !sameSelection { cachedOutputs = [:] }
        requestTask?.cancel()
        requestGeneration += 1
        let generation = requestGeneration
        var capture = capture
        if !sameSelection { capture.selection.editable = SelectionReader.isEditable(capture.selection) }   // 0.2.1.k.12: two AX calls, only now
        lastCapture = capture
        result.copiesAreSensitive = capture.overridden
        streamedText = ""
        completedTranslation = nil
        anchor.hide()

        let text = capture.selection.text
        let context = capture.context
        let header: String
        let messages: [ChatMessage]
        let temperature: Double
        var shortPhrase = false
        var reply: TranslationDirection?

        switch kind {
        case .translate:
            let mine = AppSettings.myLanguage
            let direction = LanguageDetector.direction(for: text, mine: mine, outgoing: AppSettings.outgoingLanguage)
            if let back = LanguageDetector.replyDirection(for: direction, mine: mine) {
                reply = back
                replyDirection = back
                replyContext = context
            }
            shortPhrase = Prompts.isShortPhrase(text)
            header = "\(direction.sourceLabel) → \(direction.target.shortLabel)  ·  \(context.appName)"
            messages = Prompts.translate(text: text, direction: direction, context: context,
                                         style: AppSettings.translationStyle, shortPhrase: shortPhrase)
            temperature = 0.3
        case .rewrite:
            header = L("保持原语言", "Same language", "同じ言語のまま", "같은 언어 유지") + "  ·  \(context.appName)"
            messages = Prompts.rewrite(text: text, context: context)
            temperature = 0.7
        }

        result.present(kind: kind, header: header, editable: capture.selection.editable,
                       shortPhrase: shortPhrase, at: point, reply: reply, keepPosition: sameSelection)

        if sameSelection, let cached = cachedOutputs[kind] {
            streamedText = cached
            result.append(cached)
            result.finish()
            completedTranslation = cached
            return
        }

        guard let key = Keychain.apiKey(), !key.isEmpty else {
            result.showError(LLMError.missingKey.errorDescription ?? "Missing API key")
            return
        }
        let config = LLMConfig(baseURL: AppSettings.baseURL, apiKey: key, model: AppSettings.model)

        requestTask = Task { @MainActor in
            do {
                try await LLMClient.streamChat(config: config, messages: messages, temperature: temperature) { [weak self] delta in
                    guard let self, self.requestGeneration == generation else { return }
                    self.streamedText += delta
                    self.result.append(delta)
                }
                guard self.requestGeneration == generation, !Task.isCancelled else { return }
                self.result.finish()
                self.completedTranslation = self.streamedText
                self.cachedOutputs[kind] = self.streamedText
                if !capture.overridden {
                    self.logHistory(HistoryEntry(mode: kind == .translate ? "translate" : "rewrite",
                        appBundleID: capture.selection.bundleID, appName: context.appName,
                        original: text, translation: self.streamedText))
                }
            } catch {
                guard self.requestGeneration == generation, !Task.isCancelled else { return }
                if error is CancellationError { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                self.result.showError(LLMError.userMessage(for: error))
            }
        }
    }

    private func cancelReply() {
        replyTask?.cancel()
        replyTask = nil
        replyGeneration += 1
        replyContext = nil
        replyDirection = nil
        completedTranslation = nil
    }

    private func translateReply(_ text: String) {
        guard let context = replyContext, let direction = replyDirection,
              result.isVisible, !text.trimmed.isEmpty else { return }
        // 0.2.1.k.01: a reply that looks like a password or key is held back until Translate is
        // pressed again on the same text 1–10 seconds later; such replies are never saved to history.
        let sensitiveReply = SensitiveGuard.looksSensitive(text)
        if sensitiveReply {
            let key = SensitiveGuard.ConfirmGate.Key(reason: .sensitiveText, pid: 0, title: "reply", text: text)
            guard confirmGate.isConfirmed(key) else {
                confirmGate.arm(key)
                result.showReplyError(L("你写的回复看起来像密码、密钥或卡号，没有发送。如确需继续，请在 1 秒后、10 秒内再点一次翻译；这次不会记入历史。",
                                        "Your reply looks like a password, key or card number; nothing was sent. To continue anyway, press Translate again after 1 and within 10 seconds; it will not be saved to history.",
                                        "返信がパスワード、キー、カード番号のようなので送信しませんでした。続行する場合は、1 秒以上たってから 10 秒以内にもう一度翻訳を押してください（履歴には残りません）。", "답장이 비밀번호, 키 또는 카드 번호처럼 보여 보내지 않았습니다. 그래도 계속하려면 1초 후 10초 이내에 번역을 다시 누르세요. 기록에는 저장되지 않습니다."))
                return
            }
            confirmGate.reset()
            result.copiesAreSensitive = true
        }
        replyTask?.cancel()
        replyGeneration += 1
        let generation = replyGeneration
        guard let key = Keychain.apiKey(), !key.trimmed.isEmpty else {
            result.showReplyError(LLMError.missingKey.errorDescription ?? "Missing API key")
            return
        }
        let config = LLMConfig(baseURL: AppSettings.baseURL, apiKey: key, model: AppSettings.model)
        guard let capture = lastCapture, let translation = completedTranslation else {
            result.showReplyError(L("原文已不在，请重新划词。", "The original text is gone; select it again.", "元のテキストがありません。もう一度選択してください。", "원문이 없습니다. 다시 선택하세요."))
            return
        }
        streamedReply = ""
        let messages = StyleContext.replyMessages(Prompts.reply(
            text: text, direction: direction, context: context, style: AppSettings.translationStyle,
            inReplyTo: capture.selection.text))
        replyTask = Task { @MainActor in
            do {
                try await LLMClient.streamChat(config: config, messages: messages, temperature: 0.3) { [weak self] delta in
                    guard let self, self.replyGeneration == generation else { return }
                    self.streamedReply += delta
                    self.result.appendReply(delta)
                }
                guard self.replyGeneration == generation, !Task.isCancelled else { return }
                self.result.finishReply()
                if !capture.overridden, !sensitiveReply {
                    self.logHistory(HistoryEntry(mode: "reply", appBundleID: capture.selection.bundleID,
                        appName: context.appName, original: capture.selection.text, translation: translation,
                        replyZH: text, replyEN: self.streamedReply))
                }
            } catch {
                guard self.replyGeneration == generation, !Task.isCancelled else { return }
                if error is CancellationError { return }
                if let urlError = error as? URLError, urlError.code == .cancelled { return }
                self.result.showReplyError(LLMError.userMessage(for: error))
            }
        }
    }

    private func logHistory(_ entry: HistoryEntry) {
        do {
            if try HistoryStore.shared.append(entry) { ProfileBuilder.shared.didLogEntry() }
        } catch {
            NSLog("Suiyi: history append failed: %@", error.localizedDescription)
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
        let point = NSPoint(x: result.frame.minX, y: result.frame.maxY)
        closeResult()
        let selection = capture.selection
        let scene = capture.context.scene
        Task { @MainActor in
            // Native document/e-mail editors: write the AX attribute directly.
            // Browsers, chat and code apps often accept the write but ignore
            // it, so paste there instead.
            if selection.viaAX, selection.editable, let element = selection.element,
               scene == .document || scene == .email {
                // 0.2.1.k.12: only if what is selected now is still the text that was translated.
                guard AX.string(element, kAXSelectedTextAttribute)?.trimmed == selection.text.trimmed else {
                    self.leaveOnClipboard(text, at: point); return
                }
                let error = AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString)
                if error == .success { return }
            }
            // A VM or remote desktop never gets a synthetic ⌘V.
            if SelectionReader.sendsNoSyntheticKeys(selection.bundleID) { self.leaveOnClipboard(text, at: point); return }
            if let app = NSRunningApplication(processIdentifier: selection.pid), !app.isActive {
                app.activate(options: [])
                try? await Task.sleep(nanoseconds: 150_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 80_000_000)
            }
            if !(await Clipboard.paste(text, into: selection.pid)) { self.leaveOnClipboard(text, at: point) }
        }
    }

    /// Replace could not be done safely: the text is put on the clipboard for the user to paste.
    private func leaveOnClipboard(_ text: String, at point: NSPoint) {
        let pasteboard = NSPasteboard.general
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        result.showNotice(L("没有替换（选区已变化，或此处不能粘贴）。译文已复制，请自行粘贴。",
                            "Not replaced (the selection changed, or pasting here is not safe). The text is on the clipboard; paste it yourself.",
                            "置き換えませんでした（選択が変わったか、ここには貼り付けられません）。訳文はコピー済みです。手動で貼り付けてください。", "바꾸지 않았습니다(선택이 바뀌었거나 여기에는 붙여 넣을 수 없음). 번역은 복사해 두었으니 직접 붙여 넣으세요."), at: point)
    }
}
