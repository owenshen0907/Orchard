import Fluent
import Foundation
import OrchardCore
import Vapor

struct ManagedRunInteractiveTarget: Sendable {
    let deviceID: String
    let sessionID: String
}

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
            throw Abort(.serviceUnavailable, reason: "数据库当前不可用。")
        }
        return database
    }

    func validateEnrollment(token: String) throws {
        guard token == enrollmentToken else {
            throw Abort(.unauthorized, reason: "注册令牌无效。")
        }
    }

    func dashboardSnapshot() async throws -> DashboardSnapshot {
        async let devices = listDevices()
        async let tasks = listTasks()
        async let managedRuns = listManagedRuns(limit: 200)
        return try await DashboardSnapshot(devices: devices, tasks: tasks, managedRuns: managedRuns)
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
            throw Abort(.notFound, reason: "未找到任务。")
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

    func listManagedRuns(
        deviceID: String? = nil,
        limit: Int = 50,
        statuses: [ManagedRunStatus] = []
    ) async throws -> [ManagedRunSummary] {
        let db = try database()
        var query = ManagedRunModel.query(on: db)
            .sort(\.$updatedAt, .descending)
            .limit(min(max(limit, 1), 200))

        if let deviceID, !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            query = query.filter(\.$deviceID == deviceID)
        }
        if !statuses.isEmpty {
            query = query.filter(\.$statusRaw ~~ statuses.map(\.rawValue))
        }

        let runs = try await query.all()
        let deviceNames = try await loadDeviceNames(on: db)
        let preferredDeviceIDs = try await loadPreferredDeviceIDs(taskIDs: runs.compactMap(\.taskID), on: db)
        return runs.map { run in
            run.toSummary(
                deviceName: run.deviceID.flatMap { deviceNames[$0] },
                preferredDeviceID: run.taskID.flatMap { preferredDeviceIDs[$0] }
            )
        }
    }

    func fetchManagedRunDetail(runID: String) async throws -> ManagedRunDetail {
        let db = try database()
        let run = try await requireManagedRunModel(runID: runID, on: db)
        return try await makeManagedRunDetail(run: run, on: db)
    }

    func createManagedRun(_ request: CreateManagedRunRequest) async throws -> ManagedRunSummary {
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Run 标题不能为空。")
        }
        guard !request.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "工作区 ID 不能为空。")
        }
        guard !request.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Prompt 不能为空。")
        }
        guard request.driver == .codexCLI else {
            throw Abort(.badRequest, reason: "当前只支持 codexCLI driver。")
        }

        let db = try database()
        let now = Date()
        let runID = UUID().uuidString.lowercased()
        let taskID = UUID().uuidString.lowercased()
        let taskRequest = CreateTaskRequest(
            title: request.title,
            kind: .codex,
            workspaceID: request.workspaceID,
            relativePath: request.relativePath,
            preferredDeviceID: request.preferredDeviceID,
            payload: .codex(CodexTaskPayload(prompt: request.prompt))
        )

        try await db.transaction { transaction in
            let task = try TaskModel(taskID: taskID, request: taskRequest, now: now)
            try await task.create(on: transaction)

            let run = ManagedRunModel(runID: runID, request: request, taskID: taskID, now: now)
            try await run.create(on: transaction)
            try await ManagedRunEventModel(
                runID: runID,
                kind: .runCreated,
                createdAt: now,
                title: "Run 已创建",
                message: "已进入调度队列，等待 Agent 接手。"
            ).create(on: transaction)
        }

        let run = try await requireManagedRunModel(runID: runID, on: db)
        let deviceNames = try await loadDeviceNames(on: db)
        return run.toSummary(
            deviceName: run.deviceID.flatMap { deviceNames[$0] },
            preferredDeviceID: request.preferredDeviceID
        )
    }

    func continueManagedRun(runID: String, prompt: String) async throws -> ManagedRunDetail {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "继续追问内容不能为空。")
        }

        let db = try database()
        let run = try await requireManagedRunModel(runID: runID, on: db)
        guard !run.status.isTerminal else {
            throw Abort(.conflict, reason: "当前托管 run 已结束，不能继续。")
        }
        throw Abort(.conflict, reason: "请通过代理链路继续该 run。")
    }

    func interruptManagedRun(runID: String) async throws -> ManagedRunDetail {
        let db = try database()
        let run = try await requireManagedRunModel(runID: runID, on: db)
        guard !run.status.isTerminal else {
            throw Abort(.conflict, reason: "当前托管 run 已结束，不能中断。")
        }
        throw Abort(.conflict, reason: "请通过代理链路中断该 run。")
    }

    func interactiveTargetForManagedRun(runID: String) async throws -> ManagedRunInteractiveTarget {
        let db = try database()
        let run = try await requireManagedRunModel(runID: runID, on: db)

        guard !run.status.isTerminal else {
            throw Abort(.conflict, reason: "当前托管 run 已结束，不能再交互。")
        }
        guard let deviceID = run.deviceID, !deviceID.isEmpty else {
            throw Abort(.conflict, reason: "当前托管 run 还没有分配设备。")
        }
        guard let sessionID = run.codexSessionID, !sessionID.isEmpty else {
            throw Abort(.conflict, reason: "当前托管 run 还没有可交互的 Codex 会话。")
        }

        return ManagedRunInteractiveTarget(deviceID: deviceID, sessionID: sessionID)
    }

    func recordManagedRunContinuation(
        runID: String,
        prompt: String,
        sessionDetail: CodexSessionDetail
    ) async throws -> ManagedRunDetail {
        let db = try database()
        let run = try await requireManagedRunModel(runID: runID, on: db)
        let now = Date()
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        run.codexSessionID = sessionDetail.session.id
        run.lastUserPrompt = sessionDetail.session.lastUserMessage ?? trimmedPrompt
        run.lastAssistantPreview = sessionDetail.session.lastAssistantMessage ?? run.lastAssistantPreview
        run.summary = sessionDetail.session.lastAssistantMessage ?? run.summary
        run.status = managedStatus(for: sessionDetail)
        run.updatedAt = now
        run.endedAt = run.status.isTerminal ? now : nil
        try await run.update(on: db)

        try await ManagedRunEventModel(
            runID: runID,
            kind: .continued,
            createdAt: now,
            title: "Run 已继续",
            message: trimmedPrompt
        ).create(on: db)

        return try await makeManagedRunDetail(run: run, on: db)
    }

    func recordManagedRunInterruption(
        runID: String,
        sessionDetail: CodexSessionDetail
    ) async throws -> ManagedRunDetail {
        let db = try database()
        let run = try await requireManagedRunModel(runID: runID, on: db)
        let now = Date()

        run.codexSessionID = sessionDetail.session.id
        run.lastUserPrompt = sessionDetail.session.lastUserMessage ?? run.lastUserPrompt
        run.lastAssistantPreview = sessionDetail.session.lastAssistantMessage ?? run.lastAssistantPreview
        run.summary = sessionDetail.session.lastAssistantMessage ?? run.summary
        run.status = managedStatus(for: sessionDetail)
        run.updatedAt = now
        if run.status.isTerminal {
            run.endedAt = now
        }
        try await run.update(on: db)

        try await ManagedRunEventModel(
            runID: runID,
            kind: .interruptRequested,
            createdAt: now,
            title: run.status == .interrupted ? "Run 已中断" : "Run 已请求中断",
            message: run.summary
        ).create(on: db)

        return try await makeManagedRunDetail(run: run, on: db)
    }

    func stopManagedRun(runID: String, reason: String?) async throws -> ManagedRunSummary {
        let db = try database()
        let run = try await requireManagedRunModel(runID: runID, on: db)
        guard let taskID = run.taskID else {
            throw Abort(.conflict, reason: "当前 run 没有关联可停止的底层任务。")
        }
        _ = try await requestStop(taskID: taskID, reason: reason)
        let refreshed = try await requireManagedRunModel(runID: runID, on: db)
        let deviceNames = try await loadDeviceNames(on: db)
        return refreshed.toSummary(
            deviceName: refreshed.deviceID.flatMap { deviceNames[$0] },
            preferredDeviceID: try await preferredDeviceID(for: refreshed, on: db)
        )
    }

    func retryManagedRun(runID: String, prompt: String?) async throws -> ManagedRunSummary {
        let db = try database()
        let run = try await requireManagedRunModel(runID: runID, on: db)
        let preferredDeviceID = try await preferredDeviceID(for: run, on: db)
        let retryPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)

        return try await createManagedRun(CreateManagedRunRequest(
            title: run.title,
            workspaceID: run.workspaceID,
            relativePath: run.relativePath,
            preferredDeviceID: preferredDeviceID,
            driver: run.driver,
            prompt: (retryPrompt?.isEmpty == false ? retryPrompt! : run.prompt)
        ))
    }

    func registerAgent(_ request: AgentRegistrationRequest) async throws -> DeviceRecord {
        try validateEnrollment(token: request.enrollmentToken)
        let db = try database()

        let now = Date()
        let sanitizedParallelism = min(max(request.maxParallelTasks, 1), 3)
        let workspaces = Dictionary(uniqueKeysWithValues: request.workspaces.map { ($0.id, $0) }).values.sorted { $0.id < $1.id }
        let localStatusPageHost = {
            let trimmed = request.localStatusPageHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }()

        try await db.transaction { transaction in
            if let device = try await DeviceModel.find(request.deviceID, on: transaction) {
                device.name = request.name
                device.hostName = request.hostName
                device.platform = request.platform
                device.capabilities = request.capabilities
                device.maxParallelTasks = sanitizedParallelism
                device.localStatusPageHost = localStatusPageHost
                device.localStatusPagePort = request.localStatusPagePort
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
                    lastSeenAt: now,
                    localStatusPageHost: localStatusPageHost,
                    localStatusPagePort: request.localStatusPagePort
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
            throw Abort(.notFound, reason: "设备尚未注册。")
        }

        device.lastSeenAt = Date()
        if let metrics {
            device.metrics = metrics
        }
        try await device.update(on: db)
        try await touchManagedRuns(deviceID: deviceID, seenAt: device.lastSeenAt, on: db)
        return try await requireDevice(deviceID: deviceID)
    }

    func createTask(_ request: CreateTaskRequest) async throws -> TaskRecord {
        guard request.kind == request.payload.kind else {
            throw Abort(.badRequest, reason: "任务类型与载荷不匹配。")
        }
        guard !request.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "任务标题不能为空。")
        }
        guard !request.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "工作区 ID 不能为空。")
        }

        let task = try TaskModel(taskID: UUID().uuidString.lowercased(), request: request, now: Date())
        try await task.create(on: database())
        return task.toRecord()
    }

    func assignTask(taskID: String, to deviceID: String) async throws -> TaskRecord {
        let db = try database()
        guard let task = try await TaskModel.find(taskID, on: db) else {
            throw Abort(.notFound, reason: "未找到任务。")
        }
        guard task.status == .queued else {
            throw Abort(.conflict, reason: "任务已经不在排队状态。")
        }
        let now = Date()
        task.status = .running
        task.assignedDeviceID = deviceID
        task.startedAt = task.startedAt ?? now
        task.updatedAt = now
        try await task.update(on: db)
        try await syncManagedRun(task: task, on: db)
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
        try await syncManagedRun(task: task, on: db)
    }

    func requestStop(taskID: String, reason: String?) async throws -> TaskRecord {
        let db = try database()
        guard let task = try await TaskModel.find(taskID, on: db) else {
            throw Abort(.notFound, reason: "未找到任务。")
        }

        switch task.status {
        case .queued:
            let now = Date()
            task.status = .cancelled
            task.summary = reason ?? "任务在执行前已取消。"
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
        try await syncManagedRun(task: task, on: db)
        return task.toRecord()
    }

    func appendLogs(deviceID: String, payload: AgentLogBatchPayload) async throws {
        let db = try database()
        guard let task = try await TaskModel.find(payload.taskID, on: db) else {
            throw Abort(.notFound, reason: "未找到任务。")
        }
        guard task.assignedDeviceID == deviceID else {
            throw Abort(.forbidden, reason: "当前任务未分配给该设备。")
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
        try await appendManagedRunLogsIfNeeded(taskID: payload.taskID, deviceID: deviceID, lines: payload.lines, on: db)
    }

    func applyTaskUpdate(deviceID: String, payload: AgentTaskUpdatePayload) async throws -> TaskRecord {
        let db = try database()
        guard let task = try await TaskModel.find(payload.taskID, on: db) else {
            throw Abort(.notFound, reason: "未找到任务。")
        }
        guard task.assignedDeviceID == deviceID else {
            throw Abort(.forbidden, reason: "当前任务未分配给该设备。")
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
        try await syncManagedRun(task: task, on: db, payload: payload)
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
            throw Abort(.notFound, reason: "未找到设备。")
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

    private func requireManagedRunModel(runID: String, on db: any Database) async throws -> ManagedRunModel {
        guard let run = try await ManagedRunModel.find(runID, on: db) else {
            throw Abort(.notFound, reason: "未找到托管 run。")
        }
        return run
    }

    private func loadDeviceNames(on db: any Database) async throws -> [String: String] {
        try await DeviceModel.query(on: db)
            .all()
            .reduce(into: [:]) { result, device in
                result[device.deviceID] = device.name
            }
    }

    private func loadPreferredDeviceIDs(taskIDs: [String], on db: any Database) async throws -> [String: String] {
        let uniqueTaskIDs = Array(Set(taskIDs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
        guard !uniqueTaskIDs.isEmpty else {
            return [:]
        }

        return try await TaskModel.query(on: db)
            .filter(\.$id ~~ uniqueTaskIDs)
            .all()
            .reduce(into: [:]) { result, task in
                if let preferredDeviceID = task.preferredDeviceID {
                    result[task.taskID] = preferredDeviceID
                }
            }
    }

    private func preferredDeviceID(for run: ManagedRunModel, on db: any Database) async throws -> String? {
        guard let taskID = run.taskID, let task = try await TaskModel.find(taskID, on: db) else {
            return nil
        }
        return task.preferredDeviceID
    }

    private func makeManagedRunDetail(run: ManagedRunModel, on db: any Database) async throws -> ManagedRunDetail {
        let deviceNames = try await loadDeviceNames(on: db)
        let preferredDeviceID = try await preferredDeviceID(for: run, on: db)
        let events = try await ManagedRunEventModel.query(on: db)
            .filter(\.$runID == run.runID)
            .sort(\.$createdAt, .ascending)
            .all()
            .map { $0.toRecord() }
        let logs = try await ManagedRunLogModel.query(on: db)
            .filter(\.$runID == run.runID)
            .all()
            .sorted { lhs, rhs in
                let lhsSequence = lhs.sequence ?? Int.max
                let rhsSequence = rhs.sequence ?? Int.max
                if lhsSequence != rhsSequence {
                    return lhsSequence < rhsSequence
                }
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
            }
            .map { $0.toRecord() }
        return ManagedRunDetail(
            run: run.toSummary(
                deviceName: run.deviceID.flatMap { deviceNames[$0] },
                preferredDeviceID: preferredDeviceID
            ),
            events: events,
            logs: logs
        )
    }

    private func touchManagedRuns(deviceID: String, seenAt: Date, on db: any Database) async throws {
        let runs = try await ManagedRunModel.query(on: db)
            .filter(\.$deviceID == deviceID)
            .all()

        for run in runs where !run.status.isTerminal {
            run.lastHeartbeatAt = seenAt
            if run.updatedAt < seenAt {
                run.updatedAt = seenAt
            }
            try await run.update(on: db)
        }
    }

    private func appendManagedRunLogsIfNeeded(
        taskID: String,
        deviceID: String,
        lines: [String],
        on db: any Database
    ) async throws {
        guard
            let run = try await ManagedRunModel.query(on: db)
                .filter(\.$taskID == taskID)
                .first()
        else {
            return
        }

        let existingCount = try await ManagedRunLogModel.query(on: db)
            .filter(\.$runID == run.runID)
            .count()
        let now = Date()

        for (offset, line) in lines.enumerated() {
            try await ManagedRunLogModel(
                runID: run.runID,
                deviceID: deviceID,
                createdAt: now,
                sequence: existingCount + offset,
                line: String(line.prefix(4096))
            ).create(on: db)
        }

        if !run.status.isTerminal {
            run.updatedAt = now
            try await run.update(on: db)
        }
    }

    private func syncManagedRun(
        task: TaskModel,
        on db: any Database,
        payload: AgentTaskUpdatePayload? = nil
    ) async throws {
        guard let run = try await ManagedRunModel.query(on: db)
            .filter(\.$taskID == task.taskID)
            .first()
        else {
            return
        }

        let previousStatus = run.status
        let now = Date()

        if task.status == .queued {
            run.deviceID = nil
            run.cwd = nil
            run.startedAt = nil
        } else {
            run.deviceID = task.assignedDeviceID
            run.startedAt = task.startedAt ?? run.startedAt
            if run.cwd == nil, let deviceID = task.assignedDeviceID {
                run.cwd = try await resolveManagedRunCWD(
                    deviceID: deviceID,
                    workspaceID: run.workspaceID,
                    relativePath: run.relativePath,
                    on: db
                )
            }
        }

        if let pid = payload?.pid {
            run.pid = pid
        }
        if let sessionID = payload?.codexSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !sessionID.isEmpty {
            run.codexSessionID = sessionID
        }
        if let lastUserPrompt = payload?.lastUserPrompt?.trimmedOrNil {
            run.lastUserPrompt = lastUserPrompt
        }
        if let lastAssistantPreview = payload?.lastAssistantPreview?.trimmedOrNil {
            run.lastAssistantPreview = lastAssistantPreview
        }

        if let managedRunStatus = payload?.managedRunStatus {
            run.status = managedRunStatus
        } else if task.status == .running, run.driver == .codexCLI {
            if run.codexSessionID == nil {
                run.status = .launching
            } else if previousStatus == .waitingInput || previousStatus == .interrupting {
                run.status = previousStatus
            } else {
                run.status = .running
            }
        } else {
            run.status = managedStatus(for: task.status)
        }
        run.exitCode = task.exitCode
        run.summary = task.summary
        run.updatedAt = task.updatedAt
        if run.lastUserPrompt == nil {
            run.lastUserPrompt = run.prompt
        }
        if let finishedAt = task.finishedAt, task.status.isTerminal {
            run.endedAt = finishedAt
        } else if run.status.isTerminal {
            run.endedAt = now
        } else {
            run.endedAt = nil
        }

        try await run.update(on: db)

        guard previousStatus != run.status else {
            return
        }

        let event = makeStatusEvent(for: run, previousStatus: previousStatus, at: now)
        try await event.create(on: db)
    }

    private func managedStatus(for session: CodexSessionDetail) -> ManagedRunStatus {
        switch session.session.state {
        case .running:
            if session.session.lastTurnStatus == "inProgress" {
                return .running
            }
            return .running
        case .idle:
            return .waitingInput
        case .completed:
            return .succeeded
        case .failed:
            return .failed
        case .interrupted:
            return .interrupted
        case .unknown:
            return .running
        }
    }

    private func resolveManagedRunCWD(
        deviceID: String,
        workspaceID: String,
        relativePath: String?,
        on db: any Database
    ) async throws -> String? {
        guard let workspace = try await DeviceWorkspaceModel.query(on: db)
            .filter(\.$deviceID == deviceID)
            .filter(\.$workspaceID == workspaceID)
            .first()
        else {
            return nil
        }

        guard let relativePath, !relativePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return workspace.rootPath
        }

        do {
            return try OrchardWorkspacePath.resolve(rootPath: workspace.rootPath, relativePath: relativePath).path
        } catch {
            return workspace.rootPath
        }
    }

    private func managedStatus(for taskStatus: TaskStatus) -> ManagedRunStatus {
        switch taskStatus {
        case .queued:
            return .queued
        case .running:
            return .running
        case .succeeded:
            return .succeeded
        case .failed:
            return .failed
        case .stopRequested:
            return .stopRequested
        case .cancelled:
            return .cancelled
        }
    }

    private func makeStatusEvent(
        for run: ManagedRunModel,
        previousStatus: ManagedRunStatus,
        at timestamp: Date
    ) -> ManagedRunEventModel {
        let title: String
        let kind: ManagedRunEventKind

        switch run.status {
        case .running:
            title = previousStatus == .queued ? "Run 已开始" : "Run 恢复运行"
            kind = .started
        case .stopRequested:
            title = "Run 已请求停止"
            kind = .stopRequested
        case .succeeded:
            title = "Run 已完成"
            kind = .finished
        case .failed:
            title = "Run 执行失败"
            kind = .finished
        case .cancelled:
            title = "Run 已取消"
            kind = .finished
        case .interrupted:
            title = "Run 已中断"
            kind = .finished
        case .waitingInput:
            title = "Run 等待输入"
            kind = .waitingInput
        case .interrupting:
            title = "Run 正在中断"
            kind = .interruptRequested
        case .launching:
            title = "Run 正在启动"
            kind = .launching
        case .queued:
            title = "Run 已重新排队"
            kind = .runCreated
        }

        return ManagedRunEventModel(
            runID: run.runID,
            kind: kind,
            createdAt: timestamp,
            title: title,
            message: run.summary
        )
    }
}

private extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
