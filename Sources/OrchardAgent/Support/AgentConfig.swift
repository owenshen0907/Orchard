import Foundation
import OrchardCore

struct AgentConfigFile: Codable, Sendable {
    var serverURL: String
    var enrollmentToken: String
    var deviceID: String
    var deviceName: String
    var maxParallelTasks: Int?
    var workspaceRoots: [WorkspaceDefinition]
    var heartbeatIntervalSeconds: Int?
    var codexBinaryPath: String?
}

struct ResolvedAgentConfig: Sendable {
    var serverURL: URL
    var enrollmentToken: String
    var deviceID: String
    var deviceName: String
    var hostName: String
    var maxParallelTasks: Int
    var workspaceRoots: [WorkspaceDefinition]
    var heartbeatIntervalSeconds: Int
    var codexBinaryPath: String
}

enum OrchardAgentPaths {
    static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = base.appendingPathComponent("Orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    static func configURL() throws -> URL {
        try supportDirectory().appendingPathComponent("agent.json", isDirectory: false)
    }

    static func tasksDirectory() throws -> URL {
        let url = try supportDirectory().appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    static func stateURL() throws -> URL {
        try supportDirectory().appendingPathComponent("agent-state.json", isDirectory: false)
    }
}

enum AgentConfigLoader {
    static func load() throws -> ResolvedAgentConfig {
        let url = try OrchardAgentPaths.configURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "OrchardAgentConfig", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing Orchard agent config at \(url.path)",
            ])
        }

        let file = try OrchardJSON.decoder.decode(AgentConfigFile.self, from: Data(contentsOf: url))
        guard let serverURL = URL(string: file.serverURL) else {
            throw NSError(domain: "OrchardAgentConfig", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid serverURL in agent config.",
            ])
        }

        guard !file.workspaceRoots.isEmpty else {
            throw NSError(domain: "OrchardAgentConfig", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "At least one workspace must be configured.",
            ])
        }

        return ResolvedAgentConfig(
            serverURL: serverURL,
            enrollmentToken: file.enrollmentToken,
            deviceID: file.deviceID,
            deviceName: file.deviceName,
            hostName: ProcessInfo.processInfo.hostName,
            maxParallelTasks: min(max(file.maxParallelTasks ?? 2, 1), 3),
            workspaceRoots: try file.workspaceRoots.map(validateWorkspace),
            heartbeatIntervalSeconds: max(5, file.heartbeatIntervalSeconds ?? 10),
            codexBinaryPath: file.codexBinaryPath?.isEmpty == false ? file.codexBinaryPath! : "codex"
        )
    }

    private static func validateWorkspace(_ workspace: WorkspaceDefinition) throws -> WorkspaceDefinition {
        let url = URL(fileURLWithPath: workspace.rootPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "OrchardAgentConfig", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Workspace root does not exist or is not a directory: \(workspace.rootPath)",
            ])
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw NSError(domain: "OrchardAgentConfig", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Workspace root is not readable: \(workspace.rootPath)",
            ])
        }
        return WorkspaceDefinition(id: workspace.id, name: workspace.name, rootPath: url.path)
    }
}
