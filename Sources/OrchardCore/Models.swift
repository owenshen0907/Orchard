import Foundation

#if canImport(Vapor)
import Vapor
#endif

public enum DevicePlatform: String, Codable, CaseIterable, Sendable {
    case macOS
    case iOS
    case unknown
}

public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case shell
    case codex
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
}

public enum DeviceCapability: String, Codable, CaseIterable, Sendable {
    case shell
    case filesystem
    case git
    case docker
    case browser
    case codex
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

public struct DeviceRegistration: Codable, Sendable {
    public var deviceID: String
    public var name: String
    public var hostName: String
    public var platform: DevicePlatform
    public var capabilities: [DeviceCapability]
    public var workRoot: String

    public init(
        deviceID: String,
        name: String,
        hostName: String,
        platform: DevicePlatform,
        capabilities: [DeviceCapability],
        workRoot: String
    ) {
        self.deviceID = deviceID
        self.name = name
        self.hostName = hostName
        self.platform = platform
        self.capabilities = capabilities
        self.workRoot = workRoot
    }
}

public struct HeartbeatRequest: Codable, Sendable {
    public var metrics: DeviceMetrics

    public init(metrics: DeviceMetrics) {
        self.metrics = metrics
    }
}

public struct DeviceRecord: Codable, Identifiable, Sendable {
    public var id: String { deviceID }
    public var deviceID: String
    public var name: String
    public var hostName: String
    public var platform: DevicePlatform
    public var capabilities: [DeviceCapability]
    public var workRoot: String
    public var metrics: DeviceMetrics
    public var registeredAt: Date
    public var lastSeenAt: Date

    public init(
        deviceID: String,
        name: String,
        hostName: String,
        platform: DevicePlatform,
        capabilities: [DeviceCapability],
        workRoot: String,
        metrics: DeviceMetrics,
        registeredAt: Date,
        lastSeenAt: Date
    ) {
        self.deviceID = deviceID
        self.name = name
        self.hostName = hostName
        self.platform = platform
        self.capabilities = capabilities
        self.workRoot = workRoot
        self.metrics = metrics
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
    }
}

public struct CreateTaskRequest: Codable, Sendable {
    public var title: String
    public var command: String
    public var workDirectory: String?
    public var kind: TaskKind
    public var priority: TaskPriority
    public var preferredDeviceID: String?

    public init(
        title: String,
        command: String,
        workDirectory: String? = nil,
        kind: TaskKind = .shell,
        priority: TaskPriority = .normal,
        preferredDeviceID: String? = nil
    ) {
        self.title = title
        self.command = command
        self.workDirectory = workDirectory
        self.kind = kind
        self.priority = priority
        self.preferredDeviceID = preferredDeviceID
    }
}

public struct TaskRecord: Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var command: String
    public var workDirectory: String?
    public var kind: TaskKind
    public var priority: TaskPriority
    public var status: TaskStatus
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
        command: String,
        workDirectory: String?,
        kind: TaskKind,
        priority: TaskPriority,
        status: TaskStatus,
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
        self.command = command
        self.workDirectory = workDirectory
        self.kind = kind
        self.priority = priority
        self.status = status
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

    public init(
        id: String,
        taskID: String,
        deviceID: String,
        createdAt: Date,
        line: String
    ) {
        self.id = id
        self.taskID = taskID
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.line = line
    }
}

public struct ClaimTaskRequest: Codable, Sendable {
    public var deviceID: String

    public init(deviceID: String) {
        self.deviceID = deviceID
    }
}

public struct AppendTaskLogsRequest: Codable, Sendable {
    public var deviceID: String
    public var lines: [String]

    public init(deviceID: String, lines: [String]) {
        self.deviceID = deviceID
        self.lines = lines
    }
}

public struct CompleteTaskRequest: Codable, Sendable {
    public var deviceID: String
    public var status: TaskStatus
    public var exitCode: Int?
    public var summary: String?

    public init(
        deviceID: String,
        status: TaskStatus,
        exitCode: Int? = nil,
        summary: String? = nil
    ) {
        self.deviceID = deviceID
        self.status = status
        self.exitCode = exitCode
        self.summary = summary
    }
}

public struct StopTaskRequest: Codable, Sendable {
    public var reason: String?

    public init(reason: String? = nil) {
        self.reason = reason
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

public struct TaskDetail: Codable, Sendable {
    public var task: TaskRecord
    public var logs: [TaskLogEntry]

    public init(task: TaskRecord, logs: [TaskLogEntry]) {
        self.task = task
        self.logs = logs
    }
}

public struct EmptyResponse: Codable, Sendable {
    public init() {}
}

#if canImport(Vapor)
extension DeviceMetrics: Content {}
extension DeviceRegistration: Content {}
extension HeartbeatRequest: Content {}
extension DeviceRecord: Content {}
extension CreateTaskRequest: Content {}
extension TaskRecord: Content {}
extension TaskLogEntry: Content {}
extension ClaimTaskRequest: Content {}
extension AppendTaskLogsRequest: Content {}
extension CompleteTaskRequest: Content {}
extension StopTaskRequest: Content {}
extension DashboardSnapshot: Content {}
extension TaskDetail: Content {}
extension EmptyResponse: Content {}
#endif
