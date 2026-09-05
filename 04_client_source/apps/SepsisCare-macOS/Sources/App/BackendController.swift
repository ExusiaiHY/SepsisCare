import Foundation
import Combine

struct SepsisCareHealthCheckResult: Equatable {
    let isOnline: Bool
    let statusText: String
    let detail: String

    static func online(baseURL: String, ownedProcessRunning: Bool, checkedAt: String) -> SepsisCareHealthCheckResult {
        let statusText = ownedProcessRunning ? "本地后端在线" : "外部 API 在线"
        return SepsisCareHealthCheckResult(
            isOnline: true,
            statusText: statusText,
            detail: "检查完成：\(baseURL) · \(statusText) · \(checkedAt)"
        )
    }

    static func invalidBaseURL(_ baseURL: String) -> SepsisCareHealthCheckResult {
        SepsisCareHealthCheckResult(
            isOnline: false,
            statusText: "API 地址无效",
            detail: "地址无效：\(baseURL)。\(SepsisCareAPI.remoteBaseURLHelp)"
        )
    }

    static func offline(baseURL: String, checkedAt: String) -> SepsisCareHealthCheckResult {
        SepsisCareHealthCheckResult(
            isOnline: false,
            statusText: "API 未连接",
            detail: "检查失败：\(baseURL) · API 未连接 · \(checkedAt)"
        )
    }
}

enum SepsisCareHealthProbe {
    static func healthURL(for baseURL: String) -> URL? {
        let normalizedBaseURL = SepsisCareAPI.normalizedBaseURL(baseURL)
        guard var components = URLComponents(string: normalizedBaseURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        components.query = nil
        components.fragment = nil
        let existingPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = existingPath.isEmpty ? "/health" : "/\(existingPath)/health"
        return components.url
    }

    static func isCompatibleHealthResponse(data: Data?, response: URLResponse?) -> Bool {
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard payload["status"] as? String == "ok",
              let service = payload["service"] as? String else {
            return false
        }
        if service == "sepsis" {
            return payload["history_patients"] != nil && payload["data_dir"] != nil
        }
        if service == "sepsiscare-model-service" {
            return payload["history_patients"] != nil
                && payload["model_id"] != nil
                && payload["missing"] is [Any]
        }
        return false
    }
}

@Observable
final class BackendController: ObservableObject {
    var isReady = false
    var statusText = "启动本地 API 中..."
    var isStarting = false
    var lastHealthCheck = "尚未检查"
    var logLines: [String] = []
    var serverPath = ""
    var apiBaseURL = SepsisCareAPI.defaultBaseURL
    
    private var process: Process?
    private var readinessTimer: Timer?
    private let backendPort = 8765
    private let maxLogLines = 360
    private let defaultCloudBaseURL = SepsisCareAPI.cloudBaseURL
    
    var localApiBaseURL: String { SepsisCareAPI.localBaseURL }
    var launchCommand: String {
        if serverPath.isEmpty {
            return "python3 apps/sepsiscare-studio/backend/server.py --host 127.0.0.1 --port \(backendPort)"
        }
        return "python3 \(serverPath) --host 127.0.0.1 --port \(backendPort)"
    }

    var ownedProcessRunning: Bool {
        process?.isRunning == true
    }
    
    init(autoStart: Bool = true) {
        startReadinessPolling()
        if autoStart {
            startBackend()
        } else {
            statusText = "使用外部 API"
        }
    }
    
    deinit {
        readinessTimer?.invalidate()
        process?.terminate()
    }
    
