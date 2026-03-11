import Darwin
import Foundation
import OrchardCore

struct AgentInitConfigOptions: Sendable {
    var configURL: URL
    var serverURLString: String
    var enrollmentToken: String
    var deviceID: String
    var deviceName: String
    var workspaceRootPath: String
    var workspaceID: String
    var workspaceName: String
    var maxParallelTasks: Int
    var heartbeatIntervalSeconds: Int
    var codexBinaryPath: String
    var overwrite: Bool

    init(
        configURL: URL? = nil,
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath,
        hostName: String = ProcessInfo.processInfo.hostName
    ) throws {
        let workspaceRootPath = URL(fileURLWithPath: currentDirectoryPath).standardizedFileURL.path
        let defaultWorkspaceName = AgentSetupDefaults.workspaceName(for: workspaceRootPath)

        self.configURL = try configURL ?? OrchardAgentPaths.configURL()
        self.serverURLString = "http://127.0.0.1:8080"
        self.enrollmentToken = "replace-me"
        self.deviceID = AgentSetupDefaults.deviceID(for: hostName)
        self.deviceName = hostName.isEmpty ? "Orchard Agent" : hostName
        self.workspaceRootPath = workspaceRootPath
        self.workspaceID = AgentSetupDefaults.workspaceID(for: defaultWorkspaceName)
        self.workspaceName = defaultWorkspaceName
        self.maxParallelTasks = 2
        self.heartbeatIntervalSeconds = 10
        self.codexBinaryPath = ExecutableLocator.preferredCodexPath() ?? "codex"
        self.overwrite = false
    }
}

struct AgentInstallLaunchAgentOptions: Sendable {
    var label: String
    var agentBinaryURL: URL
    var workingDirectoryURL: URL
    var logDirectoryURL: URL
    var plistURL: URL
    var bootstrap: Bool

    init(
        label: String = OrchardAgentPaths.launchAgentLabel,
        executablePath: String = CommandLine.arguments.first ?? "OrchardAgent",
        currentDirectoryPath: String = FileManager.default.currentDirectoryPath
    ) throws {
        self.label = label
        self.agentBinaryURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        self.workingDirectoryURL = URL(fileURLWithPath: currentDirectoryPath).standardizedFileURL
        self.logDirectoryURL = try OrchardAgentPaths.logsDirectory()
        self.plistURL = try OrchardAgentPaths.launchAgentPlistURL(label: label)
        self.bootstrap = true
    }
}

struct AgentDoctorOptions: Sendable {
    var configURL: URL
    var plistURL: URL?
    var launchAgentLabel: String
    var timeoutSeconds: Int
    var skipNetwork: Bool
    var skipLaunchAgent: Bool

    init(configURL: URL? = nil) throws {
        self.configURL = try configURL ?? OrchardAgentPaths.configURL()
        self.plistURL = nil
        self.launchAgentLabel = OrchardAgentPaths.launchAgentLabel
        self.timeoutSeconds = 3
        self.skipNetwork = false
        self.skipLaunchAgent = false
    }
}

struct AgentConfigInitializationResult: Sendable {
    var configURL: URL
    var resolvedConfig: ResolvedAgentConfig
}

struct LaunchAgentInstallResult: Sendable {
    var plistURL: URL
    var logDirectoryURL: URL
    var serviceTarget: String
    var bootstrapPerformed: Bool
}

struct AgentDoctorCheck: Sendable {
    var title: String
    var isSuccess: Bool
    var detail: String
}

struct AgentDoctorReport: Sendable {
    var checks: [AgentDoctorCheck]

    var isHealthy: Bool {
        checks.allSatisfy(\.isSuccess)
    }

    var renderedLines: [String] {
        let lines = checks.map { check in
            let prefix = check.isSuccess ? "[ok]" : "[fail]"
            return "\(prefix) \(check.title): \(check.detail)"
        }
        let summary = isHealthy ? "Orchard agent doctor passed." : "Orchard agent doctor found setup issues."
        return lines + [summary]
    }
}

enum AgentConfigInitializer {
    static func writeConfig(options: AgentInitConfigOptions) throws -> AgentConfigInitializationResult {
        let workspaceRoot = URL(fileURLWithPath: options.workspaceRootPath).standardizedFileURL.path
        let configURL = options.configURL.standardizedFileURL

        if FileManager.default.fileExists(atPath: configURL.path), !options.overwrite {
            throw NSError(domain: "OrchardAgentInit", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Config already exists at \(configURL.path). Pass --overwrite to replace it.",
            ])
        }

        let file = AgentConfigFile(
            serverURL: options.serverURLString,
            enrollmentToken: options.enrollmentToken,
            deviceID: options.deviceID,
            deviceName: options.deviceName,
            maxParallelTasks: options.maxParallelTasks,
            workspaceRoots: [
                WorkspaceDefinition(
                    id: options.workspaceID,
                    name: options.workspaceName,
                    rootPath: workspaceRoot
                ),
            ],
            heartbeatIntervalSeconds: options.heartbeatIntervalSeconds,
            codexBinaryPath: options.codexBinaryPath
        )

