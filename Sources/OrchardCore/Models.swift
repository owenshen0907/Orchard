import Foundation

#if canImport(Vapor)
import Vapor
#endif

public enum DevicePlatform: String, Codable, CaseIterable, Sendable {
    case macOS
    case iOS
    case unknown
}

public enum DeviceCapability: String, Codable, CaseIterable, Sendable {
    case shell
    case filesystem
    case git
    case docker
    case browser
    case codex
}

public enum DeviceStatus: String, Codable, CaseIterable, Sendable {
    case online
    case offline
}

public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case shell
    case codex

    public var requiredCapability: DeviceCapability {
        switch self {
        case .shell:
            return .shell
        case .codex:
            return .codex
        }
    }
}

public enum TaskPriority: String, Codable, CaseIterable, Sendable {
    case low
    case normal
    case high
}

public enum ConversationDriverKind: String, Codable, CaseIterable, Sendable {
    case codexCLI
    case claudeCode

    public var displayName: String {
        switch self {
        case .codexCLI:
            return "Codex CLI"
        case .claudeCode:
            return "Claude Code"
        }
    }
}

public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case stopRequested
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .cancelled:
            return true
        case .queued, .running, .stopRequested:
            return false
        }
    }

    public var occupiesSlot: Bool {
        switch self {
        case .running, .stopRequested:
            return true
        case .queued, .succeeded, .failed, .cancelled:
            return false
        }
    }
}

public struct WorkspaceDefinition: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var rootPath: String

    public init(id: String, name: String, rootPath: String) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
    }
}

public struct DeviceMetrics: Codable, Sendable {
    public var cpuPercentApprox: Double?
    public var memoryPercent: Double?
    public var loadAverage: Double?
    public var runningTasks: Int
    public var codexDesktop: CodexDesktopMetrics?

    public init(
        cpuPercentApprox: Double? = nil,
        memoryPercent: Double? = nil,
        loadAverage: Double? = nil,
        runningTasks: Int = 0,
        codexDesktop: CodexDesktopMetrics? = nil
    ) {
        self.cpuPercentApprox = cpuPercentApprox
        self.memoryPercent = memoryPercent
        self.loadAverage = loadAverage
        self.runningTasks = runningTasks
        self.codexDesktop = codexDesktop
    }
}

public struct CodexDesktopMetrics: Codable, Sendable {
    public var activeThreadCount: Int?
    public var inflightThreadCount: Int?
    public var inflightTurnCount: Int?
    public var loadedThreadCount: Int?
    public var totalThreadCount: Int?
    public var lastSnapshotAt: Date?

    public init(
        activeThreadCount: Int? = nil,
        inflightThreadCount: Int? = nil,
        inflightTurnCount: Int? = nil,
        loadedThreadCount: Int? = nil,
        totalThreadCount: Int? = nil,
        lastSnapshotAt: Date? = nil
    ) {
        self.activeThreadCount = activeThreadCount
        self.inflightThreadCount = inflightThreadCount
        self.inflightTurnCount = inflightTurnCount
        self.loadedThreadCount = loadedThreadCount
        self.totalThreadCount = totalThreadCount
        self.lastSnapshotAt = lastSnapshotAt
    }
}

public struct AgentRegistrationRequest: Codable, Sendable {
    public var enrollmentToken: String
    public var deviceID: String
    public var name: String
    public var hostName: String
    public var platform: DevicePlatform
    public var capabilities: [DeviceCapability]
    public var maxParallelTasks: Int
    public var workspaces: [WorkspaceDefinition]
    public var localStatusPageHost: String?
    public var localStatusPagePort: Int?

    public init(
        enrollmentToken: String,
        deviceID: String,
        name: String,
        hostName: String,
        platform: DevicePlatform = .macOS,
        capabilities: [DeviceCapability],
        maxParallelTasks: Int,
        workspaces: [WorkspaceDefinition],
        localStatusPageHost: String? = nil,
        localStatusPagePort: Int? = nil
    ) {
        self.enrollmentToken = enrollmentToken
        self.deviceID = deviceID
        self.name = name
        self.hostName = hostName
        self.platform = platform
        self.capabilities = capabilities
        self.maxParallelTasks = maxParallelTasks
        self.workspaces = workspaces
        self.localStatusPageHost = localStatusPageHost
        self.localStatusPagePort = localStatusPagePort
    }
}

