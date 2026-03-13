import Foundation
import OrchardCore

struct ProjectContextFile: Codable, Equatable, Sendable {
    var version: Int
    var projectID: String
    var projectName: String
    var workspaceID: String?
    var summary: String?
    var repository: ProjectRepositoryInfo?
    var environments: [ProjectEnvironment]
    var hosts: [ProjectHost]
    var services: [ProjectService]
    var databases: [ProjectDatabase]
    var commands: [ProjectCommand]
    var credentials: [ProjectCredentialRequirement]
    var notes: [String]

    private enum CodingKeys: String, CodingKey {
        case version
        case projectID
        case projectName
        case workspaceID
        case summary
        case repository
        case environments
        case hosts
        case services
        case databases
        case commands
        case credentials
        case notes
    }

    init(
        version: Int = 1,
        projectID: String,
        projectName: String,
        workspaceID: String? = nil,
        summary: String? = nil,
        repository: ProjectRepositoryInfo? = nil,
        environments: [ProjectEnvironment] = [],
        hosts: [ProjectHost] = [],
        services: [ProjectService] = [],
        databases: [ProjectDatabase] = [],
        commands: [ProjectCommand] = [],
        credentials: [ProjectCredentialRequirement] = [],
        notes: [String] = []
    ) {
        self.version = version
        self.projectID = projectID
        self.projectName = projectName
        self.workspaceID = workspaceID
        self.summary = summary
        self.repository = repository
        self.environments = environments
        self.hosts = hosts
        self.services = services
        self.databases = databases
        self.commands = commands
        self.credentials = credentials
        self.notes = notes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        projectID = try container.decode(String.self, forKey: .projectID)
        projectName = try container.decode(String.self, forKey: .projectName)
        workspaceID = try container.decodeIfPresent(String.self, forKey: .workspaceID)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        repository = try container.decodeIfPresent(ProjectRepositoryInfo.self, forKey: .repository)
        environments = try container.decodeIfPresent([ProjectEnvironment].self, forKey: .environments) ?? []
        hosts = try container.decodeIfPresent([ProjectHost].self, forKey: .hosts) ?? []
        services = try container.decodeIfPresent([ProjectService].self, forKey: .services) ?? []
        databases = try container.decodeIfPresent([ProjectDatabase].self, forKey: .databases) ?? []
        commands = try container.decodeIfPresent([ProjectCommand].self, forKey: .commands) ?? []
        credentials = try container.decodeIfPresent([ProjectCredentialRequirement].self, forKey: .credentials) ?? []
        notes = try container.decodeIfPresent([String].self, forKey: .notes) ?? []
    }
}

struct ProjectRepositoryInfo: Codable, Equatable, Sendable {
    var gitRemote: String?
    var defaultBranch: String?
    var deployRunbook: String?

    init(gitRemote: String? = nil, defaultBranch: String? = nil, deployRunbook: String? = nil) {
        self.gitRemote = gitRemote
        self.defaultBranch = defaultBranch
        self.deployRunbook = deployRunbook
    }
}

struct ProjectEnvironment: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var deploymentPath: String?
    var hostIDs: [String]
    var serviceIDs: [String]
    var databaseIDs: [String]
    var urls: [ProjectEndpoint]
    var notes: [String]

    init(
        id: String,
        name: String,
        deploymentPath: String? = nil,
        hostIDs: [String] = [],
        serviceIDs: [String] = [],
        databaseIDs: [String] = [],
        urls: [ProjectEndpoint] = [],
        notes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.deploymentPath = deploymentPath
        self.hostIDs = hostIDs
        self.serviceIDs = serviceIDs
        self.databaseIDs = databaseIDs
        self.urls = urls
        self.notes = notes
    }
}

struct ProjectEndpoint: Codable, Equatable, Sendable {
    var label: String
    var url: String

    init(label: String, url: String) {
        self.label = label
        self.url = url
    }
}

struct ProjectHost: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var provider: String?
    var region: String?
    var publicAddress: String?
    var privateAddress: String?
    var roles: [String]
    var notes: [String]

    init(
        id: String,
        name: String,
        provider: String? = nil,
        region: String? = nil,
        publicAddress: String? = nil,
        privateAddress: String? = nil,
        roles: [String] = [],
        notes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.region = region
        self.publicAddress = publicAddress
        self.privateAddress = privateAddress
        self.roles = roles
        self.notes = notes
    }
}

struct ProjectService: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: String
    var environmentIDs: [String]
    var hostID: String?
    var deployPath: String?
    var runbook: String?
    var healthURL: String?
    var configPath: String?
    var credentialIDs: [String]
    var notes: [String]

    init(
        id: String,
        name: String,
        kind: String,
        environmentIDs: [String] = [],
        hostID: String? = nil,
        deployPath: String? = nil,
        runbook: String? = nil,
        healthURL: String? = nil,
        configPath: String? = nil,
        credentialIDs: [String] = [],
        notes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.environmentIDs = environmentIDs
        self.hostID = hostID
        self.deployPath = deployPath
        self.runbook = runbook
        self.healthURL = healthURL
        self.configPath = configPath
        self.credentialIDs = credentialIDs
        self.notes = notes
    }
}

struct ProjectDatabase: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var engine: String
    var environmentIDs: [String]
    var hostID: String?
    var databaseName: String?
    var storagePath: String?
    var port: Int?
    var credentialIDs: [String]
    var notes: [String]

    init(
        id: String,
        name: String,
        engine: String,
        environmentIDs: [String] = [],
        hostID: String? = nil,
        databaseName: String? = nil,
        storagePath: String? = nil,
        port: Int? = nil,
        credentialIDs: [String] = [],
        notes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.engine = engine
        self.environmentIDs = environmentIDs
        self.hostID = hostID
        self.databaseName = databaseName
        self.storagePath = storagePath
        self.port = port
        self.credentialIDs = credentialIDs
        self.notes = notes
    }
}

struct ProjectCommand: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var runner: String
    var command: String
    var workingDirectory: String?
    var environmentIDs: [String]
    var hostID: String?
    var serviceIDs: [String]
    var databaseIDs: [String]
    var credentialIDs: [String]
    var notes: [String]

    init(
        id: String,
        name: String,
        runner: String,
        command: String,
        workingDirectory: String? = nil,
        environmentIDs: [String] = [],
        hostID: String? = nil,
        serviceIDs: [String] = [],
        databaseIDs: [String] = [],
        credentialIDs: [String] = [],
        notes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.runner = runner
        self.command = command
        self.workingDirectory = workingDirectory
        self.environmentIDs = environmentIDs
        self.hostID = hostID
        self.serviceIDs = serviceIDs
        self.databaseIDs = databaseIDs
        self.credentialIDs = credentialIDs
        self.notes = notes
    }
}

struct ProjectCredentialRequirement: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: String
    var appliesToHostIDs: [String]
    var appliesToServiceIDs: [String]
    var appliesToDatabaseIDs: [String]
    var fields: [ProjectCredentialField]
    var notes: [String]

    init(
        id: String,
        name: String,
        kind: String,
        appliesToHostIDs: [String] = [],
        appliesToServiceIDs: [String] = [],
        appliesToDatabaseIDs: [String] = [],
        fields: [ProjectCredentialField] = [],
        notes: [String] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.appliesToHostIDs = appliesToHostIDs
        self.appliesToServiceIDs = appliesToServiceIDs
        self.appliesToDatabaseIDs = appliesToDatabaseIDs
        self.fields = fields
        self.notes = notes
    }
}

struct ProjectCredentialField: Codable, Equatable, Sendable {
    var key: String
    var label: String
    var required: Bool
    var isSensitive: Bool
    var description: String?

    init(
        key: String,
        label: String,
        required: Bool = true,
        isSensitive: Bool = true,
        description: String? = nil
    ) {
        self.key = key
        self.label = label
        self.required = required
        self.isSensitive = isSensitive
        self.description = description
    }
}

struct ProjectContextSecretsFile: Codable, Equatable, Sendable {
    var version: Int
    var projectID: String
    var credentials: [ProjectCredentialValue]

    init(version: Int = 1, projectID: String, credentials: [ProjectCredentialValue] = []) {
        self.version = version
        self.projectID = projectID
        self.credentials = credentials
    }
}

struct ProjectCredentialValue: Codable, Equatable, Sendable {
    var credentialID: String
    var values: [String: String]

    init(credentialID: String, values: [String: String] = [:]) {
        self.credentialID = credentialID
        self.values = values
    }
}

extension ProjectRepositoryInfo {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case gitRemote
            case defaultBranch
            case deployRunbook
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            gitRemote: try container.decodeIfPresent(String.self, forKey: .gitRemote),
            defaultBranch: try container.decodeIfPresent(String.self, forKey: .defaultBranch),
            deployRunbook: try container.decodeIfPresent(String.self, forKey: .deployRunbook)
        )
    }
}

