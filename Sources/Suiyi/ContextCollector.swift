import ApplicationServices

enum SceneKind: String {
    case code
    case chat
    case email
    case browser
    case document

    var promptDescription: String {
        switch self {
        case .code: return "a terminal or code editor (expect commands, logs, code and error messages)"
        case .chat: return "a chat / messaging app (short conversational messages)"
        case .email: return "an e-mail client (correspondence)"
        case .browser: return "a web browser (web page content)"
        case .document: return "a document or general app window"
        }
    }

    private static let codeApps: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "dev.warp.warp-stable",
        "com.microsoft.vscode", "com.todesktop.230313mzl4w4u92", "com.apple.dt.xcode",
        "dev.zed.zed", "com.mitchellh.ghostty",
        // 0.2.1.k.01: more terminals and editors (they are off by default, see SensitiveGuard).
        "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty", "co.zeit.hyper", "org.tabby",
        "com.termius-dmg.mac", "com.microsoft.vscodeinsiders", "com.vscodium", "com.exafunction.windsurf",
        "com.sublimetext.4", "com.sublimetext.3", "com.panic.nova", "com.barebones.bbedit", "dev.zed.zed-preview",
    ]
    /// JetBrains IDEs share one bundle ID prefix.
    private static let codePrefixes = ["com.jetbrains."]
    private static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.tencent.xinwechat",
        "com.bytedance.macos.feishu", "com.electron.lark",
        "ru.keepcoder.telegram", "org.telegram.desktop",
        "net.whatsapp.whatsapp", "desktop.whatsapp", "com.hnc.discord",
        "com.alibaba.dingtalkmac", "com.tencent.weworkmac", "com.microsoft.teams2", "com.apple.mobilesms",
    ]
    private static let emailApps: Set<String> = [
        "com.apple.mail", "com.microsoft.outlook",
        "com.readdle.smartemail-mac", "com.readdle.sparkdesktop",
    ]
    private static let browserApps: Set<String> = [
        "com.apple.safari", "com.google.chrome", "company.thebrowser.browser",
        "com.microsoft.edgemac", "com.brave.browser", "org.mozilla.firefox",
    ]

    static func forBundleID(_ bundleID: String?) -> SceneKind {
        guard let id = bundleID?.lowercased() else { return .document }
        if codeApps.contains(id) || codePrefixes.contains(where: { id.hasPrefix($0) }) { return .code }
        if chatApps.contains(id) { return .chat }
        if emailApps.contains(id) { return .email }
        if browserApps.contains(id) { return .browser }
        return .document
    }
}

/// Where the selection came from. `appName`, `windowTitle` and the scene description are sent to the
/// model with the selected text (0.2.1.k); the bundle ID stays local (history, Replace strategy).
struct AppContext {
    let appName: String
    let bundleID: String
    let windowTitle: String?
    let scene: SceneKind
    /// Text around the selection (up to `ContextCollector.surroundingRadius` characters each side),
    /// sent as background so the model can pick the right meaning. Dropped when it looks sensitive.
    var surrounding: String? = nil
}

@MainActor
enum ContextCollector {
    static let surroundingRadius = 400
    private static let maxValueLength = 2_000_000

    /// `windowTitle` is read before the selection (see `windowTitle(pid:)`) so a sensitive window
    /// is rejected without reading anything else. Runs only after the guards approved the selection.
    /// A title that itself looks like a secret (e.g. a mail subject carrying a one-time code) is dropped,
    /// and so is nearby text that looks sensitive.
    static func collect(for selection: CapturedSelection, windowTitle: String?) -> AppContext {
        var surrounding: String?
        if let element = selection.element {
            surrounding = surroundingText(in: element, selected: selection.text, preferRange: selection.viaAX)
        }
        return AppContext(
            appName: selection.appName,
            bundleID: selection.bundleID ?? "",
            windowTitle: SensitiveGuard.sanitizedTitle(windowTitle),
            scene: SceneKind.forBundleID(selection.bundleID),
            surrounding: sanitizedSurrounding(surrounding)
        )
    }

    /// Nearby text is background only, so anything that looks like a secret drops all of it.
    nonisolated static func sanitizedSurrounding(_ text: String?) -> String? {
        guard let text = text?.trimmed, !text.isEmpty, !SensitiveGuard.looksSensitive(text) else { return nil }
        return text
    }

    private static func surroundingText(in element: AXUIElement, selected: String, preferRange: Bool) -> String? {
        guard let value = AX.string(element, kAXValueAttribute) else { return nil }
        let ns = value as NSString
        guard ns.length > 0, ns.length <= maxValueLength else { return nil }

        var selection = NSRange(location: NSNotFound, length: 0)
        if preferRange, let range = AX.range(element, kAXSelectedTextRangeAttribute),
           range.location >= 0, range.length > 0, range.location + range.length <= ns.length {
            selection = NSRange(location: range.location, length: range.length)
        }
        if selection.location == NSNotFound {
            let found = ns.range(of: selected)
            guard found.location != NSNotFound else { return nil }
            selection = found
        }

        let start = max(0, selection.location - surroundingRadius)
        let end = min(ns.length, NSMaxRange(selection) + surroundingRadius)
        guard end > start else { return nil }
        let window = ns.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let snippet = ns.substring(with: window).trimmed
        if snippet.isEmpty || snippet == selected.trimmed { return nil }
        return snippet
    }

    /// URL of the page around `element`: AXURL of the nearest AXWebArea ancestor (never of a link,
    /// whose AXURL is its target). Used only for the local password-page check; never sent anywhere.
    /// Short per-call timeouts and a 0.3 s budget keep a hung app from stalling the main thread.
    static func pageURL(of element: AXUIElement) -> String? {
        let deadline = Date().addingTimeInterval(0.3)
        var current: AXUIElement? = element
        for _ in 0..<16 {
            guard let node = current, Date() < deadline else { return nil }
            AXUIElementSetMessagingTimeout(node, 0.1)
            switch AX.string(node, kAXRoleAttribute) {
            case "AXWebArea":
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node, "AXURL" as CFString, &value) == .success, let value else { return nil }
                if CFGetTypeID(value) == CFURLGetTypeID() {
                    return (unsafeBitCast(value, to: CFURL.self) as URL).absoluteString
                }
                return value as? String
            case "AXWindow", "AXApplication":
                return nil
            default:
                current = AX.element(node, kAXParentAttribute)
            }
        }
        return nil
    }

    /// The focused window's title only.
    static func windowTitle(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, AX.timeout)
        guard let window = AX.element(appElement, kAXFocusedWindowAttribute) else { return nil }
        AXUIElementSetMessagingTimeout(window, AX.timeout)
        return AX.string(window, kAXTitleAttribute)
    }
}
