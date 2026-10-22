import Foundation
import Testing
@testable import Suiyi

/// Key-like samples are split with + so secret scanners do not mistake the tests for leaks.
private let keyLikeSamples: [String] = [
    "sk-" + "proj-abcdefghijklmnopqrstuvwxyz123456",
    "My key is sk-" + "ant-api03-AbCdEfGhIjKlMnOpQrSt please keep it",
    "gh" + "p_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789",
    "AKIA" + "IOSFODNN7EXAMPLE",
    "eyJhbGciOiJIUzI1NiJ9" + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
    "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH " + "PRIVATE KEY-----",
    "otp" + "auth://totp/Example:kimi?secret=JBSWY3DPEHPK3PXP",
    "postgres://admin:" + "s3cret@db.example.com/app",
    "Authorization: Bearer " + "abcdefghijklmnop1234567890",
    "https://discord.com/api/" + "webhooks/123456789012345678/AbCdEfGhIjKlMnOpQrStUvWxYz0123456789",
    "1234567890:" + "AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsawE",
]

@Suite("SensitiveGuard")
struct SensitiveGuardTests {
    @Test("Key formats are recognised", arguments: keyLikeSamples)
    func flagsKeyFormats(text: String) {
        #expect(SensitiveGuard.looksSensitive(text))
    }

    @Test("Secrets are recognised", arguments: [
        // Key and token formats
        "db_password=Xyz12345",
        // Password next to its keyword
        "password: hunter22", "Password=Tr0ub4dor", "PIN: 1234", "pw: hunter22", "Password\nhunter22",
        "My new Apple ID password is hokmu6-xewjys-Pihvat", "the wifi password is Hk2026office",
        "密码：abc12345", "我的密码是abc12345", "密碼係 abc12345", "密码就是 abc12345",
        "パスワード: abcd1234", "パスワードはabc12345です", "新的口令Xk9#mQ2$vL7p请保存",
        // One-time codes
        "验证码 482913", "Your verification code is 482913", "【招商银行】验证码482913", "認証コード 482913",
        // Password-like strings alone or in prose
        "P@ssw0rd!", "Xk9#mQ2$vL7p", "aB3dE5fG7hJ9kL1m", "password123", "unbroken-cavalry-snowfall",
        "3f786850e387550fdab836ed7e6dc881de23001b", "Use P@ssw0rd!23 to log in", "use Cr7nX9qLp2mWv4k to log in",
        // Password-manager exports and authenticator keys
        "login,,GitHub,,,0,https://github.com,kimi@x.com,Tr0ub4dor&3,JBSWY3DPEHPK3PXP",
        "jbsw y3dp ehpk 3pxp kn5g yz2e", "JBSWY3DPEHPK3PXP",
        // Card and ID numbers in their many spellings
        "4111 1111 1111 1111", "Card 4111-1111-1111-1111 exp 12/29", "4111\u{00A0}1111\u{00A0}1111\u{00A0}1111",
        "4111  1111  1111  1111", "４１１１　１１１１　１１１１　１１１１", "Card: 4111.1111.1111.1111 exp",
        "11010519491231002X", "110105 19491231 002X", "HKID A123456(7)", "SSN 123-45-6789",
        "マイナンバー 1234 5678 9012", "passport number E12345678",
        // PINs and account numbers on their own
        "482913", "+852 9123 4567",
        // Recovery phrases
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "1. abandon 2. abandon 3. abandon 4. abandon 5. abandon 6. abandon 7. abandon 8. abandon 9. abandon 10. abandon 11. abandon 12. about",
        "Abandon, abandon, abandon, abandon, abandon, abandon, abandon, abandon, abandon, abandon, abandon, about",
        "seed: abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
        "的 一 是 在 不 了 有 和 人 这 中 大",
        // Second audit pass: exemption abuse, secrets in URLs, cards next to other digits, more keywords
        "Bob$1234", "@Kimi2026!", "/Xk9#mQ2$vL7p", "example.com/Xk9#mQ2$vL7p", "#Summer2026",
        "https://example.com/reset?code=abc123XYZ789secretvalue",
        "key: Kx7-pQ2_vL9", "the token is a1b2c3d4e5f6a7b8c9d0", "api key a1b2c3d4e5f6a7b8c9d0e1",
        "Card 4111 1111 1111 1111 1227 CVV 123", "no. 1 4111111111111111",
        "Recovery codes: 5f3a-9c2e 8b1d-4e7f 2a6c-0d9b",
    ])
    func flagsSecrets(text: String) {
        #expect(SensitiveGuard.looksSensitive(text))
    }

