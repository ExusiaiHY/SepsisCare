import SwiftUI
import Charts
import WebKit

enum ResearchWorkspaceDesignContract {
    static let historicalMiniChartColumns = 2
    static let overviewProductionSignalCount = 4
    static let riskVisualizationFamilies = ["triageStack", "phenotypeBars", "wardMatrix"]
}

enum ResearchWorkspaceSection: String, CaseIterable, Identifiable {
    case overview
    case riskBoard
    case history
    case modelStatus
    case trainingTerminal
    case clinicalLab
    case diagnosis
    case subtypes
    case clinical
    case aiLab
    case bedside
    case docs
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .overview: return "总览工作台"
        case .riskBoard: return "风险看板"
        case .history: return "历史 ICU 数据库"
        case .modelStatus: return "模型运行状态"
        case .trainingTerminal: return "训练终端"
        case .clinicalLab: return "临床模型实验室"
        case .diagnosis: return "诊断工作台"
        case .subtypes: return "S6 亚型"
        case .clinical: return "临床评分"
        case .aiLab: return "AI 分析"
        case .bedside: return "床旁快照"
        case .docs: return "使用文档"
        }
    }
    
    var subtitle: String {
        switch self {
        case .overview: return "队列、风险、模型摘要"
        case .riskBoard: return "风险分层与表型分布"
        case .history: return "已出院训练队列"
        case .modelStatus: return "后端、DeepSeek、S6 模型"
        case .trainingTerminal: return "云端训练运维"
        case .clinicalLab: return "诊断、S6、评分、床旁"
        case .diagnosis: return "单例/批量诊断 API"
        case .subtypes: return "metadata/predict/recommend"
        case .clinical: return "pipeline 与评分"
        case .aiLab: return "解释、问答、分析"
        case .bedside: return "病床与快照接口"
        case .docs: return "指标、表型、计算逻辑"
        }
    }
    
    var icon: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .riskBoard: return "gauge.with.dots.needle.67percent"
        case .history: return "externaldrive.connected.to.line.below"
        case .modelStatus: return "cpu"
        case .trainingTerminal: return "terminal"
        case .clinicalLab: return "square.grid.2x2"
        case .diagnosis: return "stethoscope"
        case .subtypes: return "point.3.connected.trianglepath.dotted"
        case .clinical: return "checklist.checked"
        case .aiLab: return "sparkles"
        case .bedside: return "bed.double"
        case .docs: return "book.pages"
        }
    }

    static var navigationCases: [ResearchWorkspaceSection] {
        [.overview, .riskBoard, .history, .modelStatus, .trainingTerminal, .clinicalLab, .aiLab]
    }
}

enum FamilyWorkspaceSection: String, CaseIterable, Identifiable {
    case chat
    case monitor
    
    var id: String { rawValue }
    
    var title: String {
        switch self {
        case .chat: return "AI 智能体沟通"
        case .monitor: return "当前患者状态"
        }
    }
    
    var subtitle: String {
        switch self {
        case .chat: return "面向家属的解释问答"
        case .monitor: return "基础状态、体征、摘要"
        }
    }
    
    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .monitor: return "heart.text.square"
        }
    }
}

enum AdminWorkspaceSection: String, CaseIterable, Identifiable {
    case accounts
    case services
    case apiCoverage
    case audit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accounts: return "账号绑定"
        case .services: return "服务监控"
        case .apiCoverage: return "API 覆盖"
        case .audit: return "审计日志"
        }
    }

    var subtitle: String {
        switch self {
        case .accounts: return "家属账号与患者绑定"
        case .services: return "CPU/GPU/后端/DeepSeek"
        case .apiCoverage: return "webapp_v2 接口巡检"
        case .audit: return "本地访问记录"
        }
    }

    var icon: String {
        switch self {
        case .accounts: return "person.badge.key"
        case .services: return "server.rack"
        case .apiCoverage: return "checkmark.seal"
        case .audit: return "doc.text.magnifyingglass"
        }
    }
}

struct ResearchWorkspaceSidebar: View {
    @Bindable var viewModel: AppViewModel
    @Binding var selectedSection: ResearchWorkspaceSection
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarHeader(
                    title: "sepsis",
                    subtitle: "研究端",
                    icon: "waveform.path.ecg.rectangle"
                )
                
                VStack(alignment: .leading, spacing: 8) {
                    SidebarSectionLabel("工作台")
                    ForEach(ResearchWorkspaceSection.navigationCases) { section in
                        SidebarNavButton(
                            title: section.title,
                            subtitle: section.subtitle,
                            icon: section.icon,
                            isSelected: selectedSection == section,
                            accent: AppBrand.signalBlue
                        ) {
                            selectedSection = section
                        }
                    }
                }
            }
            .padding(16)
        }
        .background {
            SidebarChromeBackground(style: .research)
        }
    }
}

struct FamilyWorkspaceSidebar: View {
    @Bindable var viewModel: AppViewModel
    @Binding var selectedSection: FamilyWorkspaceSection
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarHeader(
                    title: "sepsis",
                    subtitle: "家属端",
                    icon: "cross.case"
                )
                
                if let patient = viewModel.selectedPatient {
                    CurrentPatientSidebarSummary(patient: patient)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    SidebarSectionLabel("功能")
                    ForEach(FamilyWorkspaceSection.allCases) { section in
                        SidebarNavButton(
                            title: section.title,
                            subtitle: section.subtitle,
                            icon: section.icon,
                            isSelected: selectedSection == section,
                            accent: AppBrand.familyAqua
                        ) {
                            selectedSection = section
                        }
                    }
                }
            }
            .padding(16)
        }
        .background {
            SidebarChromeBackground(style: .family)
        }
    }
}

struct ResearchWorkspaceDetail: View {
    @Binding var selectedSection: ResearchWorkspaceSection
    @Bindable var viewModel: AppViewModel
    
    var body: some View {
        ZStack {
            BrandPatternBackdrop(style: .research, intensity: 0.42)
                .opacity(0.34)
            content
                .id(selectedSection.id)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
        .animation(.snappy(duration: 0.34, extraBounce: 0.08), value: selectedSection.id)
    }

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .overview:
            ResearchOverviewWorkbenchView(viewModel: viewModel, selectedSection: $selectedSection)
        case .riskBoard:
            ResearchRiskBoardView(viewModel: viewModel)
        case .history:
            HistoricalICUDatabaseView(viewModel: viewModel)
        case .modelStatus:
            ModelRuntimeStatusView(viewModel: viewModel)
        case .trainingTerminal:
            ModelTrainingTerminalView(viewModel: viewModel)
        case .clinicalLab:
            ClinicalModelLabView(viewModel: viewModel)
        case .diagnosis:
            ResearchDiagnosisWorkbenchView(viewModel: viewModel)
        case .subtypes:
            ResearchSubtypeWorkbenchView(viewModel: viewModel)
        case .clinical:
            ResearchClinicalWorkbenchView(viewModel: viewModel)
        case .aiLab:
            ResearchAIWorkbenchView(viewModel: viewModel)
        case .bedside:
            ResearchBedsideWorkbenchView(viewModel: viewModel)
        case .docs:
            DocumentationCenterView(mode: .research)
        }
    }
}

struct FamilyWorkspaceDetail: View {
    let section: FamilyWorkspaceSection
    @Bindable var viewModel: AppViewModel
    
    var body: some View {
        ZStack {
            BrandPatternBackdrop(style: .family, intensity: 0.88)
            content
                .id(section.id)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .animation(.snappy(duration: 0.28, extraBounce: 0.05), value: section.id)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .chat:
            FamilyChatWorkspaceView(viewModel: viewModel)
        case .monitor:
            FamilyPatientStatusView(viewModel: viewModel)
        }
    }
}

private struct SidebarHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    
    var body: some View {
        HStack(spacing: 12) {
            BrandLogoMark(size: 46)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title == "sepsis" ? AppBrand.productName : title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    if title == "sepsis" {
                        BrandVersionPill(compact: true)
                    }
                }
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppBrand.oxygenCyan.opacity(0.82))
            }
        }
    }
}

private struct SidebarSectionLabel: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 2)
    }
}

enum SidebarNavAccessibility {
    static func label(title: String, subtitle: String) -> String {
        "\(title)，\(subtitle)"
    }

    static func value(isSelected: Bool) -> String {
        isSelected ? "已选中" : "未选中"
    }

    static func traits(isSelected: Bool) -> AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : [.isButton]
    }
}

private struct SidebarNavButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let isSelected: Bool
    var accent: Color = AppBrand.signalBlue
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? .white : accent)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? .white.opacity(0.78) : .secondary)
                }
                
                Spacer()
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? accent : Color(nsColor: .controlBackgroundColor).opacity(0.90))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.55) : accent.opacity(0.14), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarNavAccessibility.label(title: title, subtitle: subtitle))
        .accessibilityValue(SidebarNavAccessibility.value(isSelected: isSelected))
        .accessibilityRemoveTraits(.isSelected)
        .accessibilityAddTraits(SidebarNavAccessibility.traits(isSelected: isSelected))
    }
}

private struct SidebarChromeBackground: View {
    let style: BrandBackdropStyle

    var body: some View {
        ZStack {
            switch style {
            case .family:
                Color(nsColor: .windowBackgroundColor)
                BrandPatternBackdrop(style: .family, intensity: 0.36)
                    .opacity(0.78)
            case .admin:
                Color(nsColor: .windowBackgroundColor)
                BrandPatternBackdrop(style: .admin, intensity: 0.32)
                    .opacity(0.34)
            case .login, .research, .docs:
                Color(nsColor: .windowBackgroundColor)
                BrandPatternBackdrop(style: .research, intensity: 0.24)
                    .opacity(0.24)
            }
        }
    }
}

private struct SidebarPatientCard: View {
    let patient: Patient
    let isSelected: Bool
    let action: () -> Void
    
    private var prediction: PredictionResult { patient.predictions.last ?? PredictionResult.mock(for: patient) }
    
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(patient.bedNumber) \(patient.name)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(patient.age)岁 · \(patient.sex == 1 ? "男" : "女") · ICU 监护")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CompactRiskPill(riskLevel: prediction.riskLevel)
                }
                
                HStack(spacing: 12) {
                    MiniValue(label: "MAP", value: "\(Int(patient.vitals.map))")
                    MiniValue(label: "Lac", value: String(format: "%.1f", patient.labs.lactate))
                    MiniValue(label: "SpO2", value: "\(Int(patient.vitals.spo2))%")
                }
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.teal.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.teal.opacity(0.65) : Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct CurrentPatientSidebarSummary: View {
    let patient: Patient
    
    private var prediction: PredictionResult { patient.predictions.last ?? PredictionResult.mock(for: patient) }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SidebarSectionLabel("当前患者")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(patient.bedNumber)
                            .font(.system(size: 18, weight: .bold))
                        Text("\(patient.name) · \(patient.age)岁")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    CompactRiskPill(riskLevel: prediction.riskLevel)
                }
                
                Text(prediction.phenotypeName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.teal)
                
                Text("建议家属查看右侧状态页，具体治疗决策以 ICU 医生说明为准。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
    }
}

private struct MiniValue: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CompactRiskPill: View {
    let riskLevel: RiskLevel
    
    var body: some View {
        Text(riskLevel.displayName)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(riskColor.opacity(0.14))
            .foregroundStyle(riskColor)
            .clipShape(Capsule())
    }
    
    private var riskColor: Color {
        switch riskLevel {
        case .stable: return .teal
        case .watch: return .orange
        case .critical: return .red
        case .recovering: return .blue
        }
    }
}

struct ResearchOverviewWorkbenchView: View {
    @Bindable var viewModel: AppViewModel
    @Binding var selectedSection: ResearchWorkspaceSection
    
    private var predictions: [PredictionResult] {
        viewModel.patients.map { $0.predictions.last ?? PredictionResult.mock(for: $0) }
    }
    
    private var criticalCount: Int {
        predictions.filter { $0.riskLevel == .critical }.count
    }
    
    private var avgLos: Double {
        let values = predictions.map(\.remainingLOSHours)
        return values.reduce(0, +) / Double(max(values.count, 1))
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(
                    title: "总览工作台",
                    subtitle: "研究端入口与运行状态总览：把系统健康、风险分诊、历史数据库、模型实验室分开呈现，避免和风险看板重复。"
                )
                
                LazyVGrid(columns: dashboardColumns, spacing: 14) {
                    WorkspaceMetricTile(title: "后端服务", value: viewModel.backend.isReady ? "在线" : "待连接", subtitle: viewModel.backend.statusText, icon: "server.rack", color: viewModel.backend.isReady ? .green : .orange)
                    WorkspaceMetricTile(title: "当前患者队列", value: "\(viewModel.patients.count)", subtitle: "院内 ICU 当前样本", icon: "person.3.sequence", color: .blue)
                    WorkspaceMetricTile(title: "高风险待核查", value: "\(criticalCount)", subtitle: "进入风险看板逐例查看", icon: "exclamationmark.triangle", color: .red)
                    WorkspaceMetricTile(title: "平均预估 ICU", value: "\(Int(avgLos))h", subtitle: "模型估计剩余时间", icon: "clock.badge.checkmark", color: .purple)
                }

                ProductionReadinessStripView(signals: productionSignals)
                
                HStack(alignment: .top, spacing: 16) {
                    WorkbenchSection(title: "主流程入口", icon: "rectangle.grid.2x2") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            OverviewRouteCard(title: "历史 ICU 数据库", subtitle: "已出院训练队列、分钟级趋势、预测一致性自分类", icon: "externaldrive.connected.to.line.below", color: .blue) {
                                selectedSection = .history
                            }
                            OverviewRouteCard(title: "风险看板", subtitle: "高风险患者排序、病区/表型聚合、实时详情下钻", icon: "gauge.with.dots.needle.67percent", color: .red) {
                                selectedSection = .riskBoard
                            }
                            OverviewRouteCard(title: "临床模型实验室", subtitle: "诊断、S6 亚型、临床评分、床旁快照集合入口", icon: "square.grid.2x2", color: .green) {
                                selectedSection = .clinicalLab
                            }
                            OverviewRouteCard(title: "模型运行状态", subtitle: "后端、设备、DeepSeek、模型指标与 API 状态", icon: "cpu", color: .purple) {
                                selectedSection = .modelStatus
                            }
                        }
                    }
                    
                    WorkbenchSection(title: "运行状态摘要", icon: "dot.radiowaves.left.and.right") {
                        VStack(alignment: .leading, spacing: 12) {
                            OverviewHealthLine(label: "server.py", value: viewModel.backend.isReady ? "已连接" : "等待连接", detail: viewModel.backend.statusText, color: viewModel.backend.isReady ? .green : .orange)
                            OverviewHealthLine(label: "DeepSeek", value: "deepseek-v4-flash", detail: "家属端问答与研究端 AI 实验室共用配置", color: .teal)
                            OverviewHealthLine(label: "历史库", value: "分页懒加载", detail: "训练数据替代已出院 ICU 数据，详情页按需加载", color: .blue)
                            OverviewHealthLine(label: "风险下钻", value: "已启用", detail: "点击高风险患者进入实时监控详情", color: .red)
                        }
                    }
                }

                RoleVisualIdentityGrid()

                WorkbenchSection(title: "最近患者快照", icon: "person.text.rectangle") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(Array(viewModel.patients.prefix(8))) { patient in
                            PatientWorkbenchRow(patient: patient) {
                                viewModel.selectPatient(patient)
                                selectedSection = .riskBoard
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private var productionSignals: [ProductionReadinessSignal] {
        [
            ProductionReadinessSignal(
                title: "远程 API",
                value: viewModel.backend.isReady ? "已连通" : "待巡检",
                detail: SepsisCareAPI.defaultBaseURL,
                icon: "network",
                color: viewModel.backend.isReady ? AppBrand.recoveryGreen : AppBrand.lactateAmber
            ),
            ProductionReadinessSignal(
                title: "S7 模型",
                value: "远端优先",
                detail: "S7 + DeepSeek v4 flash",
                icon: "brain.head.profile",
                color: AppBrand.signalBlue
            ),
            ProductionReadinessSignal(
                title: "历史库",
                value: "懒加载",
                detail: "列表/详情/CSV 分层",
                icon: "externaldrive.connected.to.line.below",
                color: AppBrand.oxygenCyan
            ),
            ProductionReadinessSignal(
                title: "测试入口",
                value: "可回归",
                detail: "build / smoke / bundle",
                icon: "checkmark.seal",
                color: AppBrand.phenotypeViolet
            )
        ]
    }
}

private struct ProductionReadinessSignal: Identifiable {
    var id: String { title }
    let title: String
    let value: String
    let detail: String
    let icon: String
    let color: Color
}

private struct ProductionReadinessStripView: View {
    let signals: [ProductionReadinessSignal]

    var body: some View {
        WorkbenchSection(title: "生产收尾信号", icon: "checklist.checked") {
            LazyVGrid(columns: signalColumns, spacing: 12) {
                ForEach(signals) { signal in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 9) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(signal.color.opacity(0.16))
                                    .frame(width: 34, height: 34)
                                Image(systemName: signal.icon)
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(signal.color)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(signal.title)
                                    .font(.system(size: 12, weight: .bold))
                                Text(signal.value)
                                    .font(.system(size: 15, weight: .bold, design: .rounded))
                                    .foregroundStyle(signal.color)
                            }
                        }
                        Text(signal.detail)
                            .font(.system(size: 10, weight: .medium, design: signal.detail.contains("http") ? .monospaced : .default))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                    }
                    .padding(12)
                    .frame(minHeight: 108, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(signal.color.opacity(0.08))
                    }
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(signal.color.opacity(0.34))
                            .frame(height: 2)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("生产收尾信号")
    }

    private var signalColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 150), spacing: 12),
            count: ResearchWorkspaceDesignContract.overviewProductionSignalCount
        )
    }
}

private struct RoleVisualIdentityGrid: View {
    private let identities: [RoleIdentity] = [
        RoleIdentity(role: "研究端", density: "高密度", accent: AppBrand.signalBlue, support: AppBrand.oxygenCyan, icon: "waveform.path.ecg.rectangle", note: "深色工作台、风险看板、历史库图表"),
        RoleIdentity(role: "家属端", density: "低密度", accent: AppBrand.familyAqua, support: AppBrand.recoveryGreen, icon: "bubble.left.and.bubble.right", note: "浅色解释、状态摘要、AI 沟通"),
        RoleIdentity(role: "管理员端", density: "运维密度", accent: AppBrand.adminGold, support: AppBrand.phenotypeViolet, icon: "server.rack", note: "服务巡检、绑定、API 覆盖")
    ]

    var body: some View {
        WorkbenchSection(title: "角色视觉系统", icon: "paintpalette") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(identities) { item in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(item.accent.opacity(0.18))
                                    .frame(width: 38, height: 38)
                                Image(systemName: item.icon)
                                    .foregroundStyle(item.accent)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.role)
                                    .font(.system(size: 14, weight: .bold))
                                Text(item.density)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(item.accent)
                            }
                        }

                        HStack(spacing: 6) {
                            ColorSwatch(color: item.accent, label: "主色")
                            ColorSwatch(color: item.support, label: "辅助")
                            ColorSwatch(color: AppBrand.lactateAmber, label: "预警")
                            ColorSwatch(color: AppBrand.sepsisRed, label: "危重")
                        }

                        Text(item.note)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.88))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(item.accent.opacity(0.22), lineWidth: 1)
                    }
                }
            }
        }
    }
}

private struct RoleIdentity: Identifiable {
    var id: String { role }
    let role: String
    let density: String
    let accent: Color
    let support: Color
    let icon: String
    let note: String
}

private struct ColorSwatch: View {
    let color: Color
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
                .frame(height: 12)
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help(label)
    }
}

private struct OverviewRouteCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(color)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(minHeight: 124, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct OverviewHealthLine: View {
    let label: String
    let value: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(label)
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text(value)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
    }
}

struct ResearchRiskBoardView: View {
    @Bindable var viewModel: AppViewModel
    
    private var riskRows: [RiskBoardRow] {
        viewModel.patients.map { patient in
            let prediction = patient.predictions.last ?? PredictionResult.mock(for: patient)
            return RiskBoardRow(patient: patient, prediction: prediction)
        }
    }

    private var sortedRiskRows: [RiskBoardRow] {
        riskRows.sorted {
            if $0.prediction.riskLevel == $1.prediction.riskLevel {
                return $0.prediction.mortalityProbability > $1.prediction.mortalityProbability
            }
            return riskSortRank($0.prediction.riskLevel) > riskSortRank($1.prediction.riskLevel)
        }
    }

    private var selectedRow: RiskBoardRow? {
        if let selectedPatient = viewModel.selectedPatient,
           let row = riskRows.first(where: { $0.patient.id == selectedPatient.id }) {
            return row
        }
        return sortedRiskRows.first
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: "风险看板", subtitle: "聚焦患者风险分诊：点击高风险队列进入实时监控详情，死亡风险不再使用拥挤条形图展示。")
                
