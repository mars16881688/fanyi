import AppKit

/// Update checks read latest.json from the official site: when the user picks
/// 检查更新…, and — unless turned off in Settings — about once a day. Nothing
/// else is sent; the request carries no user data.
struct ReleaseInfo: Decodable, Equatable {
    let version: String
    /// Release page, opened when the update cannot be installed automatically.
    let url: String
    let notes: [String: String]?
    /// Release asset of this exact version and its SHA-256, for in-place updates.
    let download: String?
    let sha256: String?

    /// Present only when the feed has everything an automatic update needs.
    var installable: (url: URL, sha256: String)? {
        guard let download, let url = URL(string: download), UpdateInstaller.isTrustedDownload(url),
              let sha256, sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { return nil }
        return (url, sha256)
    }

    static func == (lhs: ReleaseInfo, rhs: ReleaseInfo) -> Bool {
        lhs.version == rhs.version && lhs.url == rhs.url && lhs.notes == rhs.notes
            && lhs.download == rhs.download && lhs.sha256 == rhs.sha256
    }
}

@MainActor
enum UpdateChecker {
    nonisolated static let feedURL = URL(string: "https://mars16881688.github.io/fanyi-site/latest.json")!
    nonisolated static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    private static var busy = false
    private static var timer: Timer?

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Numeric dotted comparison: "0.10.0" > "0.9.3", "1.0" == "1.0.0".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
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

    /// Due once a day; a clock that moved backwards also counts as due.
    nonisolated static func isAutoCheckDue(enabled: Bool, last: Date?, now: Date) -> Bool {
        guard enabled else { return false }
        guard let last else { return true }
        return now.timeIntervalSince(last) >= autoCheckInterval || now < last
    }

    nonisolated static func fetchLatest() async throws -> ReleaseInfo {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    /// Starts the daily check: shortly after launch, then every few hours whether a day has passed.
    static func startAutomaticChecks() {
        timer?.invalidate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 60 * 60, repeats: true) { _ in
            Task { @MainActor in checkIfDue() }
        }
    }

    private static func checkIfDue() {
        guard isAutoCheckDue(enabled: AppSettings.autoCheckUpdates, last: AppSettings.lastUpdateCheck, now: Date()) else { return }
        check(interactive: false)
    }

    static func checkInteractively() {
        check(interactive: true)
    }

    /// Interactive checks report every outcome; automatic ones speak up only when a new version exists.
    private static func check(interactive: Bool) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let latest = try await fetchLatest()
                AppSettings.lastUpdateCheck = Date()
                if isNewer(latest.version, than: currentVersion) {
                    await offer(latest)
                } else if interactive {
                    show(L("已是最新版本", "You're up to date", "最新バージョンです", "최신 버전입니다"),
                         L("随译 \(currentVersion)", "Suiyi \(currentVersion)", "Suiyi \(currentVersion)", "Suiyi \(currentVersion)"))
                }
            } catch {
                guard interactive else { return }
                show(L("检查更新失败", "Couldn't check for updates", "アップデートを確認できませんでした", "업데이트를 확인하지 못했습니다"),
                     LLMError.userMessage(for: error), style: .warning)
            }
        }
    }

    private static func offer(_ latest: ReleaseInfo) async {
        let alert = NSAlert()
        alert.messageText = L("有新版本 \(latest.version)", "Version \(latest.version) is available",
                              "新しいバージョン \(latest.version) があります", "새 버전 \(latest.version)이(가) 있습니다")
        let note = latest.notes?[noteKey] ?? latest.notes?["en"] ?? ""
        alert.informativeText = L("当前版本 \(currentVersion)。", "You have \(currentVersion).",
                                  "現在のバージョンは \(currentVersion) です。", "현재 버전은 \(currentVersion)입니다.")
            + (note.isEmpty ? "" : "\n\n" + note)
        let installable = latest.installable
        if installable != nil {
            alert.addButton(withTitle: L("立即更新", "Update Now", "今すぐアップデート", "지금 업데이트"))
        } else {
            alert.addButton(withTitle: L("前往下载", "Get Update", "ダウンロード", "다운로드"))
        }
        alert.addButton(withTitle: L("稍后", "Later", "あとで", "나중에"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let installable else {
            openReleasePage(latest)
            return
        }
        do {
            try await UpdateInstaller.downloadAndInstall(from: installable.url, expectedSHA256: installable.sha256,
                                                         expectedVersion: latest.version)
            UpdateInstaller.relaunch()
            NSApp.terminate(nil)
        } catch {
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = L("自动更新失败", "Couldn't update automatically", "自動アップデートに失敗しました", "자동 업데이트에 실패했습니다")
            failed.informativeText = (error as? UpdateInstaller.Failure)?.errorDescription ?? LLMError.userMessage(for: error)
            failed.addButton(withTitle: L("前往下载", "Get Update", "ダウンロード", "다운로드"))
            failed.addButton(withTitle: L("取消", "Cancel", "キャンセル", "취소"))
            NSApp.activate(ignoringOtherApps: true)
            if failed.runModal() == .alertFirstButtonReturn { openReleasePage(latest) }
        }
    }

    private static func openReleasePage(_ latest: ReleaseInfo) {
        if let url = URL(string: latest.url), url.scheme == "https" { NSWorkspace.shared.open(url) }
    }

    private static func show(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