        let resolvedConfig = try AgentConfigLoader.validate(file: file)
        try AgentConfigLoader.save(file, to: configURL)
        return AgentConfigInitializationResult(configURL: configURL, resolvedConfig: resolvedConfig)
    }
}

enum LaunchAgentInstaller {
    static func install(options: AgentInstallLaunchAgentOptions) throws -> LaunchAgentInstallResult {
        let plistURL = options.plistURL.standardizedFileURL
        let binaryURL = options.agentBinaryURL.standardizedFileURL
        let workdirURL = options.workingDirectoryURL.standardizedFileURL
        let logDirectoryURL = options.logDirectoryURL.standardizedFileURL

        try validateExecutable(binaryURL)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try FileManager.default.createDirectory(at: logDirectoryURL, withIntermediateDirectories: true, attributes: nil)

        let plist = renderPlist(
            label: options.label,
            binaryPath: binaryURL.path,
            workingDirectoryPath: workdirURL.path,
            logDirectoryPath: logDirectoryURL.path
        )
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)

        let serviceTarget = "gui/\(getuid())/\(options.label)"
        if options.bootstrap {
            let domainTarget = "gui/\(getuid())"
            _ = try? SystemCommandRunner.run(command: "launchctl", arguments: ["bootout", domainTarget, plistURL.path], allowFailure: true)
            _ = try SystemCommandRunner.run(command: "launchctl", arguments: ["bootstrap", domainTarget, plistURL.path])
            _ = try SystemCommandRunner.run(command: "launchctl", arguments: ["kickstart", "-k", serviceTarget])
        }