    func startBackend() {
        guard !isStarting else { return }
        if ownedProcessRunning {
            appendLog("后端已由 App 启动，跳过重复启动。")
            statusText = "本地备用后端运行中"
            return
        }
        if isReady {
            appendLog("本地 API 已在线，跳过重复启动。")
            statusText = "本地 API 在线"
            return
        }
        if isLocalBackendPortOpen() {
            appendLog("检测到 127.0.0.1:\(backendPort) 已有 API 服务，复用现有后端。")
            statusText = "检测本地 API..."
            refreshHealth()
            return
        }
        guard let serverURL = resolveBackendServerURL() else {
            statusText = "未找到后端 server.py"
            appendLog("未找到后端 server.py。可设置 SEPSISCARE_BACKEND_SERVER，或确认 apps/sepsiscare-studio/backend/server.py 已随 App 打包。")
            return
        }
        serverPath = serverURL.path
        isStarting = true
        
        let backendProcess = Process()
        backendProcess.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        backendProcess.arguments = [serverURL.path, "--host", "127.0.0.1", "--port", "\(backendPort)"]
        backendProcess.currentDirectoryURL = serverURL.deletingLastPathComponent()
        
        var environment = ProcessInfo.processInfo.environment
        loadEnvFileIfPresent(serverURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".env"), into: &environment)
        for envURL in resolveEnvFileURLs() {
            loadEnvFileIfPresent(envURL, into: &environment)
        }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["SEPSISCARE_DEVICE"] = environment["SEPSISCARE_DEVICE"] ?? "cpu"
        environment["SEPSISCARE_PUBLIC_API_BASE_URL"] = environment["SEPSISCARE_PUBLIC_API_BASE_URL"] ?? SepsisCareAPI.localBaseURL
        environment["SEPSISCARE_PUBLIC_MODEL_BASE_URL"] = environment["SEPSISCARE_PUBLIC_MODEL_BASE_URL"] ?? defaultCloudBaseURL
        let runtimeRoot = appSupportDirectory()
        environment["SEPSISCARE_RUNTIME_ROOT"] = environment["SEPSISCARE_RUNTIME_ROOT"] ?? runtimeRoot.path
        environment["SEPSISCARE_SERVICE_TOKEN_FILE"] = environment["SEPSISCARE_SERVICE_TOKEN_FILE"] ?? runtimeRoot.appendingPathComponent("sepsiscare_service_token.txt").path
        backendProcess.environment = environment
        
