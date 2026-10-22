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
    @Published var translationStyle: TranslationStyle = .colloquial
    @Published var allowInCodeApps = false
    @Published var mouseClipboardFallback = false
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
        translationStyle = AppSettings.translationStyle
        allowInCodeApps = AppSettings.allowInCodeApps
        mouseClipboardFallback = AppSettings.mouseClipboardFallback
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
        AppSettings.translationStyle = translationStyle
        AppSettings.allowInCodeApps = allowInCodeApps
        AppSettings.mouseClipboardFallback = mouseClipboardFallback
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
                    Picker(L("翻译风格", "Translation style", "翻訳スタイル"), selection: $model.translationStyle) {
                        ForEach(TranslationStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Text(L("翻译和回复译文都按此倾向措辞；改写不受影响。发给模型的是选中的文字、应用名称、窗口标题、应用类型（聊天、邮件、代码等）和选区附近的文字（像密码或密钥时不发送）；回复时加上你写的回复，开启「我的风格」时另附风格资料。",
                           "Translations and translated replies lean this way; Rewrite is unaffected. The model receives the selected text, the app name, the window title, the app type (chat, e-mail, code…) and the text around the selection (skipped if it looks like a password or key), plus your reply when replying and your style notes if My style is on.",
                           "翻訳と返信の訳文はこの傾向で表現します。書き換えには影響しません。モデルに送るのは選択したテキスト、アプリ名、ウィンドウタイトル、アプリの種類（チャット、メール、コードなど）と選択部分の前後の文章（パスワードやキーのように見える場合は送りません）です。返信時は自分の返信、「自分のスタイル」がオンの場合はスタイル情報も送ります。"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onChange(of: model.myLanguage) { mine in
                    if model.outgoingLanguage == mine {
                        model.outgoingLanguage = mine == .english ? .chinese : .english
                    }
                }
                Section(L("安全", "Security", "セキュリティ")) {
                    Text(L("始终开启：不读取钥匙串访问、密码、1Password、Bitwarden、KeePassXC 等密码类应用；窗口标题含「密码」「password」「密钥」「token」等字样时不读取（浏览器网页只看密码管理器的名称，文章照常可读，正文仍逐段检查）；选中内容像密码、密钥、卡号、证件号或助记词时不弹按钮，用快捷键需 10 秒内再触发一次才发送，且不记入历史。",
                           "Always on: password apps (Keychain Access, Passwords, 1Password, Bitwarden, KeePassXC…) are never read; windows titled with words like password, key or token are not read (on web pages only password-manager titles count, so articles stay readable; the text is still checked); selections that look like passwords, keys, card or ID numbers or recovery phrases get no button, and a shortcut must be repeated within 10 seconds to send them, without saving to history.",
                           "常に有効：パスワード管理アプリ（キーチェーンアクセス、パスワード、1Password、Bitwarden、KeePassXC など）は読み取りません。タイトルに「パスワード」「password」「token」などを含むウィンドウは読み取りません（Web ページではパスワード管理アプリ名のみが対象で、記事は読めます。本文は引き続き確認します）。パスワード、キー、カード番号、ID 番号、リカバリーフレーズのような選択にはボタンを出さず、ショートカットは 10 秒以内にもう一度実行した場合のみ送信し、履歴には残しません。"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(L("在终端和代码编辑器中启用", "Work in terminals and code editors", "ターミナルとコードエディタでも使う"), isOn: $model.allowInCodeApps)
                    Text(L("默认关闭：终端和编辑器里常有密钥和令牌。", "Off by default: terminals and editors often show keys and tokens.",
                           "既定ではオフ：ターミナルやエディタにはキーやトークンがよく表示されます。"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(L("鼠标划词读不到文字时，模拟 ⌘C 读取", "Use ⌘C when a mouse selection can't be read directly", "マウス選択を直接読めないときは ⌘C で読み取る"), isOn: $model.mouseClipboardFallback)
                    Text(L("默认开启：微信、Telegram 等无法直接读取选中文字的应用靠它弹出按钮。上面的应用、网页和窗口检查通过后才会模拟 ⌘C，读到后再检查内容；选中内容会短暂经过剪贴板，剪贴板管理器可能记下它。要求最严时可关闭，关闭后这些应用请用 ⌥⌘T。",
                           "On by default: WeChat, Telegram and other apps whose selection can't be read directly need it for the button. ⌘C is used only after the app, page and window checks pass, and the content is checked afterwards; the selection briefly passes through the clipboard, where a clipboard manager may record it. Turn it off for the strictest setting and use ⌥⌘T in those apps.",
                           "既定でオン：WeChat や Telegram など、選択を直接読めないアプリでボタンを出すために使います。アプリ・ページ・ウィンドウの確認を通過した後にだけ ⌘C を使い、読み取った内容も確認します。選択内容は一時的にクリップボードを通るため、クリップボード管理アプリに記録される場合があります。最も厳しくするならオフにし、これらのアプリでは ⌥⌘T を使ってください。"))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    Text(verbatim: L("默认关闭。只读取当前用户自己的 ~/.suiyi/profile.md、~/.codex/AGENTS.md（设置了 $CODEX_HOME 时使用该目录）和 ~/.claude/CLAUDE.md，看起来像密码或密钥的行会被去掉；风格背景会随回复发送到你配置的模型接口。", "Off by default. Reads only your own ~/.suiyi/profile.md, ~/.codex/AGENTS.md (or $CODEX_HOME) and ~/.claude/CLAUDE.md, dropping lines that look like passwords or keys; the style notes are sent with replies to your model API.", "既定ではオフ。自分の ~/.suiyi/profile.md、~/.codex/AGENTS.md（$CODEX_HOME 設定時はそのフォルダ）、~/.claude/CLAUDE.md のみを読み取り、パスワードやキーのような行は除外します。スタイル情報は返信と一緒に設定したモデル API に送信されます。"))
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
                    Text(verbatim: L("此版本停用「接入 Codex / Claude Code」：画像由模型根据他人文字生成，不应成为 Agent 的指令。如以前接入过，可点「移除接入」清掉标记块。", "Connecting Codex / Claude Code is disabled in this build: the profile is model-written from other people's text and should not become agent instructions. If you connected before, Disconnect removes the marked block.", "このビルドでは「Codex / Claude Code に接続」を無効にしています。プロファイルは他人のテキストからモデルが生成したもので、エージェントへの指示にすべきではありません。以前に接続した場合は「接続を解除」でマーク付きブロックを削除できます。"))
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
