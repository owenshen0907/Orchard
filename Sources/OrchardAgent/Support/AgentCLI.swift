import Foundation

enum OrchardAgentCommand: Sendable {
    case run
    case initConfig(AgentInitConfigOptions)
    case installLaunchAgent(AgentInstallLaunchAgentOptions)
    case doctor(AgentDoctorOptions)
    case help
}

enum AgentCLIError: LocalizedError {
    case usage(String)

    var errorDescription: String? {
        switch self {
        case let .usage(message):
            return message
        }
    }
}

enum AgentCLI {
    static let usage = """
    OrchardAgent usage:
      OrchardAgent run
      OrchardAgent init-config [options]
      OrchardAgent install-launch-agent [options]
      OrchardAgent doctor [options]

    Commands:
      run
        Start the Orchard agent service using ~/Library/Application Support/Orchard/agent.json

      init-config
        Write a validated agent config file.
        Options:
          --config-path PATH
          --server-url URL
          --enrollment-token TOKEN
          --device-id ID
          --device-name NAME
          --workspace-root PATH
          --workspace-id ID
          --workspace-name NAME
          --max-parallel-tasks N
          --heartbeat-interval N
          --codex-binary-path PATH
          --overwrite

      install-launch-agent
        Render and install the user LaunchAgent plist.
        Options:
          --agent-binary PATH
          --workdir PATH
          --log-dir PATH
          --plist-path PATH
          --label NAME
          --write-only

      doctor
        Validate local config, codex binary, server health, and LaunchAgent installation.
        Options:
          --config-path PATH
          --plist-path PATH
          --label NAME
          --timeout SECONDS
          --skip-network
          --skip-launch-agent
    """

    static func parse(arguments: [String]) throws -> OrchardAgentCommand {
        let args = Array(arguments.dropFirst())
        guard let command = args.first else {
            return .run
        }

        switch command {
        case "run":
            guard args.count == 1 else {
                throw AgentCLIError.usage("The run command does not accept additional arguments.")
            }
            return .run
        case "init-config":
            return .initConfig(try parseInitConfig(arguments: Array(args.dropFirst())))
        case "install-launch-agent":
            return .installLaunchAgent(try parseInstallLaunchAgent(arguments: Array(args.dropFirst())))
        case "doctor":
            return .doctor(try parseDoctor(arguments: Array(args.dropFirst())))
        case "help", "--help", "-h":
            return .help
        default:
            throw AgentCLIError.usage("Unknown OrchardAgent command: \(command)")
        }
    }

    private static func parseInitConfig(arguments: [String]) throws -> AgentInitConfigOptions {
        var options = try AgentInitConfigOptions()
        var workspaceRootWasSet = false
        var workspaceIDWasSet = false
        var workspaceNameWasSet = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--config-path":
                options.configURL = URL(fileURLWithPath: try value(after: argument, arguments: arguments, index: &index))
            case "--server-url":
                options.serverURLString = try value(after: argument, arguments: arguments, index: &index)
            case "--enrollment-token":
                options.enrollmentToken = try value(after: argument, arguments: arguments, index: &index)
            case "--device-id":
                options.deviceID = try value(after: argument, arguments: arguments, index: &index)
            case "--device-name":
                options.deviceName = try value(after: argument, arguments: arguments, index: &index)
            case "--workspace-root":
                options.workspaceRootPath = try value(after: argument, arguments: arguments, index: &index)
                workspaceRootWasSet = true
            case "--workspace-id":
                options.workspaceID = try value(after: argument, arguments: arguments, index: &index)
                workspaceIDWasSet = true
            case "--workspace-name":
                options.workspaceName = try value(after: argument, arguments: arguments, index: &index)
                workspaceNameWasSet = true
            case "--max-parallel-tasks":
                options.maxParallelTasks = try intValue(after: argument, arguments: arguments, index: &index)
            case "--heartbeat-interval":
                options.heartbeatIntervalSeconds = try intValue(after: argument, arguments: arguments, index: &index)
            case "--codex-binary-path":
                options.codexBinaryPath = try value(after: argument, arguments: arguments, index: &index)
            case "--overwrite":
                options.overwrite = true
            default:
                throw AgentCLIError.usage("Unknown init-config option: \(argument)")
            }
            index += 1
        }

        if workspaceRootWasSet {
            let normalizedRoot = URL(fileURLWithPath: options.workspaceRootPath).standardizedFileURL.path
            options.workspaceRootPath = normalizedRoot

            if !workspaceNameWasSet {
                options.workspaceName = AgentSetupDefaults.workspaceName(for: normalizedRoot)
            }
            if !workspaceIDWasSet {
                options.workspaceID = AgentSetupDefaults.workspaceID(for: options.workspaceName)
            }
        }

        return options
    }

    private static func parseInstallLaunchAgent(arguments: [String]) throws -> AgentInstallLaunchAgentOptions {
        var options = try AgentInstallLaunchAgentOptions()
        var labelWasSet = false
        var plistPathWasSet = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--agent-binary":
                options.agentBinaryURL = URL(fileURLWithPath: try value(after: argument, arguments: arguments, index: &index))
            case "--workdir":
                options.workingDirectoryURL = URL(fileURLWithPath: try value(after: argument, arguments: arguments, index: &index))
            case "--log-dir":
                options.logDirectoryURL = URL(fileURLWithPath: try value(after: argument, arguments: arguments, index: &index))
            case "--plist-path":
                options.plistURL = URL(fileURLWithPath: try value(after: argument, arguments: arguments, index: &index))
                plistPathWasSet = true
            case "--label":
                options.label = try value(after: argument, arguments: arguments, index: &index)
                labelWasSet = true
            case "--write-only":
                options.bootstrap = false
            default:
                throw AgentCLIError.usage("Unknown install-launch-agent option: \(argument)")
            }
            index += 1
        }

        if labelWasSet, !plistPathWasSet {
            options.plistURL = try OrchardAgentPaths.launchAgentPlistURL(label: options.label)
        }

        return options
    }

    private static func parseDoctor(arguments: [String]) throws -> AgentDoctorOptions {
        var options = try AgentDoctorOptions()
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--config-path":
                options.configURL = URL(fileURLWithPath: try value(after: argument, arguments: arguments, index: &index))
            case "--plist-path":
                options.plistURL = URL(fileURLWithPath: try value(after: argument, arguments: arguments, index: &index))
            case "--label":
                options.launchAgentLabel = try value(after: argument, arguments: arguments, index: &index)
            case "--timeout":
                options.timeoutSeconds = try intValue(after: argument, arguments: arguments, index: &index)
            case "--skip-network":
                options.skipNetwork = true
            case "--skip-launch-agent":
                options.skipLaunchAgent = true
            default:
                throw AgentCLIError.usage("Unknown doctor option: \(argument)")
            }
            index += 1
        }

        return options
    }

    private static func value(after option: String, arguments: [String], index: inout Int) throws -> String {
        let nextIndex = index + 1
        guard nextIndex < arguments.count else {
            throw AgentCLIError.usage("Missing value for \(option)")
        }
        index = nextIndex
        return arguments[nextIndex]
    }

    private static func intValue(after option: String, arguments: [String], index: inout Int) throws -> Int {
        let raw = try value(after: option, arguments: arguments, index: &index)
        guard let value = Int(raw) else {
            throw AgentCLIError.usage("Expected an integer value for \(option), got \(raw)")
        }
        return value
    }
}
