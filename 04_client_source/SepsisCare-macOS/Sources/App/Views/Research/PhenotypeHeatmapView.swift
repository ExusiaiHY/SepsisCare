import SwiftUI
import Charts

struct PhenotypeHeatmapView: View {
    let trajectory: [TrajectoryWindow]
    
    var data: [(window: String, phenotype: String, probability: Double)] {
        var result: [(String, String, Double)] = []
        for window in trajectory {
            for (pheno, prob) in window.probabilities {
                result.append(("W\(window.window)", pheno, prob))
            }
        }
        return result
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("表型转移概率热力图")
                .font(.headline)
            
            Chart(data, id: \.0) { item in
                RectangleMark(
                    x: .value("时间窗", item.window),
                    y: .value("表型", item.phenotype)
                )
                .foregroundStyle(by: .value("概率", item.probability))
            }
            .chartForegroundStyleScale(range: Gradient(colors: [.white, .teal, .orange, .red]))
            .chartLegend(position: .bottom)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }
}
