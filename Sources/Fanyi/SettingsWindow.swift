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
            problems.append("请在 系统设置 › 通用 › 登录项 中允许 Fanyi")
        }
        launchAtLogin = service.status == .enabled || service.status == .requiresApproval

        baseURL = AppSettings.baseURL
        model = AppSettings.model
        status = problems.isEmpty ? "已保存 ✓" : problems.joined(separator: "\n")
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

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("模型服务（OpenAI 兼容）") {
                    SecureField("API Key", text: $model.apiKey, prompt: Text("sk-…"))
                    TextField("Base URL", text: $model.baseURL, prompt: Text(AppSettings.defaultBaseURL))
                    TextField("模型", text: $model.model, prompt: Text(AppSettings.defaultModel))
                    HStack(spacing: 8) {
                        Button("测试连接") { model.testConnection() }
                            .disabled(model.testing)
                        if model.testing {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.testResult)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                }
                Section("翻译") {
                    Picker("目标语言", selection: $model.target) {
                        ForEach(TargetLanguage.allCases) { language in
                            Text(language.menuTitle).tag(language)
                        }
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

            HStack(alignment: .center) {
                Text(model.status)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                Spacer()
                Button("保存") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            .padding(.top, 4)
        }
        .frame(width: 500, height: 580)
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
            newWindow.title = "Fanyi 设置"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
