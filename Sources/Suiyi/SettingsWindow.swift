import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var apiKey = ""
    @Published var baseURL = ""
    @Published var model = ""
    @Published var myLanguage: Language = .chinese
    @Published var outgoingLanguage: Language = .english
    @Published var saved = false
    @Published var showAnchor = true
    @Published var launchAtLogin = false
    @Published var excluded = ""
    @Published var status = ""
    @Published var testResult = ""
    @Published var testing = false
    @Published var historyEnabled = false
    @Published var useMyStyle = false
    @Published var historyCount = 0
    @Published var styleSources = ""
    @Published var integrationStatus = ""
    @Published var localStatus = ""
    @Published var confirmClear = false

    private var testTask: Task<Void, Never>?

    init() {}

    func load() {
        apiKey = Keychain.apiKey() ?? ""
        baseURL = AppSettings.baseURL
        model = AppSettings.model
        myLanguage = AppSettings.myLanguage
        outgoingLanguage = AppSettings.outgoingLanguage
        showAnchor = AppSettings.showAnchor
        excluded = AppSettings.excludedRaw
        launchAtLogin = SMAppService.mainApp.status == .enabled
        status = ""
        saved = false
        testResult = ""
        historyEnabled = AppSettings.historyEnabled
        useMyStyle = AppSettings.useMyStyle
        refreshLocal()
    }

    static var historyExplanation: String {
        L("默认关闭。开启后只保存在本机 ~/.suiyi/，不会上传；只有点「更新我的画像」或自动更新画像时，会把最近的记录发送到你自己配置的模型接口。",
          "Off by default. When on, history stays on this Mac in ~/.suiyi/ and is never uploaded. Recent entries are sent to your own model API only when the profile is updated (manually or automatically).",
          "既定ではオフ。オンにすると履歴はこの Mac の ~/.suiyi/ にだけ保存され、アップロードされません。プロファイル更新時（手動または自動）にのみ、最近の記録を自分で設定したモデル API に送信します。")
    }

    func setHistoryEnabled(_ enabled: Bool) {
        guard enabled, !UserDefaults.standard.bool(forKey: "historyConsentShown") else {
            historyEnabled = enabled
            return
        }
        let alert = NSAlert()
        alert.messageText = L("开启记录历史？", "Turn on history?", "履歴を記録しますか？")
        alert.informativeText = Self.historyExplanation + L(" 开启后每新增 30 条记录会自动更新画像。设置需点「保存」生效。", " The profile updates automatically every 30 new entries. Click Save to apply.", " 30 件ごとにプロファイルが自動更新されます。「保存」で反映されます。")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("开启", "Turn On", "オンにする"))
        alert.addButton(withTitle: L("取消", "Cancel", "キャンセル"))
        let response = alert.runModal()
        historyEnabled = response == .alertFirstButtonReturn
        if historyEnabled { UserDefaults.standard.set(true, forKey: "historyConsentShown") }
    }

    func save() {
        var problems: [String] = []

        let keyStatus = Keychain.setAPIKey(apiKey)
        if keyStatus != errSecSuccess {
            problems.append(L("API Key 保存到钥匙串失败", "Could not save the API key to the Keychain", "API キーをキーチェーンに保存できませんでした") + "（OSStatus \(keyStatus)）")
        }
        AppSettings.baseURL = baseURL
        AppSettings.model = model
        AppSettings.myLanguage = myLanguage
        AppSettings.outgoingLanguage = outgoingLanguage
        AppSettings.showAnchor = showAnchor
        AppSettings.historyEnabled = historyEnabled
        AppSettings.useMyStyle = useMyStyle
        AppSettings.excludedRaw = excluded.trimmed

        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            problems.append(L("开机启动设置失败：", "Could not change Launch at Login: ", "ログイン時に起動の設定に失敗しました：") + error.localizedDescription)
        }
        if launchAtLogin && service.status == .requiresApproval {
            problems.append(L("请在 系统设置 › 通用 › 登录项 中允许随译", "Allow Suiyi in System Settings › General › Login Items", "システム設定 › 一般 › ログイン項目 で Suiyi を許可してください"))
        }
        launchAtLogin = service.status == .enabled || service.status == .requiresApproval

        baseURL = AppSettings.baseURL
        model = AppSettings.model
        myLanguage = AppSettings.myLanguage
        outgoingLanguage = AppSettings.outgoingLanguage
        saved = problems.isEmpty
        status = saved ? L("已保存", "Saved", "保存しました") : problems.joined(separator: "\n")
    }

    func refreshLocal() {
        historyCount = HistoryStore.shared.count
        let sources = StyleContext.build().sources
        styleSources = sources.isEmpty ? L("未找到任何资料", "Nothing found", "見つかりませんでした")
            : L("已找到：", "Found: ", "見つかったもの：") + sources.joined(separator: L("、", ", ", "、"))
        let installed = AgentIntegration.status()
        let on = L("已接入", "connected", "接続済み"), off = L("未接入", "not connected", "未接続")
        integrationStatus = "Codex: \(installed[0] ? on : off) · Claude Code: \(installed[1] ? on : off)"
    }

    func openFolder() {
        do {
            try HistoryStore.shared.ensureFolder()
            NSWorkspace.shared.open(HistoryStore.shared.folderURL)
        } catch { localStatus = error.localizedDescription }
    }

    func clearHistory() {
        do {
            try HistoryStore.shared.clear()
            localStatus = L("历史已清空（画像保留）。", "History cleared (profile kept).", "履歴を消去しました（プロファイルは保持）。")
        } catch { localStatus = L("清空失败：", "Could not clear: ", "消去に失敗しました：") + error.localizedDescription }
        refreshLocal()
    }

    func integrate(remove: Bool) {
        do {
            if remove { try AgentIntegration.remove() } else { try AgentIntegration.install() }
            localStatus = remove ? L("已移除接入。", "Disconnected.", "接続を解除しました。") : L("已接入。", "Connected.", "接続しました。")
        } catch { localStatus = L("操作失败：", "Failed: ", "失敗しました：") + error.localizedDescription }
        refreshLocal()
    }

    func testConnection() {
        testTask?.cancel()
        testing = true
        testResult = L("正在测试…", "Testing…", "テスト中…")
        let base = baseURL.trimmed.isEmpty ? AppSettings.defaultBaseURL : baseURL.trimmed
        let modelName = model.trimmed.isEmpty ? AppSettings.defaultModel : model.trimmed
        let config = LLMConfig(baseURL: base, apiKey: apiKey.trimmed, model: modelName)
        testTask = Task { @MainActor [weak self] in
            let message: String
            do {
                let reply = try await LLMClient.ping(config: config)
                message = "✅ " + L("连接成功（回复：", "Connected (reply: ", "接続に成功しました（応答：") + String(reply.prefix(30)) + L("）", ")", "）")
            } catch is CancellationError {
                return
            } catch {
                message = "❌ \(LLMError.userMessage(for: error))"
            }
            guard let self else { return }
            self.testResult = message
            self.testing = false
        }
    }
}

