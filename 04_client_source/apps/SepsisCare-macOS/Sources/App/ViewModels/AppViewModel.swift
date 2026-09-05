import Foundation
import SwiftUI

@Observable
final class AppViewModel {
    static let demoPassword = "123123"
    static let demoAuthBoundaryNotice = "演示界面门禁，不是生产认证；远端敏感接口仍以 Token 控制。"

    var isAuthenticated = false
    var currentRole: UserRole?
    var backend: BackendController
    var patients: [Patient] = Patient.mockPatients
    var selectedPatient: Patient?
    var settings: AppSettings
    var rememberedRole: UserRole = .research
    var familyBoundPatientID: String?
    
    var apiClient = APIClient.shared
    private let rememberedRoleKey = "sepsis.rememberedRole"
    private let familyBoundPatientKey = "sepsis.familyBoundPatientID"
    
    init(startBackend: Bool = true) {
        let loadedSettings = AppSettings()
        settings = loadedSettings
        let shouldAutoStartLocalBackend = startBackend && loadedSettings.backendAutoStart && loadedSettings.usesLocalAPIBaseURL
        backend = BackendController(autoStart: shouldAutoStartLocalBackend)
        backend.setAPIBaseURL(loadedSettings.apiBaseURL)
        if let savedRole = UserDefaults.standard.string(forKey: rememberedRoleKey),
           let role = UserRole(rawValue: savedRole) {
            rememberedRole = role
        }
        familyBoundPatientID = UserDefaults.standard.string(forKey: familyBoundPatientKey) ?? Patient.mockPatients.first?.id
    }

    func ensureBackendStarted() {
        backend.setAPIBaseURL(settings.apiBaseURL)
        guard settings.backendAutoStart && settings.usesLocalAPIBaseURL else {
            backend.refreshHealth()
            return
        }
        backend.ensureBackendRunning()
    }
    
    func authenticate(username: String, password: String) -> Bool {
        guard let role = UserRole(rawValue: username.lowercased()) else { return false }
        return authenticate(role: role, password: password)
    }
    
    func authenticate(role: UserRole, password: String) -> Bool {
        if password == Self.demoPassword {
            currentRole = role
            isAuthenticated = true
            rememberedRole = role
            UserDefaults.standard.set(role.rawValue, forKey: rememberedRoleKey)
            if role == .family {
                selectedPatient = familyBoundPatient
                if let patientID = selectedPatient?.id {
                    UserDefaults.standard.set(patientID, forKey: familyBoundPatientKey)
                }
            }
            return true
        }
        return false
    }
    
    func logout() {
        isAuthenticated = false
        currentRole = nil
        if rememberedRole != .family {
            selectedPatient = nil
        }
    }
    
    func selectPatient(_ patient: Patient) {
        if currentRole == .family, patient.id != familyBoundPatient?.id {
            return
        }
        selectedPatient = patient
    }

    func bindFamilyAccount(to patient: Patient) {
        familyBoundPatientID = patient.id
        UserDefaults.standard.set(patient.id, forKey: familyBoundPatientKey)
        if currentRole == .family {
            selectedPatient = patient
        }
    }
    
    var visiblePatients: [Patient] {
        if currentRole == .family, let patient = familyBoundPatient {
            return [patient]
        }
        return patients
    }

    var currentAnalysisPatient: Patient? {
        selectedPatient ?? patients.first
    }
    
    var familyBoundPatient: Patient? {
        let patientID = familyBoundPatientID ?? patients.first?.id
        return patients.first { $0.id == patientID } ?? patients.first
    }
    
    func sendFamilyChat(question: String, for patient: Patient) async throws -> ChatResponse {
        await apiClient.setBaseURL(settings.apiBaseURL)
        let latestPrediction = patient.predictions.last ?? PredictionResult.mock(for: patient)
        return try await apiClient.postFamilyChat(
            question: question,
            patientRef: patient.bedNumber,
            prediction: latestPrediction
        )
    }
    
    func runPrediction(for patient: Patient) async -> PredictionResult? {
        // 模拟预测结果，后续可替换为真实 API 调用
        let result = PredictionResult.mock(for: patient)
        if let index = patients.firstIndex(where: { $0.id == patient.id }) {
            patients[index].predictions.append(result)
        }
        if selectedPatient?.id == patient.id {
            selectedPatient = patients.first(where: { $0.id == patient.id })
        }
        return result
    }
}

    @Observable
    final class AppSettings {
        private let backendAutoStartKey = "sepsis.backendAutoStart"
        private let apiBaseURLKey = SepsisCareAPI.apiBaseURLUserDefaultsKey
        private let serviceTokenKey = SepsisCareAPI.serviceTokenUserDefaultsKey

    var language: String = "zh-Hans"
    var fontName: String = "Songti SC"
    var fontSize: Double = 14
    var theme: AppTheme = .light
    var enableNotifications: Bool = true
    var backendAutoStart: Bool = true {
        didSet { UserDefaults.standard.set(backendAutoStart, forKey: backendAutoStartKey) }
    }
    var apiBaseURL: String = SepsisCareAPI.defaultBaseURL {
        didSet {
            let normalized = SepsisCareAPI.normalizedBaseURL(apiBaseURL)
            if apiBaseURL != normalized {
                apiBaseURL = normalized
                return
            }
            UserDefaults.standard.set(normalized, forKey: apiBaseURLKey)
        }
    }
    var serviceToken: String = "" {
        didSet {
            let normalized = SepsisCareAPI.normalizedServiceToken(serviceToken)
            if serviceToken != normalized {
                serviceToken = normalized
                return
            }
            if normalized.isEmpty {
                UserDefaults.standard.removeObject(forKey: serviceTokenKey)
            } else {
                UserDefaults.standard.set(normalized, forKey: serviceTokenKey)
            }
        }
    }

    init() {
        if UserDefaults.standard.object(forKey: backendAutoStartKey) != nil {
            backendAutoStart = UserDefaults.standard.bool(forKey: backendAutoStartKey)
        }
        if let savedBaseURL = UserDefaults.standard.string(forKey: apiBaseURLKey), !savedBaseURL.isEmpty {
            apiBaseURL = SepsisCareAPI.normalizedSavedBaseURL(savedBaseURL)
            UserDefaults.standard.set(apiBaseURL, forKey: apiBaseURLKey)
        }
        if let savedServiceToken = UserDefaults.standard.string(forKey: serviceTokenKey), !savedServiceToken.isEmpty {
            serviceToken = SepsisCareAPI.normalizedServiceToken(savedServiceToken)
            UserDefaults.standard.set(serviceToken, forKey: serviceTokenKey)
        }
    }
    
    var effectiveFont: Font {
        .custom(fontName, size: fontSize)
    }

    var usesLocalAPIBaseURL: Bool {
        guard let url = URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased() else {
            return true
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}

enum AppTheme: String, CaseIterable {
    case light = "light"
    case dark = "dark"
    case system = "system"
    
    var displayName: String {
        switch self {
        case .light: return "浅色"
        case .dark: return "深色"
        case .system: return "跟随系统"
        }
    }
}
