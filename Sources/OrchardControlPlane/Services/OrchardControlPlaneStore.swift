import Fluent
import Foundation
import OrchardCore
import Vapor

final class OrchardControlPlaneStore: @unchecked Sendable {
    private let app: Application
    private let onlineThreshold: TimeInterval
    private let enrollmentToken: String

    init(app: Application, enrollmentToken: String, onlineThreshold: TimeInterval = 30) {
        self.app = app
        self.enrollmentToken = enrollmentToken
        self.onlineThreshold = onlineThreshold
    }

    private func database() throws -> any Database {
        guard let database = app.databases.database(
            nil,
            logger: app.logger,
            on: app.eventLoopGroup.any(),
            history: nil,
            pageSizeLimit: app.fluent.pagination.pageSizeLimit
        ) else {
            throw Abort(.serviceUnavailable, reason: "Database is unavailable.")
        }
        return database
    }

    func validateEnrollment(token: String) throws {
        guard token == enrollmentToken else {
            throw Abort(.unauthorized, reason: "Invalid enrollment token.")
        }
    }

    func dashboardSnapshot() async throws -> DashboardSnapshot {
        async let devices = listDevices()
        async let tasks = listTasks()
        return try await DashboardSnapshot(devices: devices, tasks: tasks)
    }

    func listDevices() async throws -> [DeviceRecord] {
        let db = try database()
        let deviceModels = try await DeviceModel.query(on: db).all()
        let workspaceModels = try await DeviceWorkspaceModel.query(on: db).all()
        let activeTasks = try await TaskModel.query(on: db)
            .filter(\.$statusRaw ~~ [TaskStatus.running.rawValue, TaskStatus.stopRequested.rawValue])
            .all()

        let workspacesByDevice = Dictionary(grouping: workspaceModels, by: \.deviceID)
        let runningCounts = Dictionary(activeTasks.compactMap { task -> (String, Int)? in
            guard let deviceID = task.assignedDeviceID else { return nil }
            return (deviceID, 1)
        }, uniquingKeysWith: +)

        return deviceModels
            .map { model in
                model.toRecord(
                    workspaces: (workspacesByDevice[model.deviceID] ?? []).map { $0.toWorkspace() },
                    runningTaskCount: runningCounts[model.deviceID] ?? 0,
                    onlineThreshold: onlineThreshold
                )
            }
            .sorted { lhs, rhs in
                if lhs.status != rhs.status {
                    return lhs.status == .online
                }
                if lhs.lastSeenAt != rhs.lastSeenAt {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return lhs.deviceID < rhs.deviceID
            }
    }

    func listTasks() async throws -> [TaskRecord] {
        let db = try database()
        return try await TaskModel.query(on: db)
            .sort(\.$updatedAt, .descending)
            .all()
            .map { $0.toRecord() }
    }

    func listQueuedTasks() async throws -> [TaskRecord] {
        let db = try database()
        let tasks = try await TaskModel.query(on: db)
            .filter(\.$statusRaw == TaskStatus.queued.rawValue)
            .all()
            .map { $0.toRecord() }
        return TaskDispatchPlanner.orderedQueuedTasks(tasks)
    }

    func fetchTaskDetail(taskID: String) async throws -> TaskDetail {
        let db = try database()
        guard let task = try await TaskModel.find(taskID, on: db) else {
            throw Abort(.notFound, reason: "Task not found.")
        }

        let logs = try await TaskLogModel.query(on: db)
            .filter(\.$taskID == taskID)
            .sort(\.$sequence, .descending)
            .sort(\.$createdAt, .descending)
            .limit(1000)
            .all()
            .map { $0.toEntry() }
            .reversed()

        return TaskDetail(task: task.toRecord(), logs: Array(logs))
    }

    func registerAgent(_ request: AgentRegistrationRequest) async throws -> DeviceRecord {
        try validateEnrollment(token: request.enrollmentToken)
        let db = try database()

        let now = Date()
        let sanitizedParallelism = min(max(request.maxParallelTasks, 1), 3)
        let workspaces = Dictionary(uniqueKeysWithValues: request.workspaces.map { ($0.id, $0) }).values.sorted { $0.id < $1.id }

        try await db.transaction { transaction in
            if let device = try await DeviceModel.find(request.deviceID, on: transaction) {
                device.name = request.name
                device.hostName = request.hostName
                device.platform = request.platform
                device.capabilities = request.capabilities
                device.maxParallelTasks = sanitizedParallelism
                device.lastSeenAt = now
                try await device.update(on: transaction)
            } else {
                let device = try DeviceModel(
                    deviceID: request.deviceID,
                    name: request.name,
                    hostName: request.hostName,
                    platform: request.platform,
                    capabilities: request.capabilities,
                    maxParallelTasks: sanitizedParallelism,
                    metrics: DeviceMetrics(),
                    registeredAt: now,
                    lastSeenAt: now
                )
                try await device.create(on: transaction)
            }

            try await DeviceWorkspaceModel.query(on: transaction)
                .filter(\.$deviceID == request.deviceID)
                .delete()

            for workspace in workspaces {
                try await DeviceWorkspaceModel(deviceID: request.deviceID, workspace: workspace).create(on: transaction)
            }
        }

        return try await requireDevice(deviceID: request.deviceID)
    }

    func markDeviceSeen(deviceID: String, metrics: DeviceMetrics?) async throws -> DeviceRecord {
        let db = try database()
        guard let device = try await DeviceModel.find(deviceID, on: db) else {
            throw Abort(.notFound, reason: "Device not registered.")
        }

        device.lastSeenAt = Date()
        if let metrics {
            device.metrics = metrics
        }
        try await device.update(on: db)
        return try await requireDevice(deviceID: deviceID)
    }

    func createTask(_ request: CreateTaskRequest) async throws -> TaskRecord {
        guard request.kind == request.payload.kind else {
            throw Abort(.badRequest, reason: "Task kind does not match payload.")
        }
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Task title is required.")
        }
        guard !request.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "workspaceID is required.")
        }

        let task = try TaskModel(taskID: UUID().uuidString.lowercased(), request: request, now: Date())
        try await task.create(on: database())
        return task.toRecord()
    }

    func assignTask(taskID: String, to deviceID: String) async throws -> TaskRecord {
        let db = try database()
        guard let task = try await TaskModel.find(taskID, on: db) else {
            throw Abort(.notFound, reason: "Task not found.")
        }
        guard task.status == .queued else {
            throw Abort(.conflict, reason: "Task is no longer queued.")
        }
        let now = Date()
        task.status = .running
        task.assignedDeviceID = deviceID
        task.startedAt = task.startedAt ?? now
        task.updatedAt = now
        try await task.update(on: db)
        return task.toRecord()
    }

    func revertAssignment(taskID: String) async throws {
        let db = try database()
        guard let task = try await TaskModel.find(taskID, on: db), task.status == .running else {
            return
        }
        task.status = .queued
        task.assignedDeviceID = nil
        task.startedAt = nil
        task.updatedAt = Date()
        try await task.update(on: db)
    }

    func requestStop(taskID: String, reason: String?) async throws -> TaskRecord {
        let db = try database()
        guard let task = try await TaskModel.find(taskID, on: db) else {
            throw Abort(.notFound, reason: "Task not found.")
        }

        switch task.status {
        case .queued:
            let now = Date()
            task.status = .cancelled
            task.summary = reason ?? "Cancelled before execution."
            task.finishedAt = now
            task.updatedAt = now
        case .running:
            let now = Date()
            task.status = .stopRequested
            task.stopRequestedAt = now
            task.updatedAt = now
            if let reason, !reason.isEmpty {
                task.summary = reason
            }
        case .stopRequested, .succeeded, .failed, .cancelled:
            break
        }

        try await task.update(on: db)
        return task.toRecord()
    }

    func appendLogs(deviceID: String, payload: AgentLogBatchPayload) async throws {
        let db = try database()
        guard let task = try await TaskModel.find(payload.taskID, on: db) else {
            throw Abort(.notFound, reason: "Task not found.")
        }
        guard task.assignedDeviceID == deviceID else {
            throw Abort(.forbidden, reason: "Task is not assigned to this device.")
        }

        let existingCount = try await TaskLogModel.query(on: db)
            .filter(\.$taskID == payload.taskID)
            .count()

        for (offset, line) in payload.lines.enumerated() {
            let log = TaskLogModel(
                taskID: payload.taskID,
                deviceID: deviceID,
                createdAt: Date(),
                sequence: existingCount + offset,
                line: String(line.prefix(4096))
            )
            try await log.create(on: db)
        }
    }

    func applyTaskUpdate(deviceID: String, payload: AgentTaskUpdatePayload) async throws -> TaskRecord {
        let db = try database()
        guard let task = try await TaskModel.find(payload.taskID, on: db) else {
            throw Abort(.notFound, reason: "Task not found.")
        }
        guard task.assignedDeviceID == deviceID else {
            throw Abort(.forbidden, reason: "Task is not assigned to this device.")
        }

        let now = Date()
        task.status = payload.status
        task.exitCode = payload.exitCode
        task.summary = payload.summary ?? task.summary
        task.updatedAt = now
        if payload.status.isTerminal {
            task.finishedAt = now
            if payload.status == .cancelled, task.stopRequestedAt == nil {
                task.stopRequestedAt = now
            }
        }
        try await task.update(on: db)
        return task.toRecord()
    }

    func pendingStopCommands(deviceID: String) async throws -> [TaskStopCommand] {
        let db = try database()
        return try await TaskModel.query(on: db)
            .filter(\.$assignedDeviceID == deviceID)
            .filter(\.$statusRaw == TaskStatus.stopRequested.rawValue)
            .all()
            .map { TaskStopCommand(taskID: $0.taskID, reason: $0.summary) }
    }

    func requireDevice(deviceID: String) async throws -> DeviceRecord {
        let db = try database()
        guard let device = try await DeviceModel.find(deviceID, on: db) else {
            throw Abort(.notFound, reason: "Device not found.")
        }
        let workspaces = try await DeviceWorkspaceModel.query(on: db)
            .filter(\.$deviceID == deviceID)
            .all()
            .map { $0.toWorkspace() }
        let runningTaskCount = try await TaskModel.query(on: db)
            .filter(\.$assignedDeviceID == deviceID)
            .filter(\.$statusRaw ~~ [TaskStatus.running.rawValue, TaskStatus.stopRequested.rawValue])
            .count()
        return device.toRecord(workspaces: workspaces, runningTaskCount: runningTaskCount, onlineThreshold: onlineThreshold)
    }
}