    @Test("Ordinary text passes", arguments: [
        "Hello, how are you?", "我们周五上线", "We use GPT-4o-mini for this task.",
        "COVID-19 cases rose sharply last year.", "我们用GPT-4o翻译，效果不错。", "版本v2.1发布了",
        "https://example.com/docs/getting-started", "kimi@example.com",
        "Please enter your password to continue.", "Forgot your password?", "Kubernetes", "iPhone 15 Pro",
        "@kimi123 thanks for the update", "The price is $1,299 this year.", "ship it Friday",
        "x86_64-apple-darwin builds are ready", "10:30", "We'll meet in Bangkok on Oct 25. Any preferred time?",
        "密码学是一门很有意思的学科。",
        // False positives reported by the audit
        "The rent is HK$12,800 per month.", "價格為HK$1,299，限時優惠。", "Apple's revenue was US$94.9B.",
        "Hello,", "Thanks!", "Doesn't", "COVID-19", "Self-driving", "~/.ssh/id_ed25519",
        "=VLOOKUP(A2,B:C,2,FALSE)", "example.com/pricing?plan=pro2",
        "can you send the report before monday morning please thanks again buddy",
        "The zip code is 10001.", "this that what when",
        // Second audit pass: dates and phone numbers after keywords, product names, versions, URLs
        "Your password expires on 2026/11/01, please change it.", "密码将于2026年过期，请及时修改。",
        "パスワードは2026年4月から変更が必要です。", "Forgot your password? Call 1-800-123-4567",
        "We sent an OTP to +852 9123 4567", "AirPods4Pro is out", "Qwen2Audio supports speech",
        "The pins on the iPhone15 connector", "Learning #Python3 today", "Release 1.2.3+build45 is live",
        "GPT-4o-mini", "Hello!", "Key features: GPT-4o and more", "x86_64-apple-darwin23 builds",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "HK$12800",
        // Public wallet addresses in crypto articles (0.2.1.k.03)
        "Send it to 0x742d35Cc6634C0532925a3b844Bc454e4438f44e please",
        "bc1qar0srrr7xfkvy5l643lydnw9re59gtzzwf5mdq",
    ])
    func passesOrdinaryText(text: String) {
        #expect(!SensitiveGuard.looksSensitive(text))
    }

    @Test("Card numbers need a valid Luhn checksum")
    func luhn() {
        #expect(SensitiveGuard.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
        #expect(!SensitiveGuard.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]))
    }

    @Test("Window titles that suggest credentials", arguments: [
        ("Google 密码管理工具 - Google Chrome", true), ("Google Password Manager - Google Chrome", true),
        ("Vault | Bitwarden Web vault", true), ("Vaults | Vaultwarden Web", true), ("Personal access tokens (classic)", true),
        ("API Keys - Anthropic Console", true), ("二段階認証の設定", true), ("钥匙串访问", true),
        ("2-Step Verification", true), ("Wallet", true), ("bitwarden_export_20261022.csv", true),
        ("Strongbox - Personal.kdbx", true), ("Your verification code is 482913", true),
        ("Inbox (3) - kimi@example.com - Gmail", false), ("Release notes – Notion", false),
        ("Tokenomics deck", false), ("Settings", false), ("Daily note - Obsidian Vault - Obsidian", false),
        ("记账凭证 - 金蝶", false), ("淘口令分享", false), ("Secret Service", false), ("Pricing per token", false),
        ("Keeper of the Lost Cities", false), ("您的登录码 482913", true),
    ])
    func titles(title: String, sensitive: Bool) {
        #expect(SensitiveGuard.isSensitiveTitle(title) == sensitive)
    }