                LazyVGrid(columns: dashboardColumns, spacing: 14) {
                    WorkspaceMetricTile(title: "危重占比", value: "\(criticalPercentage)%", subtitle: "按当前模型输出", icon: "waveform.path.ecg", color: .red)
                    WorkspaceMetricTile(title: "最高死亡风险", value: "\(maxMortality)%", subtitle: selectedRow?.patient.bedNumber ?? "队列最大值", icon: "heart.text.square", color: .red)
                    WorkspaceMetricTile(title: "机械通气均值", value: "\(avgVentilation)%", subtitle: "next MV probability", icon: "lungs", color: .orange)
                    WorkspaceMetricTile(title: "表型数", value: "\(Set(riskRows.map { $0.prediction.phenotypeId }).count)", subtitle: "P0-P3 当前覆盖", icon: "dna", color: .teal)
                }

                RiskAcuityStackChart(segments: riskAcuitySegments, total: riskRows.count)

                if let selectedRow {
                    RiskTriageInsightView(row: selectedRow)
                }
                
                HStack(alignment: .top, spacing: 16) {
                    WorkbenchSection(title: "高风险患者队列", icon: "list.number") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("按风险等级和死亡风险排序，点击后在右侧查看当前患者详情。")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            ForEach(Array(sortedRiskRows.prefix(14))) { row in
                                RiskBoardPatientRow(
                                    row: row,
                                    isSelected: selectedRow?.patient.id == row.patient.id
                                ) {
                                    viewModel.selectPatient(row.patient)
                                }
                            }
                        }
                    }

                    if let selectedRow {
                        RealtimePatientMonitorView(
                            patient: selectedRow.patient,
                            initialPrediction: selectedRow.prediction,
                            viewModel: viewModel
                        )
                    }
                }

                if let selectedRow {
                    RealtimeTrendCard(patient: selectedRow.patient)
                }

                HStack(alignment: .top, spacing: 16) {
                    WorkbenchSection(title: "表型分布", icon: "chart.pie") {
                        VStack(spacing: 12) {
                            ForEach(phenotypeDistribution, id: \.name) { item in
                                DistributionProgressRow(
                                    label: item.name,
                                    value: item.count,
                                    total: max(viewModel.patients.count, 1),
                                    color: phenotypeColor(item.name)
                                )
                            }
                        }
                    }

                    WorkbenchSection(title: "病区风险聚合", icon: "building.2") {
                        WardRiskMatrixView(items: wardRiskDistribution)
                    }
                }
            }
            .padding(24)
        }
    }
    
    private var criticalPercentage: Int {
        Int(Double(riskRows.filter { $0.prediction.riskLevel == .critical }.count) / Double(max(riskRows.count, 1)) * 100)
    }
    
    private var maxMortality: Int {
        Int((riskRows.map { $0.prediction.mortalityProbability }.max() ?? 0) * 100)
    }
    
    private var avgVentilation: Int {
        Int(riskRows.map { $0.prediction.nextMVProbability }.reduce(0, +) / Double(max(riskRows.count, 1)) * 100)
    }
    
    private var phenotypeDistribution: [(name: String, count: Int)] {
        Dictionary(grouping: riskRows, by: { $0.prediction.phenotypeName })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.name < $1.name }
    }

    private var riskAcuitySegments: [RiskAcuitySegment] {
        var cursor = 0
        let orderedLevels: [RiskLevel] = [.critical, .watch, .stable, .recovering]
        return orderedLevels.compactMap { level in
            let count = riskRows.filter { $0.prediction.riskLevel == level }.count
            guard count > 0 else { return nil }
            let segment = RiskAcuitySegment(
                riskLevel: level,
                count: count,
                start: cursor,
                end: cursor + count,
                total: max(riskRows.count, 1)
            )
            cursor += count
            return segment
        }
    }

    private var wardRiskDistribution: [WardRiskSummary] {
        Dictionary(grouping: riskRows, by: { $0.patient.icuWard })
            .map { ward, rows in
                WardRiskSummary(
                    ward: ward,
                    critical: rows.filter { $0.prediction.riskLevel == .critical }.count,
                    watch: rows.filter { $0.prediction.riskLevel == .watch }.count,
                    total: rows.count
                )
            }
            .sorted { $0.critical == $1.critical ? $0.ward < $1.ward : $0.critical > $1.critical }
    }
}

struct ModelRuntimeStatusView: View {
    @Bindable var viewModel: AppViewModel
    @State private var deploymentConfig: DeploymentConfigResponse?
    @State private var metadata: ModelMetadata?
    @State private var errorMessage = ""
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: "模型运行状态", subtitle: "复刻 webapp_v2 的系统配置、AI 配置、预测模块目录和模型指标状态。")
                
                LazyVGrid(columns: dashboardColumns, spacing: 14) {
                    WorkspaceMetricTile(title: "本地后端", value: viewModel.backend.isReady ? "在线" : "连接中", subtitle: viewModel.backend.statusText, icon: "server.rack", color: viewModel.backend.isReady ? .teal : .orange)
                    WorkspaceMetricTile(title: "LLM Provider", value: deploymentConfig?.llm_provider ?? "--", subtitle: deploymentConfig?.llm_model ?? "等待后端配置", icon: "sparkles", color: .blue)
                    WorkspaceMetricTile(title: "设备", value: deploymentConfig?.device_resolved ?? "--", subtitle: deploymentConfig?.backend_mode ?? "local", icon: "cpu", color: .teal)
                    WorkspaceMetricTile(title: "模型版本", value: deploymentConfig?.model_release ?? "20260516", subtitle: metadata?.app_model ?? "SepsisCare Studio", icon: "shippingbox", color: .purple)
                }
                
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }
                
                HStack(alignment: .top, spacing: 16) {
                    WorkbenchSection(title: "预测模块目录", icon: "square.stack.3d.up") {
                        VStack(spacing: 10) {
                            ModelModuleRow(name: "单患者表型诊断", endpoint: "/api/model/predict", status: "macOS 已接入")
                            ModelModuleRow(name: "家属 AI 智能体", endpoint: "/api/family/chat", status: deploymentConfig?.llm_configured == true ? "DeepSeek 已配置" : "Fallback")
                            ModelModuleRow(name: "部署配置", endpoint: "/api/deployment/config", status: "已接入")
                            ModelModuleRow(name: "模型元数据", endpoint: "/api/model/metadata", status: metadata == nil ? "等待读取" : "已读取")
                            ModelModuleRow(name: "ICU 流式样本", endpoint: "/api/icu/stream/next", status: "后端可用")
                        }
                    }
                    
                    WorkbenchSection(title: "模型指标", icon: "chart.xyaxis.line") {
                        VStack(spacing: 12) {
                            RuntimeMetricRow(label: "Encoder Macro-F1", value: metadata?.metrics.encoder_macro_f1)
                            RuntimeMetricRow(label: "Transition Macro-F1", value: metadata?.metrics.encoder_transition_macro_f1)
                            RuntimeMetricRow(label: "Mortality AUROC", value: metadata?.metrics.mortality_auroc)
                            RuntimeMetricRow(label: "Next MV AUROC", value: metadata?.metrics.next_mv_auroc)
                            RuntimeMetricRow(label: "LOS MAE Hours", value: metadata?.metrics.remaining_los_mae_hours, digits: 1)
                        }
                    }
                }
            }
            .padding(24)
        }
        .task {
            await loadRuntimeState()
        }
    }
    
    private func loadRuntimeState() async {
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            async let config = viewModel.apiClient.getDeploymentConfig()
            async let modelMetadata = viewModel.apiClient.getModelMetadata()
            deploymentConfig = try await config
            metadata = try await modelMetadata
            errorMessage = ""
        } catch {
            errorMessage = "暂时无法读取后端状态：\(error)"
        }
    }
}

private struct TrainingTerminalQuickAction: Identifiable {
    let id: String
    let title: String
    let icon: String
    let color: Color
    let shortcut: Character
}

struct ModelTrainingTerminalView: View {
    @Bindable var viewModel: AppViewModel
    @State private var status: TrainingTerminalStatusResponse?
    @State private var cloudBaseURL = ""
    @State private var selectedMode = "demo"
    @State private var customCommand = ""
    @State private var output = "训练终端已就绪。演示模式不会执行本机 shell；生产模式会把指令转发到配置的云端训练服务。"
    @State private var isLoading = false
    @State private var errorMessage = ""
    @State private var realtimeStatus: ICURealtimeStatusResponse?
    @State private var realtimeDemoPayload: JSONValue?
    @State private var realtimeOutput = "实时 ICU 数据接入尚未操作。"
    @State private var realtimeError = ""
    @State private var isRealtimeLoading = false

    private let actions: [TrainingTerminalQuickAction] = [
        .init(id: "update_database", title: "更新数据库", icon: "externaldrive.badge.arrowtriangle.2.circlepath", color: .teal, shortcut: "1"),
        .init(id: "continue_training", title: "继续训练", icon: "play.circle.fill", color: .green, shortcut: "2"),
        .init(id: "pause_training", title: "暂停训练", icon: "pause.circle.fill", color: .orange, shortcut: "3"),
        .init(id: "download_artifacts", title: "下载成果", icon: "square.and.arrow.down", color: .blue, shortcut: "4"),
        .init(id: "stream_metrics", title: "日志指标", icon: "waveform.path.ecg", color: .cyan, shortcut: "5"),
        .init(id: "switch_mode", title: "切换模式", icon: "arrow.triangle.2.circlepath", color: .purple, shortcut: "6"),
        .init(id: "reset_params", title: "重置参数", icon: "arrow.counterclockwise", color: .red, shortcut: "7"),
        .init(id: "sync_config", title: "同步配置", icon: "arrow.up.arrow.down.circle", color: .indigo, shortcut: "8"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: "机器学习模型训练终端", subtitle: "内置演示/生产双模式训练运维入口：本地客户端下发指令，云端训练服务执行并回传日志。")

                LazyVGrid(columns: dashboardColumns, spacing: 14) {
                    WorkspaceMetricTile(title: "调用模式", value: status?.mode_label ?? modeTitle(selectedMode), subtitle: status?.model_profile ?? "local_demo", icon: "switch.2", color: selectedMode == "production" ? .orange : .teal)
                    WorkspaceMetricTile(title: "训练状态", value: statusText, subtitle: status?.last_action ?? "initialized", icon: "dot.radiowaves.left.and.right", color: statusColor)
                    WorkspaceMetricTile(title: "Loss", value: metricString("loss"), subtitle: "epoch \(metricString("epoch", digits: 0))/\(paramString("epochs"))", icon: "chart.line.downtrend.xyaxis", color: .blue)
                    WorkspaceMetricTile(title: "Accuracy", value: metricString("accuracy"), subtitle: "macro_f1 \(metricString("macro_f1"))", icon: "target", color: .green)
                }

                WorkbenchSection(title: "模式与云端地址", icon: "server.rack") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("调用模式", selection: $selectedMode) {
                            Text("本地演示模型").tag("demo")
                            Text("云端生产模型").tag("production")
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 10) {
                            TextField("云端训练服务地址，例如 http://100.65.136.96:8788", text: $cloudBaseURL)
                                .textFieldStyle(.roundedBorder)
                            Button("保存配置", systemImage: "tray.and.arrow.down") {
                                Task { await saveConfig() }
                            }
                            .keyboardShortcut("s", modifiers: [.command])
                        }

                        Text(status?.notice ?? modeNotice)
                            .font(.system(size: 12))
                            .foregroundStyle(selectedMode == "production" && cloudBaseURL.isEmpty ? .orange : .secondary)
                            .lineSpacing(3)
                    }
                }

                WorkbenchSection(title: "实时 ICU 数据接入", icon: "waveform.path.ecg.rectangle") {
                    VStack(alignment: .leading, spacing: 12) {
                        LazyVGrid(columns: dashboardColumns, spacing: 10) {
                            WorkspaceMetricTile(title: "本地事件", value: "\(realtimeStatus?.total_events ?? 0)", subtitle: realtimeStatus?.storage ?? "未刷新", icon: "externaldrive", color: .teal)
                            WorkspaceMetricTile(title: "云端接收", value: realtimeUploadNumber("cloud_accepted"), subtitle: realtimeUploadString("endpoint", fallback: "等待上传"), icon: "icloud.and.arrow.up", color: .blue)
                            WorkspaceMetricTile(title: "训练就绪", value: realtimeUploadBool("training_ready"), subtitle: "新时序事件", icon: "brain.head.profile", color: realtimeUploadReadyColor)
                            WorkspaceMetricTile(title: "最近记录", value: realtimeLastRecordID, subtitle: "脱敏 record_id", icon: "waveform.path.ecg", color: .purple)
                        }

                        HStack(spacing: 10) {
                            Button("刷新状态", systemImage: "arrow.clockwise") {
                                Task { await loadRealtimeStatus() }
                            }
                            Button("载入 Demo", systemImage: "doc.text.magnifyingglass") {
                                Task { await loadRealtimeDemo() }
                            }
                            Button("记录本地", systemImage: "tray.and.arrow.down") {
                                Task { await ingestRealtimeDemo() }
                            }
                            Button("上传云端", systemImage: "icloud.and.arrow.up") {
                                Task { await uploadRealtimeEvents() }
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if isRealtimeLoading {
                            ProgressView("正在处理 ICU 时序接入 ...")
                        }

                        if !realtimeError.isEmpty {
                            Text(realtimeError)
                                .font(.system(size: 13))
                                .foregroundStyle(.red)
                        }

                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Demo Payload")
                                    .font(.headline)
                                ScrollView {
                                    Text(realtimeDemoPayload?.description ?? "点击“载入 Demo”读取院内监护接口示例。")
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .frame(minHeight: 180, maxHeight: 240)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("接入回显")
                                    .font(.headline)
                                ScrollView {
                                    Text(realtimeOutput)
                                        .font(.system(size: 11, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .frame(minHeight: 180, maxHeight: 240)
                            }
                        }
                    }
                }

                WorkbenchSection(title: "快捷训练操作", icon: "command") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(actions) { action in
                            TrainingTerminalActionButton(action: action) {
                                Task { await runAction(action.id) }
                            }
                        }
                    }
                }

                WorkbenchSection(title: "自定义训练指令", icon: "terminal") {
                    HStack(spacing: 10) {
                        TextField("例如 status、train --resume、show metrics、download artifacts", text: $customCommand)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await sendCommand() } }
                        Button("下发", systemImage: "paperplane.fill") {
                            Task { await sendCommand() }
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                    }
                }

                if isLoading {
                    ProgressView("正在等待训练终端返回 ...")
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                WorkbenchSection(title: "终端实时回显", icon: "curlybraces") {
                    ScrollView {
                        Text(output)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(minHeight: 320, alignment: .topLeading)
                }
            }
            .padding(24)
        }
        .task {
            await loadStatus()
            await loadRealtimeStatus()
        }
    }

    private var statusText: String {
        switch status?.task_status ?? "idle" {
        case "running": return "运行中"
        case "paused": return "已暂停"
        case "synced": return "已同步"
        case "error": return "异常"
        default: return "待命"
        }
    }

    private var statusColor: Color {
        switch status?.task_status ?? "idle" {
        case "running": return .green
        case "paused": return .orange
        case "error": return .red
        default: return .teal
        }
    }

    private var modeNotice: String {
        selectedMode == "production"
        ? "生产模式要求云端算力服务器已部署模型服务；免费轻量服务器适合演示控制流，不适合长时间大模型训练。"
        : "演示模式使用安装包内置数据和本地模型占位，适合课程答辩，不会消耗云端算力。"
    }

    private var realtimeUploadObject: [String: JSONValue] {
        guard case .object(let value) = realtimeStatus?.upload else { return [:] }
        return value
    }

    private var realtimeLastEventObject: [String: JSONValue] {
        guard case .object(let value) = realtimeStatus?.last_event else { return [:] }
        return value
    }

    private var realtimeLastRecordID: String {
        realtimeJSONText(realtimeLastEventObject["record_id"], fallback: "无记录")
    }

    private var realtimeUploadReadyColor: Color {
        realtimeUploadBool("training_ready") == "是" ? .green : .orange
    }

    private func realtimeUploadString(_ key: String, fallback: String) -> String {
        realtimeJSONText(realtimeUploadObject[key], fallback: fallback)
    }

    private func realtimeUploadNumber(_ key: String) -> String {
        realtimeJSONText(realtimeUploadObject[key], fallback: "0")
    }

    private func realtimeUploadBool(_ key: String) -> String {
        guard case .bool(let value) = realtimeUploadObject[key] else { return "否" }
        return value ? "是" : "否"
    }

    private func realtimeJSONText(_ value: JSONValue?, fallback: String) -> String {
        switch value {
        case .string(let text):
            return text.isEmpty ? fallback : text
        case .number(let number):
            return number.rounded() == number ? String(Int(number)) : String(format: "%.2f", number)
        case .bool(let value):
            return value ? "是" : "否"
        case .object, .array:
            return value?.description ?? fallback
        case .null, nil:
            return fallback
        }
    }

    private func loadStatus() async {
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let value = try await viewModel.apiClient.getTrainingTerminalStatus()
            applyStatus(value)
            errorMessage = ""
        } catch {
            errorMessage = "读取训练终端状态失败：\(error)"
        }
    }

    private func loadRealtimeStatus() async {
        await runRealtimeCall {
            let value = try await viewModel.apiClient.getICURealtimeStatus()
            realtimeStatus = value
            return [
                "实时 ICU 状态已刷新。",
                "total_events=\(value.total_events)",
                "storage=\(value.storage)",
                "upload=\(value.upload?.description ?? "{}")"
            ]
        }
    }

    private func loadRealtimeDemo() async {
        await runRealtimeCall {
            let value = try await viewModel.apiClient.getICURealtimeDemo()
            realtimeDemoPayload = value.demo
            realtimeStatus = value.status
            return [
                "已载入院内 ICU 监护 demo payload。",
                value.demo.description
            ]
        }
    }

    private func ingestRealtimeDemo() async {
        await runRealtimeCall {
            var payload = realtimeDemoPayload
            if payload == nil {
                let demo = try await viewModel.apiClient.getICURealtimeDemo()
                realtimeDemoPayload = demo.demo
                realtimeStatus = demo.status
                payload = demo.demo
            }
            guard let payload else { return ["未取得 demo payload。"] }
            let value = try await viewModel.apiClient.postICURealtimeIngest(payload: payload)
            realtimeStatus = value.status
            return [
                "已把 demo ICU 时序写入本地记录。",
                "accepted=\(value.accepted)",
                "storage=\(value.storage)",
                "latest_prediction=\(value.latest_prediction?.description ?? "{}")"
            ]
        }
    }

    private func uploadRealtimeEvents() async {
        await runRealtimeCall {
            let value = try await viewModel.apiClient.postICURealtimeUpload(cloudBaseURL: cloudBaseURL)
            realtimeStatus = value.status
            if value.ok == false {
                realtimeError = value.error ?? "ICU 时序上传失败"
            }
            return value.output + [
                "cloud_response=\(value.cloud_response?.description ?? "{}")"
            ]
        }
    }

    private func runRealtimeCall(_ operation: @escaping () async throws -> [String]) async {
        isRealtimeLoading = true
        realtimeError = ""
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let lines = try await operation()
            realtimeOutput = lines.joined(separator: "\n")
        } catch {
            realtimeError = "实时 ICU 接入调用失败：\(error)"
        }
        isRealtimeLoading = false
    }

    private func saveConfig() async {
        await runTerminalCall {
            let value = try await viewModel.apiClient.postTrainingTerminalConfig(mode: selectedMode, cloudBaseURL: cloudBaseURL)
            applyStatus(value)
            return ["[\(value.updated_at)] 配置已保存。", value.notice]
        }
    }

    private func runAction(_ action: String) async {
        await runTerminalCall {
            let response = try await viewModel.apiClient.postTrainingTerminalAction(action)
            applyStatus(response.status)
            if response.ok == false {
                errorMessage = response.error ?? "训练终端动作失败"
            }
            return response.output
        }
    }

    private func sendCommand() async {
        let command = customCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        await runTerminalCall {
            let response = try await viewModel.apiClient.postTrainingTerminalCommand(command)
            applyStatus(response.status)
            customCommand = ""
            if response.ok == false {
                errorMessage = response.error ?? "训练终端指令失败"
            }
            return response.output
        }
    }

    private func runTerminalCall(_ operation: @escaping () async throws -> [String]) async {
        isLoading = true
        errorMessage = ""
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let lines = try await operation()
            output = lines.joined(separator: "\n")
        } catch {
            errorMessage = "训练终端调用失败：\(error)"
        }
        isLoading = false
    }

    private func applyStatus(_ value: TrainingTerminalStatusResponse) {
        status = value
        selectedMode = value.mode
        cloudBaseURL = displayCloudBaseURL(value.cloud_base_url)
    }

    private func displayCloudBaseURL(_ value: String) -> String {
        let normalized = SepsisCareAPI.normalizedBaseURL(value)
        guard let url = URL(string: normalized),
              let host = url.host?.lowercased(),
              (host == "127.0.0.1" || host == "localhost" || host == "::1"),
              viewModel.settings.usesLocalAPIBaseURL == false else {
            return normalized
        }
        return viewModel.settings.apiBaseURL
    }

    private func metricString(_ key: String, digits: Int = 3) -> String {
        stringValue(status?.metrics[key], digits: digits)
    }

    private func paramString(_ key: String) -> String {
        stringValue(status?.params[key], digits: 0)
    }

    private func stringValue(_ value: JSONValue?, digits: Int) -> String {
        guard let value else { return "--" }
        switch value {
        case .number(let number):
            if digits == 0 { return String(Int(number.rounded())) }
            return String(format: "%.\(digits)f", number)
        case .string(let text):
            return text.isEmpty ? "--" : text
        case .bool(let flag):
            return flag ? "true" : "false"
        default:
            return "--"
        }
    }

    private func modeTitle(_ mode: String) -> String {
        mode == "production" ? "云端生产模式" : "本地演示模式"
    }
}

