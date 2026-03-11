import Foundation

@main
enum OrchardControlPlaneMain {
    static func main() async throws {
        let app = try await makeOrchardControlPlaneApplication()
        do {
            try await app.execute()
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
    }
}
