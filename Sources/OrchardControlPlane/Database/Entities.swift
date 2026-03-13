import Fluent
import Foundation
import OrchardCore

final class DeviceModel: Model, @unchecked Sendable {
    static let schema = "devices"

    @ID(custom: "device_id", generatedBy: .user)
    var id: String?

    @Field(key: "name")
    var name: String

    @Field(key: "host_name")
    var hostName: String

    @Field(key: "platform")
    var platformRaw: String

    @Field(key: "capabilities_json")
    var capabilitiesJSON: String

    @Field(key: "max_parallel_tasks")
    var maxParallelTasks: Int

    @Field(key: "metrics_json")
    var metricsJSON: String

    @Field(key: "registered_at")
    var registeredAt: Date

    @Field(key: "last_seen_at")
    var lastSeenAt: Date

    @OptionalField(key: "local_status_page_host")
    var localStatusPageHost: String?

    @OptionalField(key: "local_status_page_port")
    var localStatusPagePort: Int?

    init() {}

    init(
        deviceID: String,
        name: String,
        hostName: String,
        platform: DevicePlatform,
        capabilities: [DeviceCapability],
        maxParallelTasks: Int,
        metrics: DeviceMetrics,
        registeredAt: Date,
        lastSeenAt: Date,
        localStatusPageHost: String? = nil,
        localStatusPagePort: Int? = nil
    ) throws {
        self.id = deviceID
        self.name = name
        self.hostName = hostName
        self.platformRaw = platform.rawValue
        self.capabilitiesJSON = try String(decoding: OrchardJSON.encoder.encode(capabilities), as: UTF8.self)
        self.maxParallelTasks = maxParallelTasks
        self.metricsJSON = try String(decoding: OrchardJSON.encoder.encode(metrics), as: UTF8.self)
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
        self.localStatusPageHost = localStatusPageHost
        self.localStatusPagePort = localStatusPagePort
    }

    var deviceID: String {
        id ?? ""
    }

    var platform: DevicePlatform {
        get { DevicePlatform(rawValue: platformRaw) ?? .unknown }
        set { platformRaw = newValue.rawValue }
    }

    var capabilities: [DeviceCapability] {
        get { (try? OrchardJSON.decoder.decode([DeviceCapability].self, from: Data(capabilitiesJSON.utf8))) ?? [] }
        set { capabilitiesJSON = (try? String(decoding: OrchardJSON.encoder.encode(newValue), as: UTF8.self)) ?? "[]" }
    }

    var metrics: DeviceMetrics {
        get { (try? OrchardJSON.decoder.decode(DeviceMetrics.self, from: Data(metricsJSON.utf8))) ?? DeviceMetrics() }
        set { metricsJSON = (try? String(decoding: OrchardJSON.encoder.encode(newValue), as: UTF8.self)) ?? "{}" }
    }

    func toRecord(workspaces: [WorkspaceDefinition], runningTaskCount: Int, onlineThreshold: TimeInterval, now: Date = Date()) -> DeviceRecord {
        DeviceRecord(
            deviceID: deviceID,
            name: name,
            hostName: hostName,
            platform: platform,
            status: now.timeIntervalSince(lastSeenAt) <= onlineThreshold ? .online : .offline,
            capabilities: capabilities,
            maxParallelTasks: maxParallelTasks,
            workspaces: workspaces.sorted { $0.id < $1.id },
            metrics: metrics,
            runningTaskCount: runningTaskCount,
            registeredAt: registeredAt,
            lastSeenAt: lastSeenAt,
            localStatusPageHost: localStatusPageHost,
            localStatusPagePort: localStatusPagePort
        )
    }
}

final class DeviceWorkspaceModel: Model, @unchecked Sendable {
    static let schema = "device_workspaces"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "device_id")
    var deviceID: String

    @Field(key: "workspace_id")
    var workspaceID: String

    @Field(key: "name")
    var name: String

    @Field(key: "root_path")
    var rootPath: String

    init() {}

    init(deviceID: String, workspace: WorkspaceDefinition) {
        self.deviceID = deviceID
        self.workspaceID = workspace.id
        self.name = workspace.name
        self.rootPath = workspace.rootPath
    }

    func toWorkspace() -> WorkspaceDefinition {
        WorkspaceDefinition(id: workspaceID, name: name, rootPath: rootPath)
    }
}

final class TaskModel: Model, @unchecked Sendable {
    static let schema = "tasks"

