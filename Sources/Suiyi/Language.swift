import Foundation
import NaturalLanguage

enum TargetLanguage: String, CaseIterable, Identifiable {
    case auto
    case simplifiedChinese
    case english
    case japanese

    var id: String { rawValue }

    /// Shown in the Settings picker.
    var menuTitle: String {
        switch self {
        case .auto: return "自动（中文 ↔ 英文）"
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }

    /// Used in the prompt.
    var promptName: String {
        switch self {
        case .auto, .simplifiedChinese: return "Simplified Chinese (简体中文)"
        case .english: return "English"
        case .japanese: return "Japanese (日本語)"
        }
    }

    /// Used in the panel header.
    var shortLabel: String {
        switch self {
        case .auto, .simplifiedChinese: return "中文"
        case .english: return "EN"
        case .japanese: return "日本語"
        }
    }
}

struct TranslationDirection {
    let sourceLabel: String
    let target: TargetLanguage
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
            .japanese: 0.1, .korean: 0.05, .french: 0.03, .german: 0.03, .spanish: 0.04,
        ]
        recognizer.processString(text)
        return recognizer.dominantLanguage
    }

    /// Picks the translation direction. Auto mode: Chinese → English,
    /// everything else → Simplified Chinese. A fixed target that equals the
    /// source language flips to the other side of the zh/en pair.
    static func direction(for text: String, preference: TargetLanguage) -> TranslationDirection {
        let counts = scriptCounts(text)
        let detected = dominantLanguage(text)
        let unknown = detected == nil || detected == .undetermined

        var source: TargetLanguage?
        var label = "自动"
        if counts.kana > 0 || detected == .japanese {
            source = .japanese
            label = "日本語"
        } else if detected == .simplifiedChinese || detected == .traditionalChinese {
            source = .simplifiedChinese
            label = "中文"
        } else if unknown && counts.han > 0 && counts.han * 3 >= counts.latin {
            source = .simplifiedChinese
            label = "中文"
        } else if detected == .english || (unknown && counts.latin > 0) {
            source = .english
            label = "EN"
        } else if detected == .korean || counts.hangul > 0 {
            label = "한국어"
        } else if let lang = detected, lang != .undetermined {
            label = lang.rawValue.uppercased()
        }

        let target: TargetLanguage
        switch preference {
        case .auto:
            target = (source == .simplifiedChinese) ? .english : .simplifiedChinese
        case .simplifiedChinese, .english, .japanese:
            if source == preference {
                target = (preference == .english) ? .simplifiedChinese : .english
            } else {
                target = preference
            }
        }
        return TranslationDirection(sourceLabel: label, target: target)
    }
}
