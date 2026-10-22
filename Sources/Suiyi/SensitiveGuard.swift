import Foundation

/// 0.2.1.k.01: local, deterministic checks that keep passwords, keys and similar secrets away from
/// the model, the history file and the synthetic ⌘C. Nothing here touches the network; the rules
/// lean strict, since a blocked selection costs one extra key press and a leaked one cannot be undone.
enum SensitiveGuard {
    enum Reason: Hashable {
        case passwordApp      // password manager, or a launcher that hosts password extensions: never read
        case passwordPage     // password-manager extension or web page: never read
        case extensionPage    // any other browser extension page
        case codeApp          // terminals and code editors, unless allowed in Settings
        case sensitiveWindow  // the window title suggests credentials are on screen
        case sensitiveText    // the selection itself looks like a secret

        var canConfirm: Bool { self != .passwordApp && self != .passwordPage }
    }

    // MARK: - Apps, pages and windows (checked before anything is read)

    /// Password managers and credential stores, plus launchers whose panels host password-manager
    /// extensions (lower-cased bundle IDs).
    static let passwordApps: Set<String> = [
        "com.apple.keychainaccess", "com.apple.passwords",
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "org.keepassxc.keepassxc", "com.lastpass.lastpass",
        "in.sinew.enpass-desktop", "me.proton.pass.electron", "com.authy.authy-mac",
        "com.markmcguill.strongbox", "com.markmcguill.strongbox.mac", "com.hicknhacksoftware.macpass",
        "com.keepersecurity.passwordmanager", "com.nordsec.nordpass",
        "com.raycast.macos", "com.runningwithcrayons.alfred", "com.apple.spotlight",
    ]

    static func isPasswordApp(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased(), !id.isEmpty else { return false }
        return passwordApps.contains(id)
    }

    /// Chrome Web Store IDs of password-manager extensions (Bitwarden, 1Password, LastPass, Dashlane,
    /// KeePassXC-Browser, Proton Pass, Keeper).
    private static let passwordExtensionIDs: Set<String> = [
        "nngceckbapebfimnlniiiahkandclblb", "aeblfdkhhhdcdjpifhhbdiojplfjncoa", "hdokiejnpimakedhajhdlcegeplioahd",
        "fdjamakpfbbddfjaooikfcpapjohcfmg", "oboonakemofpalcgghocfoadofidjkkk", "ghmbeldphafepmbegfdlkpapadhbakde",
        "bfogiafebfohielmmehodmfbbebbbpei",
    ]
    /// Chrome's built-in PDF viewer is an extension page too; it stays usable.
    private static let harmlessExtensionIDs: Set<String> = ["mhjfbmdgcfjbbpaeojofohoefgiehjai"]
    private static let extensionSchemes = ["chrome-extension", "moz-extension", "safari-web-extension", "extension"]

