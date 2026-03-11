import Combine
import Foundation
import OrchardCore

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot = DashboardSnapshot(devices: [], tasks: [])
    @Published var errorMessage: String?
    @Published var isLoading = false

    func refresh(serverURLString: String) async {
        guard let url = URL(string: serverURLString) else {
            errorMessage = "Server URL 无效。"
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let client = OrchardAPIClient(baseURL: url)
            snapshot = try await client.fetchSnapshot()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