public struct DeviceRecord: Codable, Identifiable, Sendable {
    public var id: String { deviceID }
    public var deviceID: String
    public var name: String
    public var hostName: String
    public var platform: DevicePlatform
    public var status: DeviceStatus
    public var capabilities: [DeviceCapability]
    public var maxParallelTasks: Int
    public var workspaces: [WorkspaceDefinition]
    public var metrics: DeviceMetrics
    public var runningTaskCount: Int
    public var registeredAt: Date
    public var lastSeenAt: Date
    public var localStatusPageHost: String?
    public var localStatusPagePort: Int?

    public init(
        deviceID: String,
        name: String,
        hostName: String,
        platform: DevicePlatform,
        status: DeviceStatus,
        capabilities: [DeviceCapability],
        maxParallelTasks: Int,
        workspaces: [WorkspaceDefinition],
        metrics: DeviceMetrics,
        runningTaskCount: Int,
        registeredAt: Date,
        lastSeenAt: Date,
        localStatusPageHost: String? = nil,
        localStatusPagePort: Int? = nil
    ) {
        self.deviceID = deviceID
        self.name = name
        self.hostName = hostName
        self.platform = platform
        self.status = status
        self.capabilities = capabilities
        self.maxParallelTasks = maxParallelTasks
        self.workspaces = workspaces
        self.metrics = metrics
        self.runningTaskCount = runningTaskCount
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
        self.localStatusPageHost = localStatusPageHost
        self.localStatusPagePort = localStatusPagePort
    }
}

public struct ShellTaskPayload: Codable, Hashable, Sendable {
    public var command: String

    public init(command: String) {
        self.command = command
    }
}

public struct CodexTaskPayload: Codable, Hashable, Sendable {
    public var prompt: String
    public var driver: ConversationDriverKind?

    public init(prompt: String, driver: ConversationDriverKind? = nil) {
        self.prompt = prompt
        self.driver = driver
    }
}

public enum TaskPayload: Codable, Hashable, Sendable {
    case shell(ShellTaskPayload)
    case codex(CodexTaskPayload)

    private enum CodingKeys: String, CodingKey {
        case type
        case command
        case prompt
        case driver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TaskKind.self, forKey: .type)
        switch type {
        case .shell:
            self = .shell(ShellTaskPayload(command: try container.decode(String.self, forKey: .command)))
        case .codex:
            self = .codex(CodexTaskPayload(
                prompt: try container.decode(String.self, forKey: .prompt),
                driver: try container.decodeIfPresent(ConversationDriverKind.self, forKey: .driver)
            ))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .shell(payload):
            try container.encode(TaskKind.shell, forKey: .type)
            try container.encode(payload.command, forKey: .command)
        case let .codex(payload):
            try container.encode(TaskKind.codex, forKey: .type)
            try container.encode(payload.prompt, forKey: .prompt)
            try container.encodeIfPresent(payload.driver, forKey: .driver)
        }
    }

    public var kind: TaskKind {
        switch self {
        case .shell:
            return .shell
        case .codex:
            return .codex
        }
    }
}

public struct CreateTaskRequest: Codable, Sendable {
    public var title: String
    public var kind: TaskKind
    public var workspaceID: String
    public var relativePath: String?
    public var priority: TaskPriority
    public var preferredDeviceID: String?
    public var payload: TaskPayload

    public init(
        title: String,
        kind: TaskKind,
        workspaceID: String,
        relativePath: String? = nil,
        priority: TaskPriority = .normal,
        preferredDeviceID: String? = nil,
        payload: TaskPayload
    ) {
        self.title = title
        self.kind = kind
        self.workspaceID = workspaceID
        self.relativePath = relativePath
        self.priority = priority
        self.preferredDeviceID = preferredDeviceID
        self.payload = payload
    }
}

public struct TaskRecord: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var kind: TaskKind
    public var workspaceID: String
    public var relativePath: String?
    public var priority: TaskPriority
    public var status: TaskStatus
    public var payload: TaskPayload
    public var preferredDeviceID: String?
    public var assignedDeviceID: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var stopRequestedAt: Date?
    public var exitCode: Int?
    public var summary: String?

    public init(
        id: String,
        title: String,
        kind: TaskKind,
        workspaceID: String,
        relativePath: String?,
        priority: TaskPriority,
        status: TaskStatus,
        payload: TaskPayload,
        preferredDeviceID: String? = nil,
        assignedDeviceID: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        stopRequestedAt: Date? = nil,
        exitCode: Int? = nil,
        summary: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.workspaceID = workspaceID
        self.relativePath = relativePath
        self.priority = priority
        self.status = status
        self.payload = payload
        self.preferredDeviceID = preferredDeviceID
        self.assignedDeviceID = assignedDeviceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.stopRequestedAt = stopRequestedAt
        self.exitCode = exitCode
        self.summary = summary
    }
}

