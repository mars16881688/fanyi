import AppKit

/// Manual update check. Runs only when the user picks 检查更新… — Suiyi never
/// contacts anything on its own besides the model API the user configured.
struct ReleaseInfo: Decodable, Equatable {
    let version: String
    let url: String
    let notes: [String: String]?
}

enum UpdateChecker {
    static let feedURL = URL(string: "https://mars16881688.github.io/fanyi-site/latest.json")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Numeric dotted comparison: "0.10.0" > "0.9.3", "1.0" == "1.0.0".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ value: String) -> [Int] {
            value.trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// A Kimi build ("0.2.1.k.12"): the upstream feed can only announce upstream versions, which lack
    /// the k.* changes, so they are reported but never offered for download.
    static func isKimiVersion(_ version: String) -> Bool {
        version.split(separator: ".").contains { $0.lowercased() == "k" }
    }

    /// Only the upstream author's own hosts may be opened.
    static func isTrustedDownload(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host == "mars16881688.github.io"
    }

    static func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    @MainActor
    static func checkInteractively() {
        Task { @MainActor in
            let alert = NSAlert()
            do {
                let latest = try await fetchLatest()
                if isNewer(latest.version, than: currentVersion), isKimiVersion(currentVersion) {
                    alert.messageText = L("上游发布了 \(latest.version)", "Upstream released \(latest.version)",
                                          "上流が \(latest.version) を公開しました")
                    alert.informativeText = L("这是 Mars 的上游版本，不含 Kimi 版的改动（内容收窄、敏感内容过滤、点按钮才读取等）。当前 Kimi 版 \(currentVersion)；Kimi 版的更新请到发布页下载。",
                                              "This is the upstream build; it lacks the Kimi changes (narrower context, sensitive-content guard, read on click). You have Kimi build \(currentVersion); Kimi updates are on the release page.",
                                              "上流（Mars）のビルドで、Kimi 版の変更は含まれません。現在の Kimi 版は \(currentVersion) です。Kimi 版の更新は配布ページから。")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                    return
                }
                if isNewer(latest.version, than: currentVersion), let url = URL(string: latest.url), isTrustedDownload(url) {
                    alert.messageText = L("有新版本 \(latest.version)", "Version \(latest.version) is available",
                                          "新しいバージョン \(latest.version) があります")
                    let note = latest.notes?[noteKey] ?? latest.notes?["en"] ?? ""
                    alert.informativeText = L("当前版本 \(currentVersion)。", "You have \(currentVersion).",
                                              "現在のバージョンは \(currentVersion) です。") + (note.isEmpty ? "" : "\n\n" + note)
                    alert.addButton(withTitle: L("前往下载", "Get Update", "ダウンロード"))
                    alert.addButton(withTitle: L("稍后", "Later", "あとで"))
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                    return
                }
                alert.messageText = L("已是最新版本", "You're up to date", "最新バージョンです")
                alert.informativeText = L("随译 \(currentVersion)", "Suiyi \(currentVersion)", "Suiyi \(currentVersion)")
            } catch {
                alert.alertStyle = .warning
                alert.messageText = L("检查更新失败", "Couldn't check for updates", "アップデートを確認できませんでした")
                alert.informativeText = LLMError.userMessage(for: error)
            }
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private static var noteKey: String {
        switch UILanguage.current {
        case .zh: return "zh"
        case .en: return "en"
        case .ja: return "ja"
        }
    }
}