extension ProjectEnvironment {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case deploymentPath
            case hostIDs
            case serviceIDs
            case databaseIDs
            case urls
            case notes
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            deploymentPath: try container.decodeIfPresent(String.self, forKey: .deploymentPath),
            hostIDs: try container.decodeIfPresent([String].self, forKey: .hostIDs) ?? [],
            serviceIDs: try container.decodeIfPresent([String].self, forKey: .serviceIDs) ?? [],
            databaseIDs: try container.decodeIfPresent([String].self, forKey: .databaseIDs) ?? [],
            urls: try container.decodeIfPresent([ProjectEndpoint].self, forKey: .urls) ?? [],
            notes: try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        )
    }
}

extension ProjectEndpoint {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case label
            case url
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            label: try container.decode(String.self, forKey: .label),
            url: try container.decode(String.self, forKey: .url)
        )
    }
}

extension ProjectHost {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case provider
            case region
            case publicAddress
            case privateAddress
            case roles
            case notes
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            provider: try container.decodeIfPresent(String.self, forKey: .provider),
            region: try container.decodeIfPresent(String.self, forKey: .region),
            publicAddress: try container.decodeIfPresent(String.self, forKey: .publicAddress),
            privateAddress: try container.decodeIfPresent(String.self, forKey: .privateAddress),
            roles: try container.decodeIfPresent([String].self, forKey: .roles) ?? [],
            notes: try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        )
    }
}

extension ProjectService {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case kind
            case environmentIDs
            case hostID
            case deployPath
            case runbook
            case healthURL
            case configPath
            case credentialIDs
            case notes
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(String.self, forKey: .kind),
            environmentIDs: try container.decodeIfPresent([String].self, forKey: .environmentIDs) ?? [],
            hostID: try container.decodeIfPresent(String.self, forKey: .hostID),
            deployPath: try container.decodeIfPresent(String.self, forKey: .deployPath),
            runbook: try container.decodeIfPresent(String.self, forKey: .runbook),
            healthURL: try container.decodeIfPresent(String.self, forKey: .healthURL),
            configPath: try container.decodeIfPresent(String.self, forKey: .configPath),
            credentialIDs: try container.decodeIfPresent([String].self, forKey: .credentialIDs) ?? [],
            notes: try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        )
    }
}

extension ProjectDatabase {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case engine
            case environmentIDs
            case hostID
            case databaseName
            case storagePath
            case port
            case credentialIDs
            case notes
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            engine: try container.decode(String.self, forKey: .engine),
            environmentIDs: try container.decodeIfPresent([String].self, forKey: .environmentIDs) ?? [],
            hostID: try container.decodeIfPresent(String.self, forKey: .hostID),
            databaseName: try container.decodeIfPresent(String.self, forKey: .databaseName),
            storagePath: try container.decodeIfPresent(String.self, forKey: .storagePath),
            port: try container.decodeIfPresent(Int.self, forKey: .port),
            credentialIDs: try container.decodeIfPresent([String].self, forKey: .credentialIDs) ?? [],
            notes: try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        )
    }
}

extension ProjectCommand {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case runner
            case command
            case workingDirectory
            case environmentIDs
            case hostID
            case serviceIDs
            case databaseIDs
            case credentialIDs
            case notes
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            runner: try container.decode(String.self, forKey: .runner),
            command: try container.decode(String.self, forKey: .command),
            workingDirectory: try container.decodeIfPresent(String.self, forKey: .workingDirectory),
            environmentIDs: try container.decodeIfPresent([String].self, forKey: .environmentIDs) ?? [],
            hostID: try container.decodeIfPresent(String.self, forKey: .hostID),
            serviceIDs: try container.decodeIfPresent([String].self, forKey: .serviceIDs) ?? [],
            databaseIDs: try container.decodeIfPresent([String].self, forKey: .databaseIDs) ?? [],
            credentialIDs: try container.decodeIfPresent([String].self, forKey: .credentialIDs) ?? [],
            notes: try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        )
    }
}

extension ProjectCredentialRequirement {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case id
            case name
            case kind
            case appliesToHostIDs
            case appliesToServiceIDs
            case appliesToDatabaseIDs
            case fields
            case notes
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            kind: try container.decode(String.self, forKey: .kind),
            appliesToHostIDs: try container.decodeIfPresent([String].self, forKey: .appliesToHostIDs) ?? [],
            appliesToServiceIDs: try container.decodeIfPresent([String].self, forKey: .appliesToServiceIDs) ?? [],
            appliesToDatabaseIDs: try container.decodeIfPresent([String].self, forKey: .appliesToDatabaseIDs) ?? [],
            fields: try container.decodeIfPresent([ProjectCredentialField].self, forKey: .fields) ?? [],
            notes: try container.decodeIfPresent([String].self, forKey: .notes) ?? []
        )
    }
}

extension ProjectCredentialField {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case key
            case label
            case required
            case isSensitive
            case description
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            key: try container.decode(String.self, forKey: .key),
            label: try container.decode(String.self, forKey: .label),
            required: try container.decodeIfPresent(Bool.self, forKey: .required) ?? true,
            isSensitive: try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? true,
            description: try container.decodeIfPresent(String.self, forKey: .description)
        )
    }
}

extension ProjectContextSecretsFile {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case version
            case projectID
            case credentials
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            projectID: try container.decode(String.self, forKey: .projectID),
            credentials: try container.decodeIfPresent([ProjectCredentialValue].self, forKey: .credentials) ?? []
        )
    }
}

extension ProjectCredentialValue {
    init(from decoder: Decoder) throws {
        enum CodingKeys: String, CodingKey {
            case credentialID
            case values
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            credentialID: try container.decode(String.self, forKey: .credentialID),
            values: try container.decodeIfPresent([String: String].self, forKey: .values) ?? [:]
        )
    }
}

struct ResolvedProjectContext: Codable, Equatable, Sendable {
    var project: ProjectContextFile
    var definitionPath: String
    var localSecretsPath: String
    var localSecretsPresent: Bool
    var resolvedCredentials: [ResolvedProjectCredential]

    func redactingSensitiveValues() -> ResolvedProjectContext {
        ResolvedProjectContext(
            project: project,
            definitionPath: definitionPath,
            localSecretsPath: localSecretsPath,
            localSecretsPresent: localSecretsPresent,
            resolvedCredentials: resolvedCredentials.map { $0.redactingSensitiveValues() }
        )
    }
}

struct ResolvedProjectCredential: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: String
    var appliesToHostIDs: [String]
    var appliesToServiceIDs: [String]
    var appliesToDatabaseIDs: [String]
    var configured: Bool
    var missingRequiredFields: [String]
    var fields: [ResolvedProjectCredentialField]
    var notes: [String]

    func redactingSensitiveValues() -> ResolvedProjectCredential {
        ResolvedProjectCredential(
            id: id,
            name: name,
            kind: kind,
            appliesToHostIDs: appliesToHostIDs,
            appliesToServiceIDs: appliesToServiceIDs,
            appliesToDatabaseIDs: appliesToDatabaseIDs,
            configured: configured,
            missingRequiredFields: missingRequiredFields,
            fields: fields.map { $0.redactingSensitiveValue() },
            notes: notes
        )
    }
}

struct ResolvedProjectCredentialField: Codable, Equatable, Sendable {
    var key: String
    var label: String
    var required: Bool
    var isSensitive: Bool
    var description: String?
    var value: String?

    func redactingSensitiveValue() -> ResolvedProjectCredentialField {
        guard isSensitive, let value, !value.isEmpty else {
            return self
        }

        return ResolvedProjectCredentialField(
            key: key,
            label: label,
            required: required,
            isSensitive: isSensitive,
            description: description,
            value: "********"
        )
    }
}

struct ProjectContextShowOptions: Sendable {
    var workspaceURL: URL? = nil
    var localSecretsURL: URL? = nil
    var revealSecrets: Bool = false
}

enum ProjectContextLookupSubject: String, Codable, Equatable, Sendable {
    case environment
    case host
    case service
    case database
    case command
    case credential

    init(argument: String) throws {
        switch argument.lowercased() {
        case "environment", "environments", "env", "envs":
            self = .environment
        case "host", "hosts":
            self = .host
        case "service", "services":
            self = .service
        case "database", "databases", "db", "dbs":
            self = .database
        case "command", "commands", "cmd", "cmds", "operation", "operations":
            self = .command
        case "credential", "credentials", "secret", "secrets":
            self = .credential
        default:
            throw AgentCLIError.usage("Unknown project-context lookup subject: \(argument)")
        }
    }
}

enum ProjectContextLookupOutputFormat: String, Codable, Equatable, Sendable {
    case text
    case json
}

struct ProjectContextLookupOptions: Sendable {
    var subject: ProjectContextLookupSubject
    var selector: String? = nil
    var workspaceURL: URL? = nil
    var localSecretsURL: URL? = nil
    var revealSecrets: Bool = false
    var format: ProjectContextLookupOutputFormat = .text
}

struct ProjectContextDoctorOptions: Sendable {
    var workspaceURL: URL? = nil
    var localSecretsURL: URL? = nil
}

struct ProjectContextInitLocalOptions: Sendable {
    var workspaceURL: URL? = nil
    var localSecretsURL: URL? = nil
    var overwrite: Bool = false
}

