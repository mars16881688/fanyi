import AppKit
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
    ]
    private static let chatApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.tencent.xinwechat",
        "com.bytedance.macos.feishu", "com.electron.lark",
        "ru.keepcoder.telegram", "org.telegram.desktop",
        "net.whatsapp.whatsapp", "desktop.whatsapp", "com.hnc.discord",
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
        if codeApps.contains(id) { return .code }
        if chatApps.contains(id) { return .chat }
        if emailApps.contains(id) { return .email }
        if browserApps.contains(id) { return .browser }
        return .document
    }
}

struct AppContext {
    let appName: String
    let bundleID: String
    let windowTitle: String?
    let surrounding: String?
    let scene: SceneKind
}

@MainActor
enum ContextCollector {
    static let surroundingRadius = 400
    private static let maxValueLength = 2_000_000

    static func collect(for selection: CapturedSelection) -> AppContext {
        let appElement = AXUIElementCreateApplication(selection.pid)
        AXUIElementSetMessagingTimeout(appElement, AX.timeout)
        var title: String?
        if let window = AX.element(appElement, kAXFocusedWindowAttribute) {
            AXUIElementSetMessagingTimeout(window, AX.timeout)
            title = AX.string(window, kAXTitleAttribute)
        }
        var surrounding: String?
        if let element = selection.element {
            surrounding = surroundingText(in: element, selected: selection.text, preferRange: selection.viaAX)
        }
        return AppContext(
            appName: selection.appName,
            bundleID: selection.bundleID ?? "",
            windowTitle: title,
            surrounding: surrounding,
            scene: SceneKind.forBundleID(selection.bundleID)
        )
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
}