    @ID(custom: "task_id", generatedBy: .user)
    var id: String?

    @Field(key: "title")
    var title: String

    @Field(key: "kind")
    var kindRaw: String

    @Field(key: "workspace_id")
    var workspaceID: String

    @OptionalField(key: "relative_path")
    var relativePath: String?

    @Field(key: "priority")
    var priorityRaw: String

    @Field(key: "status")
    var statusRaw: String

    @Field(key: "payload_json")
    var payloadJSON: String

    @OptionalField(key: "preferred_device_id")
    var preferredDeviceID: String?

    @OptionalField(key: "assigned_device_id")
    var assignedDeviceID: String?

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    @OptionalField(key: "started_at")
    var startedAt: Date?

    @OptionalField(key: "finished_at")
    var finishedAt: Date?

    @OptionalField(key: "stop_requested_at")
    var stopRequestedAt: Date?

    @OptionalField(key: "exit_code")
    var exitCode: Int?

    @OptionalField(key: "summary")
    var summary: String?

    init() {}

    init(taskID: String, request: CreateTaskRequest, now: Date) throws {
        self.id = taskID
        self.title = request.title
        self.kindRaw = request.kind.rawValue
        self.workspaceID = request.workspaceID
        self.relativePath = request.relativePath
        self.priorityRaw = request.priority.rawValue
        self.statusRaw = TaskStatus.queued.rawValue
        self.payloadJSON = try String(decoding: OrchardJSON.encoder.encode(request.payload), as: UTF8.self)
        self.preferredDeviceID = request.preferredDeviceID
        self.assignedDeviceID = nil
        self.createdAt = now
        self.updatedAt = now
    }

    var taskID: String {
        id ?? ""
    }

    var kind: TaskKind {
        get { TaskKind(rawValue: kindRaw) ?? .shell }
        set { kindRaw = newValue.rawValue }
    }

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .normal }
        set { priorityRaw = newValue.rawValue }
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    var payload: TaskPayload {
        get { (try? OrchardJSON.decoder.decode(TaskPayload.self, from: Data(payloadJSON.utf8))) ?? .shell(ShellTaskPayload(command: "invalid payload")) }
        set { payloadJSON = (try? String(decoding: OrchardJSON.encoder.encode(newValue), as: UTF8.self)) ?? "{}" }
    }

    func toRecord() -> TaskRecord {
        TaskRecord(
            id: taskID,
            title: title,
            kind: kind,
            workspaceID: workspaceID,
            relativePath: relativePath,
            priority: priority,
            status: status,
            payload: payload,
            preferredDeviceID: preferredDeviceID,
            assignedDeviceID: assignedDeviceID,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            stopRequestedAt: stopRequestedAt,
            exitCode: exitCode,
            summary: summary
        )
    }
}

final class TaskLogModel: Model, @unchecked Sendable {
    static let schema = "task_logs"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "task_id")
    var taskID: String

    @Field(key: "device_id")
    var deviceID: String

    @Field(key: "created_at")
    var createdAt: Date

    @OptionalField(key: "sequence")
    var sequence: Int?

    @Field(key: "line")
    var line: String

    init() {}

    init(taskID: String, deviceID: String, createdAt: Date, sequence: Int?, line: String) {
        self.taskID = taskID
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.sequence = sequence
        self.line = line
    }

    func toEntry() -> TaskLogEntry {
        TaskLogEntry(
            id: id?.uuidString.lowercased() ?? UUID().uuidString.lowercased(),
            taskID: taskID,
            deviceID: deviceID,
            createdAt: createdAt,
            line: line
        )
    }
}

final class ManagedRunModel: Model, @unchecked Sendable {
    static let schema = "managed_runs"

    @ID(custom: "run_id", generatedBy: .user)
    var id: String?

    @OptionalField(key: "task_id")
    var taskID: String?

    @OptionalField(key: "device_id")
    var deviceID: String?

    @Field(key: "title")
    var title: String

    @Field(key: "driver")
    var driverRaw: String

    @Field(key: "workspace_id")
    var workspaceID: String

    @OptionalField(key: "relative_path")
    var relativePath: String?

    @Field(key: "prompt")
    var prompt: String

    @OptionalField(key: "cwd")
    var cwd: String?