struct ProjectContextLocalInitializationResult: Sendable {
    var projectID: String
    var localSecretsURL: URL
    var overwritten: Bool
}

struct ProjectContextDoctorReport: Sendable {
    var resolved: ResolvedProjectContext
    var issues: [String]

    var isHealthy: Bool { issues.isEmpty }

    var renderedLines: [String] {
        var lines = [
            "Project context: \(resolved.project.projectName) (\(resolved.project.projectID))",
            "Definition: \(resolved.definitionPath)",
            "Local secrets: \(resolved.localSecretsPath)\(resolved.localSecretsPresent ? "" : " [missing]")",
        ]

        if resolved.resolvedCredentials.isEmpty {
            lines.append("Credentials: none")
        } else {
            lines.append("Credentials:")
            for credential in resolved.resolvedCredentials {
                if credential.configured {
                    lines.append("  [ok] \(credential.id) (\(credential.kind))")
                } else {
                    let missing = credential.missingRequiredFields.joined(separator: ", ")
                    lines.append("  [missing] \(credential.id) (\(credential.kind)) -> \(missing)")
                }
            }
        }

        if issues.isEmpty {
            lines.append("Status: healthy")
        } else {
            lines.append("Status: needs attention")
            lines.append(contentsOf: issues.map { "  - \($0)" })
        }

        return lines
    }
}

protocol ProjectContextLookupRenderable {
    var renderedLines: [String] { get }
}

struct ProjectContextPreparedPrompt: Equatable, Sendable {
    var executionPrompt: String
    var displayPrompt: String
    var attachedProjectID: String?
}

enum ProjectContextPromptAugmentor {
    private static let contextBeginMarker = "<<<ORCHARD_PROJECT_CONTEXT>>>"
    private static let contextEndMarker = "<<<END_ORCHARD_PROJECT_CONTEXT>>>"
    private static let userTaskMarker = "<<<ORCHARD_USER_TASK>>>"

    static func prepare(
        userPrompt: String,
        workspaceURL: URL,
        localSecretsURL: URL? = nil
    ) -> ProjectContextPreparedPrompt {
        let displayPrompt = userPrompt.trimmedOrEmpty
        guard !displayPrompt.isEmpty else {
            return ProjectContextPreparedPrompt(
                executionPrompt: displayPrompt,
                displayPrompt: displayPrompt,
                attachedProjectID: nil
            )
        }

        guard
            let resolved = try? ProjectContextResolver.load(
                workspaceURL: workspaceURL,
                localSecretsURL: localSecretsURL
            ).redactingSensitiveValues()
        else {
            return ProjectContextPreparedPrompt(
                executionPrompt: displayPrompt,
                displayPrompt: displayPrompt,
                attachedProjectID: nil
            )
        }

        let injectedContext = renderInjectedContext(from: resolved)
        let executionPrompt = [
            contextBeginMarker,
            injectedContext,
            contextEndMarker,
            "",
            userTaskMarker,
            displayPrompt,
        ].joined(separator: "\n")

        return ProjectContextPreparedPrompt(
            executionPrompt: executionPrompt,
            displayPrompt: displayPrompt,
            attachedProjectID: resolved.project.projectID
        )
    }

    static func extractUserPrompt(from prompt: String?) -> String? {
        guard let prompt = prompt?.trimmedOrEmpty.nilIfEmpty else {
            return nil
        }

        guard let range = prompt.range(of: userTaskMarker) else {
            return prompt
        }

        let extracted = String(prompt[range.upperBound...]).trimmedOrEmpty
        return extracted.nilIfEmpty
    }

    private static func renderInjectedContext(from resolved: ResolvedProjectContext) -> String {
        let project = resolved.project
        var lines = [
            "你当前所在目录关联到一个已登记的项目上下文。以下内容由 OrchardAgent 自动注入，只包含非敏感事实与本机密钥配置状态。",
            "执行时优先以这些事实为准，不要猜测部署位置、主机地址、数据库路径，也不要把密钥写进仓库、提交或日志。",
            "项目: \(project.projectName) (\(project.projectID))",
        ]

        if let summary = project.summary?.trimmedOrEmpty.nilIfEmpty {
            lines.append("摘要: \(summary)")
        }
        if let workspaceID = project.workspaceID?.trimmedOrEmpty.nilIfEmpty {
            lines.append("工作区 ID: \(workspaceID)")
        }
        if let repository = renderRepository(project.repository) {
            lines.append("仓库: \(repository)")
        }

        if !project.environments.isEmpty {
            lines.append("环境:")
            for environment in project.environments {
                lines.append("  - \(renderEnvironment(environment))")
            }
        }

        if !project.hosts.isEmpty {
            lines.append("主机:")
            for host in project.hosts {
                lines.append("  - \(renderHost(host))")
            }
        }

        if !project.services.isEmpty {
            lines.append("服务:")
            for service in project.services {
                lines.append("  - \(renderService(service))")
            }
        }

        if !project.databases.isEmpty {
            lines.append("数据库:")
            for database in project.databases {
                lines.append("  - \(renderDatabase(database))")
            }
        }

        if !project.commands.isEmpty {
            lines.append("标准操作命令:")
            for command in project.commands {
                lines.append("  - \(renderCommand(command))")
            }
        }

        if resolved.localSecretsPresent {
            lines.append("本机密钥状态（不含真实敏感值）:")
        } else {
            lines.append("本机密钥状态（当前宿主机未发现 local secrets 文件，仅展示需求）:")
        }

        if resolved.resolvedCredentials.isEmpty {
            lines.append("  - 无额外凭据要求")
        } else {
            for credential in resolved.resolvedCredentials {
                lines.append("  - \(renderCredential(credential))")
            }
        }

        if !project.notes.isEmpty {
            lines.append("补充说明:")
            for note in project.notes.compactMap({ $0.trimmedOrEmpty.nilIfEmpty }) {
                lines.append("  - \(note)")
            }
        }

        lines.append("如需更细节，可直接读取当前仓库内的 `.orchard/project-context.json`。")
        return lines.joined(separator: "\n")
    }

    private static func renderRepository(_ repository: ProjectRepositoryInfo?) -> String? {
        guard let repository else { return nil }
        var components: [String] = []
        if let gitRemote = repository.gitRemote?.trimmedOrEmpty.nilIfEmpty {
            components.append("gitRemote=\(gitRemote)")
        }
        if let defaultBranch = repository.defaultBranch?.trimmedOrEmpty.nilIfEmpty {
            components.append("defaultBranch=\(defaultBranch)")
        }
        if let deployRunbook = repository.deployRunbook?.trimmedOrEmpty.nilIfEmpty {
            components.append("deployRunbook=\(deployRunbook)")
        }
        return components.isEmpty ? nil : components.joined(separator: " | ")
    }

    private static func renderEnvironment(_ environment: ProjectEnvironment) -> String {
        var components = [
            "\(environment.id) | \(environment.name)",
        ]
        appendPromptField("deploymentPath", environment.deploymentPath, to: &components)
        appendPromptField("hosts", joinIDs(environment.hostIDs), to: &components)
        appendPromptField("services", joinIDs(environment.serviceIDs), to: &components)
        appendPromptField("databases", joinIDs(environment.databaseIDs), to: &components)
        let urls = environment.urls
            .map { "\($0.label)=\($0.url)" }
            .joined(separator: ", ")
        appendPromptField("urls", urls, to: &components)
        if !environment.notes.isEmpty {
            appendPromptField("notes", joinNotes(environment.notes), to: &components)
        }
        return components.joined(separator: " | ")
    }

    private static func renderHost(_ host: ProjectHost) -> String {
        var components = [
            "\(host.id) | \(host.name)",
        ]
        appendPromptField("provider", host.provider, to: &components)
        appendPromptField("region", host.region, to: &components)
        appendPromptField("publicAddress", host.publicAddress, to: &components)
        appendPromptField("privateAddress", host.privateAddress, to: &components)
        if !host.roles.isEmpty {
            appendPromptField("roles", host.roles.joined(separator: ", "), to: &components)
        }
        if !host.notes.isEmpty {
            appendPromptField("notes", joinNotes(host.notes), to: &components)
        }
        return components.joined(separator: " | ")
    }

    private static func renderService(_ service: ProjectService) -> String {
        var components = [
            "\(service.id) | \(service.name)",
            "kind=\(service.kind)",
        ]
        appendPromptField("environments", joinIDs(service.environmentIDs), to: &components)
        appendPromptField("host", service.hostID, to: &components)
        appendPromptField("deployPath", service.deployPath, to: &components)
        appendPromptField("configPath", service.configPath, to: &components)
        appendPromptField("runbook", service.runbook, to: &components)
        appendPromptField("healthURL", service.healthURL, to: &components)
        if !service.notes.isEmpty {
            appendPromptField("notes", joinNotes(service.notes), to: &components)
        }
        return components.joined(separator: " | ")
    }

