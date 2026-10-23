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
    /// The focused element accepts writes (used to decide whether to offer 替换).
    let editable: Bool
}

@MainActor
final class SelectionReader {
    static let maxLength = 4000

    /// Electron apps only build their AX tree when asked; remember who we asked.
    private var primedPIDs = Set<pid_t>()

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

        var bundleIDs: [String?] { [app?.bundleIdentifier, focusApp?.bundleIdentifier] }
    }

    func focusTarget() -> FocusTarget? {
        guard AXIsProcessTrusted() else { return nil }
        let front = NSWorkspace.shared.frontmostApplication
        if let front {
            let appElement = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(appElement, AX.timeout)
            prime(appElement, pid: front.processIdentifier)
        }
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
        return FocusTarget(pid: owner?.processIdentifier ?? focusPID, app: owner,
                           focusPID: focusPID, focusApp: focusApp,
                           pageURL: element.flatMap(ContextCollector.pageURL(of:)))
    }

    /// Reads the current selection of the frontmost app.
    /// - allowClipboard: fall back to a synthetic ⌘C if AX has nothing.
    /// - gesturePoints: for mouse triggers, the mouse-down/up points; when the
    ///   focused element's frame is known and contains neither, the AX
    ///   selection is considered stale and nothing is returned.
    /// - target: what the guards approved (see `focusTarget()`); nothing is read, and no ⌘C is
    ///   sent, when the focus now belongs to any other process.
    func read(allowClipboard: Bool, gesturePoints: [NSPoint]?, target: FocusTarget) async -> CapturedSelection? {
        lastMiss = nil
        guard AXIsProcessTrusted() else { return nil }
        // Some app is collecting a password (or "Secure Keyboard Entry" is on).
        if IsSecureEventInputEnabled() { lastMiss = .secureInput; return nil }
        guard let app = NSRunningApplication(processIdentifier: target.pid) else { lastMiss = .focusChanged; return nil }
        let pid = app.processIdentifier
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, AX.timeout)
        prime(appElement, pid: pid)

        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, AX.timeout)
        var focused = AX.element(systemWide, kAXFocusedUIElementAttribute)
        if focused == nil {
            focused = AX.element(appElement, kAXFocusedUIElementAttribute)
        }
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
           !selected.trimmed.isEmpty {
            if let points = gesturePoints, let frame = AX.cocoaFrame(of: element) {
                let hitArea = frame.insetBy(dx: -8, dy: -8)
                if !points.contains(where: { hitArea.contains($0) }) {
                    lastMiss = .notAtPointer
                    return nil   // selection lives elsewhere; this gesture was not a text selection
                }
            }
            text = selected
            viaAX = true
        } else if let web = webSelection(at: gesturePoints?.last ?? NSEvent.mouseLocation, focused: focused,
                                         appElement: appElement, allowed: [pid, target.focusPID]) {
            text = web   // browser page text, read without the clipboard
        } else if allowClipboard {
            guard let copied = await Clipboard.copySelection() else { lastMiss = .copyFailed; return nil }
            text = copied
        } else {
            lastMiss = .unreadableWithoutCopy
            return nil
        }

        var cleaned = text.trimmed
        guard !cleaned.isEmpty else { lastMiss = .copyFailed; return nil }
        if cleaned.count > Self.maxLength {
            cleaned = String(cleaned.prefix(Self.maxLength))
        }

        var editable = false
        if let element = focused {
            editable = AX.isSettable(element, kAXSelectedTextAttribute)
                || AX.isSettable(element, kAXValueAttribute)
        }

        return CapturedSelection(
            text: cleaned,
            element: focused,
            pid: pid,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? app.bundleIdentifier ?? "App",
            viaAX: viaAX,
            editable: editable
        )
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
    private func webSelection(at point: NSPoint, focused: AXUIElement?, appElement: AXUIElement,
                              allowed: Set<pid_t>) -> String? {
        let starts = [AX.element(at: point, in: appElement), focused].compactMap { $0 }
        for start in starts {
            var owner: pid_t = 0
            guard AXUIElementGetPid(start, &owner) == .success, allowed.contains(owner) else { continue }
            var node: AXUIElement? = start
            for _ in 0..<12 {
                guard let current = node else { break }
                AXUIElementSetMessagingTimeout(current, AX.timeout)
                if AX.isSecure(current) { return nil }
                if let selected = AX.string(current, kAXSelectedTextAttribute), !selected.trimmed.isEmpty { return selected }
                if AX.string(current, kAXRoleAttribute) == "AXWebArea" {
                    if let selected = AX.webSelectedText(current), !selected.trimmed.isEmpty { return selected }
                    break
                }
                node = AX.element(current, kAXParentAttribute)
            }
        }
        return nil
    }

    private func prime(_ appElement: AXUIElement, pid: pid_t) {
        guard !primedPIDs.contains(pid) else { return }
        primedPIDs.insert(pid)
        // Harmless no-op for non-Electron apps.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