        return LaunchAgentInstallResult(
            plistURL: plistURL,
            logDirectoryURL: logDirectoryURL,
            serviceTarget: serviceTarget,
            bootstrapPerformed: options.bootstrap
        )
    }

    static func renderPlist(
        label: String,
        binaryPath: String,
        workingDirectoryPath: String,
        logDirectoryPath: String
    ) -> String {
        launchAgentTemplate
            .replacingOccurrences(of: "__ORCHARD_LABEL__", with: label)
            .replacingOccurrences(of: "__ORCHARD_AGENT_BINARY__", with: binaryPath)
            .replacingOccurrences(of: "__ORCHARD_WORKDIR__", with: workingDirectoryPath)
            .replacingOccurrences(of: "__ORCHARD_LOG_DIR__", with: logDirectoryPath)
    }

    private static func validateExecutable(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw NSError(domain: "OrchardLaunchAgent", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Agent binary does not exist: \(url.path)",
            ])
        }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw NSError(domain: "OrchardLaunchAgent", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Agent binary is not executable: \(url.path)",
            ])
        }
    }

    private static let launchAgentTemplate = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>__ORCHARD_LABEL__</string>

      <key>ProgramArguments</key>
      <array>
        <string>__ORCHARD_AGENT_BINARY__</string>
      </array>

      <key>EnvironmentVariables</key>
      <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
      </dict>

      <key>RunAtLoad</key>
      <true/>

      <key>KeepAlive</key>
      <true/>

      <key>WorkingDirectory</key>
      <string>__ORCHARD_WORKDIR__</string>

      <key>StandardOutPath</key>
      <string>__ORCHARD_LOG_DIR__/agent.out.log</string>

      <key>StandardErrorPath</key>
      <string>__ORCHARD_LOG_DIR__/agent.err.log</string>
    </dict>
    </plist>
    """
}

enum AgentDoctor {
    static func run(options: AgentDoctorOptions) async -> AgentDoctorReport {
        var checks: [AgentDoctorCheck] = []
        let configURL = options.configURL.standardizedFileURL
        let configExists = FileManager.default.fileExists(atPath: configURL.path)

        checks.append(
            AgentDoctorCheck(
                title: "Config file",
                isSuccess: configExists,
                detail: configExists ? configURL.path : "Missing \(configURL.path)"
            )
        )

        guard configExists else {
            return AgentDoctorReport(checks: checks)
        }

        let resolvedConfig: ResolvedAgentConfig
        do {
            resolvedConfig = try AgentConfigLoader.load(from: configURL)
            checks.append(
                AgentDoctorCheck(
                    title: "Config validation",
                    isSuccess: true,
                    detail: "Device \(resolvedConfig.deviceID), \(resolvedConfig.workspaceRoots.count) workspace(s)"
                )
            )
        } catch {
            checks.append(
                AgentDoctorCheck(
                    title: "Config validation",
                    isSuccess: false,
                    detail: error.localizedDescription
                )
            )
            return AgentDoctorReport(checks: checks)
        }

        if let executableURL = ExecutableLocator.resolve(commandOrPath: resolvedConfig.codexBinaryPath) {
            checks.append(
                AgentDoctorCheck(
                    title: "Codex binary",
                    isSuccess: true,
                    detail: executableURL.path
                )
            )
        } else {
            checks.append(
                AgentDoctorCheck(
                    title: "Codex binary",
                    isSuccess: false,
                    detail: "Unable to resolve executable \(resolvedConfig.codexBinaryPath)"
                )
            )
        }

        if options.skipNetwork {
            checks.append(
                AgentDoctorCheck(
                    title: "Control plane health",
                    isSuccess: true,
                    detail: "Skipped by --skip-network"
                )
            )
        } else {
            let networkCheck = await checkControlPlaneHealth(serverURL: resolvedConfig.serverURL, timeoutSeconds: options.timeoutSeconds)
            checks.append(networkCheck)
        }

        if options.skipLaunchAgent {
            checks.append(
                AgentDoctorCheck(
                    title: "LaunchAgent plist",
                    isSuccess: true,
                    detail: "Skipped by --skip-launch-agent"
                )
            )
        } else {
            let plistURL = options.plistURL?.standardizedFileURL ?? (try? OrchardAgentPaths.launchAgentPlistURL(label: options.launchAgentLabel))
            if let plistURL {
                let exists = FileManager.default.fileExists(atPath: plistURL.path)
                checks.append(
                    AgentDoctorCheck(
                        title: "LaunchAgent plist",
                        isSuccess: exists,
                        detail: exists ? plistURL.path : "Missing \(plistURL.path)"
                    )
                )
            } else {
                checks.append(
                    AgentDoctorCheck(
                        title: "LaunchAgent plist",
                        isSuccess: false,
                        detail: "Could not determine LaunchAgent plist path"
                    )
                )
            }
        }

        return AgentDoctorReport(checks: checks)
    }

    private static func checkControlPlaneHealth(serverURL: URL, timeoutSeconds: Int) async -> AgentDoctorCheck {
        guard let healthURL = makeHealthURL(serverURL: serverURL) else {
            return AgentDoctorCheck(
                title: "Control plane health",
                isSuccess: false,
                detail: "Could not derive /health URL from \(serverURL.absoluteString)"
            )
        }

        var request = URLRequest(url: healthURL)
        request.timeoutInterval = TimeInterval(max(timeoutSeconds, 1))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return AgentDoctorCheck(
                    title: "Control plane health",
                    isSuccess: false,
                    detail: "No HTTP response from \(healthURL.absoluteString)"
                )
            }

            guard http.statusCode == 200 else {
                let body = String(decoding: data, as: UTF8.self)
                return AgentDoctorCheck(
                    title: "Control plane health",
                    isSuccess: false,
                    detail: "HTTP \(http.statusCode) \(body)"
                )
            }

            return AgentDoctorCheck(
                title: "Control plane health",
                isSuccess: true,
                detail: healthURL.absoluteString
            )
        } catch {
            return AgentDoctorCheck(
                title: "Control plane health",
                isSuccess: false,
                detail: error.localizedDescription
            )
        }
    }

    private static func makeHealthURL(serverURL: URL) -> URL? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: true) else {
            return nil
        }
        let path = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = path + "/health"
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

enum ExecutableLocator {
    static func resolve(commandOrPath: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if commandOrPath.contains("/") {
            let url = URL(fileURLWithPath: commandOrPath).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }

        let pathEntries = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for entry in pathEntries where !entry.isEmpty {
            let candidate = URL(fileURLWithPath: entry)
                .appendingPathComponent(commandOrPath, isDirectory: false)
                .standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    static func preferredCodexPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let resolved = resolve(commandOrPath: "codex", environment: environment) {
            return resolved.path
        }

        for candidate in ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }
}

private enum SystemCommandRunner {
    @discardableResult
    static func run(command: String, arguments: [String], allowFailure: Bool = false) throws -> String {
        let executableURL = ExecutableLocator.resolve(commandOrPath: command) ?? URL(fileURLWithPath: "/bin/\(command)")
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile() + stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        if process.terminationStatus != 0, !allowFailure {
            throw NSError(domain: "OrchardSystemCommand", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: output.isEmpty ? "\(command) failed with exit code \(process.terminationStatus)." : output,
            ])
        }

        return output
    }
}

enum AgentSetupDefaults {
    static func deviceID(for hostName: String) -> String {
        let normalized = hostName.lowercased().map { character -> Character in
            switch character {
            case "a"..."z", "0"..."9":
                return character
            default:
                return "-"
            }
        }
        let collapsed = String(normalized).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "orchard-agent" : trimmed
    }

    static func workspaceID(for workspaceName: String) -> String {
        let normalized = workspaceName.lowercased().map { character -> Character in
            switch character {
            case "a"..."z", "0"..."9":
                return character
            default:
                return "-"
            }
        }
        let collapsed = String(normalized).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "main" : trimmed
    }

    static func workspaceName(for rootPath: String) -> String {
        let component = URL(fileURLWithPath: rootPath).lastPathComponent
        return component.isEmpty ? "Main Workspace" : component
    }
}