    private static func renderDatabase(_ database: ProjectDatabase) -> String {
        var components = [
            "\(database.id) | \(database.name)",
            "engine=\(database.engine)",
        ]
        appendPromptField("environments", joinIDs(database.environmentIDs), to: &components)
        appendPromptField("host", database.hostID, to: &components)
        appendPromptField("databaseName", database.databaseName, to: &components)
        appendPromptField("storagePath", database.storagePath, to: &components)
        appendPromptField("port", database.port.map(String.init), to: &components)
        if !database.notes.isEmpty {
            appendPromptField("notes", joinNotes(database.notes), to: &components)
        }
        return components.joined(separator: " | ")
    }

    private static func renderCommand(_ command: ProjectCommand) -> String {
        var components = [
            "\(command.id) | \(command.name)",
            "runner=\(command.runner)",
        ]
        appendPromptField("command", command.command, to: &components)
        appendPromptField("workingDirectory", command.workingDirectory, to: &components)
        appendPromptField("environments", joinIDs(command.environmentIDs), to: &components)
        appendPromptField("host", command.hostID, to: &components)
        appendPromptField("services", joinIDs(command.serviceIDs), to: &components)
        appendPromptField("databases", joinIDs(command.databaseIDs), to: &components)
        appendPromptField("credentials", joinIDs(command.credentialIDs), to: &components)
        if !command.notes.isEmpty {
            appendPromptField("notes", joinNotes(command.notes), to: &components)
        }
        return components.joined(separator: " | ")
    }

    private static func renderCredential(_ credential: ResolvedProjectCredential) -> String {
        var components = [
            "\(credential.id) | \(credential.name)",
            "kind=\(credential.kind)",
            credential.configured ? "status=已配置" : "status=缺失 \(credential.missingRequiredFields.joined(separator: ", "))",
        ]

        if !credential.appliesToHostIDs.isEmpty {
            appendPromptField("hosts", joinIDs(credential.appliesToHostIDs), to: &components)
        }
        if !credential.appliesToServiceIDs.isEmpty {
            appendPromptField("services", joinIDs(credential.appliesToServiceIDs), to: &components)
        }
        if !credential.appliesToDatabaseIDs.isEmpty {
            appendPromptField("databases", joinIDs(credential.appliesToDatabaseIDs), to: &components)
        }

        let fieldSummary = credential.fields.map { field in
            var suffix: [String] = []
            if field.required {
                suffix.append("required")
            } else {
                suffix.append("optional")
            }
            if field.isSensitive {
                suffix.append("sensitive")
            }
            return "\(field.key)[\(suffix.joined(separator: ","))]"
        }.joined(separator: ", ")
        appendPromptField("fields", fieldSummary, to: &components)
        return components.joined(separator: " | ")
    }

    private static func appendPromptField(_ key: String, _ value: String?, to components: inout [String]) {
        guard let value = value?.trimmedOrEmpty.nilIfEmpty else {
            return
        }
        components.append("\(key)=\(value)")
    }

    private static func joinIDs(_ values: [String]) -> String? {
        let normalized = values.compactMap { $0.trimmedOrEmpty.nilIfEmpty }
        guard !normalized.isEmpty else {
            return nil
        }
        return normalized.joined(separator: ", ")
    }

    private static func joinNotes(_ values: [String]) -> String? {
        let normalized = values.compactMap { $0.trimmedOrEmpty.nilIfEmpty }
        guard !normalized.isEmpty else {
            return nil
        }
        return normalized.joined(separator: " / ")
    }
}

enum ProjectContextRemoteSummaryRenderer {
    static func makeSummary(
        resolved: ResolvedProjectContext,
        workspaceID: String?
    ) -> ProjectContextRemoteSummary {
        ProjectContextRemoteSummary(
            projectID: resolved.project.projectID,
            projectName: resolved.project.projectName,
            summary: resolved.project.summary,
            workspaceID: workspaceID,
            localSecretsPresent: resolved.localSecretsPresent,
            renderedLines: summaryLines(from: resolved)
        )
    }

    static func summaryLines(from resolved: ResolvedProjectContext) -> [String] {
        let project = resolved.project
        var lines = [
            "项目: \(project.projectName) (\(project.projectID))",
            "定义文件: \(resolved.definitionPath)",
            "本机密钥: \(resolved.localSecretsPresent ? "已发现" : "缺失")",
        ]

        if let summary = project.summary?.trimmedOrEmpty.nilIfEmpty {
            lines.append("摘要: \(summary)")
        }

        if let repository = renderRepository(project.repository) {
            lines.append("仓库: \(repository)")
        }

        if !project.environments.isEmpty {
            lines.append("环境:")
            for environment in project.environments {
                lines.append("  - \(renderEnvironment(environment))")
            }
        }

        if !project.hosts.isEmpty {
            lines.append("主机:")
            for host in project.hosts {
                lines.append("  - \(renderHost(host))")
            }
        }

        if !project.services.isEmpty {
            lines.append("服务:")
            for service in project.services {
                lines.append("  - \(renderService(service))")
            }
        }

        if !project.databases.isEmpty {
            lines.append("数据库:")
            for database in project.databases {
                lines.append("  - \(renderDatabase(database))")
            }
        }

        if !project.commands.isEmpty {
            lines.append("标准操作命令:")
            for command in project.commands {
                lines.append("  - \(renderCommand(command))")
            }
        }

        if !resolved.resolvedCredentials.isEmpty {
            lines.append("凭据状态:")
            for credential in resolved.resolvedCredentials {
                lines.append("  - \(renderCredential(credential))")
            }
        }

        return lines
    }

    private static func renderRepository(_ repository: ProjectRepositoryInfo?) -> String? {
        guard let repository else { return nil }
        var components: [String] = []
        if let gitRemote = repository.gitRemote?.trimmedOrEmpty.nilIfEmpty {
            components.append("gitRemote=\(gitRemote)")
        }
        if let defaultBranch = repository.defaultBranch?.trimmedOrEmpty.nilIfEmpty {
            components.append("defaultBranch=\(defaultBranch)")
        }
        if let deployRunbook = repository.deployRunbook?.trimmedOrEmpty.nilIfEmpty {
            components.append("deployRunbook=\(deployRunbook)")
        }
        return components.isEmpty ? nil : components.joined(separator: " | ")
    }

    private static func renderEnvironment(_ environment: ProjectEnvironment) -> String {
        var components = [
            "\(environment.id) | \(environment.name)",
        ]
        appendField("deploymentPath", environment.deploymentPath, to: &components)
        appendField("hosts", join(environment.hostIDs), to: &components)
        appendField("services", join(environment.serviceIDs), to: &components)
        appendField("databases", join(environment.databaseIDs), to: &components)
        let urls = environment.urls
            .map { "\($0.label)=\($0.url)" }
            .joined(separator: ", ")
        appendField("urls", urls, to: &components)
        return components.joined(separator: " | ")
    }

    private static func renderHost(_ host: ProjectHost) -> String {
        var components = [
            "\(host.id) | \(host.name)",
        ]
        appendField("provider", host.provider, to: &components)
        appendField("region", host.region, to: &components)
        appendField("publicAddress", host.publicAddress, to: &components)
        appendField("privateAddress", host.privateAddress, to: &components)
        appendField("roles", host.roles.joined(separator: ", "), to: &components)
        return components.joined(separator: " | ")
    }

    private static func renderService(_ service: ProjectService) -> String {
        var components = [
            "\(service.id) | \(service.name)",
            "类型=\(service.kind)",
        ]
        appendField("environments", join(service.environmentIDs), to: &components)
        appendField("host", service.hostID, to: &components)
        appendField("deployPath", service.deployPath, to: &components)
        appendField("configPath", service.configPath, to: &components)
        appendField("runbook", service.runbook, to: &components)
        appendField("healthURL", service.healthURL, to: &components)
        return components.joined(separator: " | ")
    }

    private static func renderDatabase(_ database: ProjectDatabase) -> String {
        var components = [
            "\(database.id) | \(database.name)",
            "引擎=\(database.engine)",
        ]
        appendField("environments", join(database.environmentIDs), to: &components)
        appendField("host", database.hostID, to: &components)
        appendField("databaseName", database.databaseName, to: &components)
        appendField("storagePath", database.storagePath, to: &components)
        appendField("port", database.port.map(String.init), to: &components)
        return components.joined(separator: " | ")
    }

    private static func renderCommand(_ command: ProjectCommand) -> String {
        var components = [
            "\(command.id) | \(command.name)",
            "执行器=\(command.runner)",
        ]
        appendField("command", command.command, to: &components)
        appendField("workingDirectory", command.workingDirectory, to: &components)
        appendField("environments", join(command.environmentIDs), to: &components)
        appendField("host", command.hostID, to: &components)
        appendField("services", join(command.serviceIDs), to: &components)
        appendField("databases", join(command.databaseIDs), to: &components)
        appendField("credentials", join(command.credentialIDs), to: &components)
        return components.joined(separator: " | ")
    }