private struct TrainingTerminalActionButton: View {
    let action: TrainingTerminalQuickAction
    let perform: () -> Void

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                Image(systemName: action.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(action.color)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text("⌘\(String(action.shortcut))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(13)
            .frame(minHeight: 64)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(action.color.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(action.shortcut), modifiers: [.command])
    }
}

struct ResearchDiagnosisWorkbenchView: View {
    @Bindable var viewModel: AppViewModel
    @State private var output = "选择一个操作后，这里会显示 server.py 返回的 JSON。"
    @State private var isLoading = false
    @State private var errorMessage = ""

    var body: some View {
        ResearchAPIWorkbenchShell(
            title: "诊断工作台",
            subtitle: "复刻 /api/diagnose 与 /api/diagnose/batch，支持当前患者单例诊断和当前队列批量诊断。",
            output: output,
            isLoading: isLoading,
            errorMessage: errorMessage
        ) {
            APIRunButton(title: "单患者诊断", icon: "stethoscope", color: .red) {
                await run {
                    guard let patient = viewModel.currentAnalysisPatient else { return .string("无患者") }
                    return try await viewModel.apiClient.postDiagnose(patient: patient)
                }
            }
            APIRunButton(title: "批量诊断", icon: "square.stack.3d.up", color: .orange) {
                await run {
                    try await viewModel.apiClient.postDiagnoseBatch(patients: Array(viewModel.patients.prefix(8)))
                }
            }
            APIRunButton(title: "诊断特征", icon: "list.bullet.clipboard", color: .teal) {
                await run {
                    try await viewModel.apiClient.getDiagnoseFeatures()
                }
            }
        }
    }

    private func run(_ operation: @escaping () async throws -> JSONValue) async {
        isLoading = true
        errorMessage = ""
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let value = try await operation()
            output = value.description
        } catch {
            errorMessage = "调用失败：\(error)"
        }
        isLoading = false
    }
}

struct ResearchSubtypeWorkbenchView: View {
    @Bindable var viewModel: AppViewModel
    @State private var output = "S6 亚型接口输出会显示在这里。"
    @State private var isLoading = false
    @State private var errorMessage = ""

    var body: some View {
        ResearchAPIWorkbenchShell(
            title: "S6 亚型",
            subtitle: "复刻 /api/sepsis-subtypes/metadata、predict、recommend，用于研究端查看表型家族和推荐输出。",
            output: output,
            isLoading: isLoading,
            errorMessage: errorMessage
        ) {
            APIRunButton(title: "元数据", icon: "info.circle", color: .blue) {
                await run { try await viewModel.apiClient.getSubtypeMetadata() }
            }
            APIRunButton(title: "预测", icon: "point.3.connected.trianglepath.dotted", color: .purple) {
                await run {
                    guard let patient = viewModel.currentAnalysisPatient else { return .string("无患者") }
                    return try await viewModel.apiClient.postSubtypePredict(patient: patient)
                }
            }
            APIRunButton(title: "推荐", icon: "wand.and.stars", color: .orange) {
                await run {
                    guard let patient = viewModel.currentAnalysisPatient else { return .string("无患者") }
                    return try await viewModel.apiClient.postSubtypeRecommend(patient: patient)
                }
            }
        }
    }

    private func run(_ operation: @escaping () async throws -> JSONValue) async {
        isLoading = true
        errorMessage = ""
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let value = try await operation()
            output = value.description
        } catch {
            errorMessage = "调用失败：\(error)"
        }
        isLoading = false
    }
}

struct ResearchClinicalWorkbenchView: View {
    @Bindable var viewModel: AppViewModel
    @State private var output = "临床评分和 pipeline 输出会显示在这里。"
    @State private var isLoading = false
    @State private var errorMessage = ""

    var body: some View {
        ResearchAPIWorkbenchShell(
            title: "临床评分",
            subtitle: "复刻 /api/clinical/pipeline 与 /api/clinical/scores，输出 SOFA/qSOFA/SIRS/NEWS 和休克评估。",
            output: output,
            isLoading: isLoading,
            errorMessage: errorMessage
        ) {
            APIRunButton(title: "Pipeline", icon: "arrow.triangle.branch", color: .green) {
                await run {
                    guard let patient = viewModel.currentAnalysisPatient else { return .string("无患者") }
                    return try await viewModel.apiClient.postClinicalPipeline(patient: patient)
                }
            }
            APIRunButton(title: "评分计算", icon: "checklist.checked", color: .teal) {
                await run {
                    guard let patient = viewModel.currentAnalysisPatient else { return .string("无患者") }
                    return try await viewModel.apiClient.postClinicalScores(patient: patient)
                }
            }
        }
    }

    private func run(_ operation: @escaping () async throws -> JSONValue) async {
        isLoading = true
        errorMessage = ""
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let value = try await operation()
            output = value.description
        } catch {
            errorMessage = "调用失败：\(error)"
        }
        isLoading = false
    }
}

struct ResearchAIWorkbenchView: View {
    @Bindable var viewModel: AppViewModel
    @State private var output = "AI 分析、解释和助手问答输出会显示在这里。"
    @State private var isLoading = false
    @State private var errorMessage = ""

    var body: some View {
        ResearchAPIWorkbenchShell(
            title: "AI 分析",
            subtitle: "复刻 /api/ai/analysis、/api/ai/explain、/api/ai/assistant-chat 与 /api/ai/llm-diagnose，仅研究端可见。",
            output: output,
            isLoading: isLoading,
            errorMessage: errorMessage
        ) {
            APIRunButton(title: "模型分析", icon: "chart.xyaxis.line", color: .blue) {
                await run { try await viewModel.apiClient.getAIAnalysis() }
            }
            APIRunButton(title: "术语解释", icon: "text.book.closed", color: .teal) {
                await run { try await viewModel.apiClient.postAIExplain(term: "SOFA评分", context: "脓毒症器官功能评估") }
            }
            APIRunButton(title: "助手问答", icon: "bubble.left.and.bubble.right", color: .purple) {
                await run { try await viewModel.apiClient.postAssistantChat(question: "乳酸升高时研究端应该重点查看哪些趋势？") }
            }
            APIRunButton(title: "LLM诊断", icon: "sparkles", color: .orange) {
                await run {
                    guard let patient = viewModel.currentAnalysisPatient else { return .string("无患者") }
                    return try await viewModel.apiClient.postLLMDiagnose(patient: patient)
                }
            }
        }
    }

    private func run(_ operation: @escaping () async throws -> JSONValue) async {
        isLoading = true
        errorMessage = ""
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let value = try await operation()
            output = value.description
        } catch {
            errorMessage = "调用失败：\(error)"
        }
        isLoading = false
    }
}

struct ResearchBedsideWorkbenchView: View {
    @Bindable var viewModel: AppViewModel
    @State private var output = "床旁 beds/snapshot 与家属报告输出会显示在这里。"
    @State private var isLoading = false
    @State private var errorMessage = ""

    var body: some View {
        ResearchAPIWorkbenchShell(
            title: "床旁快照",
            subtitle: "复刻 /api/bedside/beds、/api/bedside/snapshot/<bed_no> 与 /api/monitor/report/<patient_id>。",
            output: output,
            isLoading: isLoading,
            errorMessage: errorMessage
        ) {
            APIRunButton(title: "床位列表", icon: "bed.double", color: .blue) {
                await run { try await viewModel.apiClient.getBedsideBeds(limit: 12) }
            }
            APIRunButton(title: "床旁快照", icon: "waveform.path.ecg", color: .red) {
                await run {
                    let bedNo = viewModel.currentAnalysisPatient?.bedNumber ?? "ICU-01"
                    return try await viewModel.apiClient.getBedsideSnapshot(bedNo: bedNo)
                }
            }
            APIRunButton(title: "家属报告", icon: "doc.text", color: .teal) {
                await run {
                    let masked = viewModel.currentAnalysisPatient?.maskedId ?? "SC-12000"
                    return try await viewModel.apiClient.getMonitorReport(patientID: masked)
                }
            }
        }
    }

    private func run(_ operation: @escaping () async throws -> JSONValue) async {
        isLoading = true
        errorMessage = ""
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let value = try await operation()
            output = value.description
        } catch {
            errorMessage = "调用失败：\(error)"
        }
        isLoading = false
    }
}

private enum ClinicalLabSection: String, CaseIterable, Identifiable {
    case overview
    case diagnosis
    case subtypes
    case clinical
    case bedside

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "实验室总览"
        case .diagnosis: return "诊断工作台"
        case .subtypes: return "S6 亚型"
        case .clinical: return "临床评分"
        case .bedside: return "床旁快照"
        }
    }

    var subtitle: String {
        switch self {
        case .overview: return "接口状态与运行入口"
        case .diagnosis: return "单例/批量诊断"
        case .subtypes: return "metadata / predict / recommend"
        case .clinical: return "pipeline / scores"
        case .bedside: return "beds / snapshot / report"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .diagnosis: return "stethoscope"
        case .subtypes: return "point.3.connected.trianglepath.dotted"
        case .clinical: return "checklist.checked"
        case .bedside: return "bed.double"
        }
    }

    var color: Color {
        switch self {
        case .overview: return .teal
        case .diagnosis: return .red
        case .subtypes: return .purple
        case .clinical: return .green
        case .bedside: return .blue
        }
    }
}

struct ClinicalModelLabView: View {
    @Bindable var viewModel: AppViewModel
    @State private var selectedSection: ClinicalLabSection = .overview

    var body: some View {
        HStack(spacing: 0) {
            clinicalLabSidebar
                .frame(width: 286)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.72))

            Divider()

            ZStack {
                clinicalLabDetail
                    .id(selectedSection.id)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .animation(.snappy(duration: 0.32, extraBounce: 0.08), value: selectedSection.id)
        }
    }

    private var clinicalLabSidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("临床模型实验室")
                    .font(.system(size: 20, weight: .bold))
                Text("诊断、S6 亚型、临床评分和床旁快照已合并为研究端二级工作台。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)

            if let patient = currentAnalysisPatient {
                ClinicalAnalysisObjectCard(patient: patient)
                    .padding(.horizontal, 14)
            }

            VStack(spacing: 8) {
                ForEach(ClinicalLabSection.allCases) { section in
                    Button {
                        selectedSection = section
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: section.icon)
                                .foregroundStyle(selectedSection == section ? .white : section.color)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(section.title)
                                    .font(.system(size: 13, weight: .bold))
                                Text(section.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundStyle(selectedSection == section ? .white.opacity(0.76) : .secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedSection == section ? section.color : Color(nsColor: .controlBackgroundColor))
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(section.color.opacity(selectedSection == section ? 0.4 : 0.18), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                BackendStatusPill(text: viewModel.backend.statusText, color: viewModel.backend.isReady ? .green : .orange)
                Text("二级导航保留原四个接口面，避免研究端左侧主导航过长。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            .padding(18)
        }
    }

    private var currentAnalysisPatient: Patient? {
        viewModel.currentAnalysisPatient
    }

    @ViewBuilder
    private var clinicalLabDetail: some View {
        switch selectedSection {
        case .overview:
            ClinicalLabOverviewView(viewModel: viewModel) { section in
                selectedSection = section
            }
        case .diagnosis:
            ResearchDiagnosisWorkbenchView(viewModel: viewModel)
        case .subtypes:
            ResearchSubtypeWorkbenchView(viewModel: viewModel)
        case .clinical:
            ResearchClinicalWorkbenchView(viewModel: viewModel)
        case .bedside:
            ResearchBedsideWorkbenchView(viewModel: viewModel)
        }
    }
}

private struct ClinicalLabOverviewView: View {
    @Bindable var viewModel: AppViewModel
    let openSection: (ClinicalLabSection) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(
                    title: "临床模型实验室",
                    subtitle: "统一管理诊断、S6 亚型、临床评分和床旁快照接口。当前页用于快速确认每个接口面的用途和运行入口。"
                )

                LazyVGrid(columns: dashboardColumns, spacing: 14) {
                    WorkspaceMetricTile(title: "当前患者", value: currentPatientLabel, subtitle: "接口调用默认样本", icon: "person.crop.rectangle", color: .teal)
                    WorkspaceMetricTile(title: "后端服务", value: viewModel.backend.isReady ? "在线" : "未连接", subtitle: viewModel.backend.statusText, icon: "server.rack", color: viewModel.backend.isReady ? .green : .orange)
                    WorkspaceMetricTile(title: "API 面", value: "4", subtitle: "诊断/S6/评分/床旁", icon: "square.grid.2x2", color: .blue)
                    WorkspaceMetricTile(title: "队列样本", value: "\(viewModel.patients.count)", subtitle: "当前演示患者池", icon: "person.3", color: .purple)
                }

                if let patient = viewModel.currentAnalysisPatient {
                    ClinicalModelComparisonPanel(patient: patient, openSection: openSection)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ClinicalLabEntryCard(section: .diagnosis, endpoints: ["/api/diagnose", "/api/diagnose/batch", "/api/diagnose/features"]) {
                        openSection(.diagnosis)
                    }
                    ClinicalLabEntryCard(section: .subtypes, endpoints: ["/api/sepsis-subtypes/metadata", "/predict", "/recommend"]) {
                        openSection(.subtypes)
                    }
                    ClinicalLabEntryCard(section: .clinical, endpoints: ["/api/clinical/pipeline", "/api/clinical/scores"]) {
                        openSection(.clinical)
                    }
                    ClinicalLabEntryCard(section: .bedside, endpoints: ["/api/bedside/beds", "/snapshot/<bed_no>", "/api/monitor/report/<patient_id>"]) {
                        openSection(.bedside)
                    }
                }
            }
            .padding(24)
        }
    }

    private var currentPatientLabel: String {
        let patient = viewModel.currentAnalysisPatient
        return patient?.maskedId ?? "--"
    }
}

private struct ClinicalAnalysisObjectCard: View {
    let patient: Patient

    private var prediction: PredictionResult {
        patient.predictions.last ?? PredictionResult.mock(for: patient)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .foregroundStyle(.teal)
                Text("当前分析对象")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                CompactRiskPill(riskLevel: prediction.riskLevel)
            }
            Text(patient.maskedId)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            Text("\(patient.bedNumber) · \(patient.icuWard) · \(prediction.phenotypeName)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("从右下角患者队列切换后，本实验室所有单患者接口都会使用该患者。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.teal.opacity(0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.teal.opacity(0.24), lineWidth: 1)
        }
    }
}

private struct ClinicalModelComparisonPanel: View {
    let patient: Patient
    let openSection: (ClinicalLabSection) -> Void

    private var prediction: PredictionResult {
        patient.predictions.last ?? PredictionResult.mock(for: patient)
    }

    private var qsofa: Int {
        (patient.vitals.respRate >= 22 ? 1 : 0) + (patient.vitals.sbp <= 100 ? 1 : 0) + (patient.vitals.gcs < 15 ? 1 : 0)
    }

    private var news: Int {
        var score = 0
        if patient.vitals.respRate >= 25 { score += 3 } else if patient.vitals.respRate >= 21 { score += 2 }
        if patient.vitals.spo2 <= 91 { score += 3 } else if patient.vitals.spo2 <= 93 { score += 2 }
        if patient.vitals.temperature >= 38 { score += 1 }
        if patient.vitals.heartRate >= 111 { score += 2 } else if patient.vitals.heartRate >= 91 { score += 1 }
        if patient.vitals.sbp <= 90 { score += 3 } else if patient.vitals.sbp <= 100 { score += 2 }
        return score
    }

    var body: some View {
        WorkbenchSection(title: "当前患者多模型对照", icon: "rectangle.3.group") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ClinicalComparisonCard(title: "诊断工作台", value: prediction.riskLevel.displayName, subtitle: "MAP \(Int(patient.vitals.map)) · Lac \(String(format: "%.1f", patient.labs.lactate))", icon: "stethoscope", color: riskColor(for: prediction.riskLevel)) {
                    openSection(.diagnosis)
                }
                ClinicalComparisonCard(title: "S6 亚型", value: prediction.phenotypeId, subtitle: prediction.phenotypeName, icon: "point.3.connected.trianglepath.dotted", color: .purple) {
                    openSection(.subtypes)
                }
                ClinicalComparisonCard(title: "临床评分", value: "qSOFA \(qsofa)", subtitle: "NEWS \(news) · GCS \(Int(patient.vitals.gcs))", icon: "checklist.checked", color: qsofa >= 2 || news >= 7 ? .red : .green) {
                    openSection(.clinical)
                }
                ClinicalComparisonCard(title: "床旁快照", value: patient.bedNumber, subtitle: "\(patient.icuWard) · SpO2 \(Int(patient.vitals.spo2))%", icon: "bed.double", color: .blue) {
                    openSection(.bedside)
                }
            }
        }
    }
}

