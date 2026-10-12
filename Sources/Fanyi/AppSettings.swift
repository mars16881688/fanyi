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
        static let target = "targetLanguage"
        static let showAnchor = "showAnchorAfterSelection"
        static let excluded = "excludedBundleIDs"
        static let paused = "selectionPaused"
    }

    private static var store: UserDefaults { UserDefaults.standard }

    static func registerDefaults() {
        store.register(defaults: [
            Key.baseURL: defaultBaseURL,
            Key.model: defaultModel,
            Key.target: TargetLanguage.auto.rawValue,
            Key.showAnchor: true,
            Key.excluded: defaultExcluded,
            Key.paused: false,
        ])
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

    static var targetLanguage: TargetLanguage {
        get { TargetLanguage(rawValue: store.string(forKey: Key.target) ?? "") ?? .auto }
        set { store.set(newValue.rawValue, forKey: Key.target) }
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

    static var excludedBundleIDs: Set<String> {
        let parts = excludedRaw
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return Set(parts)
    }

    static func isExcluded(bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return excludedBundleIDs.contains(id)
    }
}
