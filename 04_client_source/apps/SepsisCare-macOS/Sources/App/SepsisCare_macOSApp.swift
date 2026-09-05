import SwiftUI
import AppKit

final class SepsisCareAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct SepsisCare_macOSApp: App {
    @NSApplicationDelegateAdaptor(SepsisCareAppDelegate.self) private var appDelegate
    @State private var viewModel = AppViewModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppBrand.configureApplicationIcon()
    }
    
    var body: some Scene {
        WindowGroup(AppBrand.productName) {
            Group {
                if viewModel.isAuthenticated, let role = viewModel.currentRole {
                    RoleRootView(role: role, viewModel: viewModel)
                        .id(role)
                } else {
                    LoginView(viewModel: viewModel)
                }
            }
            .onAppear {
                viewModel.ensureBackendStarted()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    viewModel.ensureBackendStarted()
                }
            }
        }
        .defaultSize(width: 1280, height: 800)

        Window("科研使用文档 · \(AppBrand.productName)", id: "research-docs") {
            DocumentationCenterView(mode: .research)
                .frame(minWidth: 1080, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1180, height: 840)

        Window("后端日志 · \(AppBrand.productName)", id: "backend-logs") {
            BackendLogWindow(backend: viewModel.backend)
                .frame(minWidth: 860, minHeight: 560)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 920, height: 620)
    }
}

struct RoleRootView: View {
    let role: UserRole
    @Bindable var viewModel: AppViewModel
    @State private var showingSettings = false
    
    var body: some View {
        switch role {
        case .research:
            ResearchMainView(viewModel: viewModel, showingSettings: $showingSettings)
        case .family:
            FamilyMainView(viewModel: viewModel, showingSettings: $showingSettings)
        case .admin:
            AdminMainView(viewModel: viewModel, showingSettings: $showingSettings)
        }
    }
}

struct ResearchMainView: View {
    @Bindable var viewModel: AppViewModel
    @Binding var showingSettings: Bool
    @State private var selectedSection: ResearchWorkspaceSection = .overview
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        NavigationSplitView {
            ResearchWorkspaceSidebar(viewModel: viewModel, selectedSection: $selectedSection)
                .navigationTitle("研究端")
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
        } detail: {
            ZStack(alignment: .bottomTrailing) {
                ResearchWorkspaceDetail(selectedSection: $selectedSection, viewModel: viewModel)
                PatientQueueToggle(viewModel: viewModel) {}
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.backend.isReady ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(viewModel.backend.statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if let patient = viewModel.currentAnalysisPatient {
                        Button {
                            selectedSection = .riskBoard
                        } label: {
                            ResearchContextToolbarChip(patient: patient)
                        }
                        .buttonStyle(.plain)
                    }

                    Button("使用文档", systemImage: "book.pages") {
                        openWindow(id: "research-docs")
                    }
                    
                    Button("设置", systemImage: "gear") {
                        showingSettings = true
                    }
                    
                    Button("退出", systemImage: "arrow.right.square") {
                        viewModel.logout()
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: viewModel.settings, backend: viewModel.backend)
        }
        .preferredColorScheme(.dark)
    }
}

private struct ResearchContextToolbarChip: View {
    let patient: Patient

    private var prediction: PredictionResult {
        patient.predictions.last ?? PredictionResult.mock(for: patient)
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "scope")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(riskColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(patient.maskedId)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                Text("\(patient.bedNumber) · \(prediction.riskLevel.displayName)")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous)
                .fill(riskColor.opacity(0.12))
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(riskColor.opacity(0.24), lineWidth: 1)
        }
        .help("当前分析对象。点击进入风险看板。")
    }

    private var riskColor: Color {
        switch prediction.riskLevel {
        case .stable: return .teal
        case .watch: return .orange
        case .critical: return .red
        case .recovering: return .blue
        }
    }
}

struct FamilyMainView: View {
    @Bindable var viewModel: AppViewModel
    @Binding var showingSettings: Bool
    @State private var selectedSection: FamilyWorkspaceSection = .chat
    
    var body: some View {
        NavigationSplitView {
            FamilyWorkspaceSidebar(viewModel: viewModel, selectedSection: $selectedSection)
                .navigationTitle("家属门户")
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 380)
        } detail: {
            ZStack(alignment: .bottomTrailing) {
                FamilyWorkspaceDetail(section: selectedSection, viewModel: viewModel)
                PatientQueueToggle(viewModel: viewModel) {
                    selectedSection = .monitor
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.backend.isReady ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(viewModel.backend.statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    BrandVersionPill(compact: true)
                    
                    Button("设置", systemImage: "gear") {
                        showingSettings = true
                    }
                    
                    Button("退出", systemImage: "arrow.right.square") {
                        viewModel.logout()
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: viewModel.settings, backend: viewModel.backend)
        }
        .preferredColorScheme(.light)
    }
}

struct AdminMainView: View {
    @Bindable var viewModel: AppViewModel
    @Binding var showingSettings: Bool
    @State private var selectedSection: AdminWorkspaceSection = .accounts
    
    var body: some View {
        NavigationSplitView {
            AdminWorkspaceSidebar(selectedSection: $selectedSection)
                .navigationTitle("管理员端")
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 340)
        } detail: {
            AdminWorkspaceDetail(section: selectedSection, viewModel: viewModel)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(viewModel.backend.isReady ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(viewModel.backend.statusText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    BrandVersionPill(compact: true)
                    
                    Button("设置", systemImage: "gear") {
                        showingSettings = true
                    }
                    
                    Button("退出", systemImage: "arrow.right.square") {
                        viewModel.logout()
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(settings: viewModel.settings, backend: viewModel.backend)
        }
        .preferredColorScheme(.dark)
    }
}

struct FamilySidebarView: View {
    @Bindable var viewModel: AppViewModel
    
    var body: some View {
        List {
            Section("当前患者") {
                if let patient = viewModel.selectedPatient {
                    Label("\(patient.bedNumber) \(patient.name)", systemImage: "bed.double")
                } else {
                    Text("未选择患者")
                        .foregroundStyle(.secondary)
                }
            }
            
            Section("患者列表") {
                ForEach(viewModel.patients) { patient in
                    Button {
                        viewModel.selectPatient(patient)
                    } label: {
                        HStack {
                            Image(systemName: "bed.double")
                            VStack(alignment: .leading) {
                                Text("\(patient.bedNumber) \(patient.name)")
                                Text("\(patient.age)岁 · \(patient.sex == 1 ? "男" : "女")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
