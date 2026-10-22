import AppKit

/// Feedback goes to a public GitHub issue the user reviews and submits in the
/// browser (or by e-mail). Suiyi sends nothing itself and attaches only the
/// app/macOS version and language settings — never selected text.
enum FeedbackKind: CaseIterable {
    case bug, idea

    var title: String {
        switch self {
        case .bug: return L("问题", "Bug", "不具合", "버그")
        case .idea: return L("建议", "Suggestion", "要望", "제안")
        }
    }

    /// Fixed tag in the issue title so triage can sort regardless of language.
    var tag: String { self == .bug ? "Bug" : "Idea" }
}

struct FeedbackEnvironment: Equatable {
    let appVersion: String
    let build: String
    let macOS: String
    let interface: String
    let languages: String

    @MainActor
    static var current: FeedbackEnvironment {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let interface: String = switch UILanguage.current {
            case .zh: "zh"; case .en: "en"; case .ja: "ja"; case .ko: "ko"
        }
        return FeedbackEnvironment(
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "?",
            build: info?["CFBundleVersion"] as? String ?? "?",
            macOS: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            interface: interface,
            languages: "\(AppSettings.myLanguage.code) → \(AppSettings.outgoingLanguage.code)")
    }
}

enum FeedbackLink {
    static let repository = "mars16881688/fanyi-site"
    static let email = "mars.yahui@gmail.com"
    /// Keeps the prefilled URL well under browser and GitHub limits.
    static let maxTextLength = 3000

    static func title(kind: FeedbackKind, text: String) -> String {
        let firstLine = text.trimmed.split(separator: "\n").first.map(String.init) ?? ""
        let summary = firstLine.count > 60 ? String(firstLine.prefix(60)) + "…" : firstLine
        return "[\(kind.tag)] \(summary)"
    }

    static func body(kind: FeedbackKind, text: String, environment: FeedbackEnvironment) -> String {
        var description = text.trimmed
        if description.count > maxTextLength { description = String(description.prefix(maxTextLength)) + "…" }
        return """
        ### Type
        \(kind.tag)

        ### Description
        \(description)

        ### Environment
        - Suiyi \(environment.appVersion) (\(environment.build))
        - macOS \(environment.macOS)
        - Interface: \(environment.interface) · Languages: \(environment.languages)
        """
    }

    static func issueURL(kind: FeedbackKind, text: String, environment: FeedbackEnvironment) -> URL? {
        var components = URLComponents(string: "https://github.com/\(repository)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title(kind: kind, text: text)),
            URLQueryItem(name: "body", value: body(kind: kind, text: text, environment: environment)),
            URLQueryItem(name: "labels", value: "feedback"),
        ]
        return components?.url
    }

    static func mailURL(kind: FeedbackKind, text: String, environment: FeedbackEnvironment) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Suiyi feedback: " + title(kind: kind, text: text)),
            URLQueryItem(name: "body", value: body(kind: kind, text: text, environment: environment)),
        ]
        return components.url
    }
}

/// 反馈… window: pick a type, describe it, submit via GitHub or e-mail.
@MainActor
enum FeedbackPrompt {
    static func show() {
        let alert = NSAlert()
        alert.messageText = L("反馈", "Feedback", "フィードバック", "피드백")
        alert.informativeText = L("描述你遇到的问题或建议。提交到 GitHub 后公开可见，请不要填写 API Key、密码或私密内容。",
                                  "Describe the problem or idea. GitHub issues are public — don't include API keys, passwords or private text.",
                                  "不具合や要望を書いてください。GitHub の issue は公開されるため、API キーやパスワード、機密情報は書かないでください。", "문제나 아이디어를 적어 주세요. GitHub 이슈는 공개되므로 API 키, 비밀번호, 개인적인 내용은 적지 마세요.")

        let kinds = NSPopUpButton(frame: NSRect(x: 0, y: 128, width: 160, height: 26), pullsDown: false)
        kinds.addItems(withTitles: FeedbackKind.allCases.map(\.title))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 360, height: 120))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isRichText = false
        text.font = .systemFont(ofSize: 13)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 156))
        container.addSubview(kinds)
        container.addSubview(scroll)
        alert.accessoryView = container
        alert.addButton(withTitle: L("在 GitHub 提交", "Submit on GitHub", "GitHub で送信", "GitHub에 제출"))
        alert.addButton(withTitle: L("发邮件", "Send by Email", "メールで送信", "이메일로 보내기"))
        alert.addButton(withTitle: L("取消", "Cancel", "キャンセル", "취소"))
        alert.window.initialFirstResponder = text

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let content = text.string.trimmed
        guard response != .alertThirdButtonReturn, !content.isEmpty else { return }
        let kind = FeedbackKind.allCases[max(0, kinds.indexOfSelectedItem)]
        let environment = FeedbackEnvironment.current
        let url = response == .alertFirstButtonReturn
            ? FeedbackLink.issueURL(kind: kind, text: content, environment: environment)
            : FeedbackLink.mailURL(kind: kind, text: content, environment: environment)
        if let url { NSWorkspace.shared.open(url) }
    }
}