    @Field(key: "status")
    var statusRaw: String

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "updated_at")
    var updatedAt: Date

    @OptionalField(key: "started_at")
    var startedAt: Date?

    @OptionalField(key: "ended_at")
    var endedAt: Date?

    @OptionalField(key: "exit_code")
    var exitCode: Int?

    @OptionalField(key: "summary")
    var summary: String?

    @OptionalField(key: "pid")
    var pid: Int?

    @OptionalField(key: "last_heartbeat_at")
    var lastHeartbeatAt: Date?

    @OptionalField(key: "codex_session_id")
    var codexSessionID: String?

    @OptionalField(key: "last_user_prompt")
    var lastUserPrompt: String?

    @OptionalField(key: "last_assistant_preview")
    var lastAssistantPreview: String?

    init() {}

    init(runID: String, request: CreateManagedRunRequest, taskID: String?, now: Date) {
        self.id = runID
        self.taskID = taskID
        self.deviceID = nil
        self.title = request.title
        self.driverRaw = request.driver.rawValue
        self.workspaceID = request.workspaceID
        self.relativePath = request.relativePath
        self.prompt = request.prompt
        self.cwd = nil
        self.statusRaw = ManagedRunStatus.queued.rawValue
        self.createdAt = now
        self.updatedAt = now
        self.startedAt = nil
        self.endedAt = nil
        self.exitCode = nil
        self.summary = nil
        self.pid = nil
        self.lastHeartbeatAt = nil
        self.codexSessionID = nil
        self.lastUserPrompt = request.prompt
        self.lastAssistantPreview = nil
    }

    var runID: String {
        id ?? ""
    }

    var driver: ManagedRunDriver {
        get { ManagedRunDriver(rawValue: driverRaw) ?? .codexCLI }
        set { driverRaw = newValue.rawValue }
    }

    var status: ManagedRunStatus {
        get { ManagedRunStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    func toSummary(deviceName: String?, preferredDeviceID: String? = nil) -> ManagedRunSummary {
        ManagedRunSummary(
            id: runID,
            taskID: taskID,
            deviceID: deviceID,
            preferredDeviceID: preferredDeviceID,
            deviceName: deviceName,
            title: title,
            driver: driver,
            workspaceID: workspaceID,
            relativePath: relativePath,
            cwd: cwd ?? "",
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: exitCode,
            summary: summary,
            pid: pid,
            lastHeartbeatAt: lastHeartbeatAt,
            codexSessionID: codexSessionID,
            lastUserPrompt: lastUserPrompt,
            lastAssistantPreview: lastAssistantPreview
        )
    }
}

final class ManagedRunEventModel: Model, @unchecked Sendable {
    static let schema = "managed_run_events"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "run_id")
    var runID: String

    @Field(key: "kind")
    var kindRaw: String

    @Field(key: "created_at")
    var createdAt: Date

    @Field(key: "title")
    var title: String

    @OptionalField(key: "message")
    var message: String?

    init() {}

    init(runID: String, kind: ManagedRunEventKind, createdAt: Date, title: String, message: String? = nil) {
        self.runID = runID
        self.kindRaw = kind.rawValue
        self.createdAt = createdAt
        self.title = title
        self.message = message
    }

    var kind: ManagedRunEventKind {
        get { ManagedRunEventKind(rawValue: kindRaw) ?? .finished }
        set { kindRaw = newValue.rawValue }
    }

    func toRecord() -> ManagedRunEvent {
        ManagedRunEvent(
            id: id?.uuidString.lowercased() ?? UUID().uuidString.lowercased(),
            runID: runID,
            kind: kind,
            createdAt: createdAt,
            title: title,
            message: message
        )
    }
}

final class ManagedRunLogModel: Model, @unchecked Sendable {
    static let schema = "managed_run_logs"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "run_id")
    var runID: String

    @Field(key: "device_id")
    var deviceID: String

    @Field(key: "created_at")
    var createdAt: Date

    @OptionalField(key: "sequence")
    var sequence: Int?

    @Field(key: "line")
    var line: String

    init() {}

    init(runID: String, deviceID: String, createdAt: Date, sequence: Int?, line: String) {
        self.runID = runID
        self.deviceID = deviceID
        self.createdAt = createdAt
        self.sequence = sequence
        self.line = line
    }

    func toRecord() -> ManagedRunLogEntry {
        ManagedRunLogEntry(
            id: id?.uuidString.lowercased() ?? UUID().uuidString.lowercased(),
            runID: runID,
            deviceID: deviceID,
            createdAt: createdAt,
            line: line
        )
    }
}
