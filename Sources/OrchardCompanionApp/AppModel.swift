import Combine
import Foundation
import OrchardCore

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot = DashboardSnapshot(devices: [], tasks: [], managedRuns: [])
    @Published var codexSessions: [CodexSessionSummary] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    @Published var lastRefreshAt: Date?

    func createTask(serverURLString: String, request: CreateTaskRequest) async throws -> TaskRecord {
        let client = try apiClient(serverURLString: serverURLString)
        let task = try await client.createTask(request)
        await refresh(serverURLString: serverURLString)
        return task
    }

    func fetchTaskDetail(serverURLString: String, taskID: String) async throws -> TaskDetail {
        let client = try apiClient(serverURLString: serverURLString)
        return try await client.fetchTaskDetail(taskID: taskID)
    }

    func fetchCodexSessionDetail(serverURLString: String, deviceID: String, sessionID: String) async throws -> CodexSessionDetail {
        let client = try apiClient(serverURLString: serverURLString)
        return try await client.fetchCodexSessionDetail(deviceID: deviceID, sessionID: sessionID)
    }

    func fetchManagedRunDetail(serverURLString: String, runID: String) async throws -> ManagedRunDetail {
        let client = try apiClient(serverURLString: serverURLString)
        return try await client.fetchManagedRunDetail(runID: runID)
    }

    func fetchProjectContextSummary(
        serverURLString: String,
        deviceID: String,
        workspaceID: String
    ) async throws -> AgentProjectContextCommandResponse {
        let client = try apiClient(serverURLString: serverURLString)
        return try await client.fetchProjectContextSummary(deviceID: deviceID, workspaceID: workspaceID)
    }

    func lookupProjectContext(
        serverURLString: String,
        deviceID: String,
        workspaceID: String,
        subject: ProjectContextRemoteSubject,
        selector: String? = nil
    ) async throws -> AgentProjectContextCommandResponse {
        let client = try apiClient(serverURLString: serverURLString)
        return try await client.lookupProjectContext(
            deviceID: deviceID,
            workspaceID: workspaceID,
            subject: subject,
            selector: selector
        )
    }

    func createManagedRun(serverURLString: String, request: CreateManagedRunRequest) async throws -> ManagedRunSummary {
        let client = try apiClient(serverURLString: serverURLString)
        let run = try await client.createManagedRun(request)
        await refresh(serverURLString: serverURLString)
        return run
    }

    func continueManagedRun(serverURLString: String, runID: String, prompt: String) async throws -> ManagedRunDetail {
        let client = try apiClient(serverURLString: serverURLString)
        let detail = try await client.continueManagedRun(runID: runID, prompt: prompt)
        await refresh(serverURLString: serverURLString)
        return detail
    }

    func interruptManagedRun(serverURLString: String, runID: String) async throws -> ManagedRunDetail {
        let client = try apiClient(serverURLString: serverURLString)
        let detail = try await client.interruptManagedRun(runID: runID)
        await refresh(serverURLString: serverURLString)
        return detail
    }

    func continueCodexSession(
        serverURLString: String,
        deviceID: String,
        sessionID: String,
        prompt: String
    ) async throws -> CodexSessionDetail {
        let client = try apiClient(serverURLString: serverURLString)
        let detail = try await client.continueCodexSession(deviceID: deviceID, sessionID: sessionID, prompt: prompt)
        await refresh(serverURLString: serverURLString)
        return detail
    }

    func interruptCodexSession(serverURLString: String, deviceID: String, sessionID: String) async throws -> CodexSessionDetail {
        let client = try apiClient(serverURLString: serverURLString)
        let detail = try await client.interruptCodexSession(deviceID: deviceID, sessionID: sessionID)
        await refresh(serverURLString: serverURLString)
        return detail
    }

    func refresh(serverURLString: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let client = try apiClient(serverURLString: serverURLString)
            snapshot = try await client.fetchSnapshot()
            do {
                codexSessions = try await client.fetchCodexSessions(limit: 20)
            } catch {
                codexSessions = []
            }
            errorMessage = nil
            lastRefreshAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopTask(serverURLString: String, taskID: String, reason: String? = nil) async throws -> TaskRecord {
        let client = try apiClient(serverURLString: serverURLString)
        let task = try await client.stopTask(taskID: taskID, reason: reason)
        await refresh(serverURLString: serverURLString)
        return task
    }

    func stopManagedRun(serverURLString: String, runID: String, reason: String? = nil) async throws -> ManagedRunSummary {
        let client = try apiClient(serverURLString: serverURLString)
        let run = try await client.stopManagedRun(runID: runID, reason: reason)
        await refresh(serverURLString: serverURLString)
        return run
    }

    func retryManagedRun(serverURLString: String, runID: String, prompt: String? = nil) async throws -> ManagedRunSummary {
        let client = try apiClient(serverURLString: serverURLString)
        let run = try await client.retryManagedRun(runID: runID, prompt: prompt)
        await refresh(serverURLString: serverURLString)
        return run
    }

    private func apiClient(serverURLString: String) throws -> OrchardAPIClient {
        guard let url = URL(string: serverURLString) else {
            throw OrchardAPIError.invalidURL
        }
        let accessKey = UserDefaults.standard.string(forKey: "orchard.accessKey")
        return OrchardAPIClient(baseURL: url, accessKey: accessKey)
    }
}