    private static func renderCredential(_ credential: ResolvedProjectCredential) -> String {
        var components = [
            "\(credential.id) | \(credential.name)",
            "类型=\(credential.kind)",
            credential.configured ? "状态=已配置" : "状态=缺失 \(credential.missingRequiredFields.joined(separator: ", "))",
        ]
        appendField("hosts", join(credential.appliesToHostIDs), to: &components)
        appendField("services", join(credential.appliesToServiceIDs), to: &components)
        appendField("databases", join(credential.appliesToDatabaseIDs), to: &components)
        return components.joined(separator: " | ")
    }

    private static func appendField(_ key: String, _ value: String?, to components: inout [String]) {
        guard let value = value?.trimmedOrEmpty.nilIfEmpty else {
            return
        }
        components.append("\(translatedLookupLabel(key))=\(value)")
    }

    private static func join(_ values: [String]) -> String? {
        let normalized = values.compactMap { $0.trimmedOrEmpty.nilIfEmpty }
        guard !normalized.isEmpty else {
            return nil
        }
        return normalized.joined(separator: ", ")
    }
}

struct ProjectContextLookupContext: Codable, Equatable, Sendable {
    var projectID: String
    var projectName: String
    var definitionPath: String
    var localSecretsPath: String
    var localSecretsPresent: Bool
    var subject: ProjectContextLookupSubject
    var selector: String?
    var matchCount: Int
}

struct ProjectContextEnvironmentLookupItem: Codable, Equatable, Sendable {
    var environment: ProjectEnvironment
    var hosts: [ProjectHost]
    var services: [ProjectService]
    var databases: [ProjectDatabase]
}

struct ProjectContextHostLookupItem: Codable, Equatable, Sendable {
    var host: ProjectHost
    var environments: [ProjectEnvironment]
    var services: [ProjectService]
    var databases: [ProjectDatabase]
    var credentials: [ResolvedProjectCredential]
}

struct ProjectContextServiceLookupItem: Codable, Equatable, Sendable {
    var service: ProjectService
    var host: ProjectHost?
    var environments: [ProjectEnvironment]
    var credentials: [ResolvedProjectCredential]
}

struct ProjectContextDatabaseLookupItem: Codable, Equatable, Sendable {
    var database: ProjectDatabase
    var host: ProjectHost?
    var environments: [ProjectEnvironment]
    var credentials: [ResolvedProjectCredential]
}

struct ProjectContextCommandLookupItem: Codable, Equatable, Sendable {
    var command: ProjectCommand
    var host: ProjectHost?
    var environments: [ProjectEnvironment]
    var services: [ProjectService]
    var databases: [ProjectDatabase]
    var credentials: [ResolvedProjectCredential]
}

struct ProjectContextCredentialLookupItem: Codable, Equatable, Sendable {
    var credential: ResolvedProjectCredential
    var hosts: [ProjectHost]
    var services: [ProjectService]
    var databases: [ProjectDatabase]
}

struct ProjectContextEnvironmentLookupResult: Codable, Equatable, Sendable, ProjectContextLookupRenderable {
    var context: ProjectContextLookupContext
    var items: [ProjectContextEnvironmentLookupItem]

    var renderedLines: [String] {
        renderLookupLines(context: context, items: items, renderer: renderEnvironmentItem)
    }
}

struct ProjectContextHostLookupResult: Codable, Equatable, Sendable, ProjectContextLookupRenderable {
    var context: ProjectContextLookupContext
    var items: [ProjectContextHostLookupItem]

    var renderedLines: [String] {
        renderLookupLines(context: context, items: items, renderer: renderHostItem)
    }
}

struct ProjectContextServiceLookupResult: Codable, Equatable, Sendable, ProjectContextLookupRenderable {
    var context: ProjectContextLookupContext
    var items: [ProjectContextServiceLookupItem]

    var renderedLines: [String] {
        renderLookupLines(context: context, items: items, renderer: renderServiceItem)
    }
}

struct ProjectContextDatabaseLookupResult: Codable, Equatable, Sendable, ProjectContextLookupRenderable {
    var context: ProjectContextLookupContext
    var items: [ProjectContextDatabaseLookupItem]

    var renderedLines: [String] {
        renderLookupLines(context: context, items: items, renderer: renderDatabaseItem)
    }
}

struct ProjectContextCommandLookupResult: Codable, Equatable, Sendable, ProjectContextLookupRenderable {
    var context: ProjectContextLookupContext
    var items: [ProjectContextCommandLookupItem]

    var renderedLines: [String] {
        renderLookupLines(context: context, items: items, renderer: renderCommandItem)
    }
}

struct ProjectContextCredentialLookupResult: Codable, Equatable, Sendable, ProjectContextLookupRenderable {
    var context: ProjectContextLookupContext
    var items: [ProjectContextCredentialLookupItem]

    var renderedLines: [String] {
        renderLookupLines(context: context, items: items, renderer: renderCredentialItem)
    }
}

enum ProjectContextPaths {
    static let directoryName = ".orchard"
    static let definitionFileName = "project-context.json"

    static func definitionURL(in root: URL) -> URL {
        root
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(definitionFileName, isDirectory: false)
    }

    static func localSecretsDirectory() throws -> URL {
        let url = try OrchardAgentPaths.supportDirectory()
            .appendingPathComponent("project-context", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    static func localSecretsURL(projectID: String) throws -> URL {
        try localSecretsDirectory().appendingPathComponent("\(projectID).local.json", isDirectory: false)
    }
}

enum ProjectContextResolver {
    static func locateDefinition(startingAt url: URL) -> URL? {
        let fileManager = FileManager.default
        var currentPath = url.standardizedFileURL.path
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: currentPath, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                currentPath = (currentPath as NSString).deletingLastPathComponent
            }
        } else if !url.hasDirectoryPath {
            currentPath = (currentPath as NSString).deletingLastPathComponent
        }

        var visitedPaths = Set<String>()
        while !currentPath.isEmpty, visitedPaths.insert(currentPath).inserted {
            let candidatePath = ((currentPath as NSString)
                .appendingPathComponent(ProjectContextPaths.directoryName) as NSString)
                .appendingPathComponent(ProjectContextPaths.definitionFileName)
            if fileManager.fileExists(atPath: candidatePath) {
                return URL(fileURLWithPath: candidatePath, isDirectory: false)
            }

            let parentPath = (currentPath as NSString).deletingLastPathComponent
            if parentPath == currentPath {
                return nil
            }
            currentPath = parentPath
        }

        return nil
    }

    static func load(
        workspaceURL: URL? = nil,
        localSecretsURL explicitLocalSecretsURL: URL? = nil
    ) throws -> ResolvedProjectContext {
        let workspaceURL = workspaceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard let definitionURL = locateDefinition(startingAt: workspaceURL) else {
            throw NSError(domain: "OrchardProjectContext", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not find .orchard/project-context.json from \(workspaceURL.path)",
            ])
        }

        let definition = try OrchardJSON.decoder.decode(ProjectContextFile.self, from: Data(contentsOf: definitionURL))
        try validate(definition: definition)

        let localSecretsURL = try explicitLocalSecretsURL ?? ProjectContextPaths.localSecretsURL(projectID: definition.projectID)
        let localSecretsPresent = FileManager.default.fileExists(atPath: localSecretsURL.path)
        let localSecrets = localSecretsPresent
            ? try loadLocalSecrets(from: localSecretsURL, projectID: definition.projectID)
            : ProjectContextSecretsFile(projectID: definition.projectID)

