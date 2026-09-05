import SwiftUI
import Charts

struct RiskGaugeView: View {
    let prediction: PredictionResult
    
    var body: some View {
        HStack(spacing: 24) {
            GaugeView(title: "死亡风险", value: prediction.mortalityProbability, color: .red)
            GaugeView(title: "机械通气", value: prediction.nextMVProbability, color: .orange)
            GaugeView(title: "危重指数", value: prediction.riskLevel == .critical ? 0.9 : prediction.riskLevel == .watch ? 0.6 : 0.2, color: prediction.riskLevel == .critical ? .red : .teal)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }
}

struct GaugeView: View {
    let title: String
    let value: Double
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(color.opacity(0.2), style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(135))
                
                Circle()
                    .trim(from: 0, to: 0.75 * value)
                    .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .animation(.easeInOut(duration: 1.0), value: value)
                
                VStack(spacing: 2) {
                    Text("\(value * 100, specifier: "%.0f")%")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(color)
                }
            }
            .frame(width: 120, height: 120)
        }
    }
}