    @Test("A title that itself carries a secret is not sent")
    func sanitizedTitle() {
        #expect(SensitiveGuard.sanitizedTitle("Key sk-" + "abcdefghijklmnopqrstu - Notes") == nil)
        #expect(SensitiveGuard.sanitizedTitle("Inbox - Gmail") == "Inbox - Gmail")
        #expect(SensitiveGuard.sanitizedTitle(nil) == nil)
        #expect(SensitiveGuard.sanitizedTitle("Your Uber code: 4829") == nil)          // bare one-time code
        #expect(SensitiveGuard.sanitizedTitle("123456 is your Instagram code") == nil)
    }

    @Test("Browser extension and password-manager pages", arguments: [
        ("chrome-extension://nngceckbapebfimnlniiiahkandclblb/popup/index.html", true),
        ("https://vault.bitwarden.com/#/vault", true), ("https://passwords.google.com/", true),
        ("chrome://password-manager/passwords", true), ("https://my.1password.com/", true),
        ("edge://wallet/passwords", true), ("https://example.com/", false), ("https://notbitwarden.com/", false),
        ("about:logins", true), ("chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html", false),
        ("chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html", false),
    ])
    func pages(url: String, sensitive: Bool) {
        #expect(SensitiveGuard.isPasswordPage(url) == sensitive)
    }

    @Test("Other extension pages are blocked but confirmable; Chrome's PDF viewer is not blocked")
    func extensionPages() {
        #expect(SensitiveGuard.isExtensionPage("chrome-extension://abcdefghijklmnopabcdefghijklmnop/popup.html"))
        #expect(SensitiveGuard.isExtensionPage("moz-extension://5f1c0b1e-0000-4000-8000-000000000000/popup.html"))
        #expect(!SensitiveGuard.isExtensionPage("chrome-extension://mhjfbmdgcfjbbpaeojofohoefgiehjai/index.html"))
        #expect(!SensitiveGuard.isExtensionPage("https://example.com/"))
        #expect(SensitiveGuard.Reason.extensionPage.canConfirm)
    }

    @Test("Block reasons in order: password app, password page, code app, window title")
    func blockReasons() {
        func reason(_ id: String?, _ title: String?, _ url: String? = nil, code: Bool = false,
                    focus: String? = nil) -> SensitiveGuard.Reason? {
            SensitiveGuard.blockReason(bundleIDs: [id, focus], windowTitle: title, pageURL: url, allowCodeApps: code)
        }
        #expect(reason("com.bitwarden.desktop", nil, code: true) == .passwordApp)
        #expect(reason("com.apple.Passwords", nil, code: true) == .passwordApp)
        #expect(reason("com.google.Chrome", "New Tab", "chrome-extension://abc/popup.html") == .extensionPage)
        #expect(reason("com.mitchellh.ghostty", "zsh") == .codeApp)
        #expect(reason("com.mitchellh.ghostty", "zsh", code: true) == nil)
        #expect(reason("com.jetbrains.intellij", "Main.kt") == .codeApp)
        #expect(reason("net.kovidgoyal.kitty", "kitty") == .codeApp)
        #expect(reason("com.google.Chrome", "Google Password Manager") == .sensitiveWindow)
        // 0.2.1.k.03: articles stay readable on web pages; native windows keep the full title rule.
        let article = "https://example.com/article"
        #expect(reason("com.google.Chrome", "How to secure your crypto wallet with 2FA", article) == nil)
        #expect(reason("com.apple.Safari", "Best password managers of 2026", article) == nil)
        #expect(reason("com.google.Chrome", "API tokens explained", article) == nil)
        #expect(reason("com.google.Chrome", "Vault | Bitwarden Web vault", "https://selfhosted.example/#/vault") == .sensitiveWindow)
        #expect(reason("com.apple.Notes", "Wallet recovery phrase") == .sensitiveWindow)
        #expect(reason("com.google.Chrome", "Inbox - Gmail", "https://mail.google.com/") == nil)
        #expect(reason(nil, nil) == nil)
        #expect(reason("com.google.Chrome", "New Tab", "chrome-extension://abcdefghijklmnopabcdefghijklmnop/p.html") == .extensionPage)
        #expect(reason("com.google.Chrome", "New Tab", "chrome-extension://nngceckbapebfimnlniiiahkandclblb/popup.html") == .passwordPage)
        #expect(reason("com.apple.Safari", "Apple", focus: "com.apple.WebKit.WebContent") == nil)
        #expect(reason("com.apple.Safari", "Apple", focus: "com.raycast.macos") == .passwordApp)   // launcher panel
    }