        return ResolvedProjectContext(
            project: definition,
            definitionPath: definitionURL.path,
            localSecretsPath: localSecretsURL.path,
            localSecretsPresent: localSecretsPresent,
            resolvedCredentials: resolveCredentials(
                requirements: definition.credentials,
                localValues: localSecrets.credentials
            )
        )
    }

    static func writeLocalSecretsSkeleton(options: ProjectContextInitLocalOptions) throws -> ProjectContextLocalInitializationResult {
        let workspaceURL = options.workspaceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        guard let definitionURL = locateDefinition(startingAt: workspaceURL) else {
            throw NSError(domain: "OrchardProjectContext", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not find .orchard/project-context.json from \(workspaceURL.path)",
            ])
        }

        let definition = try OrchardJSON.decoder.decode(ProjectContextFile.self, from: Data(contentsOf: definitionURL))
        try validate(definition: definition)

        let localSecretsURL = try options.localSecretsURL ?? ProjectContextPaths.localSecretsURL(projectID: definition.projectID)
        let exists = FileManager.default.fileExists(atPath: localSecretsURL.path)
        if exists && !options.overwrite {
            throw NSError(domain: "OrchardProjectContext", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Local secrets file already exists at \(localSecretsURL.path). Pass --overwrite to replace it.",
            ])
        }

        let skeleton = ProjectContextSecretsFile(
            projectID: definition.projectID,
            credentials: definition.credentials.map { requirement in
                ProjectCredentialValue(
                    credentialID: requirement.id,
                    values: Dictionary(uniqueKeysWithValues: requirement.fields.map { ($0.key, "") })
                )
            }
        )

        let data = try OrchardJSON.encoder.encode(skeleton)
        try FileManager.default.createDirectory(
            at: localSecretsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: localSecretsURL, options: .atomic)

        return ProjectContextLocalInitializationResult(
            projectID: definition.projectID,
            localSecretsURL: localSecretsURL,
            overwritten: exists
        )
    }

    static func doctor(options: ProjectContextDoctorOptions) throws -> ProjectContextDoctorReport {
        let resolved = try load(workspaceURL: options.workspaceURL, localSecretsURL: options.localSecretsURL)
        var issues: [String] = []

        if !resolved.localSecretsPresent, !resolved.resolvedCredentials.isEmpty {
            issues.append("Local secrets file is missing. Create it at \(resolved.localSecretsPath).")
        }

        for credential in resolved.resolvedCredentials where !credential.configured {
            let missing = credential.missingRequiredFields.joined(separator: ", ")
            issues.append("Credential \(credential.id) is missing required fields: \(missing)")
        }

        return ProjectContextDoctorReport(resolved: resolved, issues: issues)
    }

    static func lookupEnvironments(options: ProjectContextLookupOptions) throws -> ProjectContextEnvironmentLookupResult {
        let resolved = try loadLookupContext(options: options)
        let environments = filterMatches(resolved.project.environments, selector: options.selector) { environment in
            [environment.id, environment.name]
        }
        try ensureLookupMatches(environments.count, subject: options.subject, selector: options.selector)

        let items = environments.map { environment in
            ProjectContextEnvironmentLookupItem(
                environment: environment,
                hosts: environment.hostIDs.compactMap { hostID in
                    resolved.project.hosts.first(where: { $0.id == hostID })
                },
                services: environment.serviceIDs.compactMap { serviceID in
                    resolved.project.services.first(where: { $0.id == serviceID })
                },
                databases: environment.databaseIDs.compactMap { databaseID in
                    resolved.project.databases.first(where: { $0.id == databaseID })
                }
            )
        }

        return ProjectContextEnvironmentLookupResult(
            context: makeLookupContext(resolved: resolved, options: options, matchCount: items.count),
            items: items
        )
    }

    static func lookupHosts(options: ProjectContextLookupOptions) throws -> ProjectContextHostLookupResult {
        let resolved = try loadLookupContext(options: options)
        let hosts = filterMatches(resolved.project.hosts, selector: options.selector) { host in
            [host.id, host.name, host.provider, host.region, host.publicAddress]
        }
        try ensureLookupMatches(hosts.count, subject: options.subject, selector: options.selector)

        let items = hosts.map { host in
            ProjectContextHostLookupItem(
                host: host,
                environments: resolved.project.environments.filter { $0.hostIDs.contains(host.id) },
                services: resolved.project.services.filter { $0.hostID == host.id },
                databases: resolved.project.databases.filter { $0.hostID == host.id },
                credentials: credentials(forHostID: host.id, in: resolved)
            )
        }

        return ProjectContextHostLookupResult(
            context: makeLookupContext(resolved: resolved, options: options, matchCount: items.count),
            items: items
        )
    }

    static func lookupServices(options: ProjectContextLookupOptions) throws -> ProjectContextServiceLookupResult {
        let resolved = try loadLookupContext(options: options)
        let services = filterMatches(resolved.project.services, selector: options.selector) { service in
            [service.id, service.name, service.kind, service.healthURL]
        }
        try ensureLookupMatches(services.count, subject: options.subject, selector: options.selector)

        let items = services.map { service in
            ProjectContextServiceLookupItem(
                service: service,
                host: service.hostID.flatMap { hostID in
                    resolved.project.hosts.first(where: { $0.id == hostID })
                },
                environments: service.environmentIDs.compactMap { environmentID in
                    resolved.project.environments.first(where: { $0.id == environmentID })
                },
                credentials: credentials(forService: service, in: resolved)
            )
        }

        return ProjectContextServiceLookupResult(
            context: makeLookupContext(resolved: resolved, options: options, matchCount: items.count),
            items: items
        )
    }

    static func lookupDatabases(options: ProjectContextLookupOptions) throws -> ProjectContextDatabaseLookupResult {
        let resolved = try loadLookupContext(options: options)
        let databases = filterMatches(resolved.project.databases, selector: options.selector) { database in
            [database.id, database.name, database.engine, database.databaseName, database.storagePath]
        }
        try ensureLookupMatches(databases.count, subject: options.subject, selector: options.selector)

        let items = databases.map { database in
            ProjectContextDatabaseLookupItem(
                database: database,
                host: database.hostID.flatMap { hostID in
                    resolved.project.hosts.first(where: { $0.id == hostID })
                },
                environments: database.environmentIDs.compactMap { environmentID in
                    resolved.project.environments.first(where: { $0.id == environmentID })
                },
                credentials: credentials(forDatabase: database, in: resolved)
            )
        }

        return ProjectContextDatabaseLookupResult(
            context: makeLookupContext(resolved: resolved, options: options, matchCount: items.count),
            items: items
        )
    }

    static func lookupCommands(options: ProjectContextLookupOptions) throws -> ProjectContextCommandLookupResult {
        let resolved = try loadLookupContext(options: options)
        let commands = filterMatches(resolved.project.commands, selector: options.selector) { command in
            [command.id, command.name, command.runner, command.command, command.workingDirectory, command.hostID]
        }
        try ensureLookupMatches(commands.count, subject: options.subject, selector: options.selector)

        let items = commands.map { command in
            ProjectContextCommandLookupItem(
                command: command,
                host: command.hostID.flatMap { hostID in
                    resolved.project.hosts.first(where: { $0.id == hostID })
                },
                environments: command.environmentIDs.compactMap { environmentID in
                    resolved.project.environments.first(where: { $0.id == environmentID })
                },
                services: command.serviceIDs.compactMap { serviceID in
                    resolved.project.services.first(where: { $0.id == serviceID })
                },
                databases: command.databaseIDs.compactMap { databaseID in
                    resolved.project.databases.first(where: { $0.id == databaseID })
                },
                credentials: credentials(forCommand: command, in: resolved)
            )
        }

        return ProjectContextCommandLookupResult(
            context: makeLookupContext(resolved: resolved, options: options, matchCount: items.count),
            items: items
        )
    }

    static func lookupCredentials(options: ProjectContextLookupOptions) throws -> ProjectContextCredentialLookupResult {
        let resolved = try loadLookupContext(options: options)
        let credentials = filterMatches(resolved.resolvedCredentials, selector: options.selector) { credential in
            [credential.id, credential.name, credential.kind]
        }
        try ensureLookupMatches(credentials.count, subject: options.subject, selector: options.selector)

        let items = credentials.map { credential in
            ProjectContextCredentialLookupItem(
                credential: credential,
                hosts: resolved.project.hosts.filter { credential.appliesToHostIDs.contains($0.id) },
                services: resolved.project.services.filter {
                    credential.appliesToServiceIDs.contains($0.id) || $0.credentialIDs.contains(credential.id)
                },
                databases: resolved.project.databases.filter {
                    credential.appliesToDatabaseIDs.contains($0.id) || $0.credentialIDs.contains(credential.id)
                }
            )
        }

        return ProjectContextCredentialLookupResult(
            context: makeLookupContext(resolved: resolved, options: options, matchCount: items.count),
            items: items
        )
    }

    private static func loadLocalSecrets(from url: URL, projectID: String) throws -> ProjectContextSecretsFile {
        let localSecrets = try OrchardJSON.decoder.decode(ProjectContextSecretsFile.self, from: Data(contentsOf: url))
        guard localSecrets.projectID == projectID else {
            throw NSError(domain: "OrchardProjectContext", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Local secrets projectID \(localSecrets.projectID) does not match \(projectID).",
            ])
        }
        return localSecrets
    }

    private static func loadLookupContext(options: ProjectContextLookupOptions) throws -> ResolvedProjectContext {
        let resolved = try load(workspaceURL: options.workspaceURL, localSecretsURL: options.localSecretsURL)
        return options.revealSecrets ? resolved : resolved.redactingSensitiveValues()
    }

    private static func makeLookupContext(
        resolved: ResolvedProjectContext,
        options: ProjectContextLookupOptions,
        matchCount: Int
    ) -> ProjectContextLookupContext {
        ProjectContextLookupContext(
            projectID: resolved.project.projectID,
            projectName: resolved.project.projectName,
            definitionPath: resolved.definitionPath,
            localSecretsPath: resolved.localSecretsPath,
            localSecretsPresent: resolved.localSecretsPresent,
            subject: options.subject,
            selector: options.selector.trimmedOrNil,
            matchCount: matchCount
        )
    }

    private static func ensureLookupMatches(
        _ matchCount: Int,
        subject: ProjectContextLookupSubject,
        selector: String?
    ) throws {
        guard let selector = selector.trimmedOrNil, matchCount == 0 else {
            return
        }

        throw NSError(domain: "OrchardProjectContext", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "No \(subject.rawValue) matched \(selector).",
        ])
    }

    private static func filterMatches<Value>(
        _ values: [Value],
        selector: String?,
        candidates: (Value) -> [String?]
    ) -> [Value] {
        guard let selector = selector.trimmedOrNil else {
            return values
        }

        let normalizedSelector = selector.lowercased()
        let exactMatches = values.filter { value in
            candidates(value)
                .compactMap { $0.trimmedOrNil }
                .contains { $0.lowercased() == normalizedSelector }
        }
        if !exactMatches.isEmpty {
            return exactMatches
        }

        return values.filter { value in
            candidates(value)
                .compactMap { $0.trimmedOrNil }
                .contains { $0.lowercased().contains(normalizedSelector) }
        }
    }

    private static func credentials(forHostID hostID: String, in resolved: ResolvedProjectContext) -> [ResolvedProjectCredential] {
        resolved.resolvedCredentials.filter { $0.appliesToHostIDs.contains(hostID) }
    }

    private static func credentials(forService service: ProjectService, in resolved: ResolvedProjectContext) -> [ResolvedProjectCredential] {
        deduplicatedCredentials(
            resolved.resolvedCredentials.filter {
                service.credentialIDs.contains($0.id) || $0.appliesToServiceIDs.contains(service.id)
            }
        )
    }

    private static func credentials(forDatabase database: ProjectDatabase, in resolved: ResolvedProjectContext) -> [ResolvedProjectCredential] {
        deduplicatedCredentials(
            resolved.resolvedCredentials.filter {
                database.credentialIDs.contains($0.id) || $0.appliesToDatabaseIDs.contains(database.id)
            }
        )
    }

    private static func credentials(forCommand command: ProjectCommand, in resolved: ResolvedProjectContext) -> [ResolvedProjectCredential] {
        let serviceIDs = Set(command.serviceIDs)
        let databaseIDs = Set(command.databaseIDs)

        return deduplicatedCredentials(
            resolved.resolvedCredentials.filter { credential in
                if command.credentialIDs.contains(credential.id) {
                    return true
                }

                if let hostID = command.hostID, credential.appliesToHostIDs.contains(hostID) {
                    return true
                }

                if !serviceIDs.isDisjoint(with: credential.appliesToServiceIDs) {
                    return true
                }

                if !databaseIDs.isDisjoint(with: credential.appliesToDatabaseIDs) {
                    return true
                }

                return false
            }
        )
    }

    private static func deduplicatedCredentials(_ credentials: [ResolvedProjectCredential]) -> [ResolvedProjectCredential] {
        var seen = Set<String>()
        return credentials.filter { credential in
            seen.insert(credential.id).inserted
        }
    }

    private static func resolveCredentials(
        requirements: [ProjectCredentialRequirement],
        localValues: [ProjectCredentialValue]
    ) -> [ResolvedProjectCredential] {
        let localValuesByID = Dictionary(uniqueKeysWithValues: localValues.map { ($0.credentialID, $0) })

        return requirements.map { requirement in
            let resolvedFields = requirement.fields.map { field in
                let value = localValuesByID[requirement.id]?.values[field.key]?.trimmedOrEmpty
                return ResolvedProjectCredentialField(
                    key: field.key,
                    label: field.label,
                    required: field.required,
                    isSensitive: field.isSensitive,
                    description: field.description,
                    value: value
                )
            }

            let missingRequiredFields = resolvedFields
                .filter { $0.required && ($0.value?.isEmpty ?? true) }
                .map(\.key)

            return ResolvedProjectCredential(
                id: requirement.id,
                name: requirement.name,
                kind: requirement.kind,
                appliesToHostIDs: requirement.appliesToHostIDs,
                appliesToServiceIDs: requirement.appliesToServiceIDs,
                appliesToDatabaseIDs: requirement.appliesToDatabaseIDs,
                configured: missingRequiredFields.isEmpty,
                missingRequiredFields: missingRequiredFields,
                fields: resolvedFields,
                notes: requirement.notes
            )
        }
    }

    private static func validate(definition: ProjectContextFile) throws {
        guard !definition.projectID.trimmedOrEmpty.isEmpty else {
            throw NSError(domain: "OrchardProjectContext", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "projectID must not be empty.",
            ])
        }
        guard !definition.projectName.trimmedOrEmpty.isEmpty else {
            throw NSError(domain: "OrchardProjectContext", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "projectName must not be empty.",
            ])
        }

        try validateUnique(values: definition.environments.map(\.id), label: "environment")
        try validateUnique(values: definition.hosts.map(\.id), label: "host")
        try validateUnique(values: definition.services.map(\.id), label: "service")
        try validateUnique(values: definition.databases.map(\.id), label: "database")
        try validateUnique(values: definition.commands.map(\.id), label: "command")
        try validateUnique(values: definition.credentials.map(\.id), label: "credential")

        let environmentIDs = Set(definition.environments.map(\.id))
        let hostIDs = Set(definition.hosts.map(\.id))
        let serviceIDs = Set(definition.services.map(\.id))
        let databaseIDs = Set(definition.databases.map(\.id))
        let credentialIDs = Set(definition.credentials.map(\.id))

        for environment in definition.environments {
            try validateKnown(ids: environment.hostIDs, in: hostIDs, label: "environment \(environment.id) host")
            try validateKnown(ids: environment.serviceIDs, in: serviceIDs, label: "environment \(environment.id) service")
            try validateKnown(ids: environment.databaseIDs, in: databaseIDs, label: "environment \(environment.id) database")
        }

        for service in definition.services {
            if let hostID = service.hostID?.trimmedOrEmpty, !hostID.isEmpty, !hostIDs.contains(hostID) {
                throw NSError(domain: "OrchardProjectContext", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "service \(service.id) references unknown host \(hostID).",
                ])
            }
            try validateKnown(ids: service.environmentIDs, in: environmentIDs, label: "service \(service.id) environment")
            try validateKnown(ids: service.credentialIDs, in: credentialIDs, label: "service \(service.id) credential")
        }

        for database in definition.databases {
            if let hostID = database.hostID?.trimmedOrEmpty, !hostID.isEmpty, !hostIDs.contains(hostID) {
                throw NSError(domain: "OrchardProjectContext", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "database \(database.id) references unknown host \(hostID).",
                ])
            }
            try validateKnown(ids: database.environmentIDs, in: environmentIDs, label: "database \(database.id) environment")
            try validateKnown(ids: database.credentialIDs, in: credentialIDs, label: "database \(database.id) credential")
        }

        for command in definition.commands {
            if let hostID = command.hostID?.trimmedOrEmpty, !hostID.isEmpty, !hostIDs.contains(hostID) {
                throw NSError(domain: "OrchardProjectContext", code: 12, userInfo: [
                    NSLocalizedDescriptionKey: "command \(command.id) references unknown host \(hostID).",
                ])
            }
            try validateKnown(ids: command.environmentIDs, in: environmentIDs, label: "command \(command.id) environment")
            try validateKnown(ids: command.serviceIDs, in: serviceIDs, label: "command \(command.id) service")
            try validateKnown(ids: command.databaseIDs, in: databaseIDs, label: "command \(command.id) database")
            try validateKnown(ids: command.credentialIDs, in: credentialIDs, label: "command \(command.id) credential")
        }

        for requirement in definition.credentials {
            try validateKnown(ids: requirement.appliesToHostIDs, in: hostIDs, label: "credential \(requirement.id) host")
            try validateKnown(ids: requirement.appliesToServiceIDs, in: serviceIDs, label: "credential \(requirement.id) service")
            try validateKnown(ids: requirement.appliesToDatabaseIDs, in: databaseIDs, label: "credential \(requirement.id) database")
            try validateUnique(values: requirement.fields.map(\.key), label: "credential \(requirement.id) field")
        }
    }

    private static func validateUnique(values: [String], label: String) throws {
        var seen = Set<String>()
        for value in values.map(\.trimmedOrEmpty) where !value.isEmpty {
            guard seen.insert(value).inserted else {
                throw NSError(domain: "OrchardProjectContext", code: 9, userInfo: [
                    NSLocalizedDescriptionKey: "Duplicate \(label) id: \(value)",
                ])
            }
        }
    }

    private static func validateKnown(ids: [String], in knownValues: Set<String>, label: String) throws {
        for value in ids.map(\.trimmedOrEmpty) where !value.isEmpty {
            guard knownValues.contains(value) else {
                throw NSError(domain: "OrchardProjectContext", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "Unknown \(label) reference: \(value)",
                ])
            }
        }
    }
}