private struct ClinicalComparisonCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.09))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct ClinicalLabEntryCard: View {
    let section: ClinicalLabSection
    let endpoints: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: section.icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(section.color)
                    Spacer()
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.system(size: 17, weight: .bold))
                    Text(section.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(endpoints, id: \.self) { endpoint in
                        Text(endpoint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(section.color.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private enum HistoryDatabaseTab: String, CaseIterable, Identifiable {
    case overview = "总览"
    case table = "患者表"
    case detail = "详情"

    var id: String { rawValue }
}

private enum HistoryGroupingMode: String, CaseIterable, Identifiable {
    case clinicalSystem
    case dataSource

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clinicalSystem: return "临床系统"
        case .dataSource: return "数据来源"
        }
    }

    func groupValue(for series: HistoricalParameterSeries) -> String {
        switch self {
        case .clinicalSystem: return series.clinical_system
        case .dataSource: return series.data_source
        }
    }
}

struct HistoricalICUDatabaseView: View {
    @Bindable var viewModel: AppViewModel
    @State private var selectedTab: HistoryDatabaseTab = .overview
    @State private var rows: [HistoricalPatientSummary] = []
    @State private var selectedRow: HistoricalPatientSummary?
    @State private var detail: HistoricalPatientDetail?
    @State private var selectedParameterName: String?
    @State private var selectedWindowID: Int?
    @State private var selectedHistoryIDs = Set<String>()
    @State private var favoriteHistoryIDs = Set<String>()
    @State private var annotationText = ""
    @State private var annotationSubmitted = false
    @State private var detailStatus = "选择患者后懒加载分钟级时序详情。"
    @State private var exportPreview = ""
    @State private var total = 0
    @State private var page = 1
    @State private var searchText = ""
    @State private var sort = "los_desc"
    @State private var sourceFilter = "all"
    @State private var icuFilter = "all"
    @State private var outcomeFilter = "all"
    @State private var phenotypeFilter = "all"
    @State private var consistencyFilter = "all"
    @State private var groupingMode: HistoryGroupingMode = .clinicalSystem
    @State private var showSmoothedPrediction = true
    @State private var showErrorPanel = true
    @State private var modelVersionPrimary = "S7-contrastive-20260516"
    @State private var modelVersionCompare = "S6-mainline-20260403"
    @State private var isLoading = false
    @State private var errorMessage = ""

    private let pageSize = 100
    private let sourceOptions = ["all", "MIMIC-IV", "eICU", "PhysioNet2012", "SepsisCare-S7"]
    private let icuOptions = ["all", "心内ICU", "外科ICU", "内科ICU", "综合ICU"]
    private let outcomeOptions = ["all", "出院存活", "院内死亡", "转出ICU后康复", "转院"]
    private let phenotypeOptions = ["all", "P0", "P1", "P2", "P3"]
    private let consistencyOptions = ["all", "exact", "mostly", "average", "mostly_mismatch", "mismatch"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    PageTitle(
                        title: "历史 ICU 数据库",
                        subtitle: "已出院训练队列。摘要列表先加载，点进患者后再懒加载分钟级真实曲线、预测曲线、误差与一致性窗口。"
                    )
                    Spacer()
                    Picker("视图", selection: $selectedTab) {
                        ForEach(HistoryDatabaseTab.allCases) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                }

                historyToolbar
                exportPreviewPanel

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                switch selectedTab {
                case .overview:
                    historyOverview
                case .table:
                    historyTable
                case .detail:
                    historyDetail
                }
            }
            .padding(24)
        }
        .task { await loadRows() }
    }

    private var historyToolbar: some View {
        WorkbenchSection(title: "历史库检索", icon: "line.3.horizontal.decrease.circle") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    TextField("搜索脱敏ID、来源、ICU类型、表型、结局", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                    Picker("排序", selection: $sort) {
                        Text("最长 LOS").tag("los_desc")
                        Text("最近出 ICU").tag("discharge_desc")
                        Text("最高不一致").tag("inconsistency_desc")
                        Text("高缺失率").tag("missing_desc")
                    }
                    .frame(width: 150)
                    Button("查询", systemImage: "magnifyingglass") {
                        Task {
                            page = 1
                            await loadRows()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    HistoryFilterPicker(title: "数据集", selection: $sourceFilter, options: sourceOptions, labels: historyFilterLabels)
                    HistoryFilterPicker(title: "ICU", selection: $icuFilter, options: icuOptions, labels: historyFilterLabels)
                    HistoryFilterPicker(title: "结局", selection: $outcomeFilter, options: outcomeOptions, labels: historyFilterLabels)
                    HistoryFilterPicker(title: "表型", selection: $phenotypeFilter, options: phenotypeOptions, labels: historyFilterLabels)
                    HistoryFilterPicker(title: "一致性", selection: $consistencyFilter, options: consistencyOptions, labels: historyFilterLabels)
                    Button("重置", systemImage: "arrow.uturn.backward") {
                        resetFilters()
                        Task { await loadRows() }
                    }
                }

                HStack {
                    Button("上一页", systemImage: "chevron.left") {
                        Task {
                            page = max(1, page - 1)
                            await loadRows()
                        }
                    }
                    .disabled(page <= 1 || isLoading)
                    Button("下一页", systemImage: "chevron.right") {
                        Task {
                            page += 1
                            await loadRows()
                        }
                    }
                    .disabled(isLoading || page * pageSize >= total)
                    Text("第 \(page) 页 · 每页 \(pageSize) · 共 \(total)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("选择本页", systemImage: "checkmark.square") {
                        selectedHistoryIDs.formUnion(rows.map(\.history_id))
                    }
                    Button("清空选择", systemImage: "square") {
                        selectedHistoryIDs.removeAll()
                    }
                    Button("导出列表", systemImage: "square.and.arrow.down") {
                        Task { await exportCSV(scope: "list", historyID: nil) }
                    }
                    if let selectedRow {
                        Button("导出详情", systemImage: "doc.badge.arrow.up") {
                            Task { await exportCSV(scope: "detail", historyID: selectedRow.history_id) }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var exportPreviewPanel: some View {
        if !exportPreview.isEmpty {
            WorkbenchSection(title: "CSV 导出预览", icon: "doc.plaintext") {
                Text(exportPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(8)
            }
        }
    }

    private var historyOverview: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: dashboardColumns, spacing: 14) {
                WorkspaceMetricTile(title: "历史患者", value: "\(total)", subtitle: "已出院训练队列", icon: "externaldrive.connected.to.line.below", color: .blue)
                WorkspaceMetricTile(title: "默认分页", value: "\(pageSize)", subtitle: "摘要懒加载", icon: "tablecells", color: .teal)
                WorkspaceMetricTile(title: "最高 LOS", value: "\(Int(rows.map(\.los_hours).max() ?? 0))h", subtitle: "当前页", icon: "clock", color: .orange)
                WorkspaceMetricTile(title: "已选样本", value: "\(selectedHistoryIDs.count)", subtitle: "批量导出/分类", icon: "checkmark.square.stack", color: .purple)
            }

            HistoryResearchWorkflowPanel(
                total: total,
                selectedCount: selectedHistoryIDs.count,
                candidate: highestPriorityHistoryRow,
                openTable: {
                    selectedTab = .table
                },
                openCandidate: {
                    guard let row = highestPriorityHistoryRow else { return }
                    selectedRow = row
                    selectedTab = .detail
                    Task { await loadDetail(for: row) }
                },
                markReviewBatch: {
                    let highPriority = rows.filter { historyPriorityScore($0) >= 3 }.map(\.history_id)
                    selectedHistoryIDs.formUnion(highPriority.isEmpty ? rows.prefix(12).map(\.history_id) : highPriority)
                },
                exportList: {
                    Task { await exportCSV(scope: "list", historyID: nil) }
                }
            )

            HStack(alignment: .top, spacing: 16) {
                WorkbenchSection(title: "聚合维度", icon: "chart.bar.xaxis") {
                    VStack(spacing: 10) {
                        HistoryDistributionRow(title: "表型", values: distribution(\.primary_phenotype))
                        HistoryDistributionRow(title: "病区", values: distribution(\.icu_type))
                        HistoryDistributionRow(title: "来源", values: distribution(\.data_source))
                        HistoryDistributionRow(title: "结局", values: distribution(\.outcome))
                    }
                }

                WorkbenchSection(title: "交互合同", icon: "hand.point.up.left") {
                    VStack(alignment: .leading, spacing: 8) {
                        ContractLine("默认深色高密度研究主题，多色医学信号色。")
                        ContractLine("图表使用 Swift Charts，参数小图矩阵固定 2 列，减少分组空档。")
                        ContractLine("分钟级大数据采用后端 + 前端视窗降采样。")
                        ContractLine("导出先按 CSV 数据导出，不包含公式和图表截图。")
                        ContractLine("历史库不接入 DeepSeek，AI 问答只保留在当前患者/家属端。")
                    }
                }
            }
        }
    }

    private var highestPriorityHistoryRow: HistoricalPatientSummary? {
        rows.max { historyPriorityScore($0) < historyPriorityScore($1) }
    }

    private func historyPriorityScore(_ row: HistoricalPatientSummary) -> Int {
        consistencyPriority(row.parameter_consistency.code)
            + consistencyPriority(row.phenotype_consistency.code)
            + (row.missing_rate >= 0.15 ? 2 : row.missing_rate >= 0.08 ? 1 : 0)
            + (row.outcome.contains("死亡") ? 1 : 0)
    }

    private var historyTable: some View {
        WorkbenchSection(title: "高密度摘要表", icon: "tablecells") {
            VStack(spacing: 0) {
                HistoryHeaderRow()
                Divider()
                if isLoading {
                    ProgressView("加载历史队列...")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else if rows.isEmpty {
                    ContentUnavailableView("无匹配历史患者", systemImage: "tray")
                        .frame(minHeight: 220)
                } else {
                    ForEach(rows) { row in
                        HistoryPatientSummaryRow(
                            row: row,
                            isSelected: selectedRow?.id == row.id,
                            isChecked: selectedHistoryIDs.contains(row.history_id),
                            isFavorite: favoriteHistoryIDs.contains(row.history_id),
                            toggleSelection: {
                                toggleBatchSelection(row)
                            }
                        ) {
                            selectedRow = row
                            selectedTab = .detail
                            Task { await loadDetail(for: row) }
                        }
                        Divider()
                    }
                }
            }
        }
    }

    private var historyDetail: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let row = selectedRow {
                if let detail {
                    historyDetailLoaded(row: row, detail: detail)
                } else {
                    WorkbenchSection(title: "\(row.masked_id) 分钟级详情", icon: "chart.xyaxis.line") {
                        VStack(alignment: .leading, spacing: 12) {
                            ProgressView()
                            Text(detailStatus)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
                    }
                }
            } else {
                ContentUnavailableView("未选择历史患者", systemImage: "externaldrive.badge.questionmark")
            }
        }
    }

    private func historyDetailLoaded(row: HistoricalPatientSummary, detail: HistoricalPatientDetail) -> some View {
        let parameter = selectedParameter(in: detail)
        return VStack(alignment: .leading, spacing: 16) {
            WorkbenchSection(title: "\(row.masked_id) 研究详情", icon: "chart.xyaxis.line") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ConsistencyChip(consistency: row.phenotype_consistency, title: "表型")
                        ConsistencyChip(consistency: row.parameter_consistency, title: "连续参数")
                        HistoryBadge(text: "\(detail.resolution) 分辨率", color: .blue)
                        HistoryBadge(text: "\(detail.duration_minutes) 分钟", color: .teal)
                        HistoryBadge(text: "\(row.available_prediction_windows) 个预测窗", color: .purple)
                        HistoryBadge(text: "缺失 \(String(format: "%.1f", row.missing_rate * 100))%", color: .orange)
                    }

                    LazyVGrid(columns: dashboardColumns, spacing: 12) {
                        InfoLine(label: "训练来源", value: "\(row.data_source) · \(row.center) · \(row.quality_tag)")
                        InfoLine(label: "ICU", value: row.icu_type)
                        InfoLine(label: "结局", value: row.outcome)
                        InfoLine(label: "主表型", value: row.primary_phenotype)
                    }

                    HStack(spacing: 12) {
                        Picker("分组", selection: $groupingMode) {
                            ForEach(HistoryGroupingMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .frame(width: 220)

                        Toggle("平滑预测", isOn: $showSmoothedPrediction)
                        Toggle("误差面板", isOn: $showErrorPanel)

                        Picker("当前版本", selection: $modelVersionPrimary) {
                            ForEach(modelVersions, id: \.self) { version in
                                Text(version).tag(version)
                            }
                        }
                        .frame(width: 220)

                        Picker("对比版本", selection: $modelVersionCompare) {
                            ForEach(modelVersions, id: \.self) { version in
                                Text(version).tag(version)
                            }
                        }
                        .frame(width: 220)

                        Spacer()

                        Button(favoriteHistoryIDs.contains(row.history_id) ? "已收藏" : "收藏", systemImage: favoriteHistoryIDs.contains(row.history_id) ? "star.fill" : "star") {
                            toggleFavorite(row)
                        }
                    }
                    .font(.system(size: 12))
                }
            }

            parameterMatrix(detail)

            if let parameter {
                selectedParameterCanvas(parameter, detail: detail)
            }
        }
    }

    private func parameterMatrix(_ detail: HistoricalPatientDetail) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 12),
            count: ResearchWorkspaceDesignContract.historicalMiniChartColumns
        )
        let grouped = Dictionary(grouping: detail.parameters, by: { groupingMode.groupValue(for: $0) })
        let order = groupingMode == .clinicalSystem ? detail.grouping_modes.clinical_system : detail.grouping_modes.data_source

        return WorkbenchSection(title: "参数小图矩阵", icon: "waveform.path.ecg") {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(order.filter { grouped[$0] != nil }, id: \.self) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(grouped[group] ?? []) { series in
                                HistoryMiniChart(
                                    series: series,
                                    windows: detail.prediction_windows,
                                    isSelected: selectedParameterName == series.name,
                                    showSmoothed: showSmoothedPrediction
                                ) {
                                    selectedParameterName = series.name
                                    selectedWindowID = detail.prediction_windows.first?.id
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func selectedParameterCanvas(_ series: HistoricalParameterSeries, detail: HistoricalPatientDetail) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkbenchSection(title: "\(series.label) 详细画布", icon: "chart.line.uptrend.xyaxis") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        HistoricalMetricPill(label: "MAE", value: series.metrics.mae, color: .blue)
                        HistoricalMetricPill(label: "RMSE", value: series.metrics.rmse, color: .purple)
                        HistoricalMetricPill(label: "MAPE", value: series.metrics.mape, suffix: "%", color: .orange)
                        HistoricalMetricPill(label: "DTW", value: series.metrics.dtw, color: .teal)
                        Spacer()
                        Text("\(series.clinical_system) · \(series.data_source) · \(series.unit)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    HistoricalDetailChart(
                        series: series,
                        windows: detail.prediction_windows,
                        showSmoothed: showSmoothedPrediction,
                        showError: showErrorPanel,
                        selectedWindowID: $selectedWindowID
                    )
                }
            }

            WorkbenchSection(title: "表型转移矩阵", icon: "arrow.triangle.branch") {
                PhenotypeTransitionMatrixView(transition: detail.phenotype_transition)
            }

            WorkbenchSection(title: "预测窗口一致性", icon: "rectangle.split.3x1") {
                PredictionWindowTimeline(
                    windows: detail.prediction_windows,
                    selectedWindowID: $selectedWindowID
                )
            }

            WorkbenchSection(title: "研究者备注", icon: "note.text") {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $annotationText)
                        .font(.system(size: 13))
                        .frame(minHeight: 92)
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        }
                    HStack {
                        Text(annotationSubmitted ? "备注已标记为待管理员审核（本地状态）。" : "备注用于研究端复核，提交后进入管理员审核队列。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("提交审核", systemImage: "paperplane") {
                            annotationSubmitted = true
                        }
                        .disabled(annotationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func loadRows() async {
        isLoading = true
        errorMessage = ""
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let response = try await viewModel.apiClient.getHistoricalPatients(
                page: page,
                perPage: pageSize,
                search: searchText,
                sort: sort,
                source: sourceFilter,
                icuType: icuFilter,
                outcome: outcomeFilter,
                phenotype: phenotypeFilter,
                consistency: consistencyFilter
            )
            rows = response.patients
            total = response.total
        } catch {
            errorMessage = "历史 ICU 数据库加载失败：\(error)"
        }
        isLoading = false
    }

    private func loadDetail(for row: HistoricalPatientSummary) async {
        detail = nil
        detailStatus = "正在懒加载 \(row.masked_id) 的分钟级时序..."
        annotationText = ""
        annotationSubmitted = false
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let loaded = try await viewModel.apiClient.getHistoricalPatientDetail(historyID: row.history_id)
            detail = loaded
            selectedParameterName = loaded.parameters.first?.name
            selectedWindowID = loaded.prediction_windows.first?.id
            modelVersionPrimary = loaded.patient.model_version
            modelVersionCompare = modelVersions.first { $0 != loaded.patient.model_version } ?? loaded.patient.model_version
            detailStatus = "已加载 \(loaded.parameters.count) 个参数、\(loaded.prediction_windows.count) 个预测窗口。"
        } catch {
            detailStatus = "详情加载失败：\(error)"
        }
    }

    private func exportCSV(scope: String, historyID: String?) async {
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let csv = try await viewModel.apiClient.exportHistoricalCSV(
                scope: scope,
                historyID: historyID,
                page: page,
                perPage: pageSize,
                search: searchText,
                sort: sort,
                source: sourceFilter,
                icuType: icuFilter,
                outcome: outcomeFilter,
                phenotype: phenotypeFilter,
                consistency: consistencyFilter
            )
            exportPreview = String(csv.prefix(1600))
        } catch {
            exportPreview = "导出失败：\(error)"
        }
    }

    private func resetFilters() {
        searchText = ""
        sort = "los_desc"
        sourceFilter = "all"
        icuFilter = "all"
        outcomeFilter = "all"
        phenotypeFilter = "all"
        consistencyFilter = "all"
        page = 1
    }

    private func toggleBatchSelection(_ row: HistoricalPatientSummary) {
        if selectedHistoryIDs.contains(row.history_id) {
            selectedHistoryIDs.remove(row.history_id)
        } else {
            selectedHistoryIDs.insert(row.history_id)
        }
    }

    private func toggleFavorite(_ row: HistoricalPatientSummary) {
        if favoriteHistoryIDs.contains(row.history_id) {
            favoriteHistoryIDs.remove(row.history_id)
        } else {
            favoriteHistoryIDs.insert(row.history_id)
        }
    }

    private func selectedParameter(in detail: HistoricalPatientDetail) -> HistoricalParameterSeries? {
        if let selectedParameterName,
           let series = detail.parameters.first(where: { $0.name == selectedParameterName }) {
            return series
        }
        return detail.parameters.first
    }

    private func distribution(_ keyPath: KeyPath<HistoricalPatientSummary, String>) -> [(String, Int)] {
        Dictionary(grouping: rows, by: { $0[keyPath: keyPath] })
            .map { ($0.key, $0.value.count) }
            .sorted { $0.1 > $1.1 }
            .prefix(4)
            .map { ($0.0, $0.1) }
    }

    private var modelVersions: [String] {
        let versions = Set(rows.map(\.model_version) + [detail?.patient.model_version].compactMap { $0 })
        return versions.sorted()
    }

    private var historyFilterLabels: [String: String] {
        [
            "all": "全部",
            "exact": "完全一致",
            "mostly": "大部分一致",
            "average": "中等一致",
            "mostly_mismatch": "大部分不一致",
            "mismatch": "完全不一致"
        ]
    }
}

private struct HistoryFilterPicker: View {
    let title: String
    @Binding var selection: String
    let options: [String]
    let labels: [String: String]

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(labels[option] ?? option).tag(option)
            }
        }
        .frame(minWidth: 116)
    }
}

private struct HistoryDistributionRow: View {
    let title: String
    let values: [(String, Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            ForEach(Array(values.enumerated()), id: \.offset) { _, item in
                HStack {
                    Text(item.0)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer()
                    Text("\(item.1)")
                        .font(.system(size: 11, weight: .bold))
                    ProgressView(value: Double(item.1), total: Double(max(values.map { $0.1 }.max() ?? 1, 1)))
                        .frame(width: 90)
                        .tint(.teal)
                }
            }
        }
    }
}

private struct HistoryResearchWorkflowPanel: View {
    let total: Int
    let selectedCount: Int
    let candidate: HistoricalPatientSummary?
    let openTable: () -> Void
    let openCandidate: () -> Void
    let markReviewBatch: () -> Void
    let exportList: () -> Void

    var body: some View {
        WorkbenchSection(title: "研究工作流", icon: "point.topleft.down.curvedto.point.bottomright.up") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                HistoryWorkflowActionCard(title: "摘要表复核", value: "\(total)", subtitle: "打开高密度分页表", icon: "tablecells", color: .teal, action: openTable)
                HistoryWorkflowActionCard(title: "高偏差样本", value: candidate?.masked_id ?? "--", subtitle: candidate.map { "\($0.parameter_consistency.label) · \($0.outcome)" } ?? "等待列表加载", icon: "scope", color: .red, action: openCandidate)
                HistoryWorkflowActionCard(title: "标记复核", value: "\(selectedCount)", subtitle: "按一致性/缺失率加入批量队列", icon: "checkmark.square.stack", color: .purple, action: markReviewBatch)
                HistoryWorkflowActionCard(title: "导出当前页", value: "CSV", subtitle: "列表先导出，详情按患者导出", icon: "square.and.arrow.down", color: .blue, action: exportList)
            }
        }
    }
}

private struct HistoryWorkflowActionCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .foregroundStyle(color)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(color.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color.opacity(0.22), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(value == "--")
    }
}

private struct ContractLine: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
}

private struct HistoryHeaderRow: View {
    var body: some View {
        HistoryGridRow(
            values: ["脱敏ID", "来源", "ICU类型", "入/出ICU", "LOS", "结局", "主表型", "表型一致", "参数一致", "缺失", "窗口"],
            isHeader: true
        )
    }
}

private struct HistoryPatientSummaryRow: View {
    let row: HistoricalPatientSummary
    let isSelected: Bool
    let isChecked: Bool
    let isFavorite: Bool
    let toggleSelection: () -> Void
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleSelection) {
                Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isChecked ? .teal : .secondary)
                    .frame(width: 26)
            }
            .buttonStyle(.plain)
            .help("批量选择")

            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFavorite ? .yellow : .secondary.opacity(0.45))
                .frame(width: 18)

            Button(action: action) {
                HistoryGridRow(
                    values: [
                        row.masked_id,
                        "\(row.data_source) · \(row.center) · \(row.quality_tag)",
                        row.icu_type,
                        "\(row.icu_admit_time)\n\(row.icu_discharge_time)",
                        "\(Int(row.los_hours))h",
                        row.outcome,
                        row.primary_phenotype,
                        row.phenotype_consistency.label,
                        row.parameter_consistency.label,
                        "\(String(format: "%.1f", row.missing_rate * 100))%",
                        "\(row.available_prediction_windows)"
                    ],
                    isHeader: false,
                    highlightColor: isSelected ? .teal.opacity(0.18) : .clear
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct HistoryGridRow: View {
    let values: [String]
    var isHeader = false
    var highlightColor: Color = .clear

    private let widths: [CGFloat] = [92, 170, 76, 156, 52, 82, 128, 76, 76, 54, 46]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    Text(value)
                        .font(.system(size: isHeader ? 11 : 10, weight: isHeader ? .bold : .medium))
                        .foregroundStyle(isHeader ? .secondary : .primary)
                        .lineLimit(2)
                        .frame(width: widths[min(index, widths.count - 1)], alignment: .leading)
                }
            }
            .padding(.vertical, isHeader ? 8 : 9)
            .padding(.horizontal, 8)
            .background(highlightColor)
        }
    }
}

private struct ConsistencyChip: View {
    let consistency: HistoricalConsistency
    let title: String

    var body: some View {
        Text("\(title) \(consistency.label)")
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(consistencyColor.opacity(0.16))
            .foregroundStyle(consistencyColor)
            .clipShape(Capsule())
    }

    private var consistencyColor: Color {
        switch consistency.color {
        case "green": return .green
        case "blue": return .blue
        case "yellow": return .yellow
        case "orange": return .orange
        case "red": return .red
        default: return .teal
        }
    }
}

private struct HistoryBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

private struct HistoricalChartValue: Identifiable {
    let id: String
    let minute: Int
    let value: Double
}

private enum HistoricalCurvePalette {
    static let actual = Color(red: 0.00, green: 0.70, blue: 0.34)
    static let predicted = Color(red: 0.08, green: 0.34, blue: 0.96)
    static let smoothed = Color(red: 0.95, green: 0.52, blue: 0.06)
    static let missing = Color(red: 0.92, green: 0.10, blue: 0.42)
    static let positiveError = Color(red: 0.92, green: 0.10, blue: 0.42)
    static let negativeError = Color(red: 0.08, green: 0.34, blue: 0.96)
}