@MainActor
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject private var profile = ProfileBuilder.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: SuiyiStyle.symbol("character.bubble", description: L("随译", "Suiyi", "Suiyi"), size: 24) ?? NSImage())
                    .foregroundColor(Color(nsColor: .controlAccentColor))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("随译设置", "Suiyi Settings", "Suiyi 設定")).font(.title3.weight(.semibold))
                    Text(L("中英日互译 · 改写 · 回复", "Translate between Chinese, English and Japanese · Rewrite · Reply", "日中英の相互翻訳 · 書き換え · 返信")).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Form {
                Section(L("模型服务（OpenAI 兼容）", "Model service (OpenAI-compatible)", "モデルサービス（OpenAI 互換）")) {
                    SecureField("API Key", text: $model.apiKey, prompt: Text("sk-…"))
                    TextField("Base URL", text: $model.baseURL, prompt: Text(AppSettings.defaultBaseURL))
                    TextField(L("模型", "Model", "モデル"), text: $model.model, prompt: Text(AppSettings.defaultModel))
                    HStack(spacing: 8) {
                        Button { model.testConnection() } label: {
                            HStack(spacing: 5) {
                                Image(nsImage: SuiyiStyle.symbol("network", description: L("测试连接", "Test Connection", "接続テスト")) ?? NSImage())
                                Text(L("测试连接", "Test Connection", "接続テスト"))
                            }
                        }
                            .disabled(model.testing)
                        if model.testing {
                            ProgressView().controlSize(.small)
                        }
                        if !model.testResult.isEmpty {
                            HStack(alignment: .top, spacing: 5) {
                                if !model.testing {
                                    Image(nsImage: SuiyiStyle.symbol(
                                        model.testResult.hasPrefix("✅") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                        description: model.testResult) ?? NSImage())
                                }
                                Text(model.testResult)
                                    .textSelection(.enabled)
                            }
                            .font(.caption)
                            .foregroundColor(model.testing ? .secondary :
                                Color(nsColor: model.testResult.hasPrefix("✅") ? .systemGreen : .systemRed))
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Section(L("翻译", "Translation", "翻訳")) {
                    Picker(L("我的语言", "My language", "自分の言語"), selection: $model.myLanguage) {
                        ForEach(Language.selectable) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    Picker(L("常用对外语言", "Usual outgoing language", "よく使う相手の言語"), selection: $model.outgoingLanguage) {
                        ForEach(Language.selectable.filter { $0 != model.myLanguage }) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    Text(L("外语一律译成我的语言；选中的是我的语言时，译成常用对外语言。回复会译回对方原文的语言。",
                           "Foreign text is translated into your language; text in your language goes to your usual outgoing language. Replies go back in the sender's language.",
                           "外国語は自分の言語に翻訳します。自分の言語のテキストは、よく使う相手の言語に翻訳します。返信は相手の言語で返します。"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onChange(of: model.myLanguage) { mine in
                    if model.outgoingLanguage == mine {
                        model.outgoingLanguage = mine == .english ? .chinese : .english
                    }
                }
                Section(L("历史与画像", "History & profile", "履歴とプロファイル")) {
                    Toggle(L("记录历史", "Keep history", "履歴を記録"), isOn: Binding(
                        get: { model.historyEnabled },
                        set: { model.setHistoryEnabled($0) }
                    ))
                    Text(SettingsModel.historyExplanation)
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("已记录 \(model.historyCount) 条", "\(model.historyCount) entries", "\(model.historyCount) 件記録済み")).foregroundColor(.secondary)
                    HStack {
                        Button(L("打开文件夹", "Open Folder", "フォルダを開く")) { model.openFolder() }
                        Button(L("清空历史", "Clear History", "履歴を消去"), role: .destructive) { model.confirmClear = true }
                    }
                    HStack {
                        Button(L("更新我的画像", "Update My Profile", "プロファイルを更新")) { profile.start() }
                            .disabled(model.historyCount == 0 || profile.running)
                        if profile.running { ProgressView().controlSize(.small) }
                        Button(L("打开画像", "Open Profile", "プロファイルを開く")) { NSWorkspace.shared.open(profile.profileURL) }
                            .disabled(!FileManager.default.fileExists(atPath: profile.profileURL.path))
                    }
                    if !profile.status.isEmpty {
                        Text(profile.status).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: L("仅在记录历史开启时，每新增 30 条记录自动更新画像；生成时发送最近记录到已保存的模型服务。", "With history on, the profile updates every 30 new entries, sending recent entries to your saved model service.", "履歴がオンのとき、30 件ごとにプロファイルを更新し、最近の記録を保存済みのモデルサービスに送信します。"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section(L("我的风格", "My style", "自分のスタイル")) {
                    Toggle(L("回复时参考我的风格", "Use my style in replies", "返信で自分のスタイルを参考にする"), isOn: $model.useMyStyle)
                    Text(verbatim: L("默认关闭。只读取当前用户自己的 ~/.suiyi/profile.md、~/.codex/AGENTS.md（设置了 $CODEX_HOME 时使用该目录）和 ~/.claude/CLAUDE.md；风格背景会随回复发送到你配置的模型接口。", "Off by default. Reads only your own ~/.suiyi/profile.md, ~/.codex/AGENTS.md (or $CODEX_HOME) and ~/.claude/CLAUDE.md; the style notes are sent with replies to your model API.", "既定ではオフ。自分の ~/.suiyi/profile.md、~/.codex/AGENTS.md（$CODEX_HOME 設定時はそのフォルダ）、~/.claude/CLAUDE.md のみを読み取り、スタイル情報は返信と一緒に設定したモデル API に送信されます。"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.styleSources).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L("接入 Codex / Claude Code", "Connect Codex / Claude Code", "Codex / Claude Code に接続")) { model.integrate(remove: false) }
                        Button(L("移除接入", "Disconnect", "接続を解除")) { model.integrate(remove: true) }
                    }
                    Text(model.integrationStatus).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: L("仅在 ~/.codex/AGENTS.md 和 ~/.claude/CLAUDE.md 中添加带标记的画像引用，保留其他内容。", "Adds a marked profile reference to ~/.codex/AGENTS.md and ~/.claude/CLAUDE.md; everything else is kept.", "~/.codex/AGENTS.md と ~/.claude/CLAUDE.md にマーク付きのプロファイル参照を追加します。ほかの内容はそのままです。"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.localStatus.isEmpty {
                        Text(model.localStatus).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section(L("行为", "Behavior", "動作")) {
                    Toggle(L("划词后显示按钮", "Show button after selecting text", "テキスト選択後にボタンを表示"), isOn: $model.showAnchor)
                    Toggle(L("开机启动", "Launch at login", "ログイン時に起動"), isOn: $model.launchAtLogin)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L("排除的应用", "Excluded apps", "除外するアプリ"), text: $model.excluded, prompt: Text(L("Bundle ID，用逗号分隔", "Bundle IDs, comma-separated", "Bundle ID（カンマ区切り）")))
                        Text(L("在这些应用中不会触发划词或快捷键（填写 Bundle ID，英文逗号分隔）。", "Selection and shortcuts are ignored in these apps (Bundle IDs, comma-separated).", "これらのアプリでは選択ボタンとショートカットが動作しません（Bundle ID、カンマ区切り）。"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .confirmationDialog(L("清空全部历史记录？此操作无法撤销。", "Clear all history? This cannot be undone.", "すべての履歴を消去しますか？元に戻せません。"), isPresented: $model.confirmClear) {
                Button(L("清空历史", "Clear History", "履歴を消去"), role: .destructive) { model.clearHistory() }
                Button(L("取消", "Cancel", "キャンセル"), role: .cancel) {}
            }
            .onReceive(profile.$running) { running in
                if !running { model.refreshLocal() }
            }

            Divider()
            HStack(alignment: .center, spacing: 10) {
                if !model.status.isEmpty {
                    Image(nsImage: SuiyiStyle.symbol(
                        model.saved ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        description: model.status) ?? NSImage())
                        .foregroundColor(Color(nsColor: model.saved ? .systemGreen : .systemOrange))
                }
                Text(model.status)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                Spacer()
                Button(L("保存", "Save", "保存")) { model.save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .padding(.top, 14)
        }
        .frame(width: 540, height: 760)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: SettingsModel

    init() {
        model = SettingsModel()
    }

    func show() {
        model.load()
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let newWindow = NSWindow(contentViewController: host)
            newWindow.title = L("随译设置", "Suiyi Settings", "Suiyi 設定")
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