private extension String {
    var trimmedOrEmpty: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        let value = trimmedOrEmpty
        return value.isEmpty ? nil : value
    }
}

private extension Optional where Wrapped == String {
    var trimmedOrNil: String? {
        switch self {
        case let .some(value):
            return value.trimmedOrEmpty.nilIfEmpty
        case .none:
            return nil
        }
    }
}

private func renderLookupLines<Item>(
    context: ProjectContextLookupContext,
    items: [Item],
    renderer: (Item) -> [String]
) -> [String] {
    var lines = [
        "项目: \(context.projectName) (\(context.projectID))",
        "查询: \(translatedLookupSubject(context.subject))\(context.selector.map { " \($0)" } ?? "")",
        "定义文件: \(context.definitionPath)",
        "本机密钥: \(context.localSecretsPath)\(context.localSecretsPresent ? "" : " [缺失]")",
        "匹配数: \(context.matchCount)",
    ]

    if items.isEmpty {
        lines.append("结果: 无")
        return lines
    }

    for item in items {
        lines.append("")
        lines.append(contentsOf: renderer(item))
    }

    return lines
}

private func renderEnvironmentItem(_ item: ProjectContextEnvironmentLookupItem) -> [String] {
    var lines = [
        "- \(item.environment.id) | \(item.environment.name)",
    ]
    appendLookupValue("deploymentPath", value: item.environment.deploymentPath, to: &lines)
    appendLookupValue("hosts", value: formatReferences(item.hosts) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("services", value: formatReferences(item.services) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("databases", value: formatReferences(item.databases) { "\($0.id) (\($0.name))" }, to: &lines)

    if !item.environment.urls.isEmpty {
        lines.append("  地址:")
        for endpoint in item.environment.urls {
            lines.append("    - \(endpoint.label): \(endpoint.url)")
        }
    }

    appendLookupNotes(item.environment.notes, to: &lines)
    return lines
}

private func renderHostItem(_ item: ProjectContextHostLookupItem) -> [String] {
    var lines = [
        "- \(item.host.id) | \(item.host.name)",
    ]
    appendLookupValue("provider", value: item.host.provider, to: &lines)
    appendLookupValue("region", value: item.host.region, to: &lines)
    appendLookupValue("publicAddress", value: item.host.publicAddress, to: &lines)
    appendLookupValue("privateAddress", value: item.host.privateAddress, to: &lines)
    appendLookupValue("roles", value: item.host.roles.isEmpty ? nil : item.host.roles.joined(separator: ", "), to: &lines)
    appendLookupValue("environments", value: formatReferences(item.environments) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("services", value: formatReferences(item.services) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("databases", value: formatReferences(item.databases) { "\($0.id) (\($0.name))" }, to: &lines)
    appendCredentialSummaries(item.credentials, to: &lines)
    appendLookupNotes(item.host.notes, to: &lines)
    return lines
}

private func renderServiceItem(_ item: ProjectContextServiceLookupItem) -> [String] {
    var lines = [
        "- \(item.service.id) | \(item.service.name)",
    ]
    appendLookupValue("kind", value: item.service.kind, to: &lines)
    appendLookupValue("host", value: item.host.map { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("environments", value: formatReferences(item.environments) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("deployPath", value: item.service.deployPath, to: &lines)
    appendLookupValue("configPath", value: item.service.configPath, to: &lines)
    appendLookupValue("runbook", value: item.service.runbook, to: &lines)
    appendLookupValue("healthURL", value: item.service.healthURL, to: &lines)
    appendCredentialSummaries(item.credentials, to: &lines)
    appendLookupNotes(item.service.notes, to: &lines)
    return lines
}

private func renderDatabaseItem(_ item: ProjectContextDatabaseLookupItem) -> [String] {
    var lines = [
        "- \(item.database.id) | \(item.database.name)",
    ]
    appendLookupValue("engine", value: item.database.engine, to: &lines)
    appendLookupValue("host", value: item.host.map { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("environments", value: formatReferences(item.environments) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("databaseName", value: item.database.databaseName, to: &lines)
    appendLookupValue("storagePath", value: item.database.storagePath, to: &lines)
    appendLookupValue("port", value: item.database.port.map(String.init), to: &lines)
    appendCredentialSummaries(item.credentials, to: &lines)
    appendLookupNotes(item.database.notes, to: &lines)
    return lines
}

private func renderCommandItem(_ item: ProjectContextCommandLookupItem) -> [String] {
    var lines = [
        "- \(item.command.id) | \(item.command.name)",
    ]
    appendLookupValue("runner", value: item.command.runner, to: &lines)
    appendLookupValue("command", value: item.command.command, to: &lines)
    appendLookupValue("workingDirectory", value: item.command.workingDirectory, to: &lines)
    appendLookupValue("host", value: item.host.map { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("environments", value: formatReferences(item.environments) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("services", value: formatReferences(item.services) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("databases", value: formatReferences(item.databases) { "\($0.id) (\($0.name))" }, to: &lines)
    appendCredentialSummaries(item.credentials, to: &lines)
    appendLookupNotes(item.command.notes, to: &lines)
    return lines
}

private func renderCredentialItem(_ item: ProjectContextCredentialLookupItem) -> [String] {
    var lines = [
        "- \(item.credential.id) | \(item.credential.name)",
    ]
    appendLookupValue("kind", value: item.credential.kind, to: &lines)
    appendLookupValue("configured", value: item.credential.configured ? "是" : "否", to: &lines)
    if !item.credential.missingRequiredFields.isEmpty {
        appendLookupValue(
            "missingRequiredFields",
            value: item.credential.missingRequiredFields.joined(separator: ", "),
            to: &lines
        )
    }
    appendLookupValue("hosts", value: formatReferences(item.hosts) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("services", value: formatReferences(item.services) { "\($0.id) (\($0.name))" }, to: &lines)
    appendLookupValue("databases", value: formatReferences(item.databases) { "\($0.id) (\($0.name))" }, to: &lines)

    if !item.credential.fields.isEmpty {
        lines.append("  字段:")
        for field in item.credential.fields {
            var attributes: [String] = []
            if field.required {
                attributes.append("必填")
            } else {
                attributes.append("可选")
            }
            if field.isSensitive {
                attributes.append("敏感")
            }

            var value = "    - \(field.key) | \(field.label)"
            if let fieldValue = field.value.trimmedOrNil {
                value += " = \(fieldValue)"
            } else {
                value += " = <空>"
            }
            if !attributes.isEmpty {
                value += " [\(attributes.joined(separator: ", "))]"
            }
            lines.append(value)
            if let description = field.description.trimmedOrNil {
                lines.append("      \(description)")
            }
        }
    }

    appendLookupNotes(item.credential.notes, to: &lines)
    return lines
}

private func appendLookupValue(_ label: String, value: String?, to lines: inout [String]) {
    guard let value = value.trimmedOrNil else {
        return
    }
    lines.append("  \(translatedLookupLabel(label)): \(value)")
}

private func appendLookupNotes(_ notes: [String], to lines: inout [String]) {
    let normalizedNotes = notes.compactMap { $0.trimmedOrEmpty.nilIfEmpty }
    guard !normalizedNotes.isEmpty else {
        return
    }

    lines.append("  备注:")
    for note in normalizedNotes {
        lines.append("    - \(note)")
    }
}

private func appendCredentialSummaries(_ credentials: [ResolvedProjectCredential], to lines: inout [String]) {
    guard !credentials.isEmpty else {
        return
    }

    lines.append("  凭据:")
    for credential in credentials {
        var line = "    - \(credential.id) | \(credential.name)"
        if credential.configured {
            line += " [ok]"
        } else if !credential.missingRequiredFields.isEmpty {
            line += " [missing: \(credential.missingRequiredFields.joined(separator: ", "))]"
        }
        lines.append(line)
    }
}

private func formatReferences<Value>(_ values: [Value], transform: (Value) -> String) -> String? {
    let rendered = values
        .map(transform)
        .map(\.trimmedOrEmpty)
        .filter { !$0.isEmpty }

    guard !rendered.isEmpty else {
        return nil
    }

    return rendered.joined(separator: ", ")
}

private func translatedLookupLabel(_ label: String) -> String {
    switch label {
    case "deploymentPath":
        return "部署目录"
    case "urls":
        return "地址"
    case "hosts":
        return "主机"
    case "services":
        return "服务"
    case "databases":
        return "数据库"
    case "provider":
        return "供应商"
    case "region":
        return "区域"
    case "publicAddress":
        return "公网地址"
    case "privateAddress":
        return "内网地址"
    case "roles":
        return "角色"
    case "environments":
        return "环境"
    case "kind":
        return "类型"
    case "host":
        return "宿主主机"
    case "deployPath":
        return "部署目录"
    case "configPath":
        return "配置文件"
    case "runbook":
        return "操作手册"
    case "healthURL":
        return "健康检查"
    case "runner":
        return "执行器"
    case "command":
        return "命令模板"
    case "workingDirectory":
        return "工作目录"
    case "credentials":
        return "凭据"
    case "engine":
        return "引擎"
    case "databaseName":
        return "库名"
    case "storagePath":
        return "存储路径"
    case "port":
        return "端口"
    case "configured":
        return "是否已配置"
    case "missingRequiredFields":
        return "缺失字段"
    default:
        return label
    }
}

private func translatedLookupSubject(_ subject: ProjectContextLookupSubject) -> String {
    switch subject {
    case .environment:
        return "环境"
    case .host:
        return "主机"
    case .service:
        return "服务"
    case .database:
        return "数据库"
    case .command:
        return "命令"
    case .credential:
        return "凭据"
    }
}
