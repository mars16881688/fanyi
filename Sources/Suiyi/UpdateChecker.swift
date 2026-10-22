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

    static func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
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
                if isNewer(latest.version, than: currentVersion), let url = URL(string: latest.url),
                   url.scheme == "https" {
                    alert.messageText = L("有新版本 \(latest.version)", "Version \(latest.version) is available",
                                          "新しいバージョン \(latest.version) があります", "새 버전 \(latest.version)이(가) 있습니다")
                    let note = latest.notes?[noteKey] ?? latest.notes?["en"] ?? ""
                    alert.informativeText = L("当前版本 \(currentVersion)。", "You have \(currentVersion).",
                                              "現在のバージョンは \(currentVersion) です。", "현재 버전은 \(currentVersion)입니다.") + (note.isEmpty ? "" : "\n\n" + note)
                    alert.addButton(withTitle: L("前往下载", "Get Update", "ダウンロード", "다운로드"))
                    alert.addButton(withTitle: L("稍后", "Later", "あとで", "나중에"))
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
                    return
                }
                alert.messageText = L("已是最新版本", "You're up to date", "最新バージョンです", "최신 버전입니다")
                alert.informativeText = L("随译 \(currentVersion)", "Suiyi \(currentVersion)", "Suiyi \(currentVersion)", "Suiyi \(currentVersion)")
            } catch {
                alert.alertStyle = .warning
                alert.messageText = L("检查更新失败", "Couldn't check for updates", "アップデートを確認できませんでした", "업데이트를 확인하지 못했습니다")
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
        case .ko: return "ko"
        }
    }
}
