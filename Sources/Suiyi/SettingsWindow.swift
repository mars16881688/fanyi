import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    @Published var apiKey = ""
    @Published var baseURL = ""
    @Published var model = ""
    @Published var target: TargetLanguage = .auto
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
        target = AppSettings.targetLanguage
        showAnchor = AppSettings.showAnchor
        excluded = AppSettings.excludedRaw
        launchAtLogin = SMAppService.mainApp.status == .enabled
        status = ""
        testResult = ""
        historyEnabled = AppSettings.historyEnabled
        useMyStyle = AppSettings.useMyStyle
        refreshLocal()
    }

    static let historyExplanation = "默认关闭。开启后只保存在本机 ~/.suiyi/，不会上传；只有点「更新我的画像」或自动更新画像时，会把最近的记录发送到你自己配置的模型接口。"

    func setHistoryEnabled(_ enabled: Bool) {
        guard enabled, !UserDefaults.standard.bool(forKey: "historyConsentShown") else {
            historyEnabled = enabled
            return
        }
        let alert = NSAlert()
        alert.messageText = "开启记录历史？"
        alert.informativeText = Self.historyExplanation + " 开启后每新增 30 条记录会自动更新画像。设置需点「保存」生效。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "开启")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        historyEnabled = response == .alertFirstButtonReturn
        if historyEnabled { UserDefaults.standard.set(true, forKey: "historyConsentShown") }
    }

    func save() {
        var problems: [String] = []

        let keyStatus = Keychain.setAPIKey(apiKey)
        if keyStatus != errSecSuccess {
            problems.append("API Key 保存到钥匙串失败（OSStatus \(keyStatus)）")
        }
        AppSettings.baseURL = baseURL
        AppSettings.model = model
        AppSettings.targetLanguage = target
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
            problems.append("开机启动设置失败：\(error.localizedDescription)")
        }
        if launchAtLogin && service.status == .requiresApproval {
            problems.append("请在 系统设置 › 通用 › 登录项 中允许随译")
        }
        launchAtLogin = service.status == .enabled || service.status == .requiresApproval

        baseURL = AppSettings.baseURL
        model = AppSettings.model
        status = problems.isEmpty ? "已保存 ✓" : problems.joined(separator: "\n")
    }

    func refreshLocal() {
        historyCount = HistoryStore.shared.count
        let sources = StyleContext.build().sources
        styleSources = sources.isEmpty ? "未找到任何资料" : "已找到：" + sources.joined(separator: "、")
        let installed = AgentIntegration.status()
        integrationStatus = "Codex：\(installed[0] ? "已接入" : "未接入")；Claude Code：\(installed[1] ? "已接入" : "未接入")"
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
            localStatus = "历史已清空（画像保留）。"
        } catch { localStatus = "清空失败：\(error.localizedDescription)" }
        refreshLocal()
    }

    func integrate(remove: Bool) {
        do {
            if remove { try AgentIntegration.remove() } else { try AgentIntegration.install() }
            localStatus = remove ? "已移除接入。" : "已接入。"
        } catch { localStatus = "操作失败：\(error.localizedDescription)" }
        refreshLocal()
    }

    func testConnection() {
        testTask?.cancel()
        testing = true
        testResult = "正在测试…"
        let base = baseURL.trimmed.isEmpty ? AppSettings.defaultBaseURL : baseURL.trimmed
        let modelName = model.trimmed.isEmpty ? AppSettings.defaultModel : model.trimmed
        let config = LLMConfig(baseURL: base, apiKey: apiKey.trimmed, model: modelName)
        testTask = Task { @MainActor [weak self] in
            let message: String
            do {
                let reply = try await LLMClient.ping(config: config)
                message = "✅ 连接成功（回复：\(String(reply.prefix(30)))）"
            } catch is CancellationError {
                return
            } catch {
                message = "❌ \(error.localizedDescription)"
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
                Image(nsImage: SuiyiStyle.symbol("character.bubble", description: "随译", size: 24) ?? NSImage())
                    .foregroundColor(Color(nsColor: .controlAccentColor))
                VStack(alignment: .leading, spacing: 3) {
                    Text("随译设置").font(.title3.weight(.semibold))
                    Text("划词翻译 · 改写 · 回复").font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Form {
                Section("模型服务（OpenAI 兼容）") {
                    SecureField("API Key", text: $model.apiKey, prompt: Text("sk-…"))
                    TextField("Base URL", text: $model.baseURL, prompt: Text(AppSettings.defaultBaseURL))
                    TextField("模型", text: $model.model, prompt: Text(AppSettings.defaultModel))
                    HStack(spacing: 8) {
                        Button { model.testConnection() } label: {
                            HStack(spacing: 5) {
                                Image(nsImage: SuiyiStyle.symbol("network", description: "测试连接") ?? NSImage())
                                Text("测试连接")
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
                Section("翻译") {
                    Picker("目标语言", selection: $model.target) {
                        ForEach(TargetLanguage.allCases) { language in
                            Text(language.menuTitle).tag(language)
                        }
                    }
                }
                Section("历史与画像") {
                    Toggle("记录历史", isOn: Binding(
                        get: { model.historyEnabled },
                        set: { model.setHistoryEnabled($0) }
                    ))
                    Text(SettingsModel.historyExplanation)
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("已记录 \(model.historyCount) 条").foregroundColor(.secondary)
                    HStack {
                        Button("打开文件夹") { model.openFolder() }
                        Button("清空历史", role: .destructive) { model.confirmClear = true }
                    }
                    HStack {
                        Button("更新我的画像") { profile.start() }
                            .disabled(model.historyCount == 0 || profile.running)
                        if profile.running { ProgressView().controlSize(.small) }
                        Button("打开画像") { NSWorkspace.shared.open(profile.profileURL) }
                            .disabled(!FileManager.default.fileExists(atPath: profile.profileURL.path))
                    }
                    if !profile.status.isEmpty {
                        Text(profile.status).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(verbatim: "仅在记录历史开启时，每新增 30 条记录自动更新画像；生成时发送最近记录到已保存的模型服务。")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("我的风格") {
                    Toggle("回复时参考我的风格", isOn: $model.useMyStyle)
                    Text(verbatim: "默认关闭。只读取当前用户自己的 ~/.suiyi/profile.md、~/.codex/AGENTS.md（设置了 $CODEX_HOME 时使用该目录）和 ~/.claude/CLAUDE.md；风格背景会随回复发送到你配置的模型接口。")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.styleSources).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("接入 Codex / Claude Code") { model.integrate(remove: false) }
                        Button("移除接入") { model.integrate(remove: true) }
                    }
                    Text(model.integrationStatus).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(verbatim: "仅在 ~/.codex/AGENTS.md 和 ~/.claude/CLAUDE.md 中添加带标记的画像引用，保留其他内容。")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.localStatus.isEmpty {
                        Text(model.localStatus).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section("行为") {
                    Toggle("划词后显示按钮", isOn: $model.showAnchor)
                    Toggle("开机启动", isOn: $model.launchAtLogin)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("排除的应用", text: $model.excluded, prompt: Text("Bundle ID，用逗号分隔"))
                        Text("在这些应用中不会触发划词或快捷键（填写 Bundle ID，英文逗号分隔）。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .confirmationDialog("清空全部历史记录？此操作无法撤销。", isPresented: $model.confirmClear) {
                Button("清空历史", role: .destructive) { model.clearHistory() }
                Button("取消", role: .cancel) {}
            }
            .onReceive(profile.$running) { running in
                if !running { model.refreshLocal() }
            }

            Divider()
            HStack(alignment: .center, spacing: 10) {
                if !model.status.isEmpty {
                    Image(nsImage: SuiyiStyle.symbol(
                        model.status == "已保存 ✓" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        description: model.status) ?? NSImage())
                        .foregroundColor(Color(nsColor: model.status == "已保存 ✓" ? .systemGreen : .systemOrange))
                }
                Text(model.status)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                Spacer()
                Button("保存") { model.save() }
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
            newWindow.title = "随译设置"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