public struct TaskLogEntry: Codable, Identifiable, Sendable {
    public var id: String
    public var taskID: String
    public var deviceID: String
    public var createdAt: Date
    public var line: String

    public init(id: String, taskID: String, deviceID: String, createdAt: Date, line: String) {
        self.id = id
        self.taskID = taskID
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.line = line
    }
}

public struct TaskDetail: Codable, Sendable {
    public var task: TaskRecord
    public var logs: [TaskLogEntry]

    public init(task: TaskRecord, logs: [TaskLogEntry]) {
        self.task = task
        self.logs = logs
    }
}

public struct DashboardSnapshot: Codable, Sendable {
    public var devices: [DeviceRecord]
    public var tasks: [TaskRecord]
    public var managedRuns: [ManagedRunSummary]

    private enum CodingKeys: String, CodingKey {
        case devices
        case tasks
        case managedRuns
    }

    public init(devices: [DeviceRecord], tasks: [TaskRecord], managedRuns: [ManagedRunSummary] = []) {
        self.devices = devices
        self.tasks = tasks
        self.managedRuns = managedRuns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = try container.decodeIfPresent([DeviceRecord].self, forKey: .devices) ?? []
        tasks = try container.decodeIfPresent([TaskRecord].self, forKey: .tasks) ?? []
        managedRuns = try container.decodeIfPresent([ManagedRunSummary].self, forKey: .managedRuns) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(devices, forKey: .devices)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(managedRuns, forKey: .managedRuns)
    }
}

public enum ManagedRunDriver: String, Codable, CaseIterable, Sendable {
    case codexCLI
}

public enum ManagedRunStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case launching
    case running
    case waitingInput
    case interrupting
    case stopRequested
    case succeeded
    case failed
    case interrupted
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .interrupted, .cancelled:
            return true
        case .queued, .launching, .running, .waitingInput, .interrupting, .stopRequested:
            return false
        }
    }

    public var occupiesSlot: Bool {
        switch self {
        case .launching, .running, .waitingInput, .interrupting, .stopRequested:
            return true
        case .queued, .succeeded, .failed, .interrupted, .cancelled:
            return false
        }
    }
}

public enum ManagedRunEventKind: String, Codable, CaseIterable, Sendable {
    case runCreated
    case launching
    case started
    case logChunk
    case waitingInput
    case continued
    case interruptRequested
    case stopRequested
    case finished
    case reattached
    case agentLost
}

public struct ManagedRunSummary: Codable, Identifiable, Sendable {
    public var id: String
    public var taskID: String?
    public var deviceID: String?
    public var preferredDeviceID: String?
    public var deviceName: String?
    public var title: String
    public var driver: ManagedRunDriver
    public var workspaceID: String
    public var relativePath: String?
    public var cwd: String
    public var status: ManagedRunStatus
    public var createdAt: Date
    public var updatedAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var exitCode: Int?
    public var summary: String?
    public var pid: Int?
    public var lastHeartbeatAt: Date?
    public var codexSessionID: String?
    public var lastUserPrompt: String?
    public var lastAssistantPreview: String?

    public init(
        id: String,
        taskID: String? = nil,
        deviceID: String? = nil,
        preferredDeviceID: String? = nil,
        deviceName: String? = nil,
        title: String,
        driver: ManagedRunDriver,
        workspaceID: String,
        relativePath: String? = nil,
        cwd: String,
        status: ManagedRunStatus,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        exitCode: Int? = nil,
        summary: String? = nil,
        pid: Int? = nil,
        lastHeartbeatAt: Date? = nil,
        codexSessionID: String? = nil,
        lastUserPrompt: String? = nil,
        lastAssistantPreview: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.deviceID = deviceID
        self.preferredDeviceID = preferredDeviceID
        self.deviceName = deviceName
        self.title = title
        self.driver = driver
        self.workspaceID = workspaceID
        self.relativePath = relativePath
        self.cwd = cwd
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.summary = summary
        self.pid = pid
        self.lastHeartbeatAt = lastHeartbeatAt
        self.codexSessionID = codexSessionID
        self.lastUserPrompt = lastUserPrompt
        self.lastAssistantPreview = lastAssistantPreview
    }
}

