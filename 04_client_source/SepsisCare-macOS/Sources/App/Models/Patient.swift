import Foundation

struct Patient: Identifiable, Hashable {
    var id: String = UUID().uuidString
    var maskedId: String = ""
    var bedNumber: String
    var name: String
    var age: Int
    var sex: Int // 1 = 男, 0 = 女
    var admissionTime: String = "2024-04-02"
    var icuWard: String = "综合ICU"
    var phenotypeLabel: String = "P0 低危型"
    var consistencyLabel: String = "L5 完全一致"
    var consistencyTone: String = "stable"
    var lastPrediction: String = "2小时前"
    var mortalityFlag: Int = 0
    var losHours: Double = 48
    var vitals: VitalSigns
    var labs: LabValues
    var bloodGas: BloodGasValues
    var history: [HistoryEntry]
    var predictions: [PredictionResult]
    
    static let mockPatients: [Patient] = generateMockPatients(count: 50)
    
    private static func generateMockPatients(count: Int) -> [Patient] {
        let wards = ["心内ICU", "外科ICU", "内科ICU", "综合ICU"]
        let phenotypes = ["P0 低危型", "P1 中高危型", "P2 高危型", "P3 低中危型"]
        let consistency = [
            ("L5 完全一致", "stable"),
            ("L4 大部分一致", "good"),
            ("L3 中等一致", "watch"),
            ("L2 大部分不一致", "warning"),
            ("L1 完全不一致", "critical"),
        ]
        
        return (0..<count).map { index in
            let patientNumber = 12000 + index * 17
            let severity = index % 5
            let wave = Double((index * 37) % 11) - 5
            let isMale = index % 2 == 0
            let age = 42 + (index * 7) % 43
            let heartRate = 82 + Double(severity * 8) + wave
            let sbp = 122 - Double(severity * 8) + wave
            let dbp = 70 - Double(severity * 4)
            let map = (sbp + 2 * dbp) / 3
            let resp = 17 + Double(severity * 2)
            let spo2 = 98 - Double(severity * 2)
            let temperature = 36.7 + Double(severity) * 0.35
            let lactate = 1.2 + Double(severity) * 0.72 + max(wave, 0) * 0.08
            let creatinine = 0.9 + Double(severity) * 0.28
            let platelet = 230 - Double(severity * 28)
            let ward = wards[index % wards.count]
            let phenotype = phenotypes[severity == 4 ? 2 : severity % phenotypes.count]
            let consistencyItem = consistency[index % consistency.count]
            
            let history = [0, 6, 12, 24, 36, 48].map { hour in
                let drift = Double(hour) / 12.0
                return HistoryEntry(
                    hour: hour,
                    heartRate: heartRate - 8 + drift * Double(max(severity, 1)),
                    map: map + 5 - drift * Double(severity),
                    respRate: resp - 2 + drift,
                    spo2: spo2 + 1 - drift * 0.4,
                    temperature: temperature - 0.2 + drift * 0.05,
                    lactate: lactate - 0.5 + drift * 0.12
                )
            }
            
            return Patient(
                id: "P-\(patientNumber)",
                maskedId: "SC-\(String(format: "%05d", patientNumber))",
                bedNumber: "ICU-\(String(format: "%02d", index + 1))",
                name: "脱敏患者\(index + 1)",
                age: age,
                sex: isMale ? 1 : 0,
                admissionTime: "2024-\(String(format: "%02d", index % 12 + 1))-\(String(format: "%02d", index % 28 + 1))",
                icuWard: ward,
                phenotypeLabel: phenotype,
                consistencyLabel: consistencyItem.0,
                consistencyTone: consistencyItem.1,
                lastPrediction: "\(index % 6 + 1)小时前",
                mortalityFlag: severity >= 4 ? 1 : 0,
                losHours: 24 + Double(severity * 18) + Double(index % 8),
                vitals: VitalSigns(
                    heartRate: heartRate,
                    sbp: sbp,
                    dbp: dbp,
                    map: map,
                    respRate: resp,
                    spo2: spo2,
                    temperature: temperature,
                    gcs: severity >= 4 ? 10 : severity >= 3 ? 13 : 15
                ),
                labs: LabValues(
                    creatinine: creatinine,
                    bun: 15 + Double(severity * 8),
                    glucose: 118 + Double(severity * 18),
                    wbc: 8.8 + Double(severity) * 2.9,
                    platelet: platelet,
                    potassium: 3.8 + Double(severity) * 0.18,
                    sodium: 140 - Double(severity),
                    lactate: lactate,
                    bilirubin: 0.8 + Double(severity) * 0.32
                ),
                bloodGas: BloodGasValues(
                    ph: 7.41 - Double(severity) * 0.035,
                    pao2: 96 - Double(severity * 8),
                    paco2: 37 + Double(severity * 2),
                    fio2: 0.28 + Double(severity) * 0.08
                ),
                history: history,
                predictions: []
            )
        }
    }
}

struct VitalSigns: Hashable {
    var heartRate: Double
    var sbp: Double
    var dbp: Double
    var map: Double
    var respRate: Double
    var spo2: Double
    var temperature: Double
    var gcs: Double
}

struct LabValues: Hashable {
    var creatinine: Double
    var bun: Double
    var glucose: Double
    var wbc: Double
    var platelet: Double
    var potassium: Double
    var sodium: Double
    var lactate: Double
    var bilirubin: Double
}

struct BloodGasValues: Hashable {
    var ph: Double
    var pao2: Double
    var paco2: Double
    var fio2: Double
}

struct HistoryEntry: Identifiable, Hashable {
    let id = UUID()
    var hour: Int
    var heartRate: Double
    var map: Double
    var respRate: Double
    var spo2: Double
    var temperature: Double
    var lactate: Double
}