        let output = Pipe()
        backendProcess.standardOutput = output
        backendProcess.standardError = output
        
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                DispatchQueue.main.async {
                    self?.appendLog(str)
                }
            }
        }

        backendProcess.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                self?.appendLog("后端进程退出，状态码 \(terminated.terminationStatus)。")
                self?.process = nil
                self?.isStarting = false
                if self?.isReady != true {
                    self?.statusText = "本地备用后端未运行"
                }
            }
        }
        
        do {
            try backendProcess.run()
            process = backendProcess
            appendLog("启动命令：\(launchCommand)")
            statusText = "等待后端就绪..."
        } catch {
            statusText = "无法启动后端: \(error.localizedDescription)"
            appendLog("无法启动后端：\(error.localizedDescription)")
            isStarting = false
        }
    }

    func ensureBackendRunning() {
        if ownedProcessRunning || isReady {
            refreshHealth()
            return
        }
        startBackend()
    }

    func setAPIBaseURL(_ value: String) {
        apiBaseURL = SepsisCareAPI.normalizedBaseURL(value)
    }

    func stopBackend() {
        if let process, process.isRunning {
            appendLog("正在停止 App 启动的后端进程。")
            process.terminate()
            statusText = "正在停止后端..."
            isReady = false
            return
        }
        if isReady {
            appendLog("API 在线。停止操作只会结束 App 启动的本地后端进程。")
            statusText = "API 在线"
        } else {
            appendLog("没有可停止的 App 后端进程。")
            statusText = "本地备用后端未运行"
        }
    }

    func restartBackend() {
        appendLog("执行后端重启。")
        if let process, process.isRunning {
            process.terminate()
            self.process = nil
        } else if isReady {
            appendLog("API 在线，继续启动本地后端。")
        }
        isReady = false
        statusText = "准备重新启动后端..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.startBackend()
        }
    }

    func refreshHealth() {
        checkHealth()
    }

    func checkHealthNow() async -> SepsisCareHealthCheckResult {
        setAPIBaseURL(apiBaseURL)
        guard let url = SepsisCareHealthProbe.healthURL(for: apiBaseURL) else {
            let checkedAt = DateFormatter.backendTime.string(from: Date())
            let result = SepsisCareHealthCheckResult.invalidBaseURL(apiBaseURL)
            applyHealthCheckResult(result, checkedAt: checkedAt)
            return result
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3

        let checkedAt = DateFormatter.backendTime.string(from: Date())
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let isOnline = SepsisCareHealthProbe.isCompatibleHealthResponse(data: data, response: response)
            let result = isOnline
                ? SepsisCareHealthCheckResult.online(baseURL: apiBaseURL, ownedProcessRunning: ownedProcessRunning, checkedAt: checkedAt)
                : SepsisCareHealthCheckResult.offline(baseURL: apiBaseURL, checkedAt: checkedAt)
            applyHealthCheckResult(result, checkedAt: checkedAt)
            return result
        } catch {
            let result = SepsisCareHealthCheckResult.offline(baseURL: apiBaseURL, checkedAt: checkedAt)
            applyHealthCheckResult(result, checkedAt: checkedAt)
            return result
        }
    }

    func clearLogs() {
        logLines.removeAll()
        appendLog("日志已清空。")
    }

    private func isLocalBackendPortOpen() -> Bool {
        guard let url = SepsisCareHealthProbe.healthURL(for: apiBaseURL) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5

        let semaphore = DispatchSemaphore(value: 0)
        var isOnline = false
        URLSession.shared.dataTask(with: request) { data, response, _ in
            isOnline = SepsisCareHealthProbe.isCompatibleHealthResponse(data: data, response: response)
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 0.8)
        return isOnline
    }
    
    private func resolveBackendServerURL() -> URL? {
        let candidates = backendServerCandidates()
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
    
    private func resolveEnvFileURLs() -> [URL] {
        var candidates: [URL] = []
        for root in projectRootCandidates() {
            candidates.append(root.appendingPathComponent("apps/sepsiscare-studio/.env"))
            candidates.append(root.appendingPathComponent("sepsiscare-studio/.env"))
        }
        
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("SepsisCareStudio/.env"))
            candidates.append(resourceURL.appendingPathComponent(".env"))
        }
        
        return candidates
    }

    private func appSupportDirectory() -> URL {
        let manager = FileManager.default
        let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base.appendingPathComponent("SepsisCare", isDirectory: true)
        try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func backendServerCandidates() -> [URL] {
        var candidates: [URL] = []

        if let explicitPath = ProcessInfo.processInfo.environment["SEPSISCARE_BACKEND_SERVER"], !explicitPath.isEmpty {
            candidates.append(URL(fileURLWithPath: explicitPath))
        }

        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("backend/server.py"))
            candidates.append(resourceURL.appendingPathComponent("SepsisCareStudio/backend/server.py"))
        }

        for root in projectRootCandidates() {
            candidates.append(root.appendingPathComponent("apps/sepsiscare-studio/backend/server.py"))
            candidates.append(root.appendingPathComponent("sepsiscare-studio/backend/server.py"))
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func projectRootCandidates() -> [URL] {
        var roots: [URL] = []

        if let explicitRoot = ProcessInfo.processInfo.environment["SEPSISCARE_PROJECT_ROOT"], !explicitRoot.isEmpty {
            roots.append(URL(fileURLWithPath: explicitRoot))
        }

        roots.append(contentsOf: ancestors(of: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)))
        roots.append(contentsOf: ancestors(of: URL(fileURLWithPath: #filePath).deletingLastPathComponent()))

        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func ancestors(of startURL: URL) -> [URL] {
        var result: [URL] = []
        var current = startURL.standardizedFileURL

        while true {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }

        return result
    }
    
    private func loadEnvFileIfPresent(_ url: URL, into environment: inout [String: String]) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
                continue
            }
            
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            
            if !key.isEmpty, environment[key, default: ""].isEmpty {
                environment[key] = value
            }
        }
    }
    
    private func startReadinessPolling() {
        readinessTimer?.invalidate()
        readinessTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }
        readinessTimer?.fire()
    }
    
    private func checkHealth() {
        guard let url = SepsisCareHealthProbe.healthURL(for: apiBaseURL) else {
            let checkedAt = DateFormatter.backendTime.string(from: Date())
            applyHealthCheckResult(SepsisCareHealthCheckResult.invalidBaseURL(apiBaseURL), checkedAt: checkedAt)
            return
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let self else { return }
            let ok = SepsisCareHealthProbe.isCompatibleHealthResponse(data: data, response: response)
            DispatchQueue.main.async {
                let checkedAt = DateFormatter.backendTime.string(from: Date())
                let result = ok
                    ? SepsisCareHealthCheckResult.online(baseURL: self.apiBaseURL, ownedProcessRunning: self.ownedProcessRunning, checkedAt: checkedAt)
                    : SepsisCareHealthCheckResult.offline(baseURL: self.apiBaseURL, checkedAt: checkedAt)
                self.applyHealthCheckResult(result, checkedAt: checkedAt)
            }
        }.resume()
    }

    private func isCompatibleHealthResponse(data: Data?, response: URLResponse?) -> Bool {
        SepsisCareHealthProbe.isCompatibleHealthResponse(data: data, response: response)
    }

    private func applyHealthCheckResult(_ result: SepsisCareHealthCheckResult, checkedAt: String) {
        lastHealthCheck = checkedAt
        isReady = result.isOnline
        if result.isOnline {
            isStarting = false
        }
        statusText = result.statusText
    }

    private func appendLog(_ raw: String) {
        let chunks = raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let stamp = DateFormatter.backendTime.string(from: Date())
        let newLines = chunks.isEmpty ? ["[\(stamp)] \(raw)"] : chunks.map { "[\(stamp)] \($0)" }
        logLines.append(contentsOf: newLines)
        if logLines.count > maxLogLines {
            logLines = Array(logLines.suffix(maxLogLines))
        }
        for line in newLines {
            print("[Backend] \(line)")
        }
    }
}

private extension DateFormatter {
    static let backendTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