public struct ManagedRunEvent: Codable, Identifiable, Sendable {
    public var id: String
    public var runID: String
    public var kind: ManagedRunEventKind
    public var createdAt: Date
    public var title: String
    public var message: String?

    public init(
        id: String,
        runID: String,
        kind: ManagedRunEventKind,
        createdAt: Date,
        title: String,
        message: String? = nil
    ) {
        self.id = id
        self.runID = runID
        self.kind = kind
        self.createdAt = createdAt
        self.title = title
        self.message = message
    }
}

public struct ManagedRunLogEntry: Codable, Identifiable, Sendable {
    public var id: String
    public var runID: String
    public var deviceID: String
    public var createdAt: Date
    public var line: String

    public init(id: String, runID: String, deviceID: String, createdAt: Date, line: String) {
        self.id = id
        self.runID = runID
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.line = line
    }
}

public struct ManagedRunDetail: Codable, Sendable {
    public var run: ManagedRunSummary
    public var events: [ManagedRunEvent]
    public var logs: [ManagedRunLogEntry]

    public init(run: ManagedRunSummary, events: [ManagedRunEvent], logs: [ManagedRunLogEntry]) {
        self.run = run
        self.events = events
        self.logs = logs
    }
}

public struct CreateManagedRunRequest: Codable, Sendable {
    public var title: String
    public var workspaceID: String
    public var relativePath: String?
    public var preferredDeviceID: String?
    public var driver: ManagedRunDriver
    public var prompt: String

    public init(
        title: String,
        workspaceID: String,
        relativePath: String? = nil,
        preferredDeviceID: String? = nil,
        driver: ManagedRunDriver = .codexCLI,
        prompt: String
    ) {
        self.title = title
        self.workspaceID = workspaceID
        self.relativePath = relativePath
        self.preferredDeviceID = preferredDeviceID
        self.driver = driver
        self.prompt = prompt
    }
}

public struct ManagedRunContinueRequest: Codable, Sendable {
    public var prompt: String

    public init(prompt: String) {
        self.prompt = prompt
    }
}

public struct ManagedRunInterruptRequest: Codable, Sendable {
    public init() {}
}

public struct ManagedRunStopRequest: Codable, Sendable {
    public var reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct ManagedRunRetryRequest: Codable, Sendable {
    public var prompt: String?

    public init(prompt: String? = nil) {
        self.prompt = prompt
    }
}

public enum CodexSessionState: String, Codable, CaseIterable, Sendable {
    case running
    case idle
    case completed
    case failed
    case interrupted
    case unknown
}

public enum CodexSessionItemKind: String, Codable, CaseIterable, Sendable {
    case userMessage
    case agentMessage
    case plan
    case reasoning
    case commandExecution
    case fileChange
    case webSearch
    case other
}

public struct CodexSessionSummary: Codable, Identifiable, Sendable {
    public var id: String
    public var deviceID: String
    public var deviceName: String
    public var workspaceID: String?
    public var name: String?
    public var preview: String
    public var cwd: String
    public var source: String
    public var modelProvider: String
    public var createdAt: Date
    public var updatedAt: Date
    public var state: CodexSessionState
    public var lastTurnID: String?
    public var lastTurnStatus: String?
    public var lastUserMessage: String?
    public var lastAssistantMessage: String?

    public init(
        id: String,
        deviceID: String,
        deviceName: String,
        workspaceID: String? = nil,
        name: String? = nil,
        preview: String,
        cwd: String,
        source: String,
        modelProvider: String,
        createdAt: Date,
        updatedAt: Date,
        state: CodexSessionState,
        lastTurnID: String? = nil,
        lastTurnStatus: String? = nil,
        lastUserMessage: String? = nil,
        lastAssistantMessage: String? = nil
    ) {
        self.id = id
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.workspaceID = workspaceID
        self.name = name
        self.preview = preview
        self.cwd = cwd
        self.source = source
        self.modelProvider = modelProvider
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.lastTurnID = lastTurnID
        self.lastTurnStatus = lastTurnStatus
        self.lastUserMessage = lastUserMessage
        self.lastAssistantMessage = lastAssistantMessage
    }
}

public struct CodexSessionTurn: Codable, Identifiable, Sendable {
    public var id: String
    public var status: String
    public var errorMessage: String?