private struct HistoryMiniChart: View {
    let series: HistoricalParameterSeries
    let windows: [HistoricalPredictionWindow]
    let isSelected: Bool
    let showSmoothed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(series.label)
                            .font(.system(size: 12, weight: .bold))
                        Text("\(series.unit) · \(series.points.count) 点")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("MAE \(String(format: "%.2f", series.metrics.mae))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Chart {
                    ForEach(windowBands) { band in
                        RectangleMark(
                            xStart: .value("start", band.start),
                            xEnd: .value("end", band.end),
                            yStart: .value("min", yDomain.lowerBound),
                            yEnd: .value("max", yDomain.upperBound)
                        )
                        .foregroundStyle(band.color.opacity(0.06))
                    }
                    ForEach(actualValues) { item in
                        LineMark(x: .value("minute", item.minute), y: .value("actual", item.value))
                            .foregroundStyle(HistoricalCurvePalette.actual)
                            .lineStyle(StrokeStyle(lineWidth: 1.7))
                    }
                    ForEach(predictedValues) { item in
                        LineMark(x: .value("minute", item.minute), y: .value("predicted", item.value))
                            .foregroundStyle(HistoricalCurvePalette.predicted)
                            .lineStyle(StrokeStyle(lineWidth: 1.45, dash: [5, 3]))
                    }
                    if showSmoothed {
                        ForEach(smoothedValues) { item in
                            LineMark(x: .value("minute", item.minute), y: .value("smooth", item.value))
                                .foregroundStyle(HistoricalCurvePalette.smoothed)
                                .lineStyle(StrokeStyle(lineWidth: 1.35))
                        }
                    }
                    ForEach(missingValues) { item in
                        PointMark(x: .value("minute", item.minute), y: .value("missing", item.value))
                            .foregroundStyle(HistoricalCurvePalette.missing)
                            .symbolSize(38)
                    }
                }
                .chartYScale(domain: yDomain)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 98)

                HStack(spacing: 8) {
                    ChartLegendDot(label: "实际", color: HistoricalCurvePalette.actual)
                    ChartLegendDot(label: "预测", color: HistoricalCurvePalette.predicted)
                    if showSmoothed {
                        ChartLegendDot(label: "平滑", color: HistoricalCurvePalette.smoothed)
                    }
                    Spacer()
                    Text("\(missingValues.count) 缺失")
                        .foregroundStyle(HistoricalCurvePalette.missing)
                }
                .font(.system(size: 9))
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.cyan.opacity(0.9) : Color.primary.opacity(0.08), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var actualValues: [HistoricalChartValue] {
        series.points.compactMap { point in
            guard let actual = point.actual else { return nil }
            return HistoricalChartValue(id: "a-\(point.minute)", minute: point.minute, value: actual)
        }
    }

    private var predictedValues: [HistoricalChartValue] {
        series.points.map { HistoricalChartValue(id: "p-\($0.minute)", minute: $0.minute, value: $0.predicted) }
    }

    private var smoothedValues: [HistoricalChartValue] {
        series.points.map { HistoricalChartValue(id: "s-\($0.minute)", minute: $0.minute, value: $0.smoothed_predicted) }
    }

    private var missingValues: [HistoricalChartValue] {
        series.points.filter(\.missing).map { HistoricalChartValue(id: "m-\($0.minute)", minute: $0.minute, value: $0.predicted) }
    }

    private var yDomain: ClosedRange<Double> {
        let values = actualValues.map(\.value) + predictedValues.map(\.value) + smoothedValues.map(\.value)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let pad = max((maxValue - minValue) * 0.16, 0.1)
        return (minValue - pad)...(maxValue + pad)
    }

    private var windowBands: [HistoryWindowBand] {
        windows.map {
            HistoryWindowBand(id: $0.id, start: $0.start_minute, end: $0.end_minute, color: color(for: $0.parameter_consistency))
        }
    }
}

private struct HistoricalDetailChart: View {
    let series: HistoricalParameterSeries
    let windows: [HistoricalPredictionWindow]
    let showSmoothed: Bool
    let showError: Bool
    @Binding var selectedWindowID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(windowBands) { band in
                    RectangleMark(
                        xStart: .value("start", band.start),
                        xEnd: .value("end", band.end),
                        yStart: .value("min", yDomain.lowerBound),
                        yEnd: .value("max", yDomain.upperBound)
                    )
                    .foregroundStyle(band.color.opacity(selectedWindowID == band.id ? 0.18 : 0.07))
                }
                ForEach(actualValues) { item in
                    LineMark(x: .value("分钟", item.minute), y: .value("实际", item.value))
                        .foregroundStyle(HistoricalCurvePalette.actual)
                        .lineStyle(StrokeStyle(lineWidth: 2.4))
                }
                ForEach(predictedValues) { item in
                    LineMark(x: .value("分钟", item.minute), y: .value("预测", item.value))
                        .foregroundStyle(HistoricalCurvePalette.predicted)
                        .lineStyle(StrokeStyle(lineWidth: 2.0, dash: [6, 4]))
                }
                if showSmoothed {
                    ForEach(smoothedValues) { item in
                        LineMark(x: .value("分钟", item.minute), y: .value("平滑预测", item.value))
                            .foregroundStyle(HistoricalCurvePalette.smoothed)
                            .lineStyle(StrokeStyle(lineWidth: 1.9))
                    }
                }
                ForEach(missingValues) { item in
                    PointMark(x: .value("分钟", item.minute), y: .value("缺失", item.value))
                        .foregroundStyle(HistoricalCurvePalette.missing)
                        .symbolSize(68)
                }
            }
            .chartYScale(domain: yDomain)
            .frame(height: 280)

            HStack(spacing: 12) {
                ChartLegendDot(label: "实际曲线", color: HistoricalCurvePalette.actual)
                ChartLegendDot(label: "预测曲线", color: HistoricalCurvePalette.predicted)
                if showSmoothed {
                    ChartLegendDot(label: "平滑预测", color: HistoricalCurvePalette.smoothed)
                }
                ChartLegendDot(label: "缺失点", color: HistoricalCurvePalette.missing)
                Spacer()
                Text("点击下方窗口矩阵可高亮对应预测窗口")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if showError {
                Chart(errorValues) { item in
                    AreaMark(x: .value("分钟", item.minute), y: .value("误差", item.value))
                        .foregroundStyle(item.value >= 0 ? HistoricalCurvePalette.positiveError.opacity(0.26) : HistoricalCurvePalette.negativeError.opacity(0.26))
                    LineMark(x: .value("分钟", item.minute), y: .value("误差", item.value))
                        .foregroundStyle(.primary.opacity(0.68))
                }
                .frame(height: 96)
            }
        }
    }

    private var actualValues: [HistoricalChartValue] {
        series.points.compactMap { point in
            guard let actual = point.actual else { return nil }
            return HistoricalChartValue(id: "a-\(point.minute)", minute: point.minute, value: actual)
        }
    }

    private var predictedValues: [HistoricalChartValue] {
        series.points.map { HistoricalChartValue(id: "p-\($0.minute)", minute: $0.minute, value: $0.predicted) }
    }

    private var smoothedValues: [HistoricalChartValue] {
        series.points.map { HistoricalChartValue(id: "s-\($0.minute)", minute: $0.minute, value: $0.smoothed_predicted) }
    }

    private var errorValues: [HistoricalChartValue] {
        series.points.compactMap { point in
            guard let error = point.error else { return nil }
            return HistoricalChartValue(id: "e-\(point.minute)", minute: point.minute, value: error)
        }
    }

    private var missingValues: [HistoricalChartValue] {
        series.points.filter(\.missing).map { HistoricalChartValue(id: "m-\($0.minute)", minute: $0.minute, value: $0.predicted) }
    }

    private var yDomain: ClosedRange<Double> {
        let values = actualValues.map(\.value) + predictedValues.map(\.value) + smoothedValues.map(\.value)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let pad = max((maxValue - minValue) * 0.18, 0.1)
        return (minValue - pad)...(maxValue + pad)
    }

    private var windowBands: [HistoryWindowBand] {
        windows.map {
            HistoryWindowBand(id: $0.id, start: $0.start_minute, end: $0.end_minute, color: color(for: $0.parameter_consistency))
        }
    }
}

private struct HistoryWindowBand: Identifiable {
    let id: Int
    let start: Int
    let end: Int
    let color: Color
}

private struct ChartLegendDot: View {
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
        }
    }
}

private struct HistoricalMetricPill: View {
    let label: String
    let value: Double
    var suffix = ""
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text("\(String(format: "%.3g", value))\(suffix)")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct FormulaRichText: View {
    let formula: HistoricalFormula

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(formula.name.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(renderedFormula)
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
    }

    private var renderedFormula: String {
        switch formula.name {
        case "point_error":
            return "e_t = y_t - ŷ_t"
        case "mae":
            return "MAE_w = (1 / n) Σ_{t∈w} |y_t - ŷ_t|"
        case "rmse":
            return "RMSE_w = √((1 / n) Σ_{t∈w} (y_t - ŷ_t)^2)"
        case "mape":
            return "MAPE_w = (100 / n) Σ_{t∈w} |(y_t - ŷ_t) / (y_t + ε)|"
        case "dtw":
            return "DTW(Y, Ŷ) = min_π Σ_{(i,j)∈π} d(y_i, ŷ_j)"
        default:
            return formula.latex
        }
    }
}

private struct PredictionWindowTimeline: View {
    let windows: [HistoricalPredictionWindow]
    @Binding var selectedWindowID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(windows) { window in
                        Button {
                            selectedWindowID = window.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("W\(window.window_index)")
                                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                                Text("\(window.start_minute)-\(window.end_minute)m")
                                    .font(.system(size: 10))
                                Text(window.parameter_consistency.label)
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .padding(10)
                            .frame(width: 112, alignment: .leading)
                            .background(color(for: window.parameter_consistency).opacity(selectedWindowID == window.id ? 0.26 : 0.13))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            VStack(spacing: 0) {
                WindowMatrixHeader()
                Divider()
                ForEach(windows) { window in
                    WindowMatrixRow(window: window, isSelected: selectedWindowID == window.id) {
                        selectedWindowID = window.id
                    }
                    Divider()
                }
            }
        }
    }
}

private struct WindowMatrixHeader: View {
    var body: some View {
        WindowMatrixGrid(values: ["窗", "范围", "实际/预测表型", "表型一致", "参数一致", "MAE", "RMSE", "MAPE", "DTW", "偏差参数"], isHeader: true)
    }
}

private struct WindowMatrixRow: View {
    let window: HistoricalPredictionWindow
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            WindowMatrixGrid(
                values: [
                    "W\(window.window_index)",
                    "\(window.start_minute)-\(window.end_minute)",
                    "\(window.phenotype_actual) / \(window.phenotype_predicted)",
                    window.phenotype_consistency.label,
                    window.parameter_consistency.label,
                    String(format: "%.3f", window.mae),
                    String(format: "%.3f", window.rmse),
                    String(format: "%.1f%%", window.mape),
                    String(format: "%.3f", window.dtw),
                    window.key_deviation_parameters.joined(separator: ", ")
                ],
                isHeader: false,
                highlightColor: isSelected ? color(for: window.parameter_consistency).opacity(0.16) : .clear
            )
        }
        .buttonStyle(.plain)
    }
}

private struct WindowMatrixGrid: View {
    let values: [String]
    var isHeader = false
    var highlightColor: Color = .clear
    private let widths: [CGFloat] = [42, 88, 112, 82, 92, 58, 58, 58, 58, 150]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    Text(value)
                        .font(.system(size: isHeader ? 11 : 10, weight: isHeader ? .bold : .medium))
                        .foregroundStyle(isHeader ? .secondary : .primary)
                        .lineLimit(2)
                        .frame(width: widths[min(index, widths.count - 1)], alignment: .leading)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(highlightColor)
        }
    }
}

private struct PhenotypeTransitionMatrixView: View {
    let transition: HistoricalPhenotypeTransition

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("")
                    .frame(width: 36)
                ForEach(transition.states, id: \.self) { state in
                    Text(state)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 46)
                }
            }
            ForEach(Array(transition.states.enumerated()), id: \.offset) { rowIndex, state in
                HStack(spacing: 6) {
                    Text(state)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .frame(width: 36, alignment: .leading)
                    ForEach(Array((transition.matrix[safe: rowIndex] ?? []).enumerated()), id: \.offset) { _, value in
                        Text("\(Int(value * 100))")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 46, height: 28)
                            .background(Color.teal.opacity(0.08 + value * 0.35))
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            Text("数字为转移比例百分数，供研究端对表型轨迹做质控分析。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

private func color(for consistency: HistoricalConsistency) -> Color {
    switch consistency.color {
    case "green": return .green
    case "blue": return .blue
    case "yellow": return .yellow
    case "orange": return .orange
    case "red": return .red
    default: return .teal
    }
}

private func riskColor(for riskLevel: RiskLevel) -> Color {
    switch riskLevel {
    case .stable: return .teal
    case .watch: return .orange
    case .critical: return .red
    case .recovering: return .blue
    }
}

private func riskSortRank(_ riskLevel: RiskLevel) -> Int {
    switch riskLevel {
    case .critical: return 4
    case .watch: return 3
    case .stable: return 2
    case .recovering: return 1
    }
}

private func phenotypeColor(_ name: String) -> Color {
    if name.contains("P0") || name.contains("稳定") { return .teal }
    if name.contains("P1") || name.contains("中") { return .blue }
    if name.contains("P2") || name.contains("高危") { return .orange }
    if name.contains("P3") || name.contains("风暴") { return .red }
    return .purple
}

private func consistencyPriority(_ code: String) -> Int {
    switch code {
    case "mismatch": return 4
    case "mostly_mismatch": return 3
    case "average": return 2
    case "mostly": return 1
    default: return 0
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct ResearchAPIWorkbenchShell<Controls: View>: View {
    let title: String
    let subtitle: String
    let output: String
    let isLoading: Bool
    let errorMessage: String
    @ViewBuilder let controls: Controls

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: title, subtitle: subtitle)

                LazyVGrid(columns: dashboardColumns, spacing: 14) {
                    controls
                }

                if isLoading {
                    ProgressView("正在调用 server.py ...")
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                WorkbenchSection(title: "API 返回", icon: "curlybraces") {
                    ScrollView(.horizontal) {
                        Text(output)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 360, alignment: .topLeading)
                }
            }
            .padding(24)
        }
    }
}

private struct APIRunButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(minHeight: 72)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(color.opacity(0.25), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

struct FamilyPatientStatusView: View {
    @Bindable var viewModel: AppViewModel
    
    var body: some View {
        Group {
            if let patient = viewModel.selectedPatient {
                FamilyPatientStatusContent(patient: patient, viewModel: viewModel)
            } else {
                ContentUnavailableView {
                    Label("未选择患者", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("请在左侧选择一位患者查看当前状态")
                }
            }
        }
    }
}

private struct FamilyPatientStatusContent: View {
    let patient: Patient
    @Bindable var viewModel: AppViewModel
    
    private var prediction: PredictionResult { patient.predictions.last ?? PredictionResult.mock(for: patient) }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FamilyStatusHero(patient: patient, prediction: prediction)
                
                LazyVGrid(columns: dashboardColumns, spacing: 14) {
                    FamilyVitalTile(title: "平均动脉压", value: "\(Int(patient.vitals.map))", unit: "mmHg", status: patient.vitals.map < 65 ? "偏低" : "稳定", color: patient.vitals.map < 65 ? .red : .teal)
                    FamilyVitalTile(title: "乳酸", value: String(format: "%.1f", patient.labs.lactate), unit: "mmol/L", status: patient.labs.lactate > 3 ? "升高" : "可接受", color: patient.labs.lactate > 3 ? .orange : .teal)
                    FamilyVitalTile(title: "血氧", value: "\(Int(patient.vitals.spo2))", unit: "%", status: patient.vitals.spo2 < 92 ? "需关注" : "稳定", color: patient.vitals.spo2 < 92 ? .red : .teal)
                    FamilyVitalTile(title: "体温", value: String(format: "%.1f", patient.vitals.temperature), unit: "°C", status: patient.vitals.temperature > 38 ? "发热" : "稳定", color: patient.vitals.temperature > 38 ? .orange : .teal)
                }
                
                HStack(alignment: .top, spacing: 16) {
                    WorkbenchSection(title: "基本状态信息", icon: "person.text.rectangle") {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            InfoLine(label: "床位", value: patient.bedNumber)
                            InfoLine(label: "年龄", value: "\(patient.age)岁")
                            InfoLine(label: "性别", value: patient.sex == 1 ? "男" : "女")
                            InfoLine(label: "GCS", value: "\(Int(patient.vitals.gcs))")
                            InfoLine(label: "当前表型", value: prediction.phenotypeName)
                            InfoLine(label: "风险等级", value: prediction.riskLevel.displayName)
                        }
                    }
                    
                    WorkbenchSection(title: "临床评分摘要", icon: "checklist.checked") {
                        VStack(spacing: 12) {
                            FamilyScoreRow(name: "qSOFA", value: "\(qsofaScore)", note: qsofaScore >= 2 ? "需要医生重点评估" : "当前未达高警戒阈值", color: qsofaScore >= 2 ? .red : .teal)
                            FamilyScoreRow(name: "NEWS", value: "\(newsScore)", note: newsScore >= 7 ? "高风险监护" : "持续观察", color: newsScore >= 7 ? .red : .orange)
                            FamilyScoreRow(name: "休克提示", value: shockFlag ? "是" : "否", note: "依据 MAP 和乳酸做简化提示", color: shockFlag ? .red : .teal)
                        }
                    }
                }
                
                WorkbenchSection(title: "面向家属的 AI 摘要", icon: "sparkles") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(familySummary)
                            .font(.system(size: 14))
                            .lineSpacing(4)
                        Divider()
                        Text("这些信息用于帮助沟通和理解趋势，不替代 ICU 医生的诊断、治疗和转归判断。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                
                WorkbenchSection(title: "近时段生命体征趋势", icon: "chart.line.uptrend.xyaxis") {
                    Chart(patient.history) { entry in
                        LineMark(x: .value("小时", entry.hour), y: .value("MAP", entry.map))
                            .foregroundStyle(.teal)
                        LineMark(x: .value("小时", entry.hour), y: .value("SpO2", entry.spo2))
                            .foregroundStyle(.blue)
                    }
                    .frame(height: 240)
                }
                
                WorkbenchSection(title: "AI 智能体沟通", icon: "bubble.left.and.bubble.right") {
                    ChatView(viewModel: viewModel, patient: patient)
                        .frame(minHeight: 360)
                }

                FamilyDisclaimerFooter()
            }
            .padding(24)
        }
    }
    
    private var qsofaScore: Int {
        (patient.vitals.respRate >= 22 ? 1 : 0) + (patient.vitals.sbp <= 100 ? 1 : 0) + (patient.vitals.gcs < 15 ? 1 : 0)
    }
    
    private var newsScore: Int {
        var score = 0
        if patient.vitals.respRate >= 25 { score += 3 } else if patient.vitals.respRate >= 21 { score += 2 }
        if patient.vitals.spo2 <= 91 { score += 3 } else if patient.vitals.spo2 <= 93 { score += 2 }
        if patient.vitals.temperature >= 38 { score += 1 }
        if patient.vitals.heartRate >= 111 { score += 2 } else if patient.vitals.heartRate >= 91 { score += 1 }
        if patient.vitals.sbp <= 90 { score += 3 } else if patient.vitals.sbp <= 100 { score += 2 }
        return score
    }
    
    private var shockFlag: Bool {
        patient.vitals.map < 65 && patient.labs.lactate >= 2
    }
    
    private var familySummary: String {
        "目前 \(patient.bedNumber) 处于\(familyRiskText)状态，模型对应表型为\(prediction.phenotypeName)。关键观察点是血压循环、乳酸变化、血氧和意识状态。机械通气支持评估为\(ventilationAssessment)，预计 ICU 停留时间约 \(Int(prediction.remainingLOSHours)) 小时。"
    }

    private var familyRiskText: String {
        switch prediction.riskLevel {
        case .critical: return "高警戒"
        case .watch: return "需要观察"
        case .recovering: return "恢复观察"
        case .stable: return "相对平稳"
        }
    }

    private var ventilationAssessment: String {
        if prediction.nextMVProbability >= 0.55 { return "需要重点关注" }
        if prediction.nextMVProbability >= 0.25 { return "继续观察" }
        return "目前较低"
    }
}

struct FamilyChatWorkspaceView: View {
    @Bindable var viewModel: AppViewModel
    
    var body: some View {
        Group {
            if let patient = viewModel.selectedPatient {
                VStack(spacing: 0) {
                    FamilyStatusHero(patient: patient, prediction: patient.predictions.last ?? PredictionResult.mock(for: patient))
                        .padding(24)
                    ChatView(viewModel: viewModel, patient: patient)
                    FamilyDisclaimerFooter()
                        .padding(.horizontal, 24)
                        .padding(.bottom, 18)
                }
            } else {
                ContentUnavailableView("未选择患者", systemImage: "person.crop.circle.badge.questionmark")
            }
        }
    }
}

private struct FamilyStatusHero: View {
    let patient: Patient
    let prediction: PredictionResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [AppBrand.familyAqua.opacity(0.95), AppBrand.recoveryGreen.opacity(0.86)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "heart.text.square.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 58, height: 58)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(patient.bedNumber) \(patient.name)")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                        Text("\(patient.age)岁 · \(patient.sex == 1 ? "男性" : "女性") · ICU 连续监护中")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                CompactRiskPill(riskLevel: prediction.riskLevel)
            }
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                FamilyHeroInfo(label: "当前表型", value: prediction.phenotypeName, icon: "dna", color: AppBrand.phenotypeViolet)
                FamilyHeroInfo(label: "整体状态", value: familyRiskText, icon: "heart.circle", color: AppBrand.familyAqua)
                FamilyHeroInfo(label: "通气评估", value: ventilationAssessment, icon: "lungs", color: AppBrand.lactateAmber)
                FamilyHeroInfo(label: "预计 ICU", value: "约 \(Int(prediction.remainingLOSHours))h", icon: "clock", color: AppBrand.signalBlue)
            }
        }
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.96), AppBrand.familyMist.opacity(0.94)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppBrand.familyAqua.opacity(0.26), lineWidth: 1)
        }
        .shadow(color: AppBrand.familyAqua.opacity(0.12), radius: 20, x: 0, y: 10)
    }

    private var familyRiskText: String {
        switch prediction.riskLevel {
        case .critical: return "高警戒"
        case .watch: return "需要观察"
        case .recovering: return "恢复观察"
        case .stable: return "相对平稳"
        }
    }

    private var ventilationAssessment: String {
        if prediction.nextMVProbability >= 0.55 { return "需重点关注" }
        if prediction.nextMVProbability >= 0.25 { return "继续观察" }
        return "目前较低"
    }
}

