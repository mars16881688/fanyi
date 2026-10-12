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

@MainActor
struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: FanyiStyle.symbol("character.bubble", description: "Fanyi", size: 24) ?? NSImage())
                    .foregroundColor(Color(nsColor: .controlAccentColor))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fanyi 设置").font(.title3.weight(.semibold))
                    Text("划词翻译 · 改写 · 回复").font(.caption).foregroundColor(.secondary)
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
                                Image(nsImage: FanyiStyle.symbol("network", description: "测试连接") ?? NSImage())
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
                                    Image(nsImage: FanyiStyle.symbol(
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

            Divider()
            HStack(alignment: .center, spacing: 10) {
                if !model.status.isEmpty {
                    Image(nsImage: FanyiStyle.symbol(
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
        .frame(width: 540, height: 640)
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