    public init(id: String, status: String, errorMessage: String? = nil) {
        self.id = id
        self.status = status
        self.errorMessage = errorMessage
    }
}

public struct CodexSessionItem: Codable, Identifiable, Sendable {
    public var id: String
    public var turnID: String
    public var sequence: Int
    public var kind: CodexSessionItemKind
    public var title: String
    public var body: String?
    public var status: String?

    public init(
        id: String,
        turnID: String,
        sequence: Int,
        kind: CodexSessionItemKind,
        title: String,
        body: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.sequence = sequence
        self.kind = kind
        self.title = title
        self.body = body
        self.status = status
    }
}

public struct CodexSessionDetail: Codable, Sendable {
    public var session: CodexSessionSummary
    public var turns: [CodexSessionTurn]
    public var items: [CodexSessionItem]

    public init(session: CodexSessionSummary, turns: [CodexSessionTurn], items: [CodexSessionItem]) {
        self.session = session
        self.turns = turns
        self.items = items
    }
}

public struct CodexSessionContinueRequest: Codable, Sendable {
    public var prompt: String

    public init(prompt: String) {
        self.prompt = prompt
    }
}

public struct CodexSessionInterruptRequest: Codable, Sendable {
    public init() {}
}

public enum AgentCodexCommandAction: String, Codable, CaseIterable, Sendable {
    case listSessions
    case readSession
    case continueSession
    case interruptSession
}

public struct AgentCodexCommandRequest: Codable, Sendable {
    public var requestID: String
    public var action: AgentCodexCommandAction
    public var sessionID: String?
    public var prompt: String?
    public var limit: Int?

    public init(
        requestID: String,
        action: AgentCodexCommandAction,
        sessionID: String? = nil,
        prompt: String? = nil,
        limit: Int? = nil
    ) {
        self.requestID = requestID
        self.action = action
        self.sessionID = sessionID
        self.prompt = prompt
        self.limit = limit
    }
}

public struct AgentCodexCommandResponse: Codable, Sendable {
    public var requestID: String
    public var sessions: [CodexSessionSummary]?
    public var detail: CodexSessionDetail?
    public var errorMessage: String?

    public init(
        requestID: String,
        sessions: [CodexSessionSummary]? = nil,
        detail: CodexSessionDetail? = nil,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.sessions = sessions
        self.detail = detail
        self.errorMessage = errorMessage
    }
}

public enum ProjectContextRemoteSubject: String, Codable, CaseIterable, Sendable, Hashable {
    case environment
    case host
    case service
    case database
    case command
    case credential
}

public struct ProjectContextRemoteSummary: Codable, Sendable {
    public var projectID: String
    public var projectName: String
    public var summary: String?
    public var workspaceID: String?
    public var localSecretsPresent: Bool
    public var renderedLines: [String]

    public init(
        projectID: String,
        projectName: String,
        summary: String? = nil,
        workspaceID: String? = nil,
        localSecretsPresent: Bool,
        renderedLines: [String]
    ) {
        self.projectID = projectID
        self.projectName = projectName
        self.summary = summary
        self.workspaceID = workspaceID
        self.localSecretsPresent = localSecretsPresent
        self.renderedLines = renderedLines
    }
}

public struct ProjectContextRemoteLookupResult: Codable, Sendable {
    public var subject: ProjectContextRemoteSubject
    public var selector: String?
    public var renderedLines: [String]
    public var payloadJSON: String?

    public init(
        subject: ProjectContextRemoteSubject,
        selector: String? = nil,
        renderedLines: [String],
        payloadJSON: String? = nil
    ) {
        self.subject = subject
        self.selector = selector
        self.renderedLines = renderedLines
        self.payloadJSON = payloadJSON
    }
}

public enum AgentProjectContextCommandAction: String, Codable, CaseIterable, Sendable {
    case summary
    case lookup
}

public struct AgentProjectContextCommandRequest: Codable, Sendable {
    public var requestID: String
    public var action: AgentProjectContextCommandAction
    public var workspaceID: String
    public var subject: ProjectContextRemoteSubject?
    public var selector: String?

