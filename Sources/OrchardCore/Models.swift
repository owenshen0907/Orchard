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

    public init(
        cpuPercentApprox: Double? = nil,
        memoryPercent: Double? = nil,
        loadAverage: Double? = nil,
        runningTasks: Int = 0
    ) {
        self.cpuPercentApprox = cpuPercentApprox
        self.memoryPercent = memoryPercent
        self.loadAverage = loadAverage
        self.runningTasks = runningTasks
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

    public init(
        enrollmentToken: String,
        deviceID: String,
        name: String,
        hostName: String,
        platform: DevicePlatform = .macOS,
        capabilities: [DeviceCapability],
        maxParallelTasks: Int,
        workspaces: [WorkspaceDefinition]
    ) {
        self.enrollmentToken = enrollmentToken
        self.deviceID = deviceID
        self.name = name
        self.hostName = hostName
        self.platform = platform
        self.capabilities = capabilities
        self.maxParallelTasks = maxParallelTasks
        self.workspaces = workspaces
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
        lastSeenAt: Date
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

    public init(prompt: String) {
        self.prompt = prompt
    }
}

public enum TaskPayload: Codable, Hashable, Sendable {
    case shell(ShellTaskPayload)
    case codex(CodexTaskPayload)

    private enum CodingKeys: String, CodingKey {
        case type
        case command
        case prompt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(TaskKind.self, forKey: .type)
        switch type {
        case .shell:
            self = .shell(ShellTaskPayload(command: try container.decode(String.self, forKey: .command)))
        case .codex:
            self = .codex(CodexTaskPayload(prompt: try container.decode(String.self, forKey: .prompt)))
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

    public init(devices: [DeviceRecord], tasks: [TaskRecord]) {
        self.devices = devices
        self.tasks = tasks
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
    public var runningTaskIDs: [String]

    public init(sentAt: Date = Date(), runningTaskIDs: [String]) {
        self.sentAt = sentAt
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

    public init(taskID: String, status: TaskStatus, exitCode: Int? = nil, summary: String? = nil) {
        self.taskID = taskID
        self.status = status
        self.exitCode = exitCode
        self.summary = summary
    }
}

public enum AgentSocketMessage: Codable, Sendable {
    case hello(AgentHelloPayload)
    case heartbeat(AgentHeartbeatPayload)
    case logBatch(AgentLogBatchPayload)
    case taskUpdate(AgentTaskUpdatePayload)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case hello
        case heartbeat
        case logBatch
        case taskUpdate
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
        }
    }
}

public enum ServerSocketMessage: Codable, Sendable {
    case taskAssigned(TaskRecord)
    case taskStop(TaskStopCommand)

    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    private enum MessageType: String, Codable {
        case taskAssigned
        case taskStop
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(MessageType.self, forKey: .type)
        switch type {
        case .taskAssigned:
            self = .taskAssigned(try container.decode(TaskRecord.self, forKey: .payload))
        case .taskStop:
            self = .taskStop(try container.decode(TaskStopCommand.self, forKey: .payload))
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
