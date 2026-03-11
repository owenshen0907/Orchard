import Foundation

public enum OrchardAPIError: Error, LocalizedError {
    case invalidURL
    case badResponse(Int, String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL."
        case let .badResponse(status, body):
            return "Server returned \(status): \(body)"
        }
    }
}

public struct OrchardAPIClient: Sendable {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        if baseURL.absoluteString.hasSuffix("/") {
            self.baseURL = baseURL
        } else {
            self.baseURL = baseURL.appending(path: "")
        }
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

    public func registerDevice(_ registration: DeviceRegistration) async throws -> DeviceRecord {
        try await post("api/devices/register", body: registration)
    }

    public func sendHeartbeat(deviceID: String, metrics: DeviceMetrics) async throws -> DeviceRecord {
        try await post("api/devices/\(deviceID)/heartbeat", body: HeartbeatRequest(metrics: metrics))
    }

    public func claimNextTask(deviceID: String) async throws -> TaskRecord? {
        try await post("api/devices/\(deviceID)/claim-next", body: ClaimTaskRequest(deviceID: deviceID))
    }

    public func createTask(_ request: CreateTaskRequest) async throws -> TaskRecord {
        try await post("api/tasks", body: request)
    }

    public func appendLogs(taskID: String, deviceID: String, lines: [String]) async throws {
        _ = try await post("api/tasks/\(taskID)/logs", body: AppendTaskLogsRequest(deviceID: deviceID, lines: lines)) as EmptyResponse
    }

    public func completeTask(taskID: String, request: CompleteTaskRequest) async throws -> TaskRecord {
        try await post("api/tasks/\(taskID)/complete", body: request)
    }

    public func stopTask(taskID: String, reason: String? = nil) async throws -> TaskRecord {
        try await post("api/tasks/\(taskID)/stop", body: StopTaskRequest(reason: reason))
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
        return request
    }

    private func send<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OrchardAPIError.badResponse(-1, "No HTTP response.")
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
