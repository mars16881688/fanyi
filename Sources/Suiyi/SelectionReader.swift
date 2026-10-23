import AppKit
import ApplicationServices
import Carbon

struct CapturedSelection {
    let text: String
    /// Focused AX element at capture time (may be nil for clipboard captures).
    let element: AXUIElement?
    let pid: pid_t
    let bundleID: String?
    let appName: String
    /// True when the text came from kAXSelectedTextAttribute.
    let viaAX: Bool
    /// The focused element accepts writes (used to decide whether to offer 替换). 0.2.1.k.12: filled
    /// in when the card is shown, not on every gesture.
    var editable: Bool
}

@MainActor
final class SelectionReader {
    static let maxLength = 4000

    /// Electron apps only build their AX tree when asked; remember who we asked (pid + launch
    /// time, so a reused pid is asked again).
    private var primed = Set<String>()
    private var isElectronByPID: [pid_t: Bool] = [:]

    init() {}

    /// Who actually has keyboard focus. A non-activating panel (Spotlight, a launcher's password
    /// extension) or a web-content helper (Safari, Mail) can differ from the frontmost app, so the
    /// guards run against both, and `read` refuses to read from any other process.
    struct FocusTarget {
        /// The regular app that owns the window (title, exclusions, app name).
        let pid: pid_t
        let app: NSRunningApplication?
        /// The process that holds the focused element; differs for helpers and floating panels.
        let focusPID: pid_t
        let focusApp: NSRunningApplication?
        /// URL of the focused web page, when the focus is inside a browser page or extension.
        let pageURL: String?
        /// 0.2.1.k.12: the focused element, so `read` does not ask for it a second time.
        let focusedElement: AXUIElement?
        /// Whether a web area can exist here (a browser, an out-of-process web view such as Safari's
        /// or Mail's, or an Electron app). Elsewhere the web walks are skipped.
        let mayHaveWebArea: Bool

        var bundleIDs: [String?] { [app?.bundleIdentifier, focusApp?.bundleIdentifier] }
    }

