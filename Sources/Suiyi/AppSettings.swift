import Foundation

/// Non-secret preferences, stored in UserDefaults. The API key lives in the
/// Keychain (see Keychain.swift).
enum AppSettings {
    static let defaultBaseURL = "https://api.deepseek.com/v1"
    static let defaultModel = "deepseek-chat"
    static let defaultExcluded = "com.apple.keychainaccess,com.1password.1password,com.agilebits.onepassword7"

    private enum Key {
        static let baseURL = "baseURL"
        static let model = "model"
        static let legacyTarget = "targetLanguage"
        static let myLanguage = "myLanguage"
        static let outgoingLanguage = "outgoingLanguage"
        static let showAnchor = "showAnchorAfterSelection"
        static let excluded = "excludedBundleIDs"
        static let paused = "selectionPaused"
        static let translationStyle = "translationStyle"
        static let allowInCodeApps = "allowInCodeApps"
        static let mouseClipboardFallback = "mouseClipboardFallback"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
    }

    private static var store: UserDefaults { UserDefaults.standard }

    static func registerDefaults() {
        store.register(defaults: [
            Key.baseURL: defaultBaseURL,
            Key.model: defaultModel,
            Key.showAnchor: true,
            Key.excluded: defaultExcluded,
            Key.paused: false,
            Key.translationStyle: TranslationStyle.colloquial.rawValue,
            Key.allowInCodeApps: false,
            Key.mouseClipboardFallback: true,
            Key.autoCheckUpdates: true,
            "historyEnabled": false,
            "useMyStyle": false,
        ])
    }

    static var historyEnabled: Bool {
        get { store.object(forKey: "historyEnabled") as? Bool ?? false }
        set { store.set(newValue, forKey: "historyEnabled") }
    }

    static var useMyStyle: Bool {
        get { store.object(forKey: "useMyStyle") as? Bool ?? false }
        set { store.set(newValue, forKey: "useMyStyle") }
    }

    /// 0.2.1.k.01: terminals and code editors often show keys and tokens, so they are off by default.
    static var allowInCodeApps: Bool {
        get { store.object(forKey: Key.allowInCodeApps) as? Bool ?? false }
        set { store.set(newValue, forKey: Key.allowInCodeApps) }
    }