private struct FamilyHeroInfo: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.white.opacity(0.70), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct FamilyDisclaimerFooter: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(AppBrand.familyAqua)
                .font(.system(size: 16, weight: .semibold))
            Text("免责声明：本页面和 AI 智能体仅用于家属沟通、信息解释和趋势理解，不构成诊断、治疗建议或转归承诺。所有医疗决策、病情解释和治疗调整均以主管医生及 ICU 医疗团队意见为准。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(AppBrand.familyMist.opacity(0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppBrand.familyAqua.opacity(0.20), lineWidth: 1)
        }
    }
}

private struct FamilyVitalTile: View {
    let title: String
    let value: String
    let unit: String
    let status: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(status)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(color)
            }
            
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 32, weight: .bold))
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minHeight: 124, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 1)
        }
    }

    private var icon: String {
        switch title {
        case "平均动脉压": return "waveform.path.ecg"
        case "乳酸": return "drop.fill"
        case "血氧": return "lungs"
        case "体温": return "thermometer"
        default: return "heart.text.square"
        }
    }
}

struct PatientQueueToggle: View {
    @Bindable var viewModel: AppViewModel
    var onSelect: () -> Void

    @State private var isExpanded = false
    @State private var searchText = ""
    @State private var riskFilter = "all"
    @State private var wardFilter = "all"
    @State private var page = 1

    private let pageSize = 8

    var body: some View {
        Group {
            if isExpanded {
                expandedQueue
            } else {
                Button {
                    withAnimation(.snappy) { isExpanded = true }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [queueAccent, AppBrand.oxygenCyan.opacity(0.86)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 56, height: 56)
                        Image(systemName: "person.3.sequence.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 56, height: 56)
                        Text("\(viewModel.visiblePatients.count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(AppBrand.sepsisRed, in: Capsule(style: .continuous))
                            .offset(x: 4, y: -4)
                    }
                }
                .buttonStyle(.plain)
                .clipShape(Circle())
                .help("展开患者队列")
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 8)
        .padding(22)
    }

    private var expandedQueue: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("患者队列", systemImage: "person.3.sequence.fill")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button {
                    withAnimation(.snappy) { isExpanded = false }
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("收起患者队列")
            }

            TextField("搜索床号、脱敏ID、病区", text: $searchText)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                Picker("风险", selection: $riskFilter) {
                    Text("全部风险").tag("all")
                    Text("稳定").tag("stable")
                    Text("观察").tag("watch")
                    Text("危重").tag("critical")
                }
                .labelsHidden()
                .frame(width: 112)

                Picker("病区", selection: $wardFilter) {
                    Text("全部病区").tag("all")
                    ForEach(wardOptions, id: \.self) { ward in
                        Text(ward).tag(ward)
                    }
                }
                .labelsHidden()
            }

            if pagedPatients.isEmpty {
                ContentUnavailableView("无匹配患者", systemImage: "magnifyingglass")
                    .frame(height: 180)
            } else {
                VStack(spacing: 8) {
                    ForEach(pagedPatients) { patient in
                        QueuePatientRow(patient: patient, isSelected: viewModel.selectedPatient?.id == patient.id) {
                            viewModel.selectPatient(patient)
                            onSelect()
                        }
                    }
                }
            }

            HStack {
                Text("\(filteredPatients.count) 位 · 第 \(page)/\(maxPage) 页")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    page = max(1, page - 1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(page <= 1)
                Button {
                    page = min(maxPage, page + 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(page >= maxPage)
            }
        }
        .padding(16)
        .frame(width: 390)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(queueAccent.opacity(0.28), lineWidth: 1)
        }
        .onChange(of: searchText) { _, _ in page = 1 }
        .onChange(of: riskFilter) { _, _ in page = 1 }
        .onChange(of: wardFilter) { _, _ in page = 1 }
    }

    private var filteredPatients: [Patient] {
        viewModel.visiblePatients.filter { patient in
            let prediction = patient.predictions.last ?? PredictionResult.mock(for: patient)
            let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matchesText = text.isEmpty
                || patient.bedNumber.lowercased().contains(text)
                || patient.maskedId.lowercased().contains(text)
                || patient.icuWard.lowercased().contains(text)
            let matchesRisk = riskFilter == "all" || prediction.riskLevel.rawValue == riskFilter
            let matchesWard = wardFilter == "all" || patient.icuWard == wardFilter
            return matchesText && matchesRisk && matchesWard
        }
    }

    private var pagedPatients: [Patient] {
        let safePage = min(max(page, 1), maxPage)
        let start = (safePage - 1) * pageSize
        return Array(filteredPatients.dropFirst(start).prefix(pageSize))
    }

    private var maxPage: Int {
        max(1, Int(ceil(Double(filteredPatients.count) / Double(pageSize))))
    }

    private var wardOptions: [String] {
        Array(Set(viewModel.visiblePatients.map(\.icuWard))).sorted()
    }

    private var queueAccent: Color {
        if let role = viewModel.currentRole {
            return AppBrand.accent(for: role)
        }
        return AppBrand.signalBlue
    }
}

private struct QueuePatientRow: View {
    let patient: Patient
    let isSelected: Bool
    let action: () -> Void

    private var prediction: PredictionResult { patient.predictions.last ?? PredictionResult.mock(for: patient) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(queueColor)
                    .frame(width: 5, height: 46)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(patient.maskedId.isEmpty ? patient.bedNumber : patient.maskedId)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Text(patient.bedNumber)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(patient.age)岁 · \(patient.sex == 1 ? "男" : "女") · \(patient.icuWard) · \(patient.phenotypeLabel)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("MAP \(Int(patient.vitals.map)) · Lac \(String(format: "%.1f", patient.labs.lactate)) · LOS \(Int(patient.losHours))h")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()
                CompactRiskPill(riskLevel: prediction.riskLevel)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? queueColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
            }
        }
        .buttonStyle(.plain)
    }

    private var queueColor: Color {
        switch prediction.riskLevel {
        case .stable, .recovering: return .green
        case .watch: return .yellow
        case .critical: return .red
        }
    }
}

struct AdminWorkspaceSidebar: View {
    @Binding var selectedSection: AdminWorkspaceSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SidebarHeader(title: "sepsis", subtitle: "管理员端", icon: "person.badge.key")

                VStack(alignment: .leading, spacing: 8) {
                    SidebarSectionLabel("后台")
                    ForEach(AdminWorkspaceSection.allCases) { section in
                        SidebarNavButton(title: section.title, subtitle: section.subtitle, icon: section.icon, isSelected: selectedSection == section, accent: AppBrand.adminGold) {
                            selectedSection = section
                        }
                    }
                }
            }
            .padding(16)
        }
        .background {
            SidebarChromeBackground(style: .admin)
        }
    }
}

struct AdminWorkspaceDetail: View {
    let section: AdminWorkspaceSection
    @Bindable var viewModel: AppViewModel

    var body: some View {
        ZStack {
            BrandPatternBackdrop(style: .admin, intensity: 0.62)
                .opacity(0.44)
            content
                .id(section.id)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
        }
        .animation(.snappy(duration: 0.30, extraBounce: 0.06), value: section.id)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .accounts:
            AdminAccountBindingView(viewModel: viewModel)
        case .services:
            AdminServiceMonitorView(viewModel: viewModel)
        case .apiCoverage:
            AdminAPICoverageView(viewModel: viewModel)
        case .audit:
            AdminAuditView(viewModel: viewModel)
        }
    }
}

private struct AdminAccountBindingView: View {
    @Bindable var viewModel: AppViewModel
    @State private var remoteBindings: [AdminFamilyBinding] = []
    @State private var storagePath = ""
    @State private var statusMessage = ""
    @State private var errorMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: "账号绑定", subtitle: "家属账号只绑定一位患者，前端不提供新增账号入口，后台在此维护绑定关系。")

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                if let bound = viewModel.familyBoundPatient {
                    WorkbenchSection(title: "当前家属账号绑定", icon: "link") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                QueuePatientRow(patient: bound, isSelected: true) {}
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text("family -> \(bound.maskedId)")
                                        .font(.system(size: 12, design: .monospaced))
                                    Text(storagePath.isEmpty ? "server.py 待同步" : storagePath)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack {
                                Button("刷新后端绑定", systemImage: "arrow.clockwise") {
                                    Task { await loadBindings() }
                                }
                                Button("同步当前绑定", systemImage: "arrow.up.doc") {
                                    Task { await persistBinding(bound) }
                                }
                                Spacer()
                                Text(statusMessage)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if !remoteBindings.isEmpty {
                    WorkbenchSection(title: "server.py 已保存绑定", icon: "externaldrive.badge.checkmark") {
                        VStack(spacing: 8) {
                            ForEach(remoteBindings) { binding in
                                HStack {
                                    Text(binding.account)
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                    Spacer()
                                    Text(binding.patient_ref)
                                        .font(.system(size: 12, design: .monospaced))
                                    Text(binding.updated_at)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(nsColor: .textBackgroundColor))
                                }
                            }
                        }
                    }
                }

                WorkbenchSection(title: "选择绑定患者", icon: "person.crop.circle.badge.checkmark") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(viewModel.patients) { patient in
                            Button {
                                viewModel.bindFamilyAccount(to: patient)
                                Task { await persistBinding(patient) }
                            } label: {
                                QueuePatientRow(patient: patient, isSelected: viewModel.familyBoundPatient?.id == patient.id) {}
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
        }
        .task { await loadBindings() }
    }

    private func loadBindings() async {
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let response = try await viewModel.apiClient.getAdminBindings()
            remoteBindings = response.bindings
            storagePath = response.storage
            errorMessage = ""
            statusMessage = response.bindings.isEmpty ? "后端暂无绑定记录" : "已读取后端绑定"
            if let family = response.bindings.first(where: { $0.account == "family" }),
               let patient = viewModel.patients.first(where: { $0.maskedId == family.patient_ref || $0.bedNumber == family.patient_ref }) {
                viewModel.bindFamilyAccount(to: patient)
            }
        } catch {
            errorMessage = "读取后端绑定失败：\(error)"
        }
    }

    private func persistBinding(_ patient: Patient) async {
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let response = try await viewModel.apiClient.postAdminBinding(patientRef: patient.maskedId)
            statusMessage = "已保存：\(response.binding.account) -> \(response.binding.patient_ref)"
            await loadBindings()
        } catch {
            errorMessage = "保存后端绑定失败：\(error)"
        }
    }
}

private struct AdminServiceMonitorView: View {
    @Bindable var viewModel: AppViewModel
    @State private var status: AdminStatusResponse?
    @State private var errorMessage = ""
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: "服务监控", subtitle: "重点监控 CPU/GPU 占用估计、后端连接状态、DeepSeek 配置和模型运行设备。")

                BackendControlPanel(backend: viewModel.backend, mode: .expanded) {
                    openWindow(id: "backend-logs")
                }

                LazyVGrid(columns: dashboardColumns, spacing: 14) {
                    WorkspaceMetricTile(title: "后端服务", value: viewModel.backend.isReady ? "在线" : "离线", subtitle: viewModel.backend.statusText, icon: "server.rack", color: viewModel.backend.isReady ? .green : .orange)
                    WorkspaceMetricTile(title: "CPU估计", value: status?.device.cpu.usageDisplayText ?? "--", subtitle: status?.device.cpu.monitorTileSubtitle ?? "等待读取", icon: "cpu", color: .blue)
                    WorkspaceMetricTile(title: "GPU", value: gpuValue, subtitle: status?.device.gpu.name ?? "等待读取", icon: "display", color: .purple)
                    WorkspaceMetricTile(title: "DeepSeek", value: status?.backend.llm_configured == true ? "已配置" : "Fallback", subtitle: status?.backend.deepseek_model ?? "deepseek-v4-flash", icon: "sparkles", color: .teal)
                }

                if let status {
                    AdminRuntimeChecklistView(status: status, backend: viewModel.backend)
                }

                HStack {
                    Button("完整巡检", systemImage: "checklist.checked") {
                        viewModel.backend.refreshHealth()
                        Task { await loadStatus() }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("刷新状态", systemImage: "arrow.clockwise") {
                        Task { await loadStatus() }
                    }

                    Button("打开日志", systemImage: "doc.text.magnifyingglass") {
                        openWindow(id: "backend-logs")
                    }
                }
                .buttonStyle(.bordered)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                if let status {
                    WorkbenchSection(title: "运行环境", icon: "terminal") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoLine(label: "服务", value: "\(status.service.name) · \(status.service.status)")
                            InfoLine(label: "Python", value: status.service.python)
                            InfoLine(label: "平台", value: status.service.platform)
                            InfoLine(label: "模型设备", value: status.backend.runtime_device)
                            InfoLine(label: "LLM Provider", value: status.backend.llm_provider)
                        }
                    }
                }
            }
            .padding(24)
        }
        .task { await loadStatus() }
    }

    private var gpuValue: String {
        guard let gpu = status?.device.gpu else { return "--" }
        guard gpu.available else { return "未启用" }
        return gpu.utilization_percent.map { "\(Int($0))%" } ?? "可用"
    }

    private func loadStatus() async {
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            status = try await viewModel.apiClient.getAdminStatus()
            errorMessage = ""
        } catch {
            errorMessage = "读取管理员状态失败：\(error)"
        }
    }
}

private struct AdminRuntimeChecklistView: View {
    let status: AdminStatusResponse
    @Bindable var backend: BackendController

    var body: some View {
        WorkbenchSection(title: "运行巡检", icon: "checkmark.seal") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                AdminCheckRow(
                    title: "后端连接",
                    detail: "\(backend.apiBaseURL) · \(backend.lastHealthCheck)",
                    state: backend.isReady ? "正常" : "异常",
                    color: backend.isReady ? .green : .red
                )
                AdminCheckRow(
                    title: "连接模式",
                    detail: backend.ownedProcessRunning ? backend.launchCommand : "腾讯云 API · 本地备用后端未托管",
                    state: backend.ownedProcessRunning ? "本地备用" : "云端",
                    color: backend.ownedProcessRunning ? .green : .orange
                )
                AdminCheckRow(
                    title: "CPU",
                    detail: status.device.cpu.monitorChecklistDetail,
                    state: status.device.cpu.usageDisplayText,
                    color: status.device.cpu.estimated_usage_percent >= 85 ? .red : status.device.cpu.estimated_usage_percent >= 60 ? .orange : .blue
                )
                AdminCheckRow(
                    title: "GPU",
                    detail: status.device.gpu.available ? "\(status.device.gpu.name) · \(gpuMemoryText)" : status.device.gpu.name,
                    state: status.device.gpu.available ? "可用" : "未启用",
                    color: status.device.gpu.available ? .purple : .secondary
                )
                AdminCheckRow(
                    title: "DeepSeek",
                    detail: "\(status.backend.llm_provider) · \(status.backend.deepseek_model)",
                    state: status.backend.llm_configured ? "已配置" : "Fallback",
                    color: status.backend.llm_configured ? .teal : .orange
                )
                AdminCheckRow(
                    title: "模型设备",
                    detail: status.service.uptime_hint,
                    state: status.backend.runtime_device,
                    color: status.backend.runtime_device.lowercased().contains("cuda") || status.backend.runtime_device.lowercased().contains("mps") ? .green : .blue
                )
            }
        }
    }

    private var gpuMemoryText: String {
        guard let used = status.device.gpu.memory_used_mb,
              let total = status.device.gpu.memory_total_mb else {
            return status.device.gpu.utilization_percent.map { "util \(Int($0))%" } ?? "memory --"
        }
        return "\(Int(used))/\(Int(total)) MB"
    }
}

private struct AdminCheckRow: View {
    let title: String
    let detail: String
    let state: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text(state)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(color)
                }
                Text(detail)
                    .font(.system(size: 10, design: title == "进程归属" ? .monospaced : .default))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
    }
}

enum BackendControlPanelMode {
    case compact
    case expanded
}

struct BackendControlPanel: View {
    @Bindable var backend: BackendController
    var mode: BackendControlPanelMode = .compact
    var showLogsAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [statusColor.opacity(0.22), AppBrand.oxygenCyan.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                    Image(systemName: "server.rack")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(backend.statusText)
                            .font(.system(size: 15, weight: .bold))
                        Text(backend.lastHealthCheck)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(backend.apiBaseURL)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if mode == .expanded {
                        Text(backend.ownedProcessRunning ? backend.launchCommand : "本地后端：\(backend.localApiBaseURL) · \(backend.launchCommand)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }

                Spacer()
                BackendStatusPill(text: backend.ownedProcessRunning ? "App进程" : "外部/未托管", color: backend.ownedProcessRunning ? .green : .orange)
            }

            HStack(spacing: 8) {
                Button("启动本地后端", systemImage: "play.fill") {
                    backend.startBackend()
                }
                .disabled(backend.isStarting || backend.ownedProcessRunning)

                Button("停止", systemImage: "stop.fill") {
                    backend.stopBackend()
                }

                Button("重启", systemImage: "arrow.clockwise") {
                    backend.restartBackend()
                }

                Button("健康检查", systemImage: "stethoscope") {
                    backend.refreshHealth()
                }

                Spacer()

                Button("日志", systemImage: "doc.text.magnifyingglass") {
                    showLogsAction()
                }
            }
            .buttonStyle(.bordered)

            if mode == .expanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("实时日志预览")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button("清空", systemImage: "trash") {
                            backend.clearLogs()
                        }
                        .buttonStyle(.borderless)
                    }
                    BackendLogPreview(lines: Array(backend.logLines.suffix(8)))
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.94))
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(statusColor.opacity(0.34))
                .frame(height: 2)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusColor.opacity(0.22), lineWidth: 1)
        }
    }

    private var statusColor: Color {
        if backend.isReady { return .green }
        if backend.isStarting { return .orange }
        return .red
    }
}

private struct BackendStatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.16))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

private struct BackendLogPreview: View {
    let lines: [String]

    var body: some View {
        ScrollView {
            Text(lines.isEmpty ? "暂无后端日志。" : lines.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minHeight: 96, maxHeight: 170)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
    }
}

struct BackendLogWindow: View {
    @Bindable var backend: BackendController

    var body: some View {
        ZStack {
            BrandPatternBackdrop(style: .admin, intensity: 0.72)
                .opacity(0.52)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    BrandLogoMark(size: 42)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("后端日志")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                        Text("\(backend.apiBaseURL) · \(backend.statusText)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    BackendStatusPill(text: backend.ownedProcessRunning ? "App 托管" : "外部/未托管", color: backend.ownedProcessRunning ? .green : .orange)
                    Button("健康检查", systemImage: "stethoscope") {
                        backend.refreshHealth()
                    }
                    Button("清空日志", systemImage: "trash") {
                        backend.clearLogs()
                    }
                }

                ScrollView {
                    Text(backend.logLines.isEmpty ? "暂无后端日志。" : backend.logLines.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.94))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AppBrand.adminGold.opacity(0.20), lineWidth: 1)
                }
            }
            .padding(24)
        }
    }
}

private struct AdminAPICoverageView: View {
    @Bindable var viewModel: AppViewModel
    @State private var output = "点击巡检按钮后显示 API 返回。"
    @State private var errorMessage = ""
    @State private var isLoading = false

