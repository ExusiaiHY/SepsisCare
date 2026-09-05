import SwiftUI

struct LoginView: View {
    @Bindable var viewModel: AppViewModel
    
    @State private var selectedRole: UserRole = .research
    @State private var password = ""
    @State private var showsPassword = false
    @State private var errorMessage = ""
    @FocusState private var passwordFieldFocused: Bool
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        ZStack {
            BrandPatternBackdrop(style: .login, intensity: 1.25)
            
            entranceConsole
        }
        .frame(minWidth: 1060, minHeight: 660)
        .onAppear {
            selectedRole = viewModel.rememberedRole
            focusPasswordField()
        }
    }

    private var entranceConsole: some View {
        HStack(alignment: .top, spacing: 20) {
            loginCard
            VStack(alignment: .leading, spacing: 16) {
                BackendControlPanel(backend: viewModel.backend, mode: .expanded) {
                    openWindow(id: "backend-logs")
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("入口控制台")
                            .font(.system(size: 14, weight: .bold))
                        Spacer()
                        BrandVersionPill(compact: true)
                    }
                    LoginConsoleRow(icon: "network", title: "远程 API", value: SepsisCareAPI.defaultBaseURL)
                    LoginConsoleRow(icon: "sparkles", title: "DeepSeek", value: "管理员端可查看 provider/model 配置")
                    LoginConsoleRow(icon: "doc.richtext", title: "科研文档", value: "右上角独立窗口 · WKWebView 公式渲染")
                    LoginConsoleRow(icon: "shippingbox", title: "构建版本", value: "\(AppBrand.version) · \(AppBrand.build)")
                }
                .padding(18)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.regularMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppBrand.oxygenCyan.opacity(0.18), lineWidth: 1)
                }
            }
            .frame(width: 500)
        }
        .padding(28)
    }
    
    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 28) {
            header
            roleSelector
            passwordSection
            loginAction
        }
        .padding(34)
        .frame(width: 440)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .shadow(color: AppBrand.oxygenCyan.opacity(0.12), radius: 28, x: 0, y: 16)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppBrand.oxygenCyan.opacity(0.18), lineWidth: 1)
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                BrandLogoMark(size: 54)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(AppBrand.productName)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                        BrandVersionPill(compact: true)
                    }
                    Text("ICU sepsiscare intelligence workspace")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppBrand.oxygenCyan)
                }
            }
            
            Text("请选择工作入口并输入演示密码。研究端保持深色高密度，家属端保持低密度医疗风，管理员端聚焦服务巡检。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
    }
    
    private var roleSelector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("工作入口")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 10) {
                ForEach(UserRole.allCases) { role in
                    RoleCardButton(
                        role: role,
                        isSelected: selectedRole == role
                    ) {
                        selectedRole = role
                        errorMessage = ""
                        focusPasswordField()
                    }
                }
            }
        }
    }
    
    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("密码")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    password = AppViewModel.demoPassword
                    focusPasswordField()
                } label: {
                    Label("填入演示密码", systemImage: "key.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
            }
            Text(AppViewModel.demoAuthBoundaryNotice)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(AppBrand.oxygenCyan)
                    .frame(width: 18)
                
                Group {
                    if showsPassword {
                        TextField("请输入密码", text: $password)
                    } else {
                        SecureField("请输入密码", text: $password)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($passwordFieldFocused)
                .onSubmit(attemptLogin)
                .frame(maxWidth: .infinity, minHeight: 30)

                Button {
                    showsPassword.toggle()
                    focusPasswordField()
                } label: {
                    Image(systemName: showsPassword ? "eye.slash" : "eye")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help(showsPassword ? "隐藏密码" : "显示密码")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.92))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(errorMessage.isEmpty ? AppBrand.oxygenCyan.opacity(0.18) : AppBrand.sepsisRed.opacity(0.72), lineWidth: 1)
            }
            
            if !errorMessage.isEmpty {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
    }
    
    private var loginAction: some View {
        VStack(spacing: 12) {
            Button {
                attemptLogin()
            } label: {
                HStack {
                    Spacer()
                    Text("进入\(selectedRole.displayName)")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "arrow.right")
                    Spacer()
                }
                .frame(height: 38)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppBrand.clinicalTeal)
            .disabled(password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                Text("本地演示环境，不连接真实患者身份信息")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
    
    private func attemptLogin() {
        let cleanPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        if viewModel.authenticate(role: selectedRole, password: cleanPassword) {
            errorMessage = ""
        } else {
            errorMessage = "密码错误，请输入 123123"
            password = ""
            focusPasswordField()
        }
    }

    private func focusPasswordField() {
        DispatchQueue.main.async {
            passwordFieldFocused = true
        }
    }
}

private struct LoginConsoleRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppBrand.oxygenCyan)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.88))
        }
    }
}

private struct RoleCardButton: View {
    let role: UserRole
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((isSelected ? .white : roleColor).opacity(isSelected ? 0.18 : 0.13))
                    Image(systemName: role.icon)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(isSelected ? .white : roleColor)
                }
                .frame(width: 32, height: 32)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
                }
                
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 82)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(roleFill) : AnyShapeStyle(Color(nsColor: .textBackgroundColor).opacity(0.90)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? roleColor : roleColor.opacity(0.20), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var roleColor: Color {
        switch role {
        case .research: return AppBrand.signalBlue
        case .family: return AppBrand.recoveryGreen
        case .admin: return AppBrand.phenotypeViolet
        }
    }

    private var roleFill: LinearGradient {
        switch role {
        case .research:
            return LinearGradient(colors: [AppBrand.signalBlue, AppBrand.oxygenCyan.opacity(0.82)], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .family:
            return LinearGradient(colors: [AppBrand.familyAqua, AppBrand.recoveryGreen], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .admin:
            return LinearGradient(colors: [AppBrand.phenotypeViolet, AppBrand.adminGold.opacity(0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
    
    private var subtitle: String {
        switch role {
        case .research: return "科研分析与队列管理"
        case .family: return "绑定患者沟通摘要"
        case .admin: return "账户绑定与系统监控"
        }
    }
}