    /// Whether a mouse selection may fall back to a synthetic ⌘C (WeChat, Telegram and other apps
    /// that do not expose the selection). 0.2.1.k.02: on by default again; the app, page and window
    /// checks still run before any ⌘C, and the content check before the button appears.
    static var mouseClipboardFallback: Bool {
        get { store.object(forKey: Key.mouseClipboardFallback) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.mouseClipboardFallback) }
    }

    /// 0.2.1.k.01 shipped with the fallback off and may have saved that; turn it back on once.
    static func applyK02Defaults() {
        let marker = "k02.mouseClipboardFallbackRestored"
        guard !store.bool(forKey: marker) else { return }
        store.set(true, forKey: Key.mouseClipboardFallback)
        store.set(true, forKey: marker)
    }

    /// Reads latest.json from the official site about once a day; no user data is sent.
    static var autoCheckUpdates: Bool {
        get { store.object(forKey: Key.autoCheckUpdates) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.autoCheckUpdates) }
    }

    static var lastUpdateCheck: Date? {
        get { store.object(forKey: Key.lastUpdateCheck) as? Date }
        set { store.set(newValue, forKey: Key.lastUpdateCheck) }
    }

    static var baseURL: String {
        get {
            let value = store.string(forKey: Key.baseURL)?.trimmed ?? ""
            return value.isEmpty ? defaultBaseURL : value
        }
        set { store.set(newValue.trimmed, forKey: Key.baseURL) }
    }

    static var model: String {
        get {
            let value = store.string(forKey: Key.model)?.trimmed ?? ""
            return value.isEmpty ? defaultModel : value
        }
        set { store.set(newValue.trimmed, forKey: Key.model) }
    }

    /// The language the user reads and writes in.
    static var myLanguage: Language {
        get { resolvedLanguages().mine }
        set { store.set(newValue.code, forKey: Key.myLanguage) }
    }

    /// Where text already in the user's language is translated to.
    static var outgoingLanguage: Language {
        get { resolvedLanguages().outgoing }
        set { store.set(newValue.code, forKey: Key.outgoingLanguage) }
    }

    private static func resolvedLanguages() -> (mine: Language, outgoing: Language) {
        languages(mine: store.string(forKey: Key.myLanguage),
                  outgoing: store.string(forKey: Key.outgoingLanguage),
                  legacyTarget: store.string(forKey: Key.legacyTarget),
                  preferred: Locale.preferredLanguages)
    }

    /// Stored choice first; otherwise derived from the pre-trilingual
    /// "targetLanguage" setting; otherwise from the system language.
    /// The outgoing language never equals the user's own language.
    static func languages(mine storedMine: String?, outgoing storedOutgoing: String?,
                          legacyTarget: String?, preferred: [String]) -> (mine: Language, outgoing: Language) {
        func selectable(_ code: String?) -> Language? {
            Language.selectable.first { $0.code == code }
        }
        let legacy: (Language, Language)? = switch legacyTarget {
        case "auto", "simplifiedChinese": (.chinese, .english)
        case "english": (.english, .chinese)
        case "japanese": (.japanese, .english)
        default: nil
        }
        let systemMine: Language = switch UILanguage.resolve(preferred) {
        case .zh: .chinese
        case .ja: .japanese
        case .en: .english
        case .ko: .korean
        }
        let mine = selectable(storedMine) ?? legacy?.0 ?? systemMine
        let fallbackOutgoing: Language = legacy.map { $0.0 == mine ? $0.1 : .english } ?? .english
        var outgoing = selectable(storedOutgoing) ?? fallbackOutgoing
        if outgoing == mine { outgoing = mine == .english ? .chinese : .english }
        return (mine, outgoing)
    }

    static var translationStyle: TranslationStyle {
        get { TranslationStyle(rawValue: store.string(forKey: Key.translationStyle) ?? "") ?? .colloquial }
        set { store.set(newValue.rawValue, forKey: Key.translationStyle) }
    }

    static var showAnchor: Bool {
        get { store.bool(forKey: Key.showAnchor) }
        set { store.set(newValue, forKey: Key.showAnchor) }
    }

    static var paused: Bool {
        get { store.bool(forKey: Key.paused) }
        set { store.set(newValue, forKey: Key.paused) }
    }

    static var excludedRaw: String {
        get { store.string(forKey: Key.excluded) ?? defaultExcluded }
        set { store.set(newValue, forKey: Key.excluded) }
    }

    static var excludedBundleIDs: Set<String> { parseExcluded(excludedRaw) }

    /// Comma (half- or full-width), newline or whitespace separated, case-insensitive.
    static func parseExcluded(_ raw: String) -> Set<String> {
        let parts = raw
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace })
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
        return Set(parts)
    }

    static func isExcluded(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return excludedBundleIDs.contains(id)
    }
}

/// How translations lean: everyday speech or business correspondence. Rewrite is unaffected.
enum TranslationStyle: String, CaseIterable, Identifiable, Sendable {
    case colloquial
    case business

    var id: String { rawValue }

    var label: String {
        switch self {
        case .colloquial: return L("口语倾向", "Conversational", "口語寄り", "대화체")
        case .business: return L("商务倾向", "Business", "ビジネス寄り", "비즈니스")
        }
    }

    var promptRule: String {
        switch self {
        case .colloquial:
            return "- Style: lean conversational. Use natural, everyday wording that a native speaker would actually say; avoid stiff, literal or overly formal phrasing."
        case .business:
            return "- Style: lean business. Use clear, polite, professional wording suited to work e-mail and business communication; avoid slang and overly casual phrasing."
        }
    }
}
