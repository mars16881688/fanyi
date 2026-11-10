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
    @Published var autoCheckUpdates = true
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
    /// 0.2.1.k.05: called after a save with no problems, so the window can close itself.
    var onSaved: (() -> Void)?

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
        autoCheckUpdates = AppSettings.autoCheckUpdates
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
          "既定ではオフ。オンにすると履歴はこの Mac の ~/.suiyi/ にだけ保存され、アップロードされません。プロファイル更新時（手動または自動）にのみ、最近の記録を自分で設定したモデル API に送信します。", "기본값은 꺼짐입니다. 켜면 기록은 이 Mac의 ~/.suiyi/에만 저장되고 업로드되지 않습니다. 프로필을 업데이트할 때(수동 또는 자동)만 최근 기록을 직접 설정한 모델 API로 보냅니다.")
    }

    func setHistoryEnabled(_ enabled: Bool) {
        guard enabled, !UserDefaults.standard.bool(forKey: "historyConsentShown") else {
            historyEnabled = enabled
            return
        }
        let alert = NSAlert()
        alert.messageText = L("开启记录历史？", "Turn on history?", "履歴を記録しますか？", "기록을 켤까요?")
        alert.informativeText = Self.historyExplanation + L(" 同时开启「回复时参考我的风格」时，每新增 30 条记录会自动更新画像。设置需点「保存」生效。", " With My style also on, the profile updates automatically every 30 new entries. Click Save to apply.", " 「自分のスタイル」もオンのとき、30 件ごとにプロファイルが自動更新されます。「保存」で反映されます。", " 「답장에 내 스타일 반영」도 켜져 있으면 새 기록이 30개 쌓일 때마다 프로필이 자동으로 업데이트됩니다. 적용하려면 저장을 누르세요.")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("开启", "Turn On", "オンにする", "켜기"))
        alert.addButton(withTitle: L("取消", "Cancel", "キャンセル", "취소"))
        let response = alert.runModal()
        historyEnabled = response == .alertFirstButtonReturn
        if historyEnabled { UserDefaults.standard.set(true, forKey: "historyConsentShown") }
    }

    func save() {
        var problems: [String] = []

        let keyStatus = Keychain.setAPIKey(apiKey)
        if keyStatus != errSecSuccess {
            problems.append(L("API Key 保存到钥匙串失败", "Could not save the API key to the Keychain", "API キーをキーチェーンに保存できませんでした", "API 키를 키체인에 저장하지 못했습니다") + "（OSStatus \(keyStatus)）")
        }
        AppSettings.baseURL = baseURL
        AppSettings.model = model
        AppSettings.myLanguage = myLanguage
        AppSettings.outgoingLanguage = outgoingLanguage
        AppSettings.translationStyle = translationStyle
        AppSettings.allowInCodeApps = allowInCodeApps
        AppSettings.mouseClipboardFallback = mouseClipboardFallback
        AppSettings.showAnchor = showAnchor
        AppSettings.autoCheckUpdates = autoCheckUpdates
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
            problems.append(L("开机启动设置失败：", "Could not change Launch at Login: ", "ログイン時に起動の設定に失敗しました：", "로그인 시 실행 설정을 바꾸지 못했습니다: ") + error.localizedDescription)
        }
        if launchAtLogin && service.status == .requiresApproval {
            problems.append(L("请在 系统设置 › 通用 › 登录项 中允许随译", "Allow Suiyi in System Settings › General › Login Items", "システム設定 › 一般 › ログイン項目 で Suiyi を許可してください", "시스템 설정 › 일반 › 로그인 항목에서 Suiyi를 허용하세요"))
        }
        launchAtLogin = service.status == .enabled || service.status == .requiresApproval

        baseURL = AppSettings.baseURL
        model = AppSettings.model
        myLanguage = AppSettings.myLanguage
        outgoingLanguage = AppSettings.outgoingLanguage
        saved = problems.isEmpty
        status = saved ? L("已保存", "Saved", "保存しました", "저장됨") : problems.joined(separator: "\n")
        if saved { onSaved?() }   // problems keep the window open so they can be read
    }

    func refreshLocal() {
        historyCount = HistoryStore.shared.count
        let sources = StyleContext.build().sources
        styleSources = sources.isEmpty ? L("未找到任何资料", "Nothing found", "見つかりませんでした", "찾은 항목 없음")
            : L("已找到：", "Found: ", "見つかったもの：", "찾음: ") + sources.joined(separator: L("、", ", ", "、", ", "))
        let installed = AgentIntegration.status()
        let on = L("已接入", "connected", "接続済み", "연결됨"), off = L("未接入", "not connected", "未接続", "연결 안 됨")
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
            localStatus = L("历史已清空（画像保留）。", "History cleared (profile kept).", "履歴を消去しました（プロファイルは保持）。", "기록을 지웠습니다(프로필은 유지).")
        } catch { localStatus = L("清空失败：", "Could not clear: ", "消去に失敗しました：", "지우지 못했습니다: ") + error.localizedDescription }
        refreshLocal()
    }

    func integrate(remove: Bool) {
        do {
            if remove { try AgentIntegration.remove() } else { try AgentIntegration.install() }
            localStatus = remove ? L("已移除接入。", "Disconnected.", "接続を解除しました。", "연결을 해제했습니다.") : L("已接入。", "Connected.", "接続しました。", "연결했습니다.")
        } catch { localStatus = L("操作失败：", "Failed: ", "失敗しました：", "실패: ") + error.localizedDescription }
        refreshLocal()
    }

    func testConnection() {
        testTask?.cancel()
        testing = true
        testResult = L("正在测试…", "Testing…", "テスト中…", "테스트 중…")
        let base = baseURL.trimmed.isEmpty ? AppSettings.defaultBaseURL : baseURL.trimmed
        let modelName = model.trimmed.isEmpty ? AppSettings.defaultModel : model.trimmed
        let config = LLMConfig(baseURL: base, apiKey: apiKey.trimmed, model: modelName)
        testTask = Task { @MainActor [weak self] in
            let message: String
            do {
                let reply = try await LLMClient.ping(config: config)
                message = "✅ " + L("连接成功（回复：", "Connected (reply: ", "接続に成功しました（応答：", "연결 성공 (응답: ") + String(reply.prefix(30)) + L("）", ")", "）", ")")
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
                Image(nsImage: SuiyiStyle.symbol("character.bubble", description: L("随译", "Suiyi", "Suiyi", "Suiyi"), size: 24) ?? NSImage())
                    .foregroundColor(Color(nsColor: .controlAccentColor))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("随译设置", "Suiyi Settings", "Suiyi 設定", "Suiyi 설정")).font(.title3.weight(.semibold))
                    Text(L("中英日韩粤互译 · 改写 · 回复", "Translate between Chinese, English, Japanese, Korean and Cantonese · Rewrite · Reply", "日中英韓・広東語の相互翻訳 · 書き換え · 返信", "한국어·중국어·영어·일본어·광둥어 상호 번역 · 다시 쓰기 · 답장")).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Form {
                Section(L("模型服务（OpenAI 兼容）", "Model service (OpenAI-compatible)", "モデルサービス（OpenAI 互換）", "모델 서비스 (OpenAI 호환)")) {
                    SecureField("API Key", text: $model.apiKey, prompt: Text("sk-…"))
                    TextField("Base URL", text: $model.baseURL, prompt: Text(AppSettings.defaultBaseURL))
                    TextField(L("模型", "Model", "モデル", "모델"), text: $model.model, prompt: Text(AppSettings.defaultModel))
                    HStack(spacing: 8) {
                        Button { model.testConnection() } label: {
                            HStack(spacing: 5) {
                                Image(nsImage: SuiyiStyle.symbol("network", description: L("测试连接", "Test Connection", "接続テスト", "연결 테스트")) ?? NSImage())
                                Text(L("测试连接", "Test Connection", "接続テスト", "연결 테스트"))
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
                Section(L("翻译", "Translation", "翻訳", "번역")) {
                    Picker(L("我的语言", "My language", "自分の言語", "내 언어"), selection: $model.myLanguage) {
                        ForEach(Language.selectable) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    Picker(L("常用对外语言", "Usual outgoing language", "よく使う相手の言語", "자주 쓰는 상대 언어"), selection: $model.outgoingLanguage) {
                        ForEach(Language.selectable.filter { $0 != model.myLanguage }) { language in
                            Text(language.nativeName).tag(language)
                        }
                    }
                    Text(L("外语一律译成我的语言；选中的是我的语言时，译成常用对外语言。回复会译回对方原文的语言。",
                           "Foreign text is translated into your language; text in your language goes to your usual outgoing language. Replies go back in the sender's language.",
                           "外国語は自分の言語に翻訳します。自分の言語のテキストは、よく使う相手の言語に翻訳します。返信は相手の言語で返します。", "외국어는 내 언어로 번역하고, 내 언어로 된 텍스트는 자주 쓰는 상대 언어로 번역합니다. 답장은 상대방의 언어로 돌려보냅니다."))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Picker(L("翻译风格", "Translation style", "翻訳スタイル", "번역 스타일"), selection: $model.translationStyle) {
                        ForEach(TranslationStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    Text(L("翻译和回复译文都按此倾向措辞；改写不受影响。发给模型的是选中的文字、应用名称、窗口标题、应用类型（聊天、邮件、代码等）和选区附近的文字（像密码或密钥时不发送）；回复时加上你写的回复，开启「我的风格」时另附风格资料。",
                           "Translations and translated replies lean this way; Rewrite is unaffected. The model receives the selected text, the app name, the window title, the app type (chat, e-mail, code…) and the text around the selection (skipped if it looks like a password or key), plus your reply when replying and your style notes if My style is on.",
                           "翻訳と返信の訳文はこの傾向で表現します。書き換えには影響しません。モデルに送るのは選択したテキスト、アプリ名、ウィンドウタイトル、アプリの種類（チャット、メール、コードなど）と選択部分の前後の文章（パスワードやキーのように見える場合は送りません）です。返信時は自分の返信、「自分のスタイル」がオンの場合はスタイル情報も送ります。", "번역과 답장 번역은 이 스타일을 따릅니다. 다시 쓰기에는 영향이 없습니다. 모델에는 선택한 텍스트, 앱 이름, 윈도우 제목, 앱 종류(채팅, 이메일, 코드 등)와 선택 영역 주변 텍스트(비밀번호나 키처럼 보이면 보내지 않음)를 보내며, 답장할 때는 내 답장을, 내 스타일이 켜져 있으면 스타일 정보도 함께 보냅니다."))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .onChange(of: model.myLanguage) { mine in
                    if model.outgoingLanguage == mine {
                        model.outgoingLanguage = mine == .english ? .chinese : .english
                    }
                }
                Section(L("安全", "Security", "セキュリティ", "보안")) {
                    Text(L("始终开启：不读取钥匙串访问、密码、1Password、Bitwarden、KeePassXC 等密码类应用；窗口标题含「密码」「password」「密钥」「token」等字样时不读取（浏览器网页只看密码管理器的名称，文章照常可读，正文仍逐段检查）；选中内容像密码、密钥、卡号、证件号或助记词时不弹按钮，用快捷键需 10 秒内再触发一次才发送，且不记入历史。",
                           "Always on: password apps (Keychain Access, Passwords, 1Password, Bitwarden, KeePassXC…) are never read; windows titled with words like password, key or token are not read (on web pages only password-manager titles count, so articles stay readable; the text is still checked); selections that look like passwords, keys, card or ID numbers or recovery phrases get no button, and a shortcut must be repeated within 10 seconds to send them, without saving to history.",
                           "常に有効：パスワード管理アプリ（キーチェーンアクセス、パスワード、1Password、Bitwarden、KeePassXC など）は読み取りません。タイトルに「パスワード」「password」「token」などを含むウィンドウは読み取りません（Web ページではパスワード管理アプリ名のみが対象で、記事は読めます。本文は引き続き確認します）。パスワード、キー、カード番号、ID 番号、リカバリーフレーズのような選択にはボタンを出さず、ショートカットは 10 秒以内にもう一度実行した場合のみ送信し、履歴には残しません。", "항상 켜짐: 비밀번호 앱(키체인 접근, 암호, 1Password, Bitwarden, KeePassXC 등)은 읽지 않습니다. 제목에 password, key, token 같은 단어가 있는 윈도우는 읽지 않습니다(웹 페이지는 비밀번호 관리자 이름만 해당하므로 기사는 읽을 수 있으며, 본문은 계속 검사합니다). 비밀번호, 키, 카드·신분증 번호, 복구 문구처럼 보이는 선택에는 버튼을 표시하지 않으며, 단축키를 10초 이내에 다시 눌러야 보내고 기록에는 저장하지 않습니다."))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(L("在终端和代码编辑器中启用", "Work in terminals and code editors", "ターミナルとコードエディタでも使う", "터미널과 코드 편집기에서도 사용"), isOn: $model.allowInCodeApps)
                    Text(L("默认关闭：终端和编辑器里常有密钥和令牌。", "Off by default: terminals and editors often show keys and tokens.",
                           "既定ではオフ：ターミナルやエディタにはキーやトークンがよく表示されます。", "기본값은 꺼짐: 터미널과 편집기에는 키와 토큰이 자주 표시됩니다."))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(L("鼠标划词读不到文字时，也显示按钮", "Show the button when a mouse selection can't be read directly", "マウス選択を直接読めないときもボタンを表示", "마우스 선택을 바로 읽을 수 없을 때도 버튼 표시"), isOn: $model.mouseClipboardFallback)
                    Text(L("默认开启：微信、Telegram 等无法直接读取选中文字的应用靠它弹出按钮。划词时不会模拟按键；只有点了按钮，才模拟一次 ⌘C 读取，读到后再检查内容。选中内容会短暂经过剪贴板，剪贴板管理器可能记下它。拖动窗口或滚动条时不出按钮，其他不是选文字的拖动偶尔也会出按钮，不点会自动消失。关闭后，这些应用请用 ⌥⌘T。",
                           "On by default: WeChat, Telegram and other apps whose selection can't be read directly need it for the button. Selecting never sends keys; only clicking the button sends ⌘C once to read the text, which is then checked. The selection briefly passes through the clipboard, where a clipboard manager may record it. Moving a window or a scroll bar shows no button; other drags that select nothing may, and it goes away by itself. Turned off, use ⌥⌘T in those apps.",
                           "既定でオン：WeChat や Telegram など、選択を直接読めないアプリでボタンを出すために使います。選択しただけではキーを送りません。ボタンをクリックしたときにだけ ⌘C で読み取り、内容を確認します。選択内容は一時的にクリップボードを通るため、クリップボード管理アプリに記録される場合があります。ウィンドウやスクロールバーのドラッグではボタンを出しません。それ以外の選択でないドラッグでは出ることがありますが、自動で消えます。オフにした場合、これらのアプリでは ⌥⌘T を使ってください。", "기본값은 켜짐: WeChat, Telegram처럼 선택을 바로 읽을 수 없는 앱에서 버튼을 표시하려면 필요합니다. 선택만으로는 키를 보내지 않고, 버튼을 눌렀을 때만 ⌘C를 한 번 보내 읽은 뒤 내용을 검사합니다. 선택한 내용이 잠시 클립보드를 거치므로 클립보드 관리자가 기록할 수 있습니다. 윈도우나 스크롤 막대를 끌 때는 버튼이 나타나지 않으며, 텍스트를 선택하지 않는 다른 드래그에서는 나타날 수 있지만 저절로 사라집니다. 끄면 해당 앱에서는 ⌥⌘T를 사용하세요."))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section(L("历史与画像", "History & profile", "履歴とプロファイル", "기록과 프로필")) {
                    Toggle(L("记录历史", "Keep history", "履歴を記録", "기록 남기기"), isOn: Binding(
                        get: { model.historyEnabled },
                        set: { model.setHistoryEnabled($0) }
                    ))
                    Text(SettingsModel.historyExplanation)
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("已记录 \(model.historyCount) 条", "\(model.historyCount) entries", "\(model.historyCount) 件記録済み", "\(model.historyCount)개 기록")).foregroundColor(.secondary)
                    HStack {
                        Button(L("打开文件夹", "Open Folder", "フォルダを開く", "폴더 열기")) { model.openFolder() }
                        Button(L("清空历史", "Clear History", "履歴を消去", "기록 지우기"), role: .destructive) { model.confirmClear = true }
                    }
                    HStack {
                        Button(L("更新我的画像", "Update My Profile", "プロファイルを更新", "내 프로필 업데이트")) { profile.start() }
                            .disabled(model.historyCount == 0 || profile.running)
                        if profile.running { ProgressView().controlSize(.small) }
                        Button(L("打开画像", "Open Profile", "プロファイルを開く", "프로필 열기")) { NSWorkspace.shared.open(profile.profileURL) }
                            .disabled(!FileManager.default.fileExists(atPath: profile.profileURL.path))
                    }
                    if !profile.status.isEmpty {
                        Text(profile.status).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: L("记录历史和「回复时参考我的风格」都开启时，每新增 30 条记录自动更新画像；生成时发送最近记录到已保存的模型服务。只开记录历史时只能手动更新。", "With history and My style both on, the profile updates every 30 new entries, sending recent entries to your saved model service. With history alone, update it by hand.", "履歴と「自分のスタイル」の両方がオンのとき、30 件ごとにプロファイルを自動更新し、最近の記録を保存済みのモデルサービスに送信します。履歴だけのときは手動で更新します。", "기록과 「답장에 내 스타일 반영」가 모두 켜져 있으면 새 기록 30개마다 프로필을 자동으로 업데이트하며, 이때 최근 기록을 저장된 모델 서비스로 보냅니다. 기록만 켜져 있으면 직접 업데이트하세요."))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section(L("我的风格", "My style", "自分のスタイル", "내 스타일")) {
                    Toggle(L("回复时参考我的风格", "Use my style in replies", "返信で自分のスタイルを参考にする", "답장에 내 스타일 반영"), isOn: $model.useMyStyle)
                    Text(verbatim: L("默认关闭。只读取当前用户自己的 ~/.suiyi/profile.md、~/.codex/AGENTS.md（设置了 $CODEX_HOME 时使用该目录）和 ~/.claude/CLAUDE.md，看起来像密码或密钥的行会被去掉；风格背景会随回复发送到你配置的模型接口。", "Off by default. Reads only your own ~/.suiyi/profile.md, ~/.codex/AGENTS.md (or $CODEX_HOME) and ~/.claude/CLAUDE.md, dropping lines that look like passwords or keys; the style notes are sent with replies to your model API.", "既定ではオフ。自分の ~/.suiyi/profile.md、~/.codex/AGENTS.md（$CODEX_HOME 設定時はそのフォルダ）、~/.claude/CLAUDE.md のみを読み取り、パスワードやキーのような行は除外します。スタイル情報は返信と一緒に設定したモデル API に送信されます。", "기본값은 꺼짐입니다. 내 ~/.suiyi/profile.md, ~/.codex/AGENTS.md($CODEX_HOME 설정 시 해당 폴더), ~/.claude/CLAUDE.md만 읽으며 비밀번호나 키처럼 보이는 줄은 제외합니다. 스타일 정보는 답장과 함께 설정한 모델 API로 보냅니다."))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.styleSources).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(L("接入 Codex / Claude Code", "Connect Codex / Claude Code", "Codex / Claude Code に接続", "Codex / Claude Code 연결")) { model.integrate(remove: false) }
                        Button(L("移除接入", "Disconnect", "接続を解除", "연결 해제")) { model.integrate(remove: true) }
                    }
                    Text(model.integrationStatus).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: L("仅在 ~/.codex/AGENTS.md 和 ~/.claude/CLAUDE.md 中添加带标记的画像引用，保留其他内容。", "Adds a marked profile reference to ~/.codex/AGENTS.md and ~/.claude/CLAUDE.md; everything else is kept.", "~/.codex/AGENTS.md と ~/.claude/CLAUDE.md にマーク付きのプロファイル参照を追加します。ほかの内容はそのままです。", "~/.codex/AGENTS.md와 ~/.claude/CLAUDE.md에 표시된 프로필 참조를 추가합니다. 다른 내용은 그대로 유지됩니다."))
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.localStatus.isEmpty {
                        Text(model.localStatus).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section(L("行为", "Behavior", "動作", "동작")) {
                    Toggle(L("划词后显示按钮", "Show button after selecting text", "テキスト選択後にボタンを表示", "텍스트 선택 후 버튼 표시"), isOn: $model.showAnchor)
                    Toggle(L("开机启动", "Launch at login", "ログイン時に起動", "로그인 시 실행"), isOn: $model.launchAtLogin)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(L("自动检查更新", "Check for updates automatically", "アップデートを自動確認", "업데이트 자동 확인"), isOn: $model.autoCheckUpdates)
                        Text(L("每天读取一次官网的版本文件，有新版时提示，可一键更新；不发送任何个人数据。关闭后只在点「检查更新…」时检查。",
                               "Reads the version file on the official site about once a day and offers one-click updates; no personal data is sent. When off, updates are checked only from “Check for Updates…”.",
                               "1 日に 1 回公式サイトのバージョン情報を読み、新しいバージョンがあればワンクリックで更新できます。個人データは送信しません。オフにすると「アップデートを確認…」のときだけ確認します。",
                               "하루에 한 번 공식 사이트의 버전 정보를 읽어 새 버전이 있으면 알리고 한 번에 업데이트할 수 있습니다. 개인 데이터는 보내지 않습니다. 끄면 「업데이트 확인…」을 누를 때만 확인합니다."))
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(L("排除的应用", "Excluded apps", "除外するアプリ", "제외할 앱"), text: $model.excluded, prompt: Text(L("Bundle ID，用逗号分隔", "Bundle IDs, comma-separated", "Bundle ID（カンマ区切り）", "Bundle ID, 쉼표로 구분")))
                        Text(L("在这些应用中不会触发划词或快捷键（填写 Bundle ID，英文逗号分隔）。", "Selection and shortcuts are ignored in these apps (Bundle IDs, comma-separated).", "これらのアプリでは選択ボタンとショートカットが動作しません（Bundle ID、カンマ区切り）。", "이 앱들에서는 선택 버튼과 단축키가 동작하지 않습니다(Bundle ID, 쉼표로 구분)."))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .confirmationDialog(L("清空全部历史记录？此操作无法撤销。", "Clear all history? This cannot be undone.", "すべての履歴を消去しますか？元に戻せません。", "모든 기록을 지울까요? 되돌릴 수 없습니다."), isPresented: $model.confirmClear) {
                Button(L("清空历史", "Clear History", "履歴を消去", "기록 지우기"), role: .destructive) { model.clearHistory() }
                Button(L("取消", "Cancel", "キャンセル", "취소"), role: .cancel) {}
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
                Button(L("保存", "Save", "保存", "저장")) { model.save() }
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
        model.onSaved = { [weak self] in self?.window?.close() }
    }

    func show() {
        model.load()
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model))
            let newWindow = NSWindow(contentViewController: host)
            newWindow.title = L("随译设置", "Suiyi Settings", "Suiyi 設定", "Suiyi 설정")
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
