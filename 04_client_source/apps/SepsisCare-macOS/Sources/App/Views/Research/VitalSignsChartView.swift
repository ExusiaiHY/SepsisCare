import SwiftUI
import Charts

struct VitalSignsChartView: View {
    let history: [HistoryEntry]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("生命体征趋势")
                .font(.headline)
            
            Chart {
                ForEach(points) { point in
                    LineMark(
                        x: .value("时间", point.hour),
                        y: .value("数值", point.value)
                    )
                    .foregroundStyle(by: .value("指标", point.metricLabel))
                }
            }
            .chartForegroundStyleScale([
                "心率": .red,
                "MAP": .blue,
                "乳酸(x30)": .orange
            ])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis {
                AxisMarks(position: .leading)
            }
            .chartXAxis {
                AxisMarks(position: .bottom) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let hour = value.as(Int.self) {
                            Text("\(hour)h")
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    private var points: [VitalTrendPoint] {
        let normalized = normalizedHistoryByHour
        return [
            VitalTrendMetric(id: "heart_rate", label: "心率", value: { $0.heartRate }),
            VitalTrendMetric(id: "map", label: "MAP", value: { $0.map }),
            VitalTrendMetric(id: "lactate", label: "乳酸(x30)", value: { $0.lactate * 30 })
        ].flatMap { metric in
            normalized.map { entry in
                VitalTrendPoint(
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
}

private struct VitalTrendMetric: Identifiable {
    let id: String
    let label: String
    let value: (HistoryEntry) -> Double
}

private struct VitalTrendPoint: Identifiable {
    let metricID: String
    let metricLabel: String
    let hour: Int
    let value: Double

    var id: String {
        "\(metricID)-\(hour)"
    }
}