    public init(
        requestID: String,
        action: AgentProjectContextCommandAction,
        workspaceID: String,
        subject: ProjectContextRemoteSubject? = nil,
        selector: String? = nil
    ) {
        self.requestID = requestID
        self.action = action
        self.workspaceID = workspaceID
        self.subject = subject
        self.selector = selector
    }
}

public struct AgentProjectContextCommandResponse: Codable, Sendable {
    public var requestID: String
    public var workspaceID: String
    public var available: Bool
    public var summary: ProjectContextRemoteSummary?
    public var lookup: ProjectContextRemoteLookupResult?
    public var errorMessage: String?

    public init(
        requestID: String,
        workspaceID: String,
        available: Bool,
        summary: ProjectContextRemoteSummary? = nil,
        lookup: ProjectContextRemoteLookupResult? = nil,
        errorMessage: String? = nil
    ) {
        self.requestID = requestID
        self.workspaceID = workspaceID
        self.available = available
        self.summary = summary
        self.lookup = lookup
        self.errorMessage = errorMessage
    }
}

public struct StopTaskRequest: Codable, Sendable {
    public var reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
    }
}

public struct TaskStopCommand: Codable, Sendable {
    public var taskID: String
    public var reason: String?

    public init(taskID: String, reason: String? = nil) {
        self.taskID = taskID
        self.reason = reason
    }
}

public struct AgentHelloPayload: Codable, Sendable {
    public var sentAt: Date
    public var metrics: DeviceMetrics?
    public var runningTaskIDs: [String]

    public init(sentAt: Date = Date(), metrics: DeviceMetrics? = nil, runningTaskIDs: [String]) {
        self.sentAt = sentAt
        self.metrics = metrics
        self.runningTaskIDs = runningTaskIDs
    }
}

public struct AgentHeartbeatPayload: Codable, Sendable {
    public var sentAt: Date
    public var metrics: DeviceMetrics
    public var runningTaskIDs: [String]

    public init(sentAt: Date = Date(), metrics: DeviceMetrics, runningTaskIDs: [String]) {
        self.sentAt = sentAt
        self.metrics = metrics
        self.runningTaskIDs = runningTaskIDs
    }
}

public struct AgentLogBatchPayload: Codable, Sendable {
    public var taskID: String
    public var lines: [String]

    public init(taskID: String, lines: [String]) {
        self.taskID = taskID
        self.lines = lines
    }
}

public struct AgentTaskUpdatePayload: Codable, Sendable {
    public var taskID: String
    public var status: TaskStatus
    public var exitCode: Int?
    public var summary: String?
    public var managedRunStatus: ManagedRunStatus?
    public var pid: Int?
    public var codexSessionID: String?
    public var lastUserPrompt: String?
    public var lastAssistantPreview: String?

    public init(
        taskID: String,
        status: TaskStatus,
        exitCode: Int? = nil,
        summary: String? = nil,
        managedRunStatus: ManagedRunStatus? = nil,
        pid: Int? = nil,
        codexSessionID: String? = nil,
        lastUserPrompt: String? = nil,
        lastAssistantPreview: String? = nil
    ) {
        self.taskID = taskID
        self.status = status
        self.exitCode = exitCode
        self.summary = summary
        self.managedRunStatus = managedRunStatus
        self.pid = pid
        self.codexSessionID = codexSessionID
        self.lastUserPrompt = lastUserPrompt
        self.lastAssistantPreview = lastAssistantPreview
    }
}

