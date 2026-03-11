import Foundation

@main
enum OrchardAgentMain {
    static func main() async throws {
        let config = try AgentConfigLoader.load()
        let stateStore = AgentStateStore(url: try OrchardAgentPaths.stateURL())
        let tasksDirectory = try OrchardAgentPaths.tasksDirectory()
        let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
        try await service.run()
    }
}
