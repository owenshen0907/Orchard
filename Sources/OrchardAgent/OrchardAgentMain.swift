import Darwin
import Foundation
import OrchardCore

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
        case let .status(options):
            if options.serve {
                try await AgentStatusHTTPServer(options: options).run()
            } else {
                let snapshot = try await AgentStatusService().snapshot(options: options)
                let rendered = try AgentStatusRenderer.render(snapshot, format: options.outputFormat)
                print(rendered)
            }
        case let .projectContext(command):
            try executeProjectContext(command)
        case .help:
            print(AgentCLI.usage)
        }
    }

    private static func runAgent() async throws {
        let configURL = try OrchardAgentPaths.configURL()
        let config = try AgentConfigLoader.load(from: configURL)
        let stateURL = try OrchardAgentPaths.stateURL()
        let stateStore = AgentStateStore(url: stateURL)
        let tasksDirectory = try OrchardAgentPaths.tasksDirectory()
        let service = OrchardAgentService(
            config: config,
            stateStore: stateStore,
            tasksDirectory: tasksDirectory,
            configURL: configURL,
            stateURL: stateURL
        )
        try await service.run()
    }

    private static func executeProjectContext(_ command: ProjectContextCommand) throws {
        switch command {
        case let .show(options):
            let resolved = try ProjectContextResolver.load(
                workspaceURL: options.workspaceURL,
                localSecretsURL: options.localSecretsURL
            )
            let output = options.revealSecrets ? resolved : resolved.redactingSensitiveValues()
            let data = try OrchardJSON.encoder.encode(output)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        case let .lookup(options):
            try executeProjectContextLookup(options)
        case let .doctor(options):
            let report = try ProjectContextResolver.doctor(options: options)
            for line in report.renderedLines {
                print(line)
            }
            if !report.isHealthy {
                throw NSError(domain: "OrchardProjectContextDoctor", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Project context has missing local credentials or validation issues.",
                ])
            }
        case let .initLocal(options):
            let result = try ProjectContextResolver.writeLocalSecretsSkeleton(options: options)
            print("\(result.overwritten ? "Overwrote" : "Wrote") local project secrets skeleton for \(result.projectID)")
            print("Path: \(result.localSecretsURL.path)")
        }
    }

    private static func executeProjectContextLookup(_ options: ProjectContextLookupOptions) throws {
        switch options.subject {
        case .environment:
            try renderLookup(ProjectContextResolver.lookupEnvironments(options: options), format: options.format)
        case .host:
            try renderLookup(ProjectContextResolver.lookupHosts(options: options), format: options.format)
        case .service:
            try renderLookup(ProjectContextResolver.lookupServices(options: options), format: options.format)
        case .database:
            try renderLookup(ProjectContextResolver.lookupDatabases(options: options), format: options.format)
        case .command:
            try renderLookup(ProjectContextResolver.lookupCommands(options: options), format: options.format)
        case .credential:
            try renderLookup(ProjectContextResolver.lookupCredentials(options: options), format: options.format)
        }
    }

    private static func renderLookup<Result: Codable & ProjectContextLookupRenderable>(
        _ result: Result,
        format: ProjectContextLookupOutputFormat
    ) throws {
        switch format {
        case .text:
            for line in result.renderedLines {
                print(line)
            }
        case .json:
            let data = try OrchardJSON.encoder.encode(result)
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        }
    }
}