public enum AgentSocketMessage: Codable, Sendable {
    case hello(AgentHelloPayload)
    case heartbeat(AgentHeartbeatPayload)
    case logBatch(AgentLogBatchPayload)
    case taskUpdate(AgentTaskUpdatePayload)
    case codexCommandResult(AgentCodexCommandResponse)
    case projectContextCommandResult(AgentProjectContextCommandResponse)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case hello
        case heartbeat
        case logBatch
        case taskUpdate
        case codexCommandResult
        case projectContextCommandResult
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .hello:
            self = .hello(try container.decode(AgentHelloPayload.self, forKey: .payload))
        case .heartbeat:
            self = .heartbeat(try container.decode(AgentHeartbeatPayload.self, forKey: .payload))
        case .logBatch:
            self = .logBatch(try container.decode(AgentLogBatchPayload.self, forKey: .payload))
        case .taskUpdate:
            self = .taskUpdate(try container.decode(AgentTaskUpdatePayload.self, forKey: .payload))
        case .codexCommandResult:
            self = .codexCommandResult(try container.decode(AgentCodexCommandResponse.self, forKey: .payload))
        case .projectContextCommandResult:
            self = .projectContextCommandResult(try container.decode(AgentProjectContextCommandResponse.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .hello(payload):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .heartbeat(payload):
            try container.encode(MessageType.heartbeat, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .logBatch(payload):
            try container.encode(MessageType.logBatch, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .taskUpdate(payload):
            try container.encode(MessageType.taskUpdate, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .codexCommandResult(payload):
            try container.encode(MessageType.codexCommandResult, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case let .projectContextCommandResult(payload):
            try container.encode(MessageType.projectContextCommandResult, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

public enum ServerSocketMessage: Codable, Sendable {
    case taskAssigned(TaskRecord)
    case taskStop(TaskStopCommand)
    case codexCommand(AgentCodexCommandRequest)
    case projectContextCommand(AgentProjectContextCommandRequest)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case taskAssigned
        case taskStop
        case codexCommand
        case projectContextCommand
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .taskAssigned:
            self = .taskAssigned(try container.decode(TaskRecord.self, forKey: .payload))
        case .taskStop:
            self = .taskStop(try container.decode(TaskStopCommand.self, forKey: .payload))
        case .codexCommand:
            self = .codexCommand(try container.decode(AgentCodexCommandRequest.self, forKey: .payload))
        case .projectContextCommand:
            self = .projectContextCommand(try container.decode(AgentProjectContextCommandRequest.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .taskAssigned(task):
            try container.encode(MessageType.taskAssigned, forKey: .type)
            try container.encode(task, forKey: .payload)
        case let .taskStop(command):
            try container.encode(MessageType.taskStop, forKey: .type)
            try container.encode(command, forKey: .payload)
        case let .codexCommand(command):
            try container.encode(MessageType.codexCommand, forKey: .type)
            try container.encode(command, forKey: .payload)
        case let .projectContextCommand(command):
            try container.encode(MessageType.projectContextCommand, forKey: .type)
            try container.encode(command, forKey: .payload)
        }
    }
}

public struct EmptyResponse: Codable, Sendable {
    public init() {}
}

#if canImport(Vapor)
extension WorkspaceDefinition: Content {}
extension DeviceMetrics: Content {}
extension AgentRegistrationRequest: Content {}
extension DeviceRecord: Content {}
extension ShellTaskPayload: Content {}
extension CodexTaskPayload: Content {}
extension TaskPayload: Content {}
extension CreateTaskRequest: Content {}
extension TaskRecord: Content {}
extension TaskLogEntry: Content {}
extension TaskDetail: Content {}
extension DashboardSnapshot: Content {}
extension ManagedRunDriver: Content {}
extension ManagedRunStatus: Content {}
extension ManagedRunEventKind: Content {}
extension ManagedRunSummary: Content {}
extension ManagedRunEvent: Content {}
extension ManagedRunLogEntry: Content {}
extension ManagedRunDetail: Content {}
extension CreateManagedRunRequest: Content {}
extension ManagedRunContinueRequest: Content {}
extension ManagedRunInterruptRequest: Content {}
extension ManagedRunStopRequest: Content {}
extension ManagedRunRetryRequest: Content {}
extension CodexSessionSummary: Content {}
extension CodexSessionTurn: Content {}
extension CodexSessionItem: Content {}
extension CodexSessionDetail: Content {}
extension CodexSessionContinueRequest: Content {}
extension CodexSessionInterruptRequest: Content {}
extension AgentCodexCommandRequest: Content {}
extension AgentCodexCommandResponse: Content {}
extension ProjectContextRemoteSubject: Content {}
extension ProjectContextRemoteSummary: Content {}
extension ProjectContextRemoteLookupResult: Content {}
extension AgentProjectContextCommandRequest: Content {}
extension AgentProjectContextCommandResponse: Content {}
extension StopTaskRequest: Content {}
extension TaskStopCommand: Content {}
extension AgentHelloPayload: Content {}
extension AgentHeartbeatPayload: Content {}
extension AgentLogBatchPayload: Content {}
extension AgentTaskUpdatePayload: Content {}
extension AgentSocketMessage: Content {}
extension ServerSocketMessage: Content {}
extension EmptyResponse: Content {}
#endif