    func focusTarget() -> FocusTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, AX.timeout)
        var element = AX.element(systemWide, kAXFocusedUIElementAttribute)
        var focusPID: pid_t = 0
        if element == nil || AXUIElementGetPid(element!, &focusPID) != .success || focusPID <= 0 {
            guard let front else { return nil }
            focusPID = front.processIdentifier
            let appElement = AXUIElementCreateApplication(focusPID)
            AXUIElementSetMessagingTimeout(appElement, AX.timeout)
            element = AX.element(appElement, kAXFocusedUIElementAttribute)
        }
        let focusApp = NSRunningApplication(processIdentifier: focusPID)
        // A helper or panel without a regular app identity is attributed to the frontmost app.
        let owner = focusApp?.activationPolicy == .regular ? focusApp : (front ?? focusApp)
        let ownerPID = owner?.processIdentifier ?? focusPID
        let web = SceneKind.forBundleID(owner?.bundleIdentifier) == .browser || focusPID != ownerPID
            || isElectronApp(owner)
        return FocusTarget(pid: ownerPID, app: owner,
                           focusPID: focusPID, focusApp: focusApp,
                           pageURL: web ? element.flatMap(ContextCollector.pageURL(of:)) : nil,
                           focusedElement: element, mayHaveWebArea: web)
    }

    private func isElectronApp(_ app: NSRunningApplication?) -> Bool {
        guard let app else { return false }
        let pid = app.processIdentifier
        if isElectronByPID[pid] == nil { isElectronByPID[pid] = Self.isElectron(app.bundleURL) }
        return isElectronByPID[pid] == true
    }

    /// Reads the current selection of the frontmost app.
    /// - allowClipboard: fall back to a synthetic ⌘C if AX has nothing.
    /// - gesturePoints: for mouse triggers, the mouse-down/up points; when the
    ///   focused element's frame is known and contains neither, the AX
    ///   selection is considered stale and nothing is returned.
    /// - target: what the guards approved (see `focusTarget()`); nothing is read, and no ⌘C is
    ///   sent, when the focus now belongs to any other process.
    func read(allowClipboard: Bool, gesturePoints: [NSPoint]?, target: FocusTarget) async -> CapturedSelection? {
        lastMiss = nil   // trust was checked by focusTarget(), which every caller runs first
        // Some app is collecting a password (or "Secure Keyboard Entry" is on).
        if IsSecureEventInputEnabled() { lastMiss = .secureInput; return nil }
        guard let app = NSRunningApplication(processIdentifier: target.pid) else { lastMiss = .focusChanged; return nil }
        let pid = app.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, AX.timeout)
        prime(appElement, app: app)

        // 0.2.1.k.12: the focused element comes from `focusTarget()` (taken just before); it is
        // not asked for again.
        let focused = target.focusedElement
        if let element = focused {
            var focusedPID: pid_t = 0
            if AXUIElementGetPid(element, &focusedPID) == .success, focusedPID != pid, focusedPID != target.focusPID {
                lastMiss = .focusChanged
                return nil
            }
            AXUIElementSetMessagingTimeout(element, AX.timeout)
            if AX.isSecure(element) { lastMiss = .secureField; return nil }
        } else if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
            lastMiss = .focusChanged
            return nil  // a ⌘C would go to some other app
        }

        var text = ""
        var viaAX = false
        if let element = focused,
           let selected = AX.string(element, kAXSelectedTextAttribute),
           selected.contains(where: { !$0.isWhitespace }) {
            if let points = gesturePoints, let frame = AX.cocoaFrame(of: element) {
                let hitArea = frame.insetBy(dx: -8, dy: -8)
                if !points.contains(where: { hitArea.contains($0) }) {
                    lastMiss = .notAtPointer
                    return nil   // selection lives elsewhere; this gesture was not a text selection
                }
            }
            text = selected
            viaAX = true
        } else if target.mayHaveWebArea,
                  let web = webSelection(at: gesturePoints?.last ?? NSEvent.mouseLocation, focused: focused,
                                         appElement: appElement, allowed: [pid, target.focusPID]) {
            text = web   // browser page text, read without the clipboard
        } else if allowClipboard {
            guard let copied = await Clipboard.copySelection() else { lastMiss = .copyFailed; return nil }
            text = copied
        } else {
            lastMiss = .unreadableWithoutCopy
            return nil
        }

        // 0.2.1.k.13: cut before trimming, so a select-all of a long document is not copied whole.
        let cleaned = String(String(text.prefix(Self.maxLength + 2000)).trimmed.prefix(Self.maxLength))
        guard !cleaned.isEmpty else { lastMiss = .copyFailed; return nil }

        return CapturedSelection(
            text: cleaned,
            element: focused,
            pid: pid,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "App",
            viaAX: viaAX,
            editable: false
        )
    }

    /// Whether the element the text came from accepts a replacement (two calls, made only when the
    /// card is shown).
    static func isEditable(_ selection: CapturedSelection) -> Bool {
        guard selection.viaAX, let element = selection.element else { return false }
        return AX.isSettable(element, kAXSelectedTextAttribute) || AX.isSettable(element, kAXValueAttribute)
    }

    /// 0.2.1.k.12: virtual machines and remote desktops. They never expose text through Accessibility,
    /// and a synthetic ⌘C there goes into the guest (often as Ctrl+C: an interrupt in a terminal).
    /// No button on unreadable drags; the hot key reads the clipboard the user filled instead.
    static let noSyntheticKeysApps: Set<String> = [
        "dev.tryomarchy.native", "com.parallels.desktop.console", "com.vmware.fusion", "com.utmapp.utm",
        "org.virtualbox.app.virtualbox", "com.microsoft.rdc.macos", "com.microsoft.rdc.mac", "com.apple.screensharing",
        "com.apple.remotedesktop", "com.edovia.screens.mac", "com.edovia.screens5.mac", "com.p5sys.jump.mac",
        "com.realvnc.vncviewer", "com.citrix.receiver.nomas", "com.philandro.anydesk", "com.teamviewer.teamviewer",
        "com.moonlight-stream.moonlight", "com.splashtop.splashtop-business", "com.splashtop.splashtop-personal",
    ]

    static func sendsNoSyntheticKeys(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return noSyntheticKeysApps.contains(id)
    }

    /// 0.2.1.k.10: dragging these moves a control, not a text selection.
    static let nonTextRoles: Set<String> = ["AXScrollBar", "AXValueIndicator", "AXSlider", "AXSplitter"]

    /// Whether the drag began on a scroll bar, slider or split divider of the app.
    func isNonTextControl(at point: NSPoint, pid: pid_t) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, AX.timeout)
        guard let hit = AX.element(at: point, in: appElement) else { return false }
        AXUIElementSetMessagingTimeout(hit, AX.timeout)
        return Self.nonTextRoles.contains(AX.string(hit, kAXRoleAttribute) ?? "")
    }

    /// Why the last `read` returned nothing (no content, just the step), for the menu's diagnosis line.
    enum Miss {
        case secureInput, focusChanged, secureField, notAtPointer, unreadableWithoutCopy, copyFailed
    }
    private(set) var lastMiss: Miss?

    /// Page text selected in a browser: walk up from the element under the pointer (and from the
    /// focused element) to the nearest element with a selection or to its AXWebArea.
    /// 0.2.1.k.12: one role read per level (the secure check reuses it), the walk stops at the window,
    /// the second chain skips nodes the first one visited, and the whole thing has a 0.4 s budget.
    private func webSelection(at point: NSPoint, focused: AXUIElement?, appElement: AXUIElement,
                              allowed: Set<pid_t>) -> String? {
        let deadline = Date().addingTimeInterval(0.4)
        var visited: [AXUIElement] = []
        let starts = [AX.element(at: point, in: appElement), focused].compactMap { $0 }
        for start in starts {
            var owner: pid_t = 0
            guard AXUIElementGetPid(start, &owner) == .success, allowed.contains(owner) else { continue }
            var node: AXUIElement? = start
            for _ in 0..<12 {
                guard let current = node, Date() < deadline else { break }
                if visited.contains(where: { CFEqual($0, current) }) { break }   // the first chain covered the rest
                visited.append(current)
                AXUIElementSetMessagingTimeout(current, AX.timeout)
                let role = AX.string(current, kAXRoleAttribute) ?? ""
                if role == "AXSecureTextField" { return nil }
                if role == "AXTextField", AX.string(current, kAXSubroleAttribute) == "AXSecureTextField" { return nil }
                if role == "AXWindow" || role == "AXApplication" { break }
                if let selected = AX.string(current, kAXSelectedTextAttribute), !selected.trimmed.isEmpty { return selected }
                if role == "AXWebArea" {
                    if let selected = AX.webSelectedText(current), !selected.trimmed.isEmpty { return selected }
                    break
                }
                node = AX.element(current, kAXParentAttribute)
            }
        }
        return nil
    }

    /// 0.2.1.k.11: the write happens only here, in `read`, i.e. after the exclusion, password-app and
    /// window checks passed, and only for Electron apps. It switches on Chromium's whole
    /// accessibility tree for the rest of that process's life, so it is not done to apps that
    /// do not need it, and never to a password manager.
    private func prime(_ appElement: AXUIElement, app: NSRunningApplication) {
        let pid = app.processIdentifier
        let key = "\(pid)-\(app.launchDate?.timeIntervalSince1970 ?? 0)"
        guard !primed.contains(key), !SensitiveGuard.isPasswordApp(app.bundleIdentifier) else { return }
        primed.insert(key)
        if isElectronByPID[pid] == nil { isElectronByPID[pid] = Self.isElectron(app.bundleURL) }
        guard isElectronByPID[pid] == true else { return }
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    nonisolated static func isElectron(_ bundleURL: URL?) -> Bool {
        guard let bundleURL else { return false }
        let framework = bundleURL.appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return FileManager.default.fileExists(atPath: framework.path)
    }
}