    var body: some View {
        ResearchAPIWorkbenchShell(
            title: "API 覆盖",
            subtitle: "server.py 已按 webapp_v2 的 API 面补齐。这里用于逐项 smoke，后续可扩展成自动巡检。",
            output: output,
            isLoading: isLoading,
            errorMessage: errorMessage
        ) {
            APIRunButton(title: "患者/看板/筛选", icon: "person.text.rectangle", color: .blue) {
                await run {
                    let patients = try await viewModel.apiClient.fetchJSON("/api/patients?page=1&per_page=3")
                    let stats = try await viewModel.apiClient.getDashboardStats()
                    let filters = try await viewModel.apiClient.getFilterOptions()
                    return .object(["patients": patients, "stats": stats, "filters": filters])
                }
            }
            APIRunButton(title: "配置/AI", icon: "gearshape.2", color: .purple) {
                await run {
                    let system = try await viewModel.apiClient.getSystemConfig()
                    let ai = try await viewModel.apiClient.getAIConfig()
                    let analysis = try await viewModel.apiClient.getAIAnalysis()
                    return .object(["system": system, "ai": ai, "analysis": analysis])
                }
            }
            APIRunButton(title: "模型/临床", icon: "brain.head.profile", color: .orange) {
                await run {
                    guard let patient = viewModel.currentAnalysisPatient else { return .string("无患者") }
                    let diagnose = try await viewModel.apiClient.postDiagnose(patient: patient)
                    let scores = try await viewModel.apiClient.postClinicalScores(patient: patient)
                    let subtype = try await viewModel.apiClient.postSubtypePredict()
                    return .object(["diagnose": diagnose, "scores": scores, "subtype": subtype])
                }
            }
            APIRunButton(title: "床旁/报告", icon: "bed.double", color: .teal) {
                await run {
                    let bedNo = viewModel.currentAnalysisPatient?.bedNumber ?? "ICU-01"
                    let masked = viewModel.currentAnalysisPatient?.maskedId ?? "SC-12000"
                    let beds = try await viewModel.apiClient.getBedsideBeds(limit: 4)
                    let snapshot = try await viewModel.apiClient.getBedsideSnapshot(bedNo: bedNo)
                    let report = try await viewModel.apiClient.getMonitorReport(patientID: masked)
                    return .object(["beds": beds, "snapshot": snapshot, "report": report])
                }
            }
        }
    }

    private func run(_ operation: @escaping () async throws -> JSONValue) async {
        isLoading = true
        errorMessage = ""
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let value = try await operation()
            output = value.description
        } catch {
            errorMessage = "巡检失败：\(error)"
        }
        isLoading = false
    }
}

private struct AdminAuditView: View {
    @Bindable var viewModel: AppViewModel
    @State private var output = "审计日志会显示在这里。"
    @State private var errorMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageTitle(title: "审计日志", subtitle: "查看 server.py 记录的模型、AI、临床和家属问答调用事件。")

                Button("刷新审计日志", systemImage: "arrow.clockwise") {
                    Task { await loadAudit() }
                }
                .buttonStyle(.borderedProminent)

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                }

                WorkbenchSection(title: "最近事件", icon: "doc.text.magnifyingglass") {
                    Text(output)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
        .task { await loadAudit() }
    }

    private func loadAudit() async {
        do {
            await viewModel.apiClient.setBaseURL(viewModel.settings.apiBaseURL)
            let value = try await viewModel.apiClient.fetchJSON("/api/audit")
            output = value.description
            errorMessage = ""
        } catch {
            errorMessage = "读取审计日志失败：\(error)"
        }
    }
}

struct DocumentationCenterView: View {
    enum Mode {
        case research
        case family
    }
    
    let mode: Mode
    
    var body: some View {
        Group {
            if mode == .research {
                MathDocumentationWebView(
                    html: SepsisCareDocumentationHTML.research,
                    baseURL: SepsisCareDocumentationHTML.resourceBaseURL
                )
            } else {
                ZStack {
                    BrandPatternBackdrop(style: .family, intensity: 0.76)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            PageTitle(
                                title: "家属端阅读文档",
                                subtitle: "把表型、风险评分和 ICU 常见指标转成家属可理解的说明。"
                            )

                            DocumentationSection(title: "数据来源与脱敏", icon: "lock.shield") {
                                Text("患者编号、床位和身份信息均按本地演示规则脱敏。家属端只展示当前绑定患者可沟通的状态摘要。")
                            }

                            DocumentationSection(title: "表型与风险", icon: "dna") {
                                Text("P0-P3 表型用于描述脓毒症患者在滚动时间窗中的生理状态。家属端只保留可理解的状态描述，不展示死亡风险量化值。")
                            }

                            DocumentationSection(title: "AI 智能体边界", icon: "sparkles") {
                                Text("AI 智能体用于解释趋势、辅助沟通和生成问题建议，不输出医嘱，不替代医生诊断。所有治疗决策以 ICU 医疗团队说明为准。")
                            }
                        }
                        .padding(24)
                    }
                }
            }
        }
    }
}

struct MathDocumentationWebView: NSViewRepresentable {
    let html: String
    var baseURL: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator {
        var loadedHTML = ""
    }
}

enum SepsisCareDocumentationHTML {
    static var resourceBaseURL: URL? {
        if let nested = Bundle.module.url(forResource: "katex.min", withExtension: "js", subdirectory: "MathDocs") {
            return nested.deletingLastPathComponent()
        }
        return Bundle.module.url(forResource: "katex.min", withExtension: "js")?.deletingLastPathComponent()
    }

