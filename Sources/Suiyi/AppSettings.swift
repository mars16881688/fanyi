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
    }

    private static var store: UserDefaults { UserDefaults.standard }

    static func registerDefaults() {
        store.register(defaults: [
            Key.baseURL: defaultBaseURL,
            Key.model: defaultModel,
            Key.showAnchor: true,
            Key.excluded: defaultExcluded,
            Key.paused: false,
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
        }
        let mine = selectable(storedMine) ?? legacy?.0 ?? systemMine
        let fallbackOutgoing: Language = legacy.map { $0.0 == mine ? $0.1 : .english } ?? .english
        var outgoing = selectable(storedOutgoing) ?? fallbackOutgoing
        if outgoing == mine { outgoing = mine == .english ? .chinese : .english }
        return (mine, outgoing)
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
