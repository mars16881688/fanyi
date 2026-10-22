import Foundation

/// Interface language. Follows the system's preferred languages: Chinese,
/// Japanese and Korean get their own strings, everything else falls back to English.
enum UILanguage: Sendable {
    case zh, en, ja, ko

    /// Set by tests to render a specific language.
    nonisolated(unsafe) static var override: UILanguage?

    static var current: UILanguage { override ?? resolved }

    private static let resolved = resolve(Locale.preferredLanguages)

    static func resolve(_ preferred: [String]) -> UILanguage {
        for identifier in preferred {
            let code = identifier.lowercased()
            if code.hasPrefix("zh") { return .zh }
            if code.hasPrefix("ja") { return .ja }
            if code.hasPrefix("ko") { return .ko }
            if code.hasPrefix("en") { return .en }
        }
        return .en
    }
}

/// Picks the interface string. Arguments are always Chinese, English, Japanese, Korean.
func L(_ zh: String, _ en: String, _ ja: String, _ ko: String) -> String {
    switch UILanguage.current {
    case .zh: return zh
    case .en: return en
    case .ja: return ja
    case .ko: return ko
    }
}
