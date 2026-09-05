import Foundation

struct PredictionResult: Identifiable, Hashable, Codable {
    let id = UUID()
    var timestamp: Date
    var phenotypeId: String
    var phenotypeName: String
    var riskLevel: RiskLevel
    var mortalityProbability: Double
    var nextMVProbability: Double
    var remainingLOSHours: Double
    var trajectory: [TrajectoryWindow]

    enum CodingKeys: String, CodingKey {
        case timestamp
        case phenotypeId
        case phenotypeName
        case riskLevel
        case mortalityProbability
        case nextMVProbability
        case remainingLOSHours
        case trajectory
    }
    
    static func mock(for patient: Patient) -> PredictionResult {
        let isHighRisk = patient.vitals.map < 65 || patient.labs.lactate > 3.0
        return PredictionResult(
            timestamp: Date(),
            phenotypeId: isHighRisk ? "P3" : "P1",
            phenotypeName: isHighRisk ? "炎症风暴型" : "相对稳定型",
            riskLevel: isHighRisk ? .critical : .stable,
            mortalityProbability: isHighRisk ? 0.35 : 0.08,
            nextMVProbability: isHighRisk ? 0.62 : 0.15,
            remainingLOSHours: isHighRisk ? 72 : 36,
            trajectory: [
                TrajectoryWindow(window: 1, startHour: 0, phenotypeId: "P1", phenotypeName: "相对稳定型", probabilities: ["P1": 0.7, "P2": 0.2, "P3": 0.1]),
                TrajectoryWindow(window: 2, startHour: 6, phenotypeId: "P2", phenotypeName: "炎症进展型", probabilities: ["P1": 0.3, "P2": 0.5, "P3": 0.2]),
                TrajectoryWindow(window: 3, startHour: 12, phenotypeId: "P3", phenotypeName: "炎症风暴型", probabilities: ["P1": 0.1, "P2": 0.3, "P3": 0.6]),
                TrajectoryWindow(window: 4, startHour: 24, phenotypeId: "P3", phenotypeName: "炎症风暴型", probabilities: ["P1": 0.05, "P2": 0.25, "P3": 0.7])
            ]
        )
    }
}

enum RiskLevel: String, CaseIterable, Codable {
    case stable = "stable"
    case watch = "watch"
    case critical = "critical"
    case recovering = "recovering"
    
    var displayName: String {
        switch self {
        case .stable: return "稳定"
        case .watch: return "观察"
        case .critical: return "危重"
        case .recovering: return "恢复中"
        }
    }
    
    var color: String {
        switch self {
        case .stable: return "teal"
        case .watch: return "amber"
        case .critical: return "red"
        case .recovering: return "blue"
        }
    }
}

struct TrajectoryWindow: Identifiable, Hashable, Codable {
    let id = UUID()
    var window: Int
    var startHour: Int
    var phenotypeId: String
    var phenotypeName: String
    var probabilities: [String: Double]

    enum CodingKeys: String, CodingKey {
        case window
        case startHour
        case phenotypeId
        case phenotypeName
        case probabilities
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    let text: String
    let timestamp: Date
}

enum ChatRole {
    case user
    case assistant
}
