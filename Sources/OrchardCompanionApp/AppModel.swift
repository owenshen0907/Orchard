import Combine
import Foundation
import OrchardCore

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot = DashboardSnapshot(devices: [], tasks: [])
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

    func refresh(serverURLString: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let client = try apiClient(serverURLString: serverURLString)
            snapshot = try await client.fetchSnapshot()
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

    private func apiClient(serverURLString: String) throws -> OrchardAPIClient {
        guard let url = URL(string: serverURLString) else {
            throw OrchardAPIError.invalidURL
        }
        return OrchardAPIClient(baseURL: url)
    }
}
