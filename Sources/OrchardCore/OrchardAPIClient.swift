import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum OrchardAPIError: Error, LocalizedError {
    case invalidURL
    case badResponse(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "服务器地址无效。"
        case let .badResponse(status, body):
            return "服务器返回 \(status)：\(body)"
        }
    }
}

// FoundationNetworking on Linux does not consistently carry Sendable annotations.
public struct OrchardAPIClient: @unchecked Sendable {
    public var baseURL: URL
    public var accessKey: String?
    public var session: URLSession

    public init(baseURL: URL, accessKey: String? = nil, session: URLSession = .shared) {
        if baseURL.absoluteString.hasSuffix("/") {
            self.baseURL = baseURL
        } else {
            self.baseURL = baseURL.appending(path: "")
        }
        let trimmedAccessKey = accessKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessKey = trimmedAccessKey?.isEmpty == false ? trimmedAccessKey : nil
        self.session = session
    }

    public func fetchSnapshot() async throws -> DashboardSnapshot {
        try await get("api/snapshot")
    }

    public func fetchDevices() async throws -> [DeviceRecord] {
        try await get("api/devices")
    }

    public func fetchTasks() async throws -> [TaskRecord] {
        try await get("api/tasks")
    }

    public func fetchTaskDetail(taskID: String) async throws -> TaskDetail {
        try await get("api/tasks/\(taskID)")
    }

    public func fetchManagedRuns(
        deviceID: String? = nil,
        limit: Int? = nil,
        statuses: [ManagedRunStatus] = []
    ) async throws -> [ManagedRunSummary] {
        var components = URLComponents()
        var items: [URLQueryItem] = []
        if let deviceID, !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "deviceID", value: deviceID))
        }
        if let limit {
            items.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        if !statuses.isEmpty {
            items.append(URLQueryItem(name: "status", value: statuses.map(\.rawValue).joined(separator: ",")))
        }
        components.queryItems = items.isEmpty ? nil : items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return try await get("api/runs\(query)")
    }

    public func fetchManagedRunDetail(runID: String) async throws -> ManagedRunDetail {
        try await get("api/runs/\(runID)")
    }

    public func createManagedRun(_ request: CreateManagedRunRequest) async throws -> ManagedRunSummary {
        try await post("api/runs", body: request)
    }

    public func continueManagedRun(runID: String, prompt: String) async throws -> ManagedRunDetail {
        try await post(
            "api/runs/\(runID)/continue",
            body: ManagedRunContinueRequest(prompt: prompt)
        )
    }

    public func interruptManagedRun(runID: String) async throws -> ManagedRunDetail {
        try await post(
            "api/runs/\(runID)/interrupt",
            body: ManagedRunInterruptRequest()
        )
    }

    public func stopManagedRun(runID: String, reason: String? = nil) async throws -> ManagedRunSummary {
        try await post(
            "api/runs/\(runID)/stop",
            body: ManagedRunStopRequest(reason: reason)
        )
    }

    public func retryManagedRun(runID: String, prompt: String? = nil) async throws -> ManagedRunSummary {
        try await post(
            "api/runs/\(runID)/retry",
            body: ManagedRunRetryRequest(prompt: prompt)
        )
    }

    public func fetchCodexSessions(deviceID: String? = nil, limit: Int? = nil) async throws -> [CodexSessionSummary] {
        var components = URLComponents()
        var items: [URLQueryItem] = []
        if let deviceID, !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "deviceID", value: deviceID))
        }
        if let limit {
            items.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        components.queryItems = items.isEmpty ? nil : items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return try await get("api/codex/sessions\(query)")
    }

    public func fetchCodexSessionDetail(deviceID: String, sessionID: String) async throws -> CodexSessionDetail {
        try await get("api/devices/\(deviceID)/codex/sessions/\(sessionID)")
    }

    public func fetchProjectContextSummary(
        deviceID: String,
        workspaceID: String
    ) async throws -> AgentProjectContextCommandResponse {
        try await get("api/devices/\(deviceID)/workspaces/\(workspaceID)/project-context")
    }

    public func lookupProjectContext(
        deviceID: String,
        workspaceID: String,
        subject: ProjectContextRemoteSubject,
        selector: String? = nil
    ) async throws -> AgentProjectContextCommandResponse {
        var components = URLComponents()
        var items = [URLQueryItem(name: "subject", value: subject.rawValue)]
        if let selector, !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "selector", value: selector))
        }
        components.queryItems = items
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        return try await get("api/devices/\(deviceID)/workspaces/\(workspaceID)/project-context/lookup\(query)")
    }

    public func continueCodexSession(deviceID: String, sessionID: String, prompt: String) async throws -> CodexSessionDetail {
        try await post(
            "api/devices/\(deviceID)/codex/sessions/\(sessionID)/continue",
            body: CodexSessionContinueRequest(prompt: prompt)
        )
    }

    public func interruptCodexSession(deviceID: String, sessionID: String) async throws -> CodexSessionDetail {
        try await post(
            "api/devices/\(deviceID)/codex/sessions/\(sessionID)/interrupt",
            body: CodexSessionInterruptRequest()
        )
    }

    public func registerAgent(_ registration: AgentRegistrationRequest) async throws -> DeviceRecord {
        try await post("api/agents/register", body: registration)
    }

    public func createTask(_ request: CreateTaskRequest) async throws -> TaskRecord {
        try await post("api/tasks", body: request)
    }

    public func stopTask(taskID: String, reason: String? = nil) async throws -> TaskRecord {
        try await post("api/tasks/\(taskID)/stop", body: StopTaskRequest(reason: reason))
    }

    public func makeAgentSessionURL(deviceID: String, enrollmentToken: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw OrchardAPIError.invalidURL
        }
        let basePath = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.path = "\(basePath)/api/agents/\(deviceID)/session"
        components.queryItems = [URLQueryItem(name: "token", value: enrollmentToken)]
        guard let url = components.url else {
            throw OrchardAPIError.invalidURL
        }
        return url
    }

    private func get<Response: Decodable>(_ path: String) async throws -> Response {
        var request = try makeRequest(path: path, method: "GET")
        request.httpBody = nil
        return try await send(request)
    }

    private func post<RequestBody: Encodable, Response: Decodable>(_ path: String, body: RequestBody) async throws -> Response {
        var request = try makeRequest(path: path, method: "POST")
        request.httpBody = try OrchardJSON.encoder.encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await send(request)
    }

    private func makeRequest(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw OrchardAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessKey {
            request.setValue(accessKey, forHTTPHeaderField: OrchardAccessControlHeader.name)
        }
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OrchardAPIError.badResponse(-1, "未收到 HTTP 响应。")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw OrchardAPIError.badResponse(http.statusCode, body)
        }
        if Response.self == EmptyResponse.self, data.isEmpty {
            return EmptyResponse() as! Response
        }
        return try OrchardJSON.decoder.decode(Response.self, from: data)
    }
}

private enum OrchardAccessControlHeader {
    static let name = "X-Orchard-Access-Key"
}
