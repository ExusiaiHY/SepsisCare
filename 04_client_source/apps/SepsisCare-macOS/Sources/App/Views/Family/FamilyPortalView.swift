import SwiftUI

struct FamilyPortalView: View {
    @Bindable var viewModel: AppViewModel
    
    var body: some View {
        Group {
            if let patient = viewModel.selectedPatient {
                ZStack {
                    BrandPatternBackdrop(style: .family, intensity: 0.78)
                    VStack(spacing: 0) {
                        FamilyPatientSummary(patient: patient, prediction: patient.predictions.last)
                            .padding(20)
                        ChatView(viewModel: viewModel, patient: patient)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("未选择患者", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text("请在左侧选择一位患者开始沟通")
                }
            }
        }
    }
}

struct FamilyPatientSummary: View {
    let patient: Patient
    let prediction: PredictionResult?
    
    var body: some View {
        HStack(spacing: 20) {
            BrandLogoMark(size: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text("\(patient.bedNumber) \(patient.name)")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text("\(patient.age)岁 · \(patient.sex == 1 ? "男性" : "女性")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if let pred = prediction {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 8) {
                        StatusPill(text: pred.riskLevel.displayName, color: pred.riskLevel == .critical ? .red : pred.riskLevel == .watch ? .orange : .teal)
                        StatusPill(text: pred.phenotypeName, color: .blue)
                    }
                    Text("当前状态由研究模型评估，仅供参考")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("暂无预测数据")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppBrand.familyAqua.opacity(0.18), lineWidth: 1)
        }
    }
}

struct StatusPill: View {
    let text: String
    let color: Color
    
    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(Capsule(style: .continuous))
    }
}