    static let research = #"""
<!doctype html>
<html lang="zh-Hans">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>sepsiscare 科研端使用文档</title>
  <link rel="stylesheet" href="katex.min.css">
  <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
  <script defer src="katex.min.js"></script>
  <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
  <script>
    window.MathJax = {
      tex: { inlineMath: [['\\(', '\\)']], displayMath: [['\\[', '\\]']] },
      svg: { fontCache: 'global' },
      startup: { typeset: false }
    };
  </script>
  <script defer src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-svg.js"></script>
  <style>
    :root {
      color-scheme: dark;
      --bg: #0b1117;
      --panel: #101a23;
      --panel-2: #162230;
      --line: rgba(184, 216, 232, 0.16);
      --text: #e6f1f5;
      --muted: #8ea8b4;
      --blue: #45a3ff;
      --cyan: #33d6d0;
      --green: #5ade8b;
      --orange: #ffb45a;
      --red: #ff6b78;
      --violet: #b98cff;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: radial-gradient(circle at 18% 0%, rgba(69, 163, 255, 0.13), transparent 32%),
                  linear-gradient(180deg, #0b1117 0%, #0d151d 50%, #0b1117 100%);
      color: var(--text);
      font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "SF Pro Text", "PingFang SC", sans-serif;
      line-height: 1.62;
    }
    .layout { display: grid; grid-template-columns: 248px minmax(0, 1fr); min-height: 100vh; }
    aside {
      position: sticky;
      top: 0;
      height: 100vh;
      padding: 28px 20px;
      border-right: 1px solid var(--line);
      background: rgba(12, 20, 28, 0.88);
      backdrop-filter: blur(14px);
    }
    .brand { display: flex; align-items: center; gap: 12px; margin-bottom: 26px; }
    .mark {
      width: 40px; height: 40px; border-radius: 12px;
      background: linear-gradient(135deg, #06101f, var(--cyan) 45%, var(--blue) 78%, var(--violet));
      box-shadow: 0 16px 42px rgba(51, 214, 208, 0.18);
      position: relative;
      overflow: hidden;
    }
    .mark:before {
      content: "";
      position: absolute;
      left: 7px; right: 7px; top: 22px;
      height: 3px;
      background: #1ff0dc;
      box-shadow: 9px -8px 0 -1px #1ff0dc, 17px 7px 0 -1px #1ff0dc, 26px -13px 0 -1px #1ff0dc;
      border-radius: 999px;
    }
    .mark:after {
      content: "+";
      position: absolute;
      inset: 3px 0 auto 0;
      text-align: center;
      color: white;
      font-weight: 900;
      font-size: 20px;
      line-height: 24px;
    }
    .brand h1 { font-size: 17px; margin: 0; letter-spacing: 0; }
    .brand p { margin: 2px 0 0; color: var(--muted); font-size: 12px; }
    nav a {
      display: block;
      padding: 9px 10px;
      color: var(--muted);
      text-decoration: none;
      border-radius: 8px;
      font-size: 13px;
    }
    nav a:hover { background: rgba(69, 163, 255, 0.10); color: var(--text); }
    main { padding: 34px 44px 56px; max-width: 1180px; }
    .hero {
      padding-bottom: 24px;
      border-bottom: 1px solid var(--line);
      margin-bottom: 24px;
    }
    .eyebrow { color: var(--cyan); font-weight: 700; font-size: 12px; text-transform: uppercase; }
    h2 { margin: 0 0 10px; font-size: 32px; line-height: 1.15; letter-spacing: 0; }
    h3 { margin: 30px 0 12px; font-size: 22px; letter-spacing: 0; }
    h4 { margin: 22px 0 8px; font-size: 15px; color: #cfe6ef; }
    p { margin: 8px 0 12px; color: #c7d9df; }
    .grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 12px; }
    .card {
      background: linear-gradient(180deg, rgba(22, 34, 48, 0.92), rgba(14, 24, 34, 0.92));
      border: 1px solid var(--line);
      border-radius: 8px;
      padding: 16px;
    }
    .card strong { color: #ffffff; }
    .pill {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 8px;
      border: 1px solid var(--line);
      border-radius: 999px;
      color: var(--muted);
      font-size: 12px;
      margin: 0 6px 6px 0;
    }
    .endpoint {
      display: grid;
      grid-template-columns: 92px 1fr;
      gap: 12px;
      align-items: start;
      padding: 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: rgba(255,255,255,0.025);
      margin: 8px 0;
    }
    .method {
      font: 700 11px ui-monospace, SFMono-Regular, Menlo, monospace;
      color: #071014;
      background: var(--green);
      border-radius: 6px;
      padding: 4px 7px;
      text-align: center;
    }
    .post { background: var(--orange); }
    code, pre {
      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
      background: rgba(0, 0, 0, 0.22);
      border: 1px solid var(--line);
      border-radius: 8px;
    }
    code { padding: 2px 5px; color: #d7f5ff; }
    pre { padding: 14px; overflow: auto; color: #d9edf3; }
    table { width: 100%; border-collapse: collapse; margin: 12px 0; overflow: hidden; border-radius: 8px; }
    th, td { border: 1px solid var(--line); padding: 10px 12px; text-align: left; vertical-align: top; }
    th { color: #eaf8fb; background: rgba(69, 163, 255, 0.10); }
    td { color: #c7d9df; }
    .math-display, .math-inline {
      border: 1px solid rgba(51, 214, 208, 0.2);
      background: rgba(51, 214, 208, 0.07);
      color: #e9ffff;
    }
    .math-display {
      display: block;
      margin: 10px 0;
      padding: 14px 16px;
      border-radius: 8px;
      overflow-x: auto;
      font-size: 16px;
    }
    .math-inline { padding: 1px 5px; border-radius: 6px; }
    .warn {
      border-left: 4px solid var(--orange);
      background: rgba(255, 180, 90, 0.08);
      padding: 12px 14px;
      border-radius: 8px;
      color: #ffe0b8;
    }
    .engine {
      margin-top: 16px;
      color: var(--muted);
      font-size: 12px;
    }
    @media (max-width: 900px) {
      .layout { grid-template-columns: 1fr; }
      aside { position: relative; height: auto; }
      main { padding: 24px; }
      .grid { grid-template-columns: 1fr; }
    }
  </style>
</head>
<body>
  <div class="layout">
    <aside>
      <div class="brand">
        <div class="mark"></div>
        <div>
          <h1>sepsiscare</h1>
          <p>科研端使用文档</p>
        </div>
      </div>
      <nav>
        <a href="#quickstart">快速开始</a>
        <a href="#api">API 参考</a>
        <a href="#coverage">API 覆盖清单</a>
        <a href="#model">模型与预测</a>
        <a href="#formula">公式与指标</a>
        <a href="#history">历史 ICU 数据库</a>
        <a href="#clinical">临床评分</a>
        <a href="#safety">边界与免责声明</a>
        <a href="#references">参考风格</a>
      </nav>
      <div class="engine" id="engine">公式引擎：fallback text</div>
    </aside>
    <main>
      <section class="hero">
        <div class="eyebrow">Research Manual / WKWebView Math Renderer</div>
        <h2>sepsiscare 科研端使用文档</h2>
        <p>本文档按照大模型 API 文档常见结构组织：快速开始、端点说明、参数定义、错误处理、示例、公式和边界说明。公式以 LaTeX 源码维护，并由 KaTeX 优先渲染；如果 KaTeX 加载失败，则尝试 MathJax；两者都不可用时保留可读文本。</p>
        <span class="pill">KaTeX first</span><span class="pill">MathJax fallback</span><span class="pill">copyable LaTeX</span><span class="pill">research only</span>
      </section>

      <section id="quickstart">
        <h3>1. 快速开始</h3>
        <div class="grid">
          <div class="card"><strong>连接后端</strong><p>客户端默认连接本机 API <code>http://127.0.0.1:8765</code>，由本机后端统一转发到远程模型服务；训练终端可配置云端训练地址 <code>http://100.65.136.96:8788</code>。</p></div>
          <div class="card"><strong>进入研究端</strong><p>账号选择研究端，默认密码 <code>123123</code>。研究端默认面向模型、历史数据库和 API 验证。</p></div>
          <div class="card"><strong>查看文档</strong><p>右上角“使用文档”打开独立文档窗口；公式统一放在科研文档中维护和渲染。</p></div>
        </div>
        <pre><code>curl http://127.0.0.1:8765/health
# 远程模型服务：curl http://100.65.136.96:8788/health</code></pre>
      </section>

      <section id="api">
        <h3>2. API 参考</h3>
        <div class="endpoint"><div class="method">GET</div><div><code>/health</code><p>服务健康检查，返回服务名、状态和演示患者数量。</p></div></div>
        <div class="endpoint"><div class="method post">POST</div><div><code>/api/model/predict</code><p>单患者模型预测，返回当前表型、死亡风险、机械通气风险、剩余 ICU 时间和窗口轨迹。</p></div></div>
        <div class="endpoint"><div class="method">GET</div><div><code>/api/history/patients</code><p>历史 ICU 摘要列表，支持分页、搜索、数据源、ICU 类型、结局、表型和一致性筛选。</p></div></div>
        <div class="endpoint"><div class="method">GET</div><div><code>/api/history/patients/{history_id}</code><p>懒加载历史患者分钟级详情，包括实际曲线、预测曲线、误差、平滑预测和预测窗口。</p></div></div>
        <div class="endpoint"><div class="method">GET</div><div><code>/api/admin/status</code><p>管理员运行状态，包含后端、DeepSeek、CPU/GPU 和运行设备。</p></div></div>
      </section>

      <section id="coverage">
        <h3>3. API 覆盖清单</h3>
        <table>
          <tr><th>模块</th><th>已接入端点</th><th>macOS 页面</th></tr>
          <tr><td>当前患者队列</td><td><code>/api/patients</code>, <code>/api/patients/{id}</code>, <code>/api/dashboard/stats</code>, <code>/api/filters/options</code></td><td>右下角患者队列、风险看板、总览工作台</td></tr>
          <tr><td>诊断</td><td><code>/api/diagnose</code>, <code>/api/diagnose/batch</code>, <code>/api/diagnose/features</code></td><td>临床模型实验室 / 诊断工作台</td></tr>
          <tr><td>S6 亚型</td><td><code>/api/sepsis-subtypes/metadata</code>, <code>/api/sepsis-subtypes/predict</code>, <code>/api/sepsis-subtypes/recommend</code></td><td>临床模型实验室 / S6 亚型</td></tr>
          <tr><td>临床评分</td><td><code>/api/clinical/pipeline</code>, <code>/api/clinical/scores</code></td><td>临床模型实验室 / 临床评分</td></tr>
          <tr><td>床旁</td><td><code>/api/bedside/beds</code>, <code>/api/bedside/snapshot/{bed_no}</code>, <code>/api/monitor/report/{patient_id}</code></td><td>临床模型实验室 / 床旁快照、家属端当前状态</td></tr>
          <tr><td>AI</td><td><code>/api/ai/analysis</code>, <code>/api/ai/explain</code>, <code>/api/ai/assistant-chat</code>, <code>/api/family/chat</code></td><td>AI 分析、家属 AI 问答</td></tr>
          <tr><td>历史 ICU</td><td><code>/api/history/patients</code>, <code>/api/history/patients/{history_id}</code>, <code>/api/history/stats</code>, <code>/api/history/export</code></td><td>历史 ICU 数据库</td></tr>
          <tr><td>管理员</td><td><code>/api/admin/status</code>, <code>/api/admin/bindings</code>, <code>/api/audit</code></td><td>服务监控、账号绑定、审计日志</td></tr>
        </table>
      </section>

      <section id="model">
        <h3>4. 模型与预测对象</h3>
        <p>模型输出以患者时间窗为核心：当前状态、历史序列和滚动窗口轨迹共同形成研究端可分析对象。</p>
        <table>
          <tr><th>对象</th><th>说明</th><th>研究用途</th></tr>
          <tr><td>phenotype</td><td>P0-P3 表型</td><td>分析状态转移、聚类稳定性和窗口一致性</td></tr>
          <tr><td>mortality_probability</td><td>死亡风险概率</td><td>仅研究端使用，家属端不显示量化值</td></tr>
          <tr><td>next_mech_vent_probability</td><td>下一窗口机械通气支持概率</td><td>研究模型预警能力</td></tr>
          <tr><td>remaining_los_hours</td><td>预计剩余 ICU 小时数</td><td>评估资源占用和转归趋势</td></tr>
        </table>
      </section>

      <section id="formula">
        <h3>5. 公式与指标</h3>
        <h4>4.1 点误差</h4>
        <div class="math-display" data-tex="e_t = y_t - \hat{y}_t">e_t = y_t - yhat_t</div>
        <p>其中 <span class="math-inline" data-tex="y_t">y_t</span> 是真实观测值，<span class="math-inline" data-tex="\hat{y}_t">yhat_t</span> 是模型预测值。</p>

        <h4>4.2 连续参数误差</h4>
        <div class="math-display" data-tex="MAE_w = \frac{1}{n}\sum_{t \in w}|y_t-\hat{y}_t|">MAE_w = (1/n) sum |y_t - yhat_t|</div>
        <div class="math-display" data-tex="RMSE_w = \sqrt{\frac{1}{n}\sum_{t \in w}(y_t-\hat{y}_t)^2}">RMSE_w = sqrt((1/n) sum (y_t - yhat_t)^2)</div>
        <div class="math-display" data-tex="MAPE_w = \frac{100}{n}\sum_{t \in w}\left|\frac{y_t-\hat{y}_t}{y_t+\epsilon}\right|">MAPE_w = (100/n) sum |(y_t-yhat_t)/(y_t+epsilon)|</div>
        <div class="math-display" data-tex="DTW(Y,\hat{Y}) = \min_{\pi}\sum_{(i,j)\in\pi} d(y_i,\hat{y}_j)">DTW(Y,Yhat) = min_pi sum d(y_i,yhat_j)</div>

        <h4>4.3 表型一致性</h4>
        <div class="math-display" data-tex="r = \frac{1}{K}\sum_{k=1}^{K}\mathbb{1}(\hat{c}_k = c_k)">r = (1/K) sum indicator(c_hat_k = c_k)</div>
        <table>
          <tr><th>标签</th><th>含义</th><th>建议色</th></tr>
          <tr><td>完全一致</td><td>窗口内预测类别与真实类别完全匹配</td><td>绿色</td></tr>
          <tr><td>大部分一致</td><td>多数窗口匹配，少数偏移</td><td>蓝色</td></tr>
          <tr><td>中等一致</td><td>约半数匹配，需复核</td><td>黄色</td></tr>
          <tr><td>大部分不一致</td><td>多数窗口偏离</td><td>橙色</td></tr>
          <tr><td>完全不一致</td><td>预测类别与真实类别系统性背离</td><td>红色</td></tr>
        </table>

        <h4>4.4 风险判别与校准</h4>
        <div class="math-display" data-tex="p = \sigma(z) = \frac{1}{1+e^{-z}}">p = sigmoid(z)</div>
        <div class="math-display" data-tex="\operatorname{Brier} = \frac{1}{N}\sum_{i=1}^{N}(p_i-o_i)^2">Brier = (1/N) sum (p_i - o_i)^2</div>
      </section>

      <section id="history">
        <h3>6. 历史 ICU 数据库</h3>
        <p>历史 ICU 数据库代表已出院训练队列。摘要列表先加载，点击患者后再加载分钟级详情，避免主表被大体量时序数据拖慢。</p>
        <table>
          <tr><th>层级</th><th>字段</th><th>说明</th></tr>
          <tr><td>摘要表</td><td>脱敏ID、数据源、ICU、LOS、结局、主表型、一致性</td><td>用于快速检索和筛选</td></tr>
          <tr><td>详情页</td><td>actual / predicted / smoothed_predicted / error</td><td>用于趋势复核、误差分析和窗口比较</td></tr>
          <tr><td>窗口矩阵</td><td>phenotype_actual / phenotype_predicted / MAE / RMSE / MAPE / DTW</td><td>用于判断完全一致、大部分一致等自分类标签</td></tr>
        </table>
      </section>

      <section id="clinical">
        <h3>7. 临床评分</h3>
        <h4>6.1 qSOFA</h4>
        <div class="math-display" data-tex="qSOFA = \mathbb{1}(RR \ge 22) + \mathbb{1}(SBP \le 100) + \mathbb{1}(GCS < 15)">qSOFA = I(RR>=22) + I(SBP<=100) + I(GCS<15)</div>
        <h4>6.2 休克评估</h4>
        <div class="math-display" data-tex="\operatorname{ShockFlag} = \mathbb{1}(MAP < 65 \land Lactate \ge 2)">ShockFlag = I(MAP < 65 and Lactate >= 2)</div>
        <p>临床评分用于研究复核和趋势解释，不替代医生诊断，也不直接生成治疗建议。</p>
      </section>

      <section id="safety">
        <h3>8. 边界与免责声明</h3>
        <div class="warn">本系统用于科研、模型评估、历史队列分析和家属沟通辅助。家属端不显示死亡风险量化值，不提供诊断或治疗建议。所有医疗决策以 ICU 医疗团队意见为准。</div>
      </section>

      <section id="references">
        <h3>9. 参考风格</h3>
        <p>文档结构参考了主流大模型 API 文档的组织方式：快速开始、API 端点、鉴权和参数、示例、错误处理、模型说明与 FAQ。实现上保留 sepsiscare 自身的科研逻辑，不复制外部文档内容。</p>
        <ul>
          <li>DeepSeek API Docs：<code>https://api-docs.deepseek.com/</code></li>
          <li>Kimi API Platform：<code>https://platform.kimi.ai/docs/api/overview</code></li>
          <li>火山方舟 / Doubao API 文档：<code>https://www.volcengine.com/docs/82379/1511946</code></li>
        </ul>
      </section>
    </main>
  </div>
  <script>
    function setEngine(name) {
      var el = document.getElementById('engine');
      if (el) el.textContent = '公式引擎：' + name;
    }
    function mathNodes() {
      return Array.prototype.slice.call(document.querySelectorAll('[data-tex]'));
    }
    function renderKatex() {
      if (!window.katex) return false;
      mathNodes().forEach(function(node) {
        try {
          window.katex.render(node.getAttribute('data-tex'), node, {
            displayMode: node.classList.contains('math-display'),
            throwOnError: false,
            strict: false,
            trust: false
          });
        } catch (error) {
          node.textContent = node.getAttribute('data-tex');
        }
      });
      setEngine('KaTeX');
      return true;
    }
    function renderMathJax() {
      if (!window.MathJax || !window.MathJax.typesetPromise) return false;
      mathNodes().forEach(function(node) {
        var tex = node.getAttribute('data-tex');
        node.textContent = node.classList.contains('math-display') ? '\\[' + tex + '\\]' : '\\(' + tex + '\\)';
      });
      window.MathJax.typesetPromise(mathNodes()).then(function() { setEngine('MathJax'); });
      return true;
    }
    function renderMath() {
      if (renderKatex()) return;
      if (renderMathJax()) return;
      setEngine('fallback text');
    }
    window.addEventListener('load', function() {
      setTimeout(renderMath, 250);
      setTimeout(renderMath, 1200);
      setTimeout(renderMath, 2500);
    });
  </script>
</body>
</html>
"""#
}

private struct DocumentationSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        WorkbenchSection(title: title, icon: icon) {
            content
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .lineSpacing(4)
        }
    }
}

private struct PageTitle: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            BrandLogoMark(size: 38)
                .opacity(0.88)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    BrandVersionPill(compact: true)
                }
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineSpacing(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.bottom, 2)
    }
}

private struct WorkbenchSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(AppBrand.oxygenCyan)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [AppBrand.oxygenCyan.opacity(0.55), AppBrand.signalBlue.opacity(0.18), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 1)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [AppBrand.oxygenCyan.opacity(0.18), AppBrand.phenotypeViolet.opacity(0.12), Color.primary.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}

private struct WorkspaceMetricTile: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(color.opacity(0.14))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .foregroundStyle(color)
                }
                Spacer()
            }
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(16)
        .frame(minHeight: 144, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        }
        .overlay(alignment: .topTrailing) {
            Image(systemName: icon)
                .font(.system(size: 54, weight: .bold))
                .foregroundStyle(color.opacity(0.055))
                .padding(12)
        }
        .overlay(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.32))
                .frame(height: 3)
                .padding(.horizontal, 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct PatientWorkbenchRow: View {
    let patient: Patient
    let action: () -> Void
    
    private var prediction: PredictionResult { patient.predictions.last ?? PredictionResult.mock(for: patient) }
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CompactRiskPill(riskLevel: prediction.riskLevel)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(patient.bedNumber) \(patient.name)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("\(prediction.phenotypeName) · MAP \(Int(patient.vitals.map)) · Lac \(String(format: "%.1f", patient.labs.lactate))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RiskBoardRow: Identifiable {
    var id: String { patient.id }
    let patient: Patient
    let prediction: PredictionResult
}

private struct RiskAcuitySegment: Identifiable {
    var id: String { riskLevel.rawValue }
    let riskLevel: RiskLevel
    let count: Int
    let start: Int
    let end: Int
    let total: Int

    var percentage: Int {
        Int((Double(count) / Double(max(total, 1))) * 100)
    }

    var color: Color {
        riskColor(for: riskLevel)
    }
}

private struct WardRiskSummary: Identifiable {
    var id: String { ward }
    let ward: String
    let critical: Int
    let watch: Int
    let total: Int

    var activeRiskCount: Int {
        critical + watch
    }
}

private struct RiskAcuityStackChart: View {
    let segments: [RiskAcuitySegment]
    let total: Int

    var body: some View {
        WorkbenchSection(title: "队列风险构成", icon: "chart.bar.xaxis") {
            VStack(alignment: .leading, spacing: 13) {
                Chart {
                    ForEach(segments) { segment in
                        BarMark(
                            xStart: .value("起点", segment.start),
                            xEnd: .value("终点", segment.end),
                            y: .value("队列", "当前")
                        )
                        .foregroundStyle(segment.color)
                        .annotation(position: .overlay) {
                            if segment.percentage >= 10 {
                                Text("\(segment.riskLevel.displayName) \(segment.percentage)%")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }
                .chartXScale(domain: 0...max(total, 1))
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 70)

                HStack(spacing: 12) {
                    ForEach(segments) { segment in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(segment.color)
                                .frame(width: 10, height: 10)
                            Text("\(segment.riskLevel.displayName) \(segment.count)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("总计 \(total) 例")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("队列风险构成图")
    }
}

private struct RiskBoardPatientRow: View {
    let row: RiskBoardRow
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(riskColor(for: row.prediction.riskLevel))
                    .frame(width: 5, height: 52)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(row.patient.maskedId)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                        Text(row.patient.bedNumber)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(row.prediction.phenotypeName) · \(row.patient.icuWard)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("MAP \(Int(row.patient.vitals.map)) · Lac \(String(format: "%.1f", row.patient.labs.lactate)) · \(row.patient.consistencyLabel)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                RiskValue(label: "死亡", value: row.prediction.mortalityProbability)
                RiskValue(label: "通气", value: row.prediction.nextMVProbability)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(isSelected ? riskColor(for: row.prediction.riskLevel) : .secondary)
            }
            .padding(12)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? riskColor(for: row.prediction.riskLevel).opacity(0.14) : Color(nsColor: .textBackgroundColor))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? riskColor(for: row.prediction.riskLevel).opacity(0.55) : Color.primary.opacity(0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct RiskTriageInsightView: View {
    let row: RiskBoardRow

    private var signals: [RiskSignal] {
        [
            RiskSignal(label: "MAP", value: "\(Int(row.patient.vitals.map))", detail: "mmHg", color: row.patient.vitals.map < 65 ? .red : .blue),
            RiskSignal(label: "乳酸", value: String(format: "%.1f", row.patient.labs.lactate), detail: "mmol/L", color: row.patient.labs.lactate >= 3 ? .red : .orange),
            RiskSignal(label: "SpO2", value: "\(Int(row.patient.vitals.spo2))", detail: "%", color: row.patient.vitals.spo2 < 92 ? .orange : .green),
            RiskSignal(label: "GCS", value: "\(Int(row.patient.vitals.gcs))", detail: "", color: row.patient.vitals.gcs < 13 ? .red : .teal),
            RiskSignal(label: "MV", value: "\(Int(row.prediction.nextMVProbability * 100))", detail: "%", color: row.prediction.nextMVProbability > 0.55 ? .red : .purple)
        ]
    }

    var body: some View {
        WorkbenchSection(title: "当前分析对象分诊摘要", icon: "scope") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(row.patient.maskedId)
                            .font(.system(size: 18, weight: .bold, design: .monospaced))
                        CompactRiskPill(riskLevel: row.prediction.riskLevel)
                        Text(row.prediction.phenotypeName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("风险看板、临床模型实验室和右下角患者队列共享同一个当前分析对象。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(signals) { signal in
                            RiskSignalCapsule(signal: signal)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .leading, spacing: 8) {
                    RiskActionLine(icon: "chart.line.uptrend.xyaxis", text: "先核查 48h 趋势是否与风险等级一致")
                    RiskActionLine(icon: "square.grid.2x2", text: "再进入临床模型实验室运行诊断/S6/评分对照")
                    RiskActionLine(icon: "externaldrive.connected.to.line.below", text: "需要科研复核时到历史 ICU 数据库查找相似轨迹")
                }
                .frame(width: 360, alignment: .leading)
            }
        }
    }
}

private struct RiskSignal: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    let detail: String
    let color: Color
}

private struct RiskSignalCapsule: View {
    let signal: RiskSignal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(signal.label)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(signal.value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(signal.color)
            if !signal.detail.isEmpty {
                Text(signal.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(signal.color.opacity(0.11))
        .clipShape(Capsule(style: .continuous))
    }
}

private struct RiskActionLine: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.teal)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct RiskValue: View {
    let label: String
    let value: Double
    var suffix: String?
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(suffix ?? "\(Int(value * 100))%")
                .font(.system(size: 13, weight: .bold))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(width: 56, alignment: .trailing)
    }
}

private struct RealtimePatientMonitorView: View {
    let patient: Patient
    let initialPrediction: PredictionResult
    @Bindable var viewModel: AppViewModel
    @State private var latestPrediction: PredictionResult?
    @State private var isPredicting = false

    private var prediction: PredictionResult {
        latestPrediction ?? initialPrediction
    }

    var body: some View {
        WorkbenchSection(title: "\(patient.bedNumber) 实时监控详情", icon: "waveform.path.ecg.rectangle") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(patient.maskedId)
                                .font(.system(size: 18, weight: .bold, design: .monospaced))
                            CompactRiskPill(riskLevel: prediction.riskLevel)
                        }
                        Text("\(patient.icuWard) · \(patient.age)岁 · \(patient.sex == 1 ? "男" : "女") · 入 ICU \(Int(patient.losHours))h")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(prediction.phenotypeName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(riskColor(for: prediction.riskLevel))
                    }

                    Spacer()

                    Button(isPredicting ? "模型运行中" : "刷新预测", systemImage: "play.fill") {
                        Task {
                            isPredicting = true
                            latestPrediction = await viewModel.runPrediction(for: patient)
                            isPredicting = false
                        }
                    }
                    .disabled(isPredicting)
                    .buttonStyle(.borderedProminent)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    RealtimeMetricTile(title: "MAP", value: "\(Int(patient.vitals.map))", unit: "mmHg", color: patient.vitals.map < 65 ? .red : .blue)
                    RealtimeMetricTile(title: "SpO2", value: "\(Int(patient.vitals.spo2))", unit: "%", color: patient.vitals.spo2 < 92 ? .orange : .green)
                    RealtimeMetricTile(title: "乳酸", value: String(format: "%.1f", patient.labs.lactate), unit: "mmol/L", color: patient.labs.lactate > 3 ? .red : .orange)
                    RealtimeMetricTile(title: "心率", value: "\(Int(patient.vitals.heartRate))", unit: "bpm", color: .pink)
                    RealtimeMetricTile(title: "死亡风险", value: "\(Int(prediction.mortalityProbability * 100))", unit: "%", color: .red)
                    RealtimeMetricTile(title: "机械通气", value: "\(Int(prediction.nextMVProbability * 100))", unit: "%", color: .orange)
                    RealtimeMetricTile(title: "剩余 ICU", value: "\(Int(prediction.remainingLOSHours))", unit: "h", color: .purple)
                    RealtimeMetricTile(title: "GCS", value: "\(Int(patient.vitals.gcs))", unit: "", color: patient.vitals.gcs < 13 ? .red : .teal)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("表型轨迹")
                        .font(.system(size: 13, weight: .bold))
                    TrajectoryCompactView(trajectory: prediction.trajectory)
                }

                RealtimeVitalsGrid(patient: patient)
            }
        }
    }
}

private struct RealtimeTrendCard: View {
    let patient: Patient

    var body: some View {
        WorkbenchSection(title: "\(patient.bedNumber) · 48h 实时趋势", icon: "chart.line.uptrend.xyaxis") {
            VStack(alignment: .leading, spacing: 10) {
                Text("趋势图单独承载，避免和风险指标、表型轨迹挤在同一个监控卡片里。乳酸按 x20 缩放用于和血流动力学曲线同屏比较。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                RealtimeTrendChart(history: patient.history)
                    .frame(height: 240)
            }
        }
    }
}

private struct RealtimeMetricTile: View {
    let title: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text(unit)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(minHeight: 72, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.10))
        }
    }
}

private struct RealtimeTrendChart: View {
    let history: [HistoryEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("小时", point.hour),
                        y: .value("数值", point.value)
                    )
                    .foregroundStyle(by: .value("指标", point.metricLabel))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartForegroundStyleScale([
                "HR": .red,
                "MAP": .blue,
                "SpO2": .green,
                "Lac x20": .orange
            ])
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text("\(hour)h")
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading)
            }

            HStack(spacing: 12) {
                ChartLegendDot(label: "HR", color: .red)
                ChartLegendDot(label: "MAP", color: .blue)
                ChartLegendDot(label: "SpO2", color: .green)
                ChartLegendDot(label: "Lac x20", color: .orange)
            }
            .font(.system(size: 10))
        }
    }

    private var points: [RealtimeTrendPoint] {
        let normalizedHistory = normalizedHistoryByHour
        return Self.metrics.flatMap { metric in
            normalizedHistory.map { entry in
                RealtimeTrendPoint(
                    metricID: metric.id,
                    metricLabel: metric.label,
                    hour: entry.hour,
                    value: metric.value(entry)
                )
            }
        }
    }

    private var normalizedHistoryByHour: [HistoryEntry] {
        var latestEntryByHour: [Int: HistoryEntry] = [:]
        for entry in history {
            latestEntryByHour[entry.hour] = entry
        }
        return latestEntryByHour.keys.sorted().compactMap { latestEntryByHour[$0] }
    }

    private static let metrics: [RealtimeTrendMetric] = [
        RealtimeTrendMetric(id: "hr", label: "HR", value: { $0.heartRate }),
        RealtimeTrendMetric(id: "map", label: "MAP", value: { $0.map }),
        RealtimeTrendMetric(id: "spo2", label: "SpO2", value: { $0.spo2 }),
        RealtimeTrendMetric(id: "lac", label: "Lac x20", value: { $0.lactate * 20 })
    ]
}

private struct RealtimeTrendMetric: Identifiable {
    let id: String
    let label: String
    let value: (HistoryEntry) -> Double
}

private struct RealtimeTrendPoint: Identifiable {
    let metricID: String
    let metricLabel: String
    let hour: Int
    let value: Double

    var id: String {
        "\(metricID)-\(hour)"
    }
}

private struct TrajectoryCompactView: View {
    let trajectory: [TrajectoryWindow]

    var body: some View {
        VStack(spacing: 8) {
            ForEach(trajectory) { window in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("W\(window.window) · \(window.startHour)h")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                        Spacer()
                        Text(window.phenotypeName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(window.probabilities.keys.sorted(), id: \.self) { key in
                        let value = window.probabilities[key] ?? 0
                        HStack(spacing: 8) {
                            Text(key)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .frame(width: 26, alignment: .leading)
                            ProgressView(value: value)
                                .tint(phenotypeColor(key))
                            Text("\(Int(value * 100))%")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                }
                .padding(9)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }
}

private struct RealtimeVitalsGrid: View {
    let patient: Patient

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("床旁快照参数")
                .font(.system(size: 13, weight: .bold))
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                VitalsCompactCell(label: "收缩压", value: "\(Int(patient.vitals.sbp))", unit: "mmHg")
                VitalsCompactCell(label: "舒张压", value: "\(Int(patient.vitals.dbp))", unit: "mmHg")
                VitalsCompactCell(label: "呼吸", value: "\(Int(patient.vitals.respRate))", unit: "次/分")
                VitalsCompactCell(label: "体温", value: String(format: "%.1f", patient.vitals.temperature), unit: "C")
                VitalsCompactCell(label: "肌酐", value: String(format: "%.1f", patient.labs.creatinine), unit: "mg/dL")
                VitalsCompactCell(label: "BUN", value: "\(Int(patient.labs.bun))", unit: "mg/dL")
                VitalsCompactCell(label: "WBC", value: String(format: "%.1f", patient.labs.wbc), unit: "K/uL")
                VitalsCompactCell(label: "血小板", value: "\(Int(patient.labs.platelet))", unit: "K/uL")
                VitalsCompactCell(label: "pH", value: String(format: "%.2f", patient.bloodGas.ph), unit: "")
                VitalsCompactCell(label: "PaO2", value: "\(Int(patient.bloodGas.pao2))", unit: "mmHg")
                VitalsCompactCell(label: "PaCO2", value: "\(Int(patient.bloodGas.paco2))", unit: "mmHg")
                VitalsCompactCell(label: "FiO2", value: "\(Int(patient.bloodGas.fio2 * 100))", unit: "%")
            }
        }
    }
}

private struct VitalsCompactCell: View {
    let label: String
    let value: String
    let unit: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
            }
            Text(unit)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct DistributionProgressRow: View {
    let label: String
    let value: Int
    let total: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(value)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            ProgressView(value: Double(value), total: Double(max(total, 1)))
                .tint(color)
        }
    }
}

private struct WardRiskMatrixView: View {
    let items: [WardRiskSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(item.ward)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Text("需关注 \(item.activeRiskCount) / \(item.total)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 3) {
                        ForEach(0..<max(item.total, 1), id: \.self) { index in
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(blockColor(index: index, item: item))
                                .frame(height: 16)
                                .help(blockHelp(index: index, item: item))
                        }
                    }
                }
                .padding(10)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }

    private func blockColor(index: Int, item: WardRiskSummary) -> Color {
        if index < item.critical { return AppBrand.sepsisRed.opacity(0.86) }
        if index < item.critical + item.watch { return AppBrand.lactateAmber.opacity(0.82) }
        return AppBrand.recoveryGreen.opacity(0.48)
    }

    private func blockHelp(index: Int, item: WardRiskSummary) -> String {
        if index < item.critical { return "\(item.ward) 危重样本" }
        if index < item.critical + item.watch { return "\(item.ward) 观察样本" }
        return "\(item.ward) 稳定或恢复样本"
    }
}

private struct WardRiskRow: View {
    let ward: String
    let critical: Int
    let watch: Int
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(ward)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("危重 \(critical) / 观察 \(watch) / 总数 \(total)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                let criticalWidth = width * CGFloat(Double(critical) / Double(max(total, 1)))
                let watchWidth = width * CGFloat(Double(watch) / Double(max(total, 1)))
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color.orange.opacity(0.55)).frame(width: criticalWidth + watchWidth)
                    Capsule().fill(Color.red.opacity(0.76)).frame(width: criticalWidth)
                }
            }
            .frame(height: 8)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct ModelModuleRow: View {
    let name: String
    let endpoint: String
    let status: String
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                Text(endpoint)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(status)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct RuntimeMetricRow: View {
    let label: String
    let value: Double?
    var digits: Int = 3
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(formattedValue)
                    .font(.system(size: 13, weight: .bold))
            }
            ProgressView(value: progressValue)
                .tint(.teal)
        }
    }
    
    private var formattedValue: String {
        guard let value else { return "--" }
        return String(format: "%.\(digits)f", value)
    }
    
    private var progressValue: Double {
        guard let value else { return 0 }
        return min(max(value, 0), 1)
    }
}

private struct FamilyScoreRow: View {
    let name: String
    let value: String
    let note: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 12) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 48, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        }
    }
}

private struct InfoLine: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private let dashboardColumns = [
    GridItem(.flexible(), spacing: 14),
    GridItem(.flexible(), spacing: 14),
    GridItem(.flexible(), spacing: 14),
    GridItem(.flexible(), spacing: 14)
]
