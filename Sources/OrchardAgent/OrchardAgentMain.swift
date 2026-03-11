import Darwin
import Foundation

@main
enum OrchardAgentMain {
    static func main() async {
        do {
            try await execute()
        } catch let error as AgentCLIError {
            fputs("error: \(error.localizedDescription)\n\n", stderr)
            fputs(AgentCLI.usage + "\n", stderr)
            exit(1)
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func execute() async throws {
        switch try AgentCLI.parse(arguments: CommandLine.arguments) {
        case .run:
            try await runAgent()
        case let .initConfig(options):
            let result = try AgentConfigInitializer.writeConfig(options: options)
            print("Wrote Orchard agent config to \(result.configURL.path)")
            print("Workspace: \(result.resolvedConfig.workspaceRoots.first?.rootPath ?? "-")")
            print("Device: \(result.resolvedConfig.deviceName) (\(result.resolvedConfig.deviceID))")
        case let .installLaunchAgent(options):
            let result = try LaunchAgentInstaller.install(options: options)
            print("Wrote launch agent plist to \(result.plistURL.path)")
            print("Log directory: \(result.logDirectoryURL.path)")
            if result.bootstrapPerformed {
                print("LaunchAgent bootstrapped and restarted: \(result.serviceTarget)")
            } else {
                print("LaunchAgent plist written only. Bootstrap manually when ready.")
            }
        case let .doctor(options):
            let report = await AgentDoctor.run(options: options)
            for line in report.renderedLines {
                print(line)
            }
            if !report.isHealthy {
                throw NSError(domain: "OrchardAgentDoctor", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "One or more Orchard agent checks failed.",
                ])
            }
        case .help:
            print(AgentCLI.usage)
        }
    }

    private static func runAgent() async throws {
        let config = try AgentConfigLoader.load()
        let stateStore = AgentStateStore(url: try OrchardAgentPaths.stateURL())
        let tasksDirectory = try OrchardAgentPaths.tasksDirectory()
        let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
        try await service.run()
    }
}