    /// Password-manager extensions and web pages, and the browsers' own password pages.
    static func isPasswordPage(_ url: String?) -> Bool {
        guard let raw = url?.trimmed.lowercased(), !raw.isEmpty else { return false }
        let prefixes = ["chrome://password-manager", "chrome://settings/passwords", "chrome://settings/autofill",
                        "edge://wallet", "edge://settings/passwords", "brave://password-manager",
                        "brave://settings/passwords", "opera://settings/passwords", "vivaldi://settings/passwords",
                        "about:logins"]
        if prefixes.contains(where: { raw.hasPrefix($0) }) { return true }
        guard let parsed = URL(string: raw), let host = parsed.host else { return false }
        if parsed.scheme == "chrome-extension" { return passwordExtensionIDs.contains(host) }
        let hosts = ["vault.bitwarden.com", "vault.bitwarden.eu", "passwords.google.com", "passwords.google",
                     "1password.com", "1password.eu", "1password.ca", "lastpass.com", "keepersecurity.com",
                     "keepersecurity.eu", "nordpass.com", "pass.proton.me", "app.dashlane.com"]
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Any other extension page (popups of unknown extensions, Firefox/Safari extensions whose IDs
    /// differ per install): blocked, but the user may confirm.
    static func isExtensionPage(_ url: String?) -> Bool {
        guard let raw = url?.trimmed.lowercased(), let parsed = URL(string: raw),
              let scheme = parsed.scheme, extensionSchemes.contains(scheme) else { return false }
        return !harmlessExtensionIDs.contains(parsed.host ?? "")
    }

    /// `bundleIDs`: the app that owns the window and, if different, the process that has the focus
    /// (a web-content helper or a floating panel); the stricter result wins.
    static func blockReason(bundleIDs: [String?], windowTitle: String?, pageURL: String?, allowCodeApps: Bool) -> Reason? {
        if bundleIDs.contains(where: isPasswordApp) { return .passwordApp }
        if isPasswordPage(pageURL) { return .passwordPage }
        if isExtensionPage(pageURL) { return .extensionPage }
        if !allowCodeApps, bundleIDs.contains(where: { SceneKind.forBundleID($0) == .code }) { return .codeApp }
        // 0.2.1.k.03: on web pages, articles about passwords, tokens or wallets must stay readable,
        // so only a password manager's own title blocks; the page text is still checked per selection.
        let onWebPage = isWebPage(pageURL) || bundleIDs.contains(where: { SceneKind.forBundleID($0) == .browser })
        if onWebPage ? isPasswordManagerTitle(windowTitle) : isSensitiveTitle(windowTitle) { return .sensitiveWindow }
        return nil
    }

    static func isWebPage(_ url: String?) -> Bool {
        guard let scheme = url.flatMap({ URL(string: $0)?.scheme?.lowercased() }) else { return false }
        return scheme == "http" || scheme == "https"
    }

    private static let managerTitle = regex(#"(?i)(?<![a-z])(bitwarden|vaultwarden|1password|keepass(xc)?|lastpass|dashlane|enpass|nordpass|proton pass|strongbox|macpass|google password manager)(?![a-z])|Google 密码管理工具|Google 密碼管理工具|Google パスワード マネージャー"#)

    static func isPasswordManagerTitle(_ title: String?) -> Bool {
        guard let title = title.map(Self.normalized)?.trimmed, !title.isEmpty else { return false }
        return matches(managerTitle, title)
    }

    // Letter lookarounds instead of \b, so "bitwarden_export.csv" or "db_password" still match.
    private static let titleWords = regex(#"(?i)(?<![a-z])(pass(word|wd|code|key|phrase)s?|bitwarden|vaultwarden|1password|keepass(xc)?|kdbx|1pux|1pif|lastpass|dashlane|enpass|nordpass|proton pass|strongbox|macpass|keychain|wallet|credentials?|(api|access|auth|bearer|refresh|personal access)[ _-]?tokens?|api[ _-]?keys?|secret[ _-]?keys?|(client|api)[ _-]?secrets?|secrets? manager|private[ _-]?keys?|recovery[ _-]?(codes?|keys?|phrase)|backup[ _-]?codes?|seed[ _-]?phrase|mnemonic|(two|2)[ -]?(factor|step)|2fa|mfa|authenticator|verification[ _-]?codes?|security[ _-]?codes?|one[ -]?time[ _-]?(code|password|passcode)|otp)(?![a-z])"#)
    private static let titleCJK = ["密码", "密碼", "パスワード", "暗証番号", "钥匙串", "鑰匙圈", "キーチェーン", "凭据",
                                   "認証情報", "私钥", "私鑰", "秘密鍵", "密钥", "密鑰", "令牌", "助记词", "助記詞",
                                   "恢复码", "恢复代码", "备用码", "備用碼", "验证器", "驗證器", "两步验证", "兩步驗證",
                                   "双重验证", "二要素", "二段階認証", "验证码", "驗證碼", "校验码", "动态码", "動態碼",
                                   "登录码", "登入碼", "確認コード", "認証コード", "ワンタイム"]
    private static let standaloneCode = regex(#"(?<![0-9A-Za-z])\d{4,8}(?![0-9A-Za-z])"#)

    static func isSensitiveTitle(_ title: String?) -> Bool {
        guard let title = title.map(Self.normalized)?.trimmed, !title.isEmpty else { return false }
        if titleCJK.contains(where: { title.contains($0) }) { return true }
        return matches(titleWords, title)
    }

    /// The window title is sent with the text; drop it when it carries something secret, or a bare
    /// 4–8 digit number that may be a one-time code ("123456 is your Instagram code").
    static func sanitizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let normalizedTitle = normalized(title)
        if looksSensitive(title) || matches(standaloneCode, normalizedTitle) { return nil }
        return title
    }

    // MARK: - Selected text

    /// Known secret formats, matched anywhere in the selection.
    private static let secretPatterns: [NSRegularExpression] = [
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY( BLOCK)?-----"#,
        #"(?<![A-Za-z0-9])(AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])"#,             // AWS access key ID
        #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}"#,                              // OpenAI / Anthropic / DeepSeek style
        #"(?<![A-Za-z0-9])(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{30,}"#, #"github_pat_[A-Za-z0-9_]{22,}"#,
        #"glpat-[A-Za-z0-9_-]{20,}"#, #"xox[abopsr]-[A-Za-z0-9-]{10,}"#,
        #"AIza[0-9A-Za-z_-]{35}"#, #"(?<![A-Za-z0-9])(sk|rk|pk)_(live|test)_[A-Za-z0-9]{16,}"#,
        #"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36}"#, #"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}"#,
        #"(?<![0-9])\d{8,10}:[A-Za-z0-9_-]{35}(?![A-Za-z0-9_-])"#,             // Telegram bot token
        #"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,       // JWT
        #"(?i)otpauth(-migration)?://"#,
        #"(?i)(hooks\.slack\.com/services/|discord(app)?\.com/api/webhooks/|api\.telegram\.org/bot|hooks\.zapier\.com/hooks/catch/|webhook\.office\.com/)"#,
        #"(?i)(?<![a-z0-9+.-])[a-z][a-z0-9+.-]{0,30}://[^\s/:@]{1,256}:[^\s/@]{1,256}@"#, // URL with user:password@
        #"(?i)[?&#](code|token|access_token|id_token|refresh_token|reset_token|key|apikey|api_key|sig|signature|secret|auth|otp|ticket|session|sid|password|pwd)=[^&#\s]{6,}"#,
        #"(?i)(?<![a-z])bearer\s+[A-Za-z0-9._~+/=-]{16,}"#,
        #"(?i)(?<![a-z])(password|passwd|pwd|passcode|passphrase|pin|secret|client[_-]?secret|api[_-]?key|access[_-]?key|(auth|access|refresh)[_-]?token|token|private[_-]?key)\s*[:=：]\s*\S{4,}"#,
        #"(?<![A-Za-z0-9])(?=[A-Z2-7]*[2-7][A-Z2-7]*[2-7])[A-Z2-7]{16,}(?![A-Za-z0-9])"#, // TOTP secret (base32)
        #"(?<![0-9-])\d{3}-\d{2}-\d{4}(?![0-9-])"#,                             // US SSN
        #"(?<![A-Za-z0-9])[A-Z]{1,2}[0-9]{6}\s?\([0-9A]\)"#,                    // HKID A123456(7)
    ].map { regex($0) }

    /// A password / code / ID keyword followed within a few characters by something that looks like
    /// its value: "password is Hk2026office", "Password\nhunter22", "パスワードはabc12345です".
    private static let secretKeywords = regex(#"(?i)(?<![a-z])(passwords?|passwd|passcode|passphrase|pwd|pw|(?-i:PIN)|pin\s*(code|number)?\s*[:=：]|key\s*[:=：]|(api|access|secret|private|license|product|wi-?fi|encryption|recovery|activation)[ _-]?keys?|tokens?|wi-?fi key|verification code|security code|one[- ]time (code|password|passcode)|otp|auth code|2fa code|(recovery|backup) codes?)(?![a-z])|密码|密碼|口令|パスワード|暗証番号|验证码|驗證碼|校验码|动态码|動態碼|登录码|登入碼|确认码|安全码|恢复码|备用码|認証コード|確認コード|ワンタイムパスワード"#)
    private static let idKeywords = regex(#"(?i)(?<![a-z])(ssn|social security( number)?|passport( no\.?| number)?|hkid|id (no\.?|number)|national id)(?![a-z])|身份证|身分證|身份證|证件号|證件號|护照|護照|マイナンバー|旅券番号|個人番号"#)
    private static let keywordReach = 24
    private static let phoneLike = regex(#"(\+\d{1,3}[ -]?)?\(?\d{2,4}\)?[ -]\d{3,4}([ -]\d{3,4})?"#)

    private static let digitRun = regex(#"\d(?:[ .\-]{0,2}\d){12,}"#)
    private static let chinaID = regex(#"(?<![0-9])[1-9](?:\s?\d){16}\s?[\dXx](?![0-9A-Za-z])"#)
    private static let spacedBase32 = regex(#"(?<![A-Za-z0-9])(?:[A-Za-z2-7]{4} ){3,}[A-Za-z2-7]{4}(?![A-Za-z0-9])"#)
    private static let codeGroups = regex(#"(?i)(?<![a-z0-9])(?:[a-z0-9]{4,5}-[a-z0-9]{4,5}[\s,;]+){2,}[a-z0-9]{4,5}-[a-z0-9]{4,5}(?![a-z0-9])"#)
    private static let asciiRun = regex(#"[!-~]+"#)
    private static let currency = regex(#"^(HK|US|NT|S|A|C|NZ|AU|CA|SG|MOP|RM|R|CN|JP|RMB)?[$€£¥￥][\d,.]+[kKmMbB]?n?$"#)
    private static let domainLike = regex(#"^[A-Za-z0-9-]{1,63}(\.[A-Za-z0-9-]{1,63}){0,8}\.[A-Za-z]{2,}(:\d+)?([/?#]\S*)?$"#)
    private static let urlLike = regex(#"^[A-Za-z][A-Za-z0-9+.-]{0,30}://\S+$"#)
    private static let acronymNumber = regex(#"^[A-Za-z]{2,}-\d{1,4}[a-z]?(-[a-z]+)*$"#)   // COVID-19, GPT-4o-mini
    private static let semver = regex(#"^v?\d+(\.\d+){1,3}([-+][0-9A-Za-z.-]+)?$"#)
    private static let hashtag = regex(#"^#[A-Za-z][A-Za-z0-9_]*$"#)
    /// Public wallet addresses (never keys): 0x + 40 hex, bech32 bc1/tb1. 64-hex strings stay flagged,
    /// since a private key looks like a transaction hash.
    private static let publicAddress = regex(#"^(0x[0-9a-fA-F]{40}|(bc1|tb1)[02-9ac-hj-np-z]{11,71})$"#)
    private static let mention = regex(#"^@[A-Za-z0-9_.]+$"#)
    private static let passphrase = regex(#"^[A-Za-z]{3,}\d?([-_.][A-Za-z]{3,}\d?){2,}$"#)
    private static let tokenChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-.")
    private static let strongSymbols = CharacterSet(charactersIn: "!@#$%^&*+=?~|<>\\")
    /// Stripped from both ends of a word: quotes, brackets and sentence punctuation (not ! ? # $ @).
    private static let edges = CharacterSet(charactersIn: ".,;:()[]{}\"'`“”‘’。，、；：！？（）《》「」『』")

    static func looksSensitive(_ raw: String) -> Bool {
        let text = normalized(raw).trimmed
        guard !text.isEmpty else { return false }
        if secretPatterns.contains(where: { matches($0, text) }) { return true }
        if keywordFollowedByValue(text) { return true }
        if containsCardNumber(text) || containsChinaID(text) || containsSpacedTOTP(text) || containsCodeGroups(text) {
            return true
        }
        if isNumericOnly(text) || containsRecoveryPhrase(text) { return true }

        // CJK sentences have no spaces: judge only the ASCII runs inside them, never the whole line.
        let hasCJK = text.unicodeScalars.contains { !$0.isASCII && CharacterSet.letters.contains($0) }
        let pieces = hasCJK ? allMatches(asciiRun, text) : text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        // Commas, semicolons and pipes separate fields (CSV exports, key=value lists); URLs stay whole.
        let fields = pieces.flatMap { piece -> [String] in
            matches(urlLike, piece) ? [piece] : piece.split(whereSeparator: { ",;|".contains($0) }).map(String.init)
        }
        if !hasCJK, fields.count == 1 { return isSecretWord(fields[0], alone: true) }
        return fields.contains { isSecretWord($0, alone: false) }
    }

    private static func keywordFollowedByValue(_ text: String) -> Bool {
        for range in matchRanges(secretKeywords, text) {
            let after = String(text[range.upperBound...].prefix(keywordReach))
            let phoneNearby = matches(phoneLike, after)
            if allMatches(asciiRun, after).contains(where: { run in
                let t = run.trimmingCharacters(in: edges)
                guard t.count >= 4 else { return false }
                if hasLetter(t), hasDigit(t) || hasStrongSymbol(t) { return !matches(semver, t) }
                if hasInnerUpper(t), t.count >= 6 { return true }
                // A bare 4–8 digit code, but not a year ("2026年", "in 2026") or part of a phone number.
                let isCode = t.count <= 8 && t.allSatisfy { $0.isASCII && $0.isNumber }
                let isYear = t.count == 4 && (t.hasPrefix("19") || t.hasPrefix("20"))
                return isCode && !isYear && !phoneNearby
            }) { return true }
        }
        for range in matchRanges(idKeywords, text) {
            let after = text[range.upperBound...].prefix(keywordReach)
            if after.filter({ $0.isASCII && $0.isNumber }).count >= 6 { return true }
        }
        return false
    }

    /// One word (or CSV field). `alone`: it is the whole selection, so the rules are stricter —
    /// a lone random string is rarely something to translate.
    private static func isSecretWord(_ raw: String, alone: Bool) -> Bool {
        let t = raw.trimmingCharacters(in: edges)
        guard t.count >= 4, t.count <= 512 else { return t.count > 512 && isTokenCharset(t) }
        if isEmail(t) || matches(currency, t) || matches(semver, t) || matches(publicAddress, t) { return false }
        // URLs and paths: judge their parts, so a password hidden in a path is still caught.
        if matches(urlLike, t) || matches(domainLike, t) || t.hasPrefix("/") || t.hasPrefix("~/") || t.hasPrefix("./") {
            return t.split(whereSeparator: { "/?&=#:".contains($0) }).contains { part in
                let p = String(part)
                return p.count >= 6 && hasLetter(p) && hasDigit(p) && hasStrongSymbol(p)
            }
        }
        if t.hasPrefix("="), t.contains("(") { return false }                      // spreadsheet formula
        if !alone, matches(hashtag, t), t.filter(\.isNumber).count <= 2 { return false }  // #Python3
        if !alone, matches(mention, t) { return false }                                   // @kimi123 in a message
        let letters = hasLetter(t), digits = hasDigit(t), strong = hasStrongSymbol(t)
        if letters, digits, strong, t.count >= (alone ? 6 : 8) { return true }              // P@ssw0rd!, Bob$1234
        if alone {
            guard t.count >= 8 else { return false }
            let classes = [hasLower(t), hasUpper(t), digits, strong].filter { $0 }.count
            if classes >= 3, !matches(acronymNumber, t) { return true }
            if letters, digits, !matches(acronymNumber, t) { return true }          // password123, hex keys
            return matches(passphrase, t)                                            // unbroken-cavalry-snowfall
        }
        // In prose: random-looking mixes and long key- or hash-like strings, not product names.
        if t.count >= 10, t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), hasLower(t),
           hasInnerUpper(t), letterDigitSwitches(t) >= 4 { return true }             // Cr7nX9qLp2mWv4k
        return t.count >= 20 && isTokenCharset(t) && letterDigitSwitches(t) >= 4      // a1b2c3d4e5f6a7b8c9d0
    }

    /// PINs, one-time codes, account and phone numbers: digits with separators only, at least 4 digits.
    private static func isNumericOnly(_ t: String) -> Bool {
        let separators = CharacterSet(charactersIn: " -./()+").union(.whitespacesAndNewlines)
        let digits = t.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        return digits >= 4 && t.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) || separators.contains($0) }
    }

    /// 12+ consecutive BIP39 words (numbering, commas and case ignored), or 12–24 single CJK
    /// characters separated by spaces (the Chinese word lists).
    private static func containsRecoveryPhrase(_ text: String) -> Bool {
        var run = 0
        for word in text.lowercased().split(whereSeparator: { !($0.isASCII && $0.isLetter) }) {
            run = BIP39Words.english.contains(String(word)) ? run + 1 : 0
            if run >= 12 { return true }
        }
        let parts = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "，" })
        return (12...24).contains(parts.count) && parts.allSatisfy { part in
            part.count == 1 && part.unicodeScalars.allSatisfy { !$0.isASCII && CharacterSet.letters.contains($0) }
        }
    }

    /// Any run of separated digit groups whose consecutive groups add up to 13–19 digits and pass
    /// Luhn, so trailing expiry dates or a leading number do not hide the card.
    private static func containsCardNumber(_ text: String) -> Bool {
        allMatches(digitRun, text).contains { run in
            let groups = run.split(whereSeparator: { !$0.isNumber }).map { $0.compactMap(\.wholeNumberValue) }
            for start in groups.indices {
                var digits: [Int] = []
                for group in groups[start...] {
                    digits += group
                    if digits.count > 19 { break }
                    if digits.count >= 13, luhn(digits) { return true }
                }
            }
            return false
        }
    }

    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    /// Mainland resident ID number (spaces allowed) with a valid check character.
    private static func containsChinaID(_ text: String) -> Bool {
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checks = Array("10X98765432")
        return allMatches(chinaID, text).contains { match in
            let chars = Array(match.uppercased().filter { !$0.isWhitespace })
            guard chars.count == 18 else { return false }
            let sum = zip(chars.prefix(17), weights).reduce(0) { $0 + ($1.0.wholeNumberValue ?? 0) * $1.1 }
            return chars[17] == checks[sum % 11]
        }
    }

    /// Authenticator setup keys shown in groups of four ("jbsw y3dp ehpk 3pxp").
    private static func containsSpacedTOTP(_ text: String) -> Bool {
        allMatches(spacedBase32, text).contains { group in group.filter { "234567".contains($0) }.count >= 2 }
    }

    /// Recovery / backup codes printed as groups ("5f3a-9c2e 8b1d-4e7f 2a6c-0d9b").
    private static func containsCodeGroups(_ text: String) -> Bool {
        allMatches(codeGroups, text).contains { $0.filter(\.isNumber).count >= 3 }
    }

    // MARK: - Pasteboard

    /// Markers that password managers and well-behaved apps put on secrets they copy.
    static let sensitivePasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword", "com.bitwarden.desktop",
    ]

    static func isSensitivePasteboard(types: [String]) -> Bool {
        types.contains { sensitivePasteboardTypes.contains($0) }
    }

    // MARK: - Confirming a block

    /// "Trigger again to continue": the same reason, app, window title and (for text blocks) the same
    /// selection, between 1 and 10 seconds after the notice, so a double press cannot skip reading it.
    /// Several keys may be armed at once (window first, then text).
    struct ConfirmGate {
        struct Key: Hashable {
            let reason: Reason
            let pid: pid_t
            let title: String?
            let text: String?
        }

        static let minDelay: TimeInterval = 1
        static let window: TimeInterval = 10
        private var armed: [Key: Date] = [:]

        mutating func isConfirmed(_ key: Key, now: Date = Date()) -> Bool {
            armed = armed.filter { now.timeIntervalSince($0.value) <= Self.window }
            guard key.reason.canConfirm, let at = armed[key] else { return false }
            return now.timeIntervalSince(at) >= Self.minDelay
        }

        /// Keeps the first arming time, so pressing again too early does not restart the wait.
        mutating func arm(_ key: Key, now: Date = Date()) {
            guard key.reason.canConfirm, armed[key] == nil else { return }
            armed[key] = now
        }

        mutating func reset() { armed = [:] }
    }

    // MARK: - User-facing notices

    static func notice(for reason: Reason) -> String {
        let again = L("如确需继续，请在 1 秒后、10 秒内再触发一次（同一快捷键或菜单）；这次内容不会记入历史。",
                      "To continue anyway, trigger it again (same shortcut or menu) after 1 and within 10 seconds; it will not be saved to history.",
                      "続行する場合は、1 秒以上たってから 10 秒以内にもう一度実行してください（同じショートカットまたはメニュー）。履歴には残りません。")
        switch reason {
        case .passwordApp:
            return L("这是密码类应用（或可调出密码扩展的启动器），随译不会读取其中的文字。",
                     "This is a password app (or a launcher that can show password extensions); Suiyi never reads text in it.",
                     "パスワード管理アプリ（またはパスワード拡張機能を表示できるランチャー）のため、Suiyi はテキストを読み取りません。")
        case .passwordPage:
            return L("这是密码管理扩展或密码管理页面，随译不会读取其中的文字。", "This is a password-manager extension or page; Suiyi never reads text in it.",
                     "パスワード管理の拡張機能またはページのため、Suiyi はテキストを読み取りません。")
        case .extensionPage:
            return L("这是浏览器扩展页面，没有读取。", "This is a browser extension page; nothing was read. ",
                     "ブラウザ拡張機能のページのため、読み取りませんでした。") + again
        case .codeApp:
            return L("终端和代码编辑器默认不读取（可在 设置 › 安全 中开启）。", "Terminals and code editors are off by default (Settings › Security). ",
                     "ターミナルとコードエディタは既定で読み取りません（設定 › セキュリティ）。") + again
        case .sensitiveWindow:
            return L("当前窗口看起来涉及密码或密钥，没有读取。", "This window looks like it shows passwords or keys; nothing was read. ",
                     "このウィンドウはパスワードやキーを表示しているようなので、読み取りませんでした。") + again
        case .sensitiveText:
            return L("选中的内容看起来像密码、密钥、验证码、卡号或证件号，没有发送。", "The selection looks like a password, key, code, card or ID number; nothing was sent. ",
                     "選択内容がパスワード、キー、認証コード、カード番号または ID 番号のようなので、送信しませんでした。") + again
        }
    }

    // MARK: - Helpers

    /// Full-width digits and letters to ASCII, every kind of space to a plain space.
    static func normalized(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            switch u.value {
            case 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
                out.append(Unicode.Scalar(u.value - 0xFEE0)!)
            case 0x00A0, 0x2000...0x200B, 0x202F, 0x205F, 0x3000:
                out.append(" ")
            default:
                out.append(u)
            }
        }
        return String(out)
    }

    private static func hasLower(_ t: String) -> Bool { t.contains { $0.isASCII && $0.isLowercase } }
    private static func hasUpper(_ t: String) -> Bool { t.contains { $0.isASCII && $0.isUppercase } }
    private static func hasLetter(_ t: String) -> Bool { t.contains { $0.isASCII && $0.isLetter } }
    private static func hasDigit(_ t: String) -> Bool { t.contains { $0.isASCII && $0.isNumber } }
    private static func hasInnerUpper(_ t: String) -> Bool { t.dropFirst().contains { $0.isASCII && $0.isUppercase } }
    private static func hasStrongSymbol(_ t: String) -> Bool { t.unicodeScalars.contains { strongSymbols.contains($0) } }

    /// How often the string switches between a letter and a digit: high for random keys, low for
    /// product names (AirPods4Pro: 2, Cr7nX9qLp2mWv4k: 8).
    private static func letterDigitSwitches(_ t: String) -> Int {
        zip(t, t.dropFirst()).filter { a, b in
            (a.isASCII && a.isLetter && b.isASCII && b.isNumber) || (a.isASCII && a.isNumber && b.isASCII && b.isLetter)
        }.count
    }

    private static func isEmail(_ t: String) -> Bool {
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !parts[1].hasSuffix(".")
            && !t.unicodeScalars.contains(where: { strongSymbols.contains($0) && $0 != "@" && $0 != "+" })
    }

    private static func isTokenCharset(_ t: String) -> Bool {
        t.unicodeScalars.allSatisfy { tokenChars.contains($0) }
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are constants covered by tests; a bad one is a programming error.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func matchRanges(_ regex: NSRegularExpression, _ text: String) -> [Range<String.Index>] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    private static func allMatches(_ regex: NSRegularExpression, _ text: String) -> [String] {
        matchRanges(regex, text).map { String(text[$0]) }
    }
}
