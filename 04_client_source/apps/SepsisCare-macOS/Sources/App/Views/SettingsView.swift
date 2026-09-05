import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Bindable var backend: BackendController
    @Environment(\.dismiss) private var dismiss
    
    private let availableFonts = ["Songti SC", "PingFang SC", "Heiti SC", "Helvetica Neue", "Arial"]
    private let availableLanguages = [("zh-Hans", "简体中文"), ("en", "English")]
    @State private var deepSeekAPIKey = ""
    @State private var deepSeekModel = "deepseek-chat"
    @State private var deepSeekBaseURL = "https://api.deepseek.com/chat/completions"
    @State private var deepSeekTimeout = "18"
    @State private var deepSeekStatus = "尚未读取配置"
    @State private var isSavingDeepSeek = false
    @State private var apiCheckStatus = "尚未测试 API 连接"
    
    var body: some View {
        NavigationStack {
            Form {
                Section("外观") {
                    Picker("字体", selection: $settings.fontName) {
                        ForEach(availableFonts, id: \.self) { font in
                            Text(font).tag(font)
                        }
                    }
                    
                    HStack {
                        Text("字体大小")
                        Slider(value: $settings.fontSize, in: 12...20, step: 1)
                        Text("\(Int(settings.fontSize))pt")
                            .foregroundStyle(.secondary)
                    }
                    
                    Picker("主题", selection: $settings.theme) {
                        ForEach(AppTheme.allCases, id: \.self) { theme in
                            Text(theme.displayName).tag(theme)
                        }
                    }
                }
                
                Section("语言") {
                    Picker("界面语言", selection: $settings.language) {
                        ForEach(availableLanguages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                    .pickerStyle(.radioGroup)
                }
                
                Section("后端") {
                    Toggle("启动本地后端", isOn: $settings.backendAutoStart)
                    TextField("API 地址", text: $settings.apiBaseURL)
                        .textFieldStyle(.roundedBorder)
                    SecureField("服务端访问 Token", text: $settings.serviceToken)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            testAPIConnection()
                        } label: {
                            Label("测试 API", systemImage: "network")
                        }

                        Spacer()

                        Text(backend.statusText)
                            .font(.caption)
                            .foregroundStyle(backend.isReady ? Color.green : Color.orange)
                    }
                    Text(apiCheckStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("默认连接远程 API：\(SepsisCareAPI.defaultBaseURL)。\(SepsisCareAPI.remoteBaseURLHelp)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(settings.serviceToken.isEmpty ? "未配置 Token 时只能访问本机或公开健康检查；远端患者、训练、配置和模型接口会被拒绝。" : "Token 已保存；请求会自动附加 Authorization: Bearer。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("DeepSeek") {
                    SecureField("API Key", text: $deepSeekAPIKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("模型", text: $deepSeekModel)
                        .textFieldStyle(.roundedBorder)
                    TextField("接口地址", text: $deepSeekBaseURL)
                        .textFieldStyle(.roundedBorder)
                    TextField("超时秒数", text: $deepSeekTimeout)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button {
                            saveDeepSeekConfig(clearKey: false)
                        } label: {
                            Label(isSavingDeepSeek ? "保存中" : "保存配置", systemImage: "key.fill")
                        }
                        .disabled(isSavingDeepSeek)

                        Button(role: .destructive) {
                            saveDeepSeekConfig(clearKey: true)
                        } label: {
                            Label("清除 Key", systemImage: "trash")
                        }
                        .disabled(isSavingDeepSeek)
                    }
                    Text(deepSeekStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Section("通知") {
                    Toggle("启用通知", isOn: $settings.enableNotifications)
                }
                
                Section("关于") {
                    HStack(spacing: 12) {
                        BrandLogoMark(size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppBrand.productName)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                            Text(AppBrand.releaseName)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(AppBrand.version)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("构建")
                        Spacer()
                        Text(AppBrand.build)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Bundle ID")
                        Spacer()
                        Text(AppBrand.bundleIdentifier)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("品牌资源")
                        Spacer()
                        Text(AppBrand.brandManifestURL == nil ? "未打包" : "已打包")
                            .foregroundStyle(AppBrand.brandManifestURL == nil ? Color.orange : Color.secondary)
                    }
                    HStack {
                        Text("模型版本")
                        Spacer()
                        Text("20260516")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("开发者")
                        Spacer()
                        Text("sepsiscare research")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            syncBackendAPIBaseURL()
            apiCheckStatus = "当前 API：\(backend.apiBaseURL) · \(backend.lastHealthCheck)"
            loadDeepSeekConfig()
        }
    }

    private func syncBackendAPIBaseURL() {
        settings.apiBaseURL = SepsisCareAPI.normalizedBaseURL(settings.apiBaseURL)
        backend.setAPIBaseURL(settings.apiBaseURL)
    }

    private func testAPIConnection() {
        syncBackendAPIBaseURL()
        Task {
            await APIClient.shared.setBaseURL(settings.apiBaseURL)
            await MainActor.run {
                apiCheckStatus = "正在检查：\(backend.apiBaseURL)/health"
            }
            let result = await backend.checkHealthNow()
            await MainActor.run {
                apiCheckStatus = result.detail
            }
        }
    }

    private func loadDeepSeekConfig() {
        syncBackendAPIBaseURL()
        Task {
            do {
                await APIClient.shared.setBaseURL(settings.apiBaseURL)
                let config = try await APIClient.shared.getDeepSeekConfig()
                await MainActor.run {
                    deepSeekAPIKey = ""
                    deepSeekModel = config.model
                    deepSeekBaseURL = config.base_url
                    deepSeekTimeout = config.timeout_seconds
                    deepSeekStatus = config.configured
                        ? "DeepSeek 已配置：\(config.api_key_hint)。配置文件：\(config.config_path)"
                        : "DeepSeek 未配置。保存 API Key 后，家属端 AI 智能体会立即使用 DeepSeek。"
                }
            } catch {
                await MainActor.run {
                    deepSeekStatus = "无法读取 DeepSeek 配置，请确认本地后端已启动。"
                }
            }
        }
    }

    private func saveDeepSeekConfig(clearKey: Bool) {
        isSavingDeepSeek = true
        deepSeekStatus = clearKey ? "正在清除 DeepSeek Key..." : "正在保存 DeepSeek 配置..."
        syncBackendAPIBaseURL()
        Task {
            do {
                await APIClient.shared.setBaseURL(settings.apiBaseURL)
                let config = try await APIClient.shared.postDeepSeekConfig(
                    apiKey: clearKey ? "" : deepSeekAPIKey,
                    model: deepSeekModel,
                    baseURL: deepSeekBaseURL,
                    timeoutSeconds: deepSeekTimeout,
                    clearKey: clearKey
                )
                await MainActor.run {
                    isSavingDeepSeek = false
                    deepSeekAPIKey = ""
                    deepSeekModel = config.model
                    deepSeekBaseURL = config.base_url
                    deepSeekTimeout = config.timeout_seconds
                    deepSeekStatus = config.configured
                        ? "DeepSeek 已保存并生效：\(config.api_key_hint)。现在可回到家属端继续提问。"
                        : "DeepSeek Key 已清除，家属端会回到本地说明模式。"
                }
            } catch {
                await MainActor.run {
                    isSavingDeepSeek = false
                    deepSeekStatus = "保存失败：请确认本地后端在线。"
                }
            }
        }
    }
}
