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

    /// Reads the current selection of the frontmost app.
    /// - allowClipboard: fall back to a synthetic ⌘C if AX has nothing.
    /// - gesturePoints: for mouse triggers, the mouse-down/up points; when the
    ///   focused element's frame is known and contains neither, the AX
    ///   selection is considered stale and nothing is returned.
    func read(allowClipboard: Bool, gesturePoints: [NSPoint]?) async -> CapturedSelection? {
        guard AXIsProcessTrusted() else { return nil }
        // Some app is collecting a password (or "Secure Keyboard Entry" is on).
        if IsSecureEventInputEnabled() { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
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
            AXUIElementSetMessagingTimeout(element, AX.timeout)
            if AX.isSecure(element) { return nil }
        }

        var text = ""
        var viaAX = false
        if let element = focused,
           let selected = AX.string(element, kAXSelectedTextAttribute),
           !selected.trimmed.isEmpty {
            if let points = gesturePoints, let frame = AX.cocoaFrame(of: element) {
                let hitArea = frame.insetBy(dx: -8, dy: -8)
                if !points.contains(where: { hitArea.contains($0) }) {
                    return nil   // selection lives elsewhere; this gesture was not a text selection
                }
            }
            text = selected
            viaAX = true
        } else if allowClipboard {
            guard let copied = await Clipboard.copySelection() else { return nil }
            text = copied
        } else {
            return nil
        }

        var cleaned = text.trimmed
        guard !cleaned.isEmpty else { return nil }
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

    private func prime(_ appElement: AXUIElement, pid: pid_t) {
        guard !primedPIDs.contains(pid) else { return }
        primedPIDs.insert(pid)
        // Harmless no-op for non-Electron apps.
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}
