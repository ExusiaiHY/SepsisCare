import Foundation

enum SepsisCareAPI {
    static let cloudBaseURL = "http://100.65.136.96:8788"
    static let localBaseURL = "http://127.0.0.1:8765"
    static let legacyCloudBaseURL = "http://106.55.230.127"
    static let defaultBaseURL = localBaseURL
    static let apiBaseURLUserDefaultsKey = "sepsis.apiBaseURL"
    static let serviceTokenUserDefaultsKey = "sepsis.serviceToken"
    static let serviceTokenFileName = "sepsiscare_service_token.txt"
    static let remoteBaseURLHelp = "客户端默认连接本地 API：\(localBaseURL)。训练终端可使用远程模型服务：\(cloudBaseURL)，也可填写 http://目标电脑IP:端口、http://server.local:端口 或 http://[IPv6地址]:端口"

    static func normalizedBaseURL(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return defaultBaseURL }

        while normalized.hasSuffix("/"),
              normalized.lowercased() != "http://",
              normalized.lowercased() != "https://" {
            normalized.removeLast()
        }

        return normalized.isEmpty ? defaultBaseURL : bracketBareIPv6Authority(in: normalized)
    }

    static func normalizedSavedBaseURL(_ value: String) -> String {
        let normalized = normalizedBaseURL(value)
        if normalized == cloudBaseURL || normalized == legacyCloudBaseURL {
            return defaultBaseURL
        }
        return normalized
    }

    static func normalizedServiceToken(_ value: String) -> String {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("bearer ") {
            normalized = String(normalized.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    static func authorizationHeader(for token: String) -> String? {
        let normalized = normalizedServiceToken(token)
        return normalized.isEmpty ? nil : "Bearer \(normalized)"
    }

    static func serviceTokenFileCandidates(fileManager: FileManager = .default) -> [URL] {
        var candidates: [URL] = []
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent("SepsisCare", isDirectory: true).appendingPathComponent(serviceTokenFileName))
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        candidates.append(home.appendingPathComponent("Library/Application Support/SepsisCare", isDirectory: true).appendingPathComponent(serviceTokenFileName))

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static func fileBackedServiceToken(fileManager: FileManager = .default) -> String {
        for url in serviceTokenFileCandidates(fileManager: fileManager) {
            guard fileManager.fileExists(atPath: url.path),
                  let raw = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }
            let normalized = normalizedServiceToken(raw)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return ""
    }

    static func configuredServiceToken(defaults: UserDefaults = .standard, fileManager: FileManager = .default) -> String {
        if let savedServiceToken = defaults.string(forKey: serviceTokenUserDefaultsKey) {
            let normalized = normalizedServiceToken(savedServiceToken)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return fileBackedServiceToken(fileManager: fileManager)
    }

    private static func bracketBareIPv6Authority(in baseURL: String) -> String {
        guard let schemeRange = baseURL.range(of: "://") else { return baseURL }

        let prefix = String(baseURL[..<schemeRange.upperBound])
        let remainder = String(baseURL[schemeRange.upperBound...])
        guard !remainder.hasPrefix("[") else { return baseURL }

        let pathIndex = remainder.firstIndex(of: "/") ?? remainder.endIndex
        let authority = String(remainder[..<pathIndex])
        let suffix = String(remainder[pathIndex...])
        guard authority.filter({ $0 == ":" }).count >= 2 else { return baseURL }

        var host = authority
        var port: String?
        if let lastColon = authority.lastIndex(of: ":") {
            let candidatePort = String(authority[authority.index(after: lastColon)...])
            if !candidatePort.isEmpty && candidatePort.allSatisfy(\.isNumber) {
                host = String(authority[..<lastColon])
                port = candidatePort
            }
        }

        guard !host.isEmpty else { return baseURL }
        let bracketedAuthority = port.map { "[\(host)]:\($0)" } ?? "[\(host)]"
        return prefix + bracketedAuthority + suffix
    }
}

enum APIError: Error {
    case invalidURL
    case requestFailed(Int)
    case decodingFailed
    case backendNotReady
}

actor APIClient {
    static let shared = APIClient()
    init() {
        if let savedBaseURL = UserDefaults.standard.string(forKey: SepsisCareAPI.apiBaseURLUserDefaultsKey) {
            baseURL = SepsisCareAPI.normalizedSavedBaseURL(savedBaseURL)
        }
        serviceToken = SepsisCareAPI.configuredServiceToken()
    }

    var baseURL: String = SepsisCareAPI.defaultBaseURL
    private var serviceToken: String = ""
    
    func setBaseURL(_ value: String) {
        baseURL = SepsisCareAPI.normalizedBaseURL(value)
    }

    func setServiceToken(_ value: String) {
        serviceToken = SepsisCareAPI.normalizedServiceToken(value)
        if serviceToken.isEmpty {
            UserDefaults.standard.removeObject(forKey: SepsisCareAPI.serviceTokenUserDefaultsKey)
        } else {
            UserDefaults.standard.set(serviceToken, forKey: SepsisCareAPI.serviceTokenUserDefaultsKey)
        }
    }

    func buildRequest(path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        serviceToken = SepsisCareAPI.configuredServiceToken()

        guard let url = URL(string: baseURL + path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorization = SepsisCareAPI.authorizationHeader(for: serviceToken) {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        request.httpBody = body
        return request
    }

    func fetch<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        let request = try buildRequest(path: path, method: method, body: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchText(_ path: String) async throws -> String {
        let request = try buildRequest(path: path)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.requestFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    func fetchJSON(_ path: String, method: String = "GET", body: JSONValue? = nil) async throws -> JSONValue {
        let encodedBody = try body.map { try JSONEncoder().encode($0) }
        return try await fetch(path, method: method, body: encodedBody)
    }
    
    func getHealth() async throws -> HealthResponse {
        try await fetch("/health")
    }
    
    func getModelMetadata() async throws -> ModelMetadata {
        try await fetch("/api/model/metadata")
    }
    
    func getDeploymentConfig() async throws -> DeploymentConfigResponse {
        try await fetch("/api/deployment/config")
    }

    func getPatients(page: Int = 1, perPage: Int = 20, search: String = "", riskLevel: String = "all", icuType: String = "all", phenotype: String = "-1", consistency: String = "all") async throws -> PatientListResponse {
        var components = URLComponents()
        components.path = "/api/patients"
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "search", value: search),
            URLQueryItem(name: "risk_level", value: riskLevel),
            URLQueryItem(name: "icu_type", value: icuType),
            URLQueryItem(name: "phenotype", value: phenotype),
            URLQueryItem(name: "consistency", value: consistency)
        ]
        return try await fetch(components.string ?? "/api/patients")
    }

    func getPatientDetail(maskedID: String) async throws -> JSONValue {
        try await fetchJSON("/api/patients/\(maskedID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? maskedID)")
    }

    func getDashboardStats() async throws -> JSONValue {
        try await fetchJSON("/api/dashboard/stats")
    }

    func getFilterOptions() async throws -> JSONValue {
        try await fetchJSON("/api/filters/options")
    }

    func getSubtypeMetadata() async throws -> JSONValue {
        try await fetchJSON("/api/sepsis-subtypes/metadata")
    }

    func getSystemConfig() async throws -> JSONValue {
        try await fetchJSON("/api/config/system")
    }

    func getAIConfig() async throws -> JSONValue {
        try await fetchJSON("/api/config/ai")
    }

    func getDeepSeekConfig() async throws -> DeepSeekConfigResponse {
        try await fetch("/api/config/deepseek")
    }

    func postDeepSeekConfig(apiKey: String, model: String, baseURL: String, timeoutSeconds: String, clearKey: Bool = false) async throws -> DeepSeekConfigResponse {
        let payload: JSONValue = .object([
            "api_key": .string(apiKey),
            "model": .string(model),
            "base_url": .string(baseURL),
            "timeout_seconds": .string(timeoutSeconds),
            "clear_key": .bool(clearKey)
        ])
        return try await fetch(
            "/api/config/deepseek",
            method: "POST",
            body: JSONEncoder().encode(payload)
        )
    }

    func getAIAnalysis() async throws -> JSONValue {
        try await fetchJSON("/api/ai/analysis")
    }

    func getDiagnoseFeatures() async throws -> JSONValue {
        try await fetchJSON("/api/diagnose/features")
    }

    func getMonitorReport(patientID: String) async throws -> JSONValue {
        try await fetchJSON("/api/monitor/report/\(patientID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? patientID)")
    }

    func getBedsideBeds(limit: Int = 12) async throws -> JSONValue {
        try await fetchJSON("/api/bedside/beds?limit=\(limit)")
    }

    func getBedsideSnapshot(bedNo: String) async throws -> JSONValue {
        try await fetchJSON("/api/bedside/snapshot/\(bedNo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? bedNo)")
    }

    func getAdminStatus() async throws -> AdminStatusResponse {
        let status: AdminStatusResponse = try await fetch("/api/admin/status")
        guard let config = try? await getDeepSeekConfig() else {
            return status
        }
        return status.applying(deepSeekConfig: config)
    }

    func getAdminBindings() async throws -> AdminBindingResponse {
        try await fetch("/api/admin/bindings")
    }

    func postAdminBinding(account: String = "family", patientRef: String) async throws -> AdminBindingUpdateResponse {
        try await fetch(
            "/api/admin/bindings",
            method: "POST",
            body: JSONEncoder().encode(JSONValue.object(["account": .string(account), "patient_ref": .string(patientRef)]))
        )
    }

    func getHistoricalPatients(
        page: Int = 1,
        perPage: Int = 100,
        search: String = "",
        sort: String = "los_desc",
        source: String = "all",
        icuType: String = "all",
        outcome: String = "all",
        phenotype: String = "all",
        consistency: String = "all"
    ) async throws -> HistoricalPatientListResponse {
        var components = URLComponents()
        components.path = "/api/history/patients"
        components.queryItems = [
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "search", value: search),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "icu_type", value: icuType),
            URLQueryItem(name: "outcome", value: outcome),
            URLQueryItem(name: "phenotype", value: phenotype),
            URLQueryItem(name: "consistency", value: consistency)
        ]
        return try await fetch(components.string ?? "/api/history/patients")
    }

    func getHistoricalStats() async throws -> JSONValue {
        try await fetchJSON("/api/history/stats")
    }

    func getTrainingTerminalStatus() async throws -> TrainingTerminalStatusResponse {
        try await fetch("/api/training-terminal/status")
    }

    func getTrainingTerminalLogs(limit: Int = 80) async throws -> TrainingTerminalLogsResponse {
        try await fetch("/api/training-terminal/logs?limit=\(limit)")
    }

    func getICURealtimeStatus() async throws -> ICURealtimeStatusResponse {
        try await fetch("/api/icu/realtime/status")
    }

    func getICURealtimeDemo() async throws -> ICURealtimeDemoResponse {
        try await fetch("/api/icu/realtime/demo")
    }

    func postICURealtimeIngest(payload: JSONValue) async throws -> ICURealtimeIngestResponse {
        try await fetch(
            "/api/icu/realtime/ingest",
            method: "POST",
            body: JSONEncoder().encode(payload)
        )
    }

    func postICURealtimeUpload(cloudBaseURL: String, limit: Int = 500) async throws -> ICURealtimeUploadResponse {
        let payload = JSONValue.object([
            "cloud_base_url": .string(cloudBaseURL),
            "limit": .number(Double(limit))
        ])
        return try await fetch(
            "/api/icu/realtime/upload",
            method: "POST",
            body: JSONEncoder().encode(payload)
        )
    }

    func postTrainingTerminalConfig(mode: String, cloudBaseURL: String, params: [String: JSONValue] = [:]) async throws -> TrainingTerminalStatusResponse {
        let payload = JSONValue.object([
            "mode": .string(mode),
            "cloud_base_url": .string(cloudBaseURL),
            "params": .object(params)
        ])
        let body = try JSONEncoder().encode(payload)
        return try await fetch(
            "/api/training-terminal/config",
            method: "POST",
            body: body
        )
    }

    func postTrainingTerminalAction(_ action: String) async throws -> TrainingTerminalActionResponse {
        let body = try JSONEncoder().encode(JSONValue.object(["action": .string(action)]))
        return try await fetch(
            "/api/training-terminal/action",
            method: "POST",
            body: body
        )
    }

    func postTrainingTerminalCommand(_ command: String) async throws -> TrainingTerminalActionResponse {
        let body = try JSONEncoder().encode(JSONValue.object(["command": .string(command)]))
        return try await fetch(
            "/api/training-terminal/command",
            method: "POST",
            body: body
        )
    }

    func getHistoricalPatientDetail(historyID: String) async throws -> HistoricalPatientDetail {
        try await fetch("/api/history/patients/\(historyID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? historyID)")
    }

    func exportHistoricalCSV(
        scope: String = "list",
        historyID: String? = nil,
        page: Int = 1,
        perPage: Int = 100,
        search: String = "",
        sort: String = "los_desc",
        source: String = "all",
        icuType: String = "all",
        outcome: String = "all",
        phenotype: String = "all",
        consistency: String = "all"
    ) async throws -> String {
        var components = URLComponents()
        components.path = "/api/history/export"
        components.queryItems = [
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per_page", value: String(perPage)),
            URLQueryItem(name: "search", value: search),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "source", value: source),
            URLQueryItem(name: "icu_type", value: icuType),
            URLQueryItem(name: "outcome", value: outcome),
            URLQueryItem(name: "phenotype", value: phenotype),
            URLQueryItem(name: "consistency", value: consistency)
        ]
        if let historyID {
            components.queryItems?.append(URLQueryItem(name: "history_id", value: historyID))
        }
        return try await fetchText(components.string ?? "/api/history/export?scope=list")
    }

    func postDiagnose(patient: Patient) async throws -> JSONValue {
        try await fetchJSON("/api/diagnose", method: "POST", body: webAppPatientPayload(patient))
    }

    func postDiagnoseBatch(patients: [Patient]) async throws -> JSONValue {
        try await fetchJSON("/api/diagnose/batch", method: "POST", body: .object(["patients": .array(patients.map(webAppPatientPayload))]))
    }

    func postClinicalPipeline(patient: Patient) async throws -> JSONValue {
        try await fetchJSON("/api/clinical/pipeline", method: "POST", body: webAppPatientPayload(patient))
    }

    func postClinicalScores(patient: Patient) async throws -> JSONValue {
        try await fetchJSON("/api/clinical/scores", method: "POST", body: webAppPatientPayload(patient))
    }

    func postSubtypePredict() async throws -> JSONValue {
        try await fetchJSON("/api/sepsis-subtypes/predict", method: "POST", body: subtypePayload)
    }

    func postSubtypePredict(patient: Patient) async throws -> JSONValue {
        try await fetchJSON("/api/sepsis-subtypes/predict", method: "POST", body: subtypePayload(for: patient))
    }

    func postSubtypeRecommend() async throws -> JSONValue {
        try await fetchJSON("/api/sepsis-subtypes/recommend", method: "POST", body: subtypePayload)
    }

    func postSubtypeRecommend(patient: Patient) async throws -> JSONValue {
        try await fetchJSON("/api/sepsis-subtypes/recommend", method: "POST", body: subtypePayload(for: patient))
    }

    func postLLMDiagnose(patient: Patient) async throws -> JSONValue {
        try await fetchJSON("/api/ai/llm-diagnose", method: "POST", body: webAppPatientPayload(patient))
    }

    func postAIExplain(term: String, context: String = "") async throws -> JSONValue {
        try await fetchJSON("/api/ai/explain", method: "POST", body: .object(["term": .string(term), "context": .string(context)]))
    }

    func postAssistantChat(question: String) async throws -> JSONValue {
        try await fetchJSON("/api/ai/assistant-chat", method: "POST", body: .object(["question": .string(question), "context": .object([:])]))
    }
    
    func postPrediction(payload: PredictionPayload) async throws -> PredictionResponse {
        let body = try JSONEncoder().encode(payload)
        return try await fetch("/api/model/predict", method: "POST", body: body)
    }
    
    func postFamilyChat(question: String, patientRef: String, prediction: PredictionResult?) async throws -> ChatResponse {
        let payload = FamilyChatPayload(
            patient_ref: patientRef,
            question: question,
            prediction: prediction.map { ChatPredictionPayload(result: $0) },
            context: ChatContext(interface: "family", model: "SepsisCare Studio", scope: "explanation_and_communication_only")
        )
        let body = try JSONEncoder().encode(payload)
        return try await fetch("/api/family/chat", method: "POST", body: body)
    }

    private func webAppPatientPayload(_ patient: Patient) -> JSONValue {
        .object([
            "age": .number(Double(patient.age)),
            "sex": .number(Double(patient.sex)),
            "icu_type": .number(1),
            "vitals": .object([
                "heart_rate": .number(patient.vitals.heartRate),
                "sbp": .number(patient.vitals.sbp),
                "dbp": .number(patient.vitals.dbp),
                "map": .number(patient.vitals.map),
                "resp_rate": .number(patient.vitals.respRate),
                "spo2": .number(patient.vitals.spo2),
                "temperature": .number(patient.vitals.temperature),
                "gcs": .number(patient.vitals.gcs)
            ]),
            "labs": .object([
                "creatinine": .number(patient.labs.creatinine),
                "bun": .number(patient.labs.bun),
                "glucose": .number(patient.labs.glucose),
                "wbc": .number(patient.labs.wbc),
                "platelet": .number(patient.labs.platelet),
                "potassium": .number(patient.labs.potassium),
                "sodium": .number(patient.labs.sodium),
                "lactate": .number(patient.labs.lactate),
                "bilirubin": .number(patient.labs.bilirubin)
            ])
        ])
    }

    private var subtypePayload: JSONValue {
        let featureVector = Array(repeating: JSONValue.number(0.2), count: 43)
        let sequence = Array(repeating: JSONValue.array(featureVector), count: 48)
        return .object(["time_series": .array([.array(sequence)]), "mortality_threshold": .number(0.4)])
    }

    private func subtypePayload(for patient: Patient) -> JSONValue {
        let baseFeatures: [Double] = [
            Double(patient.age) / 100.0,
            Double(patient.sex),
            patient.vitals.heartRate / 180.0,
            patient.vitals.sbp / 220.0,
            patient.vitals.dbp / 140.0,
            patient.vitals.map / 140.0,
            patient.vitals.respRate / 45.0,
            patient.vitals.spo2 / 100.0,
            patient.vitals.temperature / 42.0,
            patient.vitals.gcs / 15.0,
            patient.labs.creatinine / 6.0,
            patient.labs.bun / 120.0,
            patient.labs.glucose / 400.0,
            patient.labs.wbc / 40.0,
            patient.labs.platelet / 500.0,
            patient.labs.potassium / 7.0,
            patient.labs.sodium / 170.0,
            patient.labs.lactate / 12.0,
            patient.labs.bilirubin / 10.0,
            patient.bloodGas.ph / 7.8,
            patient.bloodGas.pao2 / 220.0,
            patient.bloodGas.paco2 / 90.0,
            patient.bloodGas.fio2
        ]
        let padded = baseFeatures + Array(repeating: 0.0, count: max(0, 43 - baseFeatures.count))
        let featureVector = Array(padded.prefix(43)).map { JSONValue.number(min(max($0, 0), 1.5)) }
        let sequence = Array(repeating: JSONValue.array(featureVector), count: 48)
        return .object([
            "patient_ref": .string(patient.maskedId.isEmpty ? patient.bedNumber : patient.maskedId),
            "time_series": .array([.array(sequence)]),
            "mortality_threshold": .number(0.4)
        ])
    }
}

enum JSONValue: Codable, Hashable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var description: String {
        guard let data = try? JSONEncoder.pretty.encode(self),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

struct HealthResponse: Decodable {
    let status: String
    let service: String
}

struct ModelMetadata: Decodable {
    let app_model: String
    let device: String
    let metrics: ModelMetrics
}

struct ModelMetrics: Decodable {
    let encoder_macro_f1: Double
    let encoder_transition_macro_f1: Double
    let mortality_auroc: Double
    let next_mv_auroc: Double
    let remaining_los_mae_hours: Double
}

struct DeploymentConfigResponse: Decodable {
    let backend_mode: String
    let api_base_url: String
    let device_requested: String
    let device_resolved: String
    let llm_configured: Bool
    let llm_provider: String
    let llm_model: String
    let deidentification: String
    let model_release: String
    let interfaces: [String]
}

struct DeepSeekConfigResponse: Decodable {
    let provider: String
    let configured: Bool
    let model: String
    let base_url: String
    let timeout_seconds: String
    let api_key_hint: String
    let config_path: String
    let saved: Bool?
}

struct PredictionPayload: Encodable {
    let patient_ref: String
    let use_transition: Bool
    let current: CurrentState
    let history: [HistoryPayload]
}

struct CurrentState: Encodable {
    let age: Int
    let sex: Int
    let vitals: [String: Double]
    let labs: [String: Double]
    let blood_gas: [String: Double]
}

struct HistoryPayload: Encodable {
    let hour: Int
    let values: [String: Double]
}

struct PredictionResponse: Decodable {
    let latest: LatestPrediction
    let risk_level: String
    let trajectory: [TrajectoryResponse]
}

struct LatestPrediction: Decodable {
    let phenotype: PhenotypeInfo
    let mortality_probability: Double
    let next_mech_vent_probability: Double
    let remaining_los_hours: Double
}

struct PhenotypeInfo: Decodable {
    let id: String
    let name: String
    let family_label: String?
    let description: String?
}

struct TrajectoryResponse: Decodable {
    let window: Int
    let start_hour: Int
    let phenotype: PhenotypeInfo
    let probabilities: [String: Double]
}

struct FamilyChatPayload: Encodable {
    let patient_ref: String
    let question: String
    let prediction: ChatPredictionPayload?
    let context: ChatContext
}

struct ChatPredictionPayload: Encodable {
    let latest: ChatLatestPredictionPayload
    let risk_level: String
    let trajectory: [ChatTrajectoryPayload]
    
    init(result: PredictionResult) {
        latest = ChatLatestPredictionPayload(result: result)
        risk_level = result.riskLevel.rawValue
        trajectory = result.trajectory.map(ChatTrajectoryPayload.init)
    }
}

struct ChatLatestPredictionPayload: Encodable {
    let phenotype: ChatPhenotypePayload
    let mortality_probability: Double
    let next_mech_vent_probability: Double
    let remaining_los_hours: Double
    
    init(result: PredictionResult) {
        phenotype = ChatPhenotypePayload(id: result.phenotypeId, name: result.phenotypeName)
        mortality_probability = result.mortalityProbability
        next_mech_vent_probability = result.nextMVProbability
        remaining_los_hours = result.remainingLOSHours
    }
}

struct ChatPhenotypePayload: Encodable {
    let id: String
    let name: String
}

struct ChatTrajectoryPayload: Encodable {
    let window: Int
    let start_hour: Int
    let phenotype: ChatPhenotypePayload
    let probabilities: [String: Double]
    
    init(window: TrajectoryWindow) {
        self.window = window.window
        start_hour = window.startHour
        phenotype = ChatPhenotypePayload(id: window.phenotypeId, name: window.phenotypeName)
        probabilities = window.probabilities
    }
}


struct ChatContext: Encodable {
    let interface: String
    let model: String
    let scope: String
}

struct ChatResponse: Decodable {
    let answer: String
    let source: String
}

struct PatientListResponse: Decodable {
    let patients: [ServerPatient]
    let total: Int
    let page: Int
    let per_page: Int
}

struct ServerPatient: Decodable, Identifiable {
    var id: String { masked_id }
    let patient_id: Int
    let masked_id: String
    let bed_no: String
    let admission_time: String
    let icu_ward: String
    let risk_level: String
    let risk_score: Double
    let phenotype: Int
    let phenotype_name: String
    let vitals_summary: String
    let last_prediction: String
    let age_group: String
    let age: Int
    let sex: String
    let mortality_flag: Int
    let los_hours: Double
    let prediction_consistency: ServerPredictionConsistency
}

struct ServerPredictionConsistency: Decodable {
    let label: String
    let tone: String
    let match_count: Int
    let total_windows: Int
    let match_rate: Double
}

struct AdminStatusResponse: Decodable {
    let service: AdminServiceStatus
    let backend: AdminBackendStatus
    let device: AdminDeviceStatus

    private enum CodingKeys: String, CodingKey {
        case service
        case backend
        case device
    }

    init(service: AdminServiceStatus, backend: AdminBackendStatus, device: AdminDeviceStatus) {
        self.service = service
        self.backend = backend
        self.device = device
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let service = try? container.decode(AdminServiceStatus.self, forKey: .service) {
            self.service = service
            self.backend = (try? container.decode(AdminBackendStatus.self, forKey: .backend)) ?? Self.fallbackBackend(runtimeDevice: "cpu")
            self.device = (try? container.decode(AdminDeviceStatus.self, forKey: .device)) ?? Self.fallbackDevice(runtimeDevice: self.backend.runtime_device)
            return
        }

        let backendStatus = (try? container.decode(String.self, forKey: .backend)) ?? "online"
        let runtimeDevice = (try? container.decode(String.self, forKey: .device)) ?? "cpu"
        self.service = AdminServiceStatus(
            name: "sepsiscare-remote-windows-model-server",
            status: backendStatus,
            uptime_hint: "remote",
            python: "--",
            platform: "Windows"
        )
        self.backend = Self.fallbackBackend(runtimeDevice: runtimeDevice)
        self.device = Self.fallbackDevice(runtimeDevice: runtimeDevice)
    }

    func applying(deepSeekConfig config: DeepSeekConfigResponse) -> AdminStatusResponse {
        AdminStatusResponse(
            service: service,
            backend: AdminBackendStatus(
                runtime_device: backend.runtime_device,
                llm_provider: config.provider,
                llm_configured: config.configured,
                deepseek_model: config.model
            ),
            device: device
        )
    }

    private static func fallbackBackend(runtimeDevice: String) -> AdminBackendStatus {
        AdminBackendStatus(
            runtime_device: runtimeDevice,
            llm_provider: "deepseek",
            llm_configured: false,
            deepseek_model: "deepseek-v4-flash"
        )
    }

    private static func fallbackDevice(runtimeDevice: String) -> AdminDeviceStatus {
        AdminDeviceStatus(
            cpu: AdminCPUStatus(
                cores: 0,
                load_1m: 0,
                load_5m: 0,
                load_15m: 0,
                estimated_usage_percent: 0
            ),
            gpu: AdminGPUStatus(
                available: runtimeDevice.lowercased().contains("cuda"),
                name: runtimeDevice.lowercased().contains("cuda") ? "CUDA device" : "Not reported",
                utilization_percent: nil,
                memory_used_mb: nil,
                memory_total_mb: nil
            )
        )
    }
}

struct AdminServiceStatus: Decodable {
    let name: String
    let status: String
    let uptime_hint: String
    let python: String
    let platform: String
}

struct AdminBackendStatus: Decodable {
    let runtime_device: String
    let llm_provider: String
    let llm_configured: Bool
    let deepseek_model: String
}

struct AdminDeviceStatus: Decodable {
    let cpu: AdminCPUStatus
    let gpu: AdminGPUStatus
}

struct AdminCPUStatus: Decodable {
    let cores: Int
    let load_1m: Double
    let load_5m: Double
    let load_15m: Double
    let estimated_usage_percent: Double

    var hasReportedMetrics: Bool {
        cores > 0
    }

    var usageDisplayText: String {
        hasReportedMetrics ? "\(Int(estimated_usage_percent))%" : "--"
    }

    var load1mDisplayText: String {
        Self.formatLoad(load_1m)
    }

    var loadAverageDisplayText: String {
        "\(Self.formatLoad(load_1m))/\(Self.formatLoad(load_5m))/\(Self.formatLoad(load_15m))"
    }

    var monitorTileSubtitle: String {
        guard hasReportedMetrics else { return "远端未上报" }
        return "\(cores) cores · load \(load1mDisplayText)"
    }

    var monitorChecklistDetail: String {
        guard hasReportedMetrics else { return "远端 CPU 指标未上报" }
        return "\(cores) cores · load \(loadAverageDisplayText)"
    }

    private static func formatLoad(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct AdminGPUStatus: Decodable {
    let available: Bool
    let name: String
    let utilization_percent: Double?
    let memory_used_mb: Double?
    let memory_total_mb: Double?
}

struct AdminBindingResponse: Decodable {
    let bindings: [AdminFamilyBinding]
    let storage: String
}

struct AdminBindingUpdateResponse: Decodable {
    let ok: Bool
    let binding: AdminFamilyBinding
    let storage: String
}

struct AdminFamilyBinding: Decodable, Identifiable, Hashable {
    var id: String { account }
    let account: String
    let patient_ref: String
    let updated_at: String
}

struct TrainingTerminalStatusResponse: Decodable {
    let ok: Bool
    let version: String
    let mode: String
    let mode_label: String
    let model_profile: String
    let task_status: String
    let cloud_base_url: String
    let cloud_ready: Bool
    let last_action: String
    let updated_at: String
    let params: [String: JSONValue]
    let metrics: [String: JSONValue]
    let artifacts: [JSONValue]
    let actions: [TrainingTerminalActionDefinition]
    let notice: String
}

struct TrainingTerminalActionDefinition: Decodable, Identifiable, Hashable {
    var id: String { action }
    let action: String
    let title: String
    let shortcut: String
}

struct TrainingTerminalActionResponse: Decodable {
    let ok: Bool
    let mode: String
    let action: String?
    let command: String?
    let output: [String]
    let status: TrainingTerminalStatusResponse
    let error: String?
    let cloud_response: JSONValue?
}

struct TrainingTerminalLogsResponse: Decodable {
    let ok: Bool
    let storage: String
    let logs: [TrainingTerminalLogEntry]
}

struct TrainingTerminalLogEntry: Decodable, Identifiable, Hashable {
    var id: String { "\(ts)-\(action)-\(message)" }
    let ts: String
    let level: String
    let source: String
    let action: String
    let message: String
}

struct ICURealtimeStatusResponse: Decodable {
    let ok: Bool
    let storage: String
    let total_events: Int
    let last_event: JSONValue?
    let upload: JSONValue?
}

struct ICURealtimeDemoResponse: Decodable {
    let ok: Bool
    let demo: JSONValue
    let status: ICURealtimeStatusResponse
}

struct ICURealtimeIngestResponse: Decodable {
    let ok: Bool
    let accepted: Int
    let storage: String
    let status: ICURealtimeStatusResponse
    let latest_prediction: JSONValue?
}

struct ICURealtimeUploadResponse: Decodable {
    let ok: Bool
    let status: ICURealtimeStatusResponse
    let output: [String]
    let error: String?
    let cloud_response: JSONValue?
}

struct HistoricalPatientListResponse: Decodable {
    let patients: [HistoricalPatientSummary]
    let total: Int
    let page: Int
    let per_page: Int
    let sort: String
    let lazy_detail: Bool
}

struct HistoricalPatientSummary: Decodable, Identifiable, Hashable {
    var id: String { history_id }
    let history_id: String
    let masked_id: String
    let data_source: String
    let center: String
    let icu_type: String
    let quality_tag: String
    let icu_admit_time: String
    let icu_discharge_time: String
    let los_hours: Double
    let outcome: String
    let primary_phenotype: String
    let phenotype_consistency: HistoricalConsistency
    let parameter_consistency: HistoricalConsistency
    let missing_rate: Double
    let available_prediction_windows: Int
    let model_version: String
    let favorite: Bool
    let annotation_status: String
}

struct HistoricalConsistency: Decodable, Hashable {
    let code: String
    let label: String
    let color: String
}

struct HistoricalPatientDetail: Decodable {
    let patient: HistoricalPatientSummary
    let resolution: String
    let duration_minutes: Int
    let grouping_modes: HistoricalGroupingModes
    let display_contract: HistoricalDisplayContract
    let formulae: [HistoricalFormula]
    let parameters: [HistoricalParameterSeries]
    let prediction_windows: [HistoricalPredictionWindow]
    let phenotype_transition: HistoricalPhenotypeTransition
}

struct HistoricalGroupingModes: Decodable {
    let clinical_system: [String]
    let data_source: [String]
}

struct HistoricalDisplayContract: Decodable {
    let chart_columns: Int
    let chart_library: String
    let curves: [String]
    let missing_display: String
    let window_overlap_display: String
    let ai_summary: Bool
}

struct HistoricalFormula: Decodable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let latex: String
}

struct HistoricalParameterSeries: Decodable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let label: String
    let unit: String
    let clinical_system: String
    let data_source: String
    let points: [HistoricalPoint]
    let metrics: HistoricalParameterMetrics
}

struct HistoricalPoint: Decodable, Identifiable, Hashable {
    var id: Int { minute }
    let minute: Int
    let actual: Double?
    let predicted: Double
    let smoothed_predicted: Double
    let error: Double?
    let missing: Bool
}

struct HistoricalParameterMetrics: Decodable, Hashable {
    let mae: Double
    let rmse: Double
    let mape: Double
    let dtw: Double
}

struct HistoricalPredictionWindow: Decodable, Identifiable, Hashable {
    var id: Int { window_index }
    let window_index: Int
    let start_minute: Int
    let end_minute: Int
    let phenotype_actual: String
    let phenotype_predicted: String
    let phenotype_consistency: HistoricalConsistency
    let parameter_consistency: HistoricalConsistency
    let mae: Double
    let rmse: Double
    let mape: Double
    let dtw: Double
    let key_deviation_parameters: [String]
}

struct HistoricalPhenotypeTransition: Decodable, Hashable {
    let display: String
    let states: [String]
    let matrix: [[Double]]
}
