import Foundation
import NaturalLanguage

/// A language text can be translated from or into, by ISO 639-1 code.
/// Chinese means Simplified Chinese on output; Traditional input is "zh" too.
struct Language: Hashable, Identifiable, Sendable {
    let code: String
    var id: String { code }

    static let chinese = Language(code: "zh")
    static let english = Language(code: "en")
    static let japanese = Language(code: "ja")
    static let korean = Language(code: "ko")

    /// Languages a user can choose as their own or outgoing language.
    static let selectable: [Language] = [.chinese, .english, .japanese, .korean]

    /// Used in prompts.
    var promptName: String {
        switch code {
        case "zh": return "Simplified Chinese (简体中文)"
        case "en": return "English"
        case "ja": return "Japanese (日本語)"
        case "ko": return "Korean (한국어)"
        default: return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }

    /// Short tag for the card header, in the language's own script.
    var shortLabel: String {
        switch code {
        case "zh": return "中文"
        case "en": return "EN"
        case "ja": return "日本語"
        case "ko": return "한국어"
        default: return code.uppercased()
        }
    }

    /// Name in pickers, in the language's own script.
    var nativeName: String {
        switch code {
        case "zh": return "中文"
        case "en": return "English"
        case "ja": return "日本語"
        case "ko": return "한국어"
        default: return Locale(identifier: code).localizedString(forLanguageCode: code) ?? shortLabel
        }
    }

    /// Name in the interface language, e.g. 日文 / Japanese / 日本語.
    var uiName: String {
        switch (code, UILanguage.current) {
        case ("zh", .zh): return "中文"
        case ("en", .zh): return "英文"
        case ("ja", .zh): return "日文"
        case ("ko", .zh): return "韩文"
        case ("zh", .ja): return "中国語"
        case ("en", .ja): return "英語"
        case ("ja", .ja): return "日本語"
        case ("ko", .ja): return "韓国語"
        case ("zh", .ko): return "중국어"
        case ("en", .ko): return "영어"
        case ("ja", .ko): return "일본어"
        case ("ko", .ko): return "한국어"
        case (_, .zh): return Locale(identifier: "zh-Hans").localizedString(forLanguageCode: code) ?? shortLabel
        case (_, .ja): return Locale(identifier: "ja").localizedString(forLanguageCode: code) ?? shortLabel
        case (_, .en): return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? shortLabel
        case (_, .ko): return Locale(identifier: "ko").localizedString(forLanguageCode: code) ?? shortLabel
        }
    }

    init(code: String) {
        self.code = code.lowercased()
    }

    init?(_ nl: NLLanguage) {
        switch nl {
        case .undetermined: return nil
        case .simplifiedChinese, .traditionalChinese: self = .chinese
        default:
            guard let base = nl.rawValue.split(separator: "-").first, !base.isEmpty else { return nil }
            self.init(code: String(base))
        }
    }
}

struct TranslationDirection: Equatable, Sendable {
    /// nil when the source language could not be determined.
    let source: Language?
    let target: Language

    var sourceLabel: String { source?.shortLabel ?? L("自动", "Auto", "自動", "자동") }
}

enum LanguageDetector {
    struct ScriptCounts {
        var han = 0
        var kana = 0
        var hangul = 0
        var latin = 0
    }

    static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF,
             0x3040...0x30FF, 0x31F0...0x31FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }

    static func scriptCounts(_ text: String) -> ScriptCounts {
        var counts = ScriptCounts()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x20000...0x2A6DF:
                counts.han += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF:
                counts.kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF:
                counts.hangul += 1
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F:
                counts.latin += 1
            default:
                break
            }
        }
        return counts
    }

    static func dominantLanguage(_ text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageHints = [
            .english: 0.4, .simplifiedChinese: 0.3, .traditionalChinese: 0.05,
            .japanese: 0.15, .korean: 0.03, .french: 0.02, .german: 0.02, .spanish: 0.03,
        ]
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    /// Kana always means Japanese; Han-heavy text that the recogniser cannot
    /// place is treated as Chinese, Latin text as English.
    static func detect(_ text: String) -> Language? {
        let counts = scriptCounts(text)
        let detected = dominantLanguage(text)
        let unknown = detected == nil || detected == .undetermined

        if counts.kana > 0 || detected == .japanese { return .japanese }
        if detected == .simplifiedChinese || detected == .traditionalChinese { return .chinese }
        if unknown && counts.han > 0 && counts.han * 3 >= counts.latin { return .chinese }
        if detected == .english || (unknown && counts.latin > 0) { return .english }
        if counts.hangul > 0 { return Language(code: "ko") }
        return detected.flatMap(Language.init)
    }

    /// Foreign text goes into the user's language; text already in the
    /// user's language goes into their usual outgoing language.
    static func direction(for text: String, mine: Language, outgoing: Language) -> TranslationDirection {
        let source = detect(text)
        return TranslationDirection(source: source, target: source == mine ? outgoing : mine)
    }

    /// A reply written in the user's language goes back to the sender's
    /// language. Only offered when the original was foreign and identified.
    static func replyDirection(for translation: TranslationDirection, mine: Language) -> TranslationDirection? {
        guard translation.target == mine, let source = translation.source, source != mine else { return nil }
        return TranslationDirection(source: mine, target: source)
    }
}
