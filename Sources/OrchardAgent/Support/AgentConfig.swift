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

    init(
        serverURL: String,
        enrollmentToken: String,
        deviceID: String,
        deviceName: String,
        maxParallelTasks: Int?,
        workspaceRoots: [WorkspaceDefinition],
        heartbeatIntervalSeconds: Int?,
        codexBinaryPath: String?
    ) {
        self.serverURL = serverURL
        self.enrollmentToken = enrollmentToken
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.maxParallelTasks = maxParallelTasks
        self.workspaceRoots = workspaceRoots
        self.heartbeatIntervalSeconds = heartbeatIntervalSeconds
        self.codexBinaryPath = codexBinaryPath
    }
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
    static let launchAgentLabel = "com.owen.orchard.agent"

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

    static func logsDirectory() throws -> URL {
        let url = try supportDirectory().appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    static func launchAgentsDirectory() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    static func launchAgentPlistURL(label: String = launchAgentLabel) throws -> URL {
        try launchAgentsDirectory().appendingPathComponent("\(label).plist", isDirectory: false)
    }
}

enum AgentConfigLoader {
    static func load() throws -> ResolvedAgentConfig {
        try load(from: OrchardAgentPaths.configURL())
    }

    static func load(from url: URL, hostName: String = ProcessInfo.processInfo.hostName) throws -> ResolvedAgentConfig {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "OrchardAgentConfig", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Missing Orchard agent config at \(url.path)",
            ])
        }

        let file = try OrchardJSON.decoder.decode(AgentConfigFile.self, from: Data(contentsOf: url))
        return try validate(file: file, hostName: hostName)
    }

    static func save(_ file: AgentConfigFile, to url: URL) throws {
        let data = try OrchardJSON.encoder.encode(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try data.write(to: url, options: .atomic)
    }

    static func validate(file: AgentConfigFile, hostName: String = ProcessInfo.processInfo.hostName) throws -> ResolvedAgentConfig {
        let serverURLString = file.serverURL.trimmedValue
        guard !serverURLString.isEmpty else {
            throw NSError(domain: "OrchardAgentConfig", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid serverURL in agent config.",
            ])
        }

        guard
            let serverURL = URL(string: serverURLString),
            let scheme = serverURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw NSError(domain: "OrchardAgentConfig", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Invalid serverURL in agent config.",
            ])
        }

        let enrollmentToken = file.enrollmentToken.trimmedValue
        guard !enrollmentToken.isEmpty else {
            throw NSError(domain: "OrchardAgentConfig", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Enrollment token must not be empty.",
            ])
        }

        let deviceID = file.deviceID.trimmedValue
        guard !deviceID.isEmpty else {
            throw NSError(domain: "OrchardAgentConfig", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Device ID must not be empty.",
            ])
        }

        let deviceName = file.deviceName.trimmedValue
        guard !deviceName.isEmpty else {
            throw NSError(domain: "OrchardAgentConfig", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Device name must not be empty.",
            ])
        }

        guard !file.workspaceRoots.isEmpty else {
            throw NSError(domain: "OrchardAgentConfig", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "At least one workspace must be configured.",
            ])
        }

        let codexBinaryPath = file.codexBinaryPath?.trimmedValue.isEmpty == false ? file.codexBinaryPath!.trimmedValue : "codex"

        return ResolvedAgentConfig(
            serverURL: serverURL,
            enrollmentToken: enrollmentToken,
            deviceID: deviceID,
            deviceName: deviceName,
            hostName: hostName,
            maxParallelTasks: min(max(file.maxParallelTasks ?? 2, 1), 3),
            workspaceRoots: try file.workspaceRoots.map(validateWorkspace),
            heartbeatIntervalSeconds: max(5, file.heartbeatIntervalSeconds ?? 10),
            codexBinaryPath: codexBinaryPath
        )
    }

    private static func validateWorkspace(_ workspace: WorkspaceDefinition) throws -> WorkspaceDefinition {
        let workspaceID = workspace.id.trimmedValue
        guard !workspaceID.isEmpty else {
            throw NSError(domain: "OrchardAgentConfig", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Workspace ID must not be empty.",
            ])
        }

        let workspaceName = workspace.name.trimmedValue
        guard !workspaceName.isEmpty else {
            throw NSError(domain: "OrchardAgentConfig", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "Workspace name must not be empty.",
            ])
        }

        let rootPath = workspace.rootPath.trimmedValue
        guard !rootPath.isEmpty else {
            throw NSError(domain: "OrchardAgentConfig", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "Workspace root path must not be empty.",
            ])
        }

        let url = URL(fileURLWithPath: rootPath).standardizedFileURL
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
        return WorkspaceDefinition(id: workspaceID, name: workspaceName, rootPath: url.path)
    }
}

private extension String {
    var trimmedValue: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