    @Test("Confirming a block: same key, 1–10 s later; never for password apps or pages")
    func confirmGate() {
        typealias Key = SensitiveGuard.ConfirmGate.Key
        let t0 = Date()
        let key = Key(reason: .sensitiveText, pid: 42, title: "Chat", text: "P@ssw0rd!")
        var gate = SensitiveGuard.ConfirmGate()
        func confirmed(_ k: Key, after seconds: TimeInterval) -> Bool {
            gate.isConfirmed(k, now: t0.addingTimeInterval(seconds))
        }
        #expect(!confirmed(key, after: 0))
        gate.arm(key, now: t0)
        #expect(!confirmed(key, after: 0.3))                 // a quick double press does not confirm
        gate.arm(key, now: t0.addingTimeInterval(0.3))       // and does not restart the wait
        #expect(confirmed(key, after: 1.2))
        #expect(!confirmed(Key(reason: .sensitiveText, pid: 42, title: "Chat", text: "other"), after: 1.2))
        #expect(!confirmed(Key(reason: .sensitiveText, pid: 42, title: "Other tab", text: "P@ssw0rd!"), after: 1.2))
        #expect(!confirmed(Key(reason: .sensitiveText, pid: 7, title: "Chat", text: "P@ssw0rd!"), after: 1.2))
        #expect(!confirmed(key, after: 11))                  // expired

        for reason in [SensitiveGuard.Reason.passwordApp, .passwordPage] {
            let blocked = Key(reason: reason, pid: 1, title: nil, text: nil)
            gate.arm(blocked, now: t0)
            #expect(!confirmed(blocked, after: 2))
        }

        gate.arm(key, now: t0)
        gate.reset()
        #expect(!confirmed(key, after: 2))
    }

    @Test("Pasteboard copies marked concealed or transient are refused")
    func pasteboard() {
        #expect(SensitiveGuard.isSensitivePasteboard(types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        #expect(SensitiveGuard.isSensitivePasteboard(types: ["org.nspasteboard.TransientType"]))
        #expect(!SensitiveGuard.isSensitivePasteboard(types: ["public.utf8-plain-text", "public.html"]))
    }

    @Test("Only the password-app and password-page notices have no way to continue")
    func notices() {
        for reason in [SensitiveGuard.Reason.passwordApp, .passwordPage] {
            #expect(!SensitiveGuard.notice(for: reason).contains("10"))
        }
        for reason in [SensitiveGuard.Reason.extensionPage, .codeApp, .sensitiveWindow, .sensitiveText] {
            #expect(SensitiveGuard.notice(for: reason).contains("10"))
        }
    }

    @Test("Defaults: code apps off; mouse ⌘C on again (0.2.1.k.02) for apps like WeChat and Telegram")
    func defaults() {
        #expect(!AppSettings.allowInCodeApps)
        #expect(AppSettings.mouseClipboardFallback)
    }
}
