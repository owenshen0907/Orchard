@preconcurrency import Fluent
@preconcurrency import FluentSQL
@preconcurrency import FluentSQLiteDriver
import Foundation
import NIOWebSocket
import OrchardCore
@preconcurrency import Vapor

public func makeOrchardControlPlaneApplication() async throws -> Application {
    try await makeOrchardControlPlaneApplication(environment: try Environment.detect())
}

public func makeOrchardControlPlaneApplication(environment: Environment) async throws -> Application {
    let app = try await Application.make(environment)
    let databaseURL = try OrchardControlPlanePaths.databaseURL()
    try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)

    app.http.server.configuration.hostname = Environment.get("ORCHARD_BIND") ?? "127.0.0.1"
    app.http.server.configuration.port = Int(Environment.get("ORCHARD_PORT") ?? "") ?? 8080

    app.databases.use(.sqlite(.file(databaseURL.path)), as: .sqlite)
    app.migrations.add(CreateDeviceTablesMigration())
    app.migrations.add(AddTaskLogSequenceMigration())
    app.migrations.add(CreateManagedRunTablesMigration())
    try await app.autoMigrate()
    guard let sqlDatabase = app.db as? any SQLDatabase else {
        throw NSError(domain: "OrchardControlPlane", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "当前数据库配置未提供 SQLDatabase。",
        ])
    }
    try await sqlDatabase.raw("PRAGMA journal_mode=WAL;").run()

    let enrollmentToken = Environment.get("ORCHARD_ENROLLMENT_TOKEN") ?? "orchard-dev-token"
    let accessControl = OrchardAccessControl(accessKey: Environment.get("ORCHARD_ACCESS_KEY"))
    let store = OrchardControlPlaneStore(app: app, enrollmentToken: enrollmentToken)
    let registry = AgentConnectionRegistry()
    let codexBroker = AgentCodexCommandBroker()
    let codexProxy = CodexSessionProxyService(store: store, registry: registry, broker: codexBroker)
    let projectContextBroker = AgentProjectContextCommandBroker()
    let projectContextProxy = ProjectContextProxyService(store: store, registry: registry, broker: projectContextBroker)
    let scheduler = TaskScheduler(store: store, registry: registry)

    configureRoutes(
        app: app,
        store: store,
        registry: registry,
        scheduler: scheduler,
        accessControl: accessControl,
        codexBroker: codexBroker,
        codexProxy: codexProxy,
        projectContextBroker: projectContextBroker,
        projectContextProxy: projectContextProxy
    )
    return app
}

private func configureRoutes(
    app: Application,
    store: OrchardControlPlaneStore,
    registry: AgentConnectionRegistry,
    scheduler: TaskScheduler,
    accessControl: OrchardAccessControl,
    codexBroker: AgentCodexCommandBroker,
    codexProxy: CodexSessionProxyService,
    projectContextBroker: AgentProjectContextCommandBroker,
    projectContextProxy: ProjectContextProxyService
) {
    app.get { req async throws -> Response in
        guard !accessControl.isEnabled || accessControl.isAuthorized(req) else {
            return OrchardUnlockPage.response()
        }
        do {
            let snapshot = try await store.dashboardSnapshot()
            let codexSessions = (try? await codexProxy.listSessions(limit: 20)) ?? []
            return OrchardLandingPage.response(
                snapshot: snapshot,
                codexSessions: codexSessions,
                showLogout: accessControl.isEnabled
            )
        } catch {
            req.logger.error("控制台快照加载失败：\(String(describing: error))")
            return OrchardLandingPage.response(
                snapshot: DashboardSnapshot(devices: [], tasks: [], managedRuns: []),
                codexSessions: [],
                showLogout: accessControl.isEnabled,
                errorMessage: "暂时无法加载实时数据，但服务仍可用。"
            )
        }
    }

    app.get("health") { _ in
        ["status": "ok", "service": "orchard-control-plane"]
    }

    app.post("unlock") { req async throws -> Response in
        guard accessControl.isEnabled else {
            return req.redirect(to: "/")
        }

        let unlockRequest = try req.content.decode(OrchardUnlockRequest.self)
        guard unlockRequest.accessKey == accessControl.accessKey else {
            return OrchardUnlockPage.response(status: .unauthorized, errorMessage: "访问密钥不正确。")
        }

        let response = req.redirect(to: "/")
        if let cookie = accessControl.makeUnlockCookie() {
            response.cookies[OrchardAccessControl.cookieName] = cookie
        }
        return response
    }

    app.post("logout") { req -> Response in
        let response = req.redirect(to: "/")
        response.cookies[OrchardAccessControl.cookieName] = OrchardAccessControl.makeExpiredCookie()
        return response
    }

    let protected = app.grouped(OrchardAccessKeyMiddleware(accessControl: accessControl))

    protected.get("api", "snapshot") { _ async throws in
        try await store.dashboardSnapshot()
    }

    protected.get("api", "devices") { _ async throws in
        try await store.listDevices()
    }

    protected.get("api", "tasks") { _ async throws in
        try await store.listTasks()
    }

    protected.get("api", "tasks", ":taskID") { req async throws in
        guard let taskID = req.parameters.get("taskID") else {
            throw Abort(.badRequest, reason: "缺少任务 ID。")
        }
        return try await store.fetchTaskDetail(taskID: taskID)
    }

    protected.get("api", "runs") { req async throws in
        let deviceID = req.query[String.self, at: "deviceID"]
        let limit = req.query[Int.self, at: "limit"] ?? 50
        let statuses = try parseManagedRunStatuses(req)
        return try await store.listManagedRuns(deviceID: deviceID, limit: limit, statuses: statuses)
    }

    protected.get("api", "runs", ":runID") { req async throws in
        guard let runID = req.parameters.get("runID") else {
            throw Abort(.badRequest, reason: "缺少 run ID。")
        }
        return try await store.fetchManagedRunDetail(runID: runID)
    }

    protected.get("api", "codex", "sessions") { req async throws in
        let deviceID = req.query[String.self, at: "deviceID"]
        let limit = req.query[Int.self, at: "limit"] ?? 20
        return try await codexProxy.listSessions(deviceID: deviceID, limit: limit)
    }

    protected.get("api", "devices", ":deviceID", "codex", "sessions", ":sessionID") { req async throws in
        guard let deviceID = req.parameters.get("deviceID"), let sessionID = req.parameters.get("sessionID") else {
            throw Abort(.badRequest, reason: "缺少设备 ID 或会话 ID。")
        }
        return try await codexProxy.fetchSessionDetail(deviceID: deviceID, sessionID: sessionID)
    }

    protected.post("api", "devices", ":deviceID", "codex", "sessions", ":sessionID", "continue") { req async throws in
        guard let deviceID = req.parameters.get("deviceID"), let sessionID = req.parameters.get("sessionID") else {
            throw Abort(.badRequest, reason: "缺少设备 ID 或会话 ID。")
        }
        let request = try req.content.decode(CodexSessionContinueRequest.self)
        return try await codexProxy.continueSession(deviceID: deviceID, sessionID: sessionID, prompt: request.prompt)
    }

    protected.post("api", "devices", ":deviceID", "codex", "sessions", ":sessionID", "interrupt") { req async throws in
        guard let deviceID = req.parameters.get("deviceID"), let sessionID = req.parameters.get("sessionID") else {
            throw Abort(.badRequest, reason: "缺少设备 ID 或会话 ID。")
        }
        _ = try req.content.decode(CodexSessionInterruptRequest.self)
        return try await codexProxy.interruptSession(deviceID: deviceID, sessionID: sessionID)
    }

    protected.get("api", "devices", ":deviceID", "workspaces", ":workspaceID", "project-context") { req async throws in
        guard
            let deviceID = req.parameters.get("deviceID"),
            let workspaceID = req.parameters.get("workspaceID")
        else {
            throw Abort(.badRequest, reason: "缺少设备 ID 或工作区 ID。")
        }
        return try await projectContextProxy.fetchSummary(deviceID: deviceID, workspaceID: workspaceID)
    }

    protected.get("api", "devices", ":deviceID", "workspaces", ":workspaceID", "project-context", "lookup") { req async throws in
        guard
            let deviceID = req.parameters.get("deviceID"),
            let workspaceID = req.parameters.get("workspaceID")
        else {
            throw Abort(.badRequest, reason: "缺少设备 ID 或工作区 ID。")
        }

        guard let rawSubject = req.query[String.self, at: "subject"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let subject = ProjectContextRemoteSubject(rawValue: rawSubject.lowercased()) else {
            throw Abort(.badRequest, reason: "缺少或无效的项目上下文查询 subject。")
        }

        let selector = req.query[String.self, at: "selector"]
        return try await projectContextProxy.lookup(
            deviceID: deviceID,
            workspaceID: workspaceID,
            subject: subject,
            selector: selector
        )
    }

    app.post("api", "agents", "register") { req async throws in
        let registration = try req.content.decode(AgentRegistrationRequest.self)
        let device = try await store.registerAgent(registration)
        await scheduler.trigger()
        return device
    }

    protected.post("api", "tasks") { req async throws in
        let create = try req.content.decode(CreateTaskRequest.self)
        let task = try await store.createTask(create)
        await scheduler.trigger()
        return task
    }

    protected.post("api", "runs") { req async throws in
        let create = try req.content.decode(CreateManagedRunRequest.self)
        let run = try await store.createManagedRun(create)
        await scheduler.trigger()
        return run
    }

    protected.post("api", "tasks", ":taskID", "stop") { req async throws in
        guard let taskID = req.parameters.get("taskID") else {
            throw Abort(.badRequest, reason: "缺少任务 ID。")
        }
        let request = try req.content.decode(StopTaskRequest.self)
        let task = try await store.requestStop(taskID: taskID, reason: request.reason)
        if task.status == .stopRequested, let deviceID = task.assignedDeviceID {
            _ = await registry.send(.taskStop(TaskStopCommand(taskID: taskID, reason: request.reason)), to: deviceID)
        }
        await scheduler.trigger()
        return task
    }

    protected.post("api", "runs", ":runID", "continue") { req async throws in
        guard let runID = req.parameters.get("runID") else {
            throw Abort(.badRequest, reason: "缺少 run ID。")
        }
        let request = try req.content.decode(ManagedRunContinueRequest.self)
        let target = try await store.interactiveTargetForManagedRun(runID: runID)
        let detail = try await codexProxy.continueSession(
            deviceID: target.deviceID,
            sessionID: target.sessionID,
            prompt: request.prompt
        )
        return try await store.recordManagedRunContinuation(
            runID: runID,
            prompt: request.prompt,
            sessionDetail: detail
        )
    }

    protected.post("api", "runs", ":runID", "interrupt") { req async throws in
        guard let runID = req.parameters.get("runID") else {
            throw Abort(.badRequest, reason: "缺少 run ID。")
        }
        _ = try req.content.decode(ManagedRunInterruptRequest.self)
        let target = try await store.interactiveTargetForManagedRun(runID: runID)
        let detail = try await codexProxy.interruptSession(
            deviceID: target.deviceID,
            sessionID: target.sessionID
        )
        return try await store.recordManagedRunInterruption(runID: runID, sessionDetail: detail)
    }

    protected.post("api", "runs", ":runID", "stop") { req async throws in
        guard let runID = req.parameters.get("runID") else {
            throw Abort(.badRequest, reason: "缺少 run ID。")
        }
        let request = try req.content.decode(ManagedRunStopRequest.self)
        let run = try await store.stopManagedRun(runID: runID, reason: request.reason)
        if run.status == .stopRequested, let taskID = run.taskID, let deviceID = run.deviceID {
            _ = await registry.send(.taskStop(TaskStopCommand(taskID: taskID, reason: request.reason)), to: deviceID)
        }
        await scheduler.trigger()
        return run
    }

    protected.post("api", "runs", ":runID", "retry") { req async throws in
        guard let runID = req.parameters.get("runID") else {
            throw Abort(.badRequest, reason: "缺少 run ID。")
        }
        let request = try req.content.decode(ManagedRunRetryRequest.self)
        let run = try await store.retryManagedRun(runID: runID, prompt: request.prompt)
        await scheduler.trigger()
        return run
    }

    app.webSocket("api", "agents", ":deviceID", "session", maxFrameSize: 1_048_576) { req, ws async in
        guard let deviceID = req.parameters.get("deviceID") else {
            closeSocket(ws)
            return
        }
        let token = req.query[String.self, at: "token"] ?? ""
        do {
            try store.validateEnrollment(token: token)
            _ = try await store.requireDevice(deviceID: deviceID)
        } catch {
            closeSocket(ws, code: .policyViolation)
            return
        }

        registry.connect(deviceID: deviceID, socket: ws)
        ws.pingInterval = .seconds(15)
        _ = try? await store.markDeviceSeen(deviceID: deviceID, metrics: nil)
        await scheduler.trigger()

        for command in (try? await store.pendingStopCommands(deviceID: deviceID)) ?? [] {
            _ = await registry.send(.taskStop(command), to: deviceID)
        }

        ws.eventLoop.execute {
            ws.onText { socket, text in
                Task {
                    do {
                        let message = try OrchardJSON.decoder.decode(AgentSocketMessage.self, from: Data(text.utf8))
                        try await handleAgentMessage(
                            message,
                            deviceID: deviceID,
                            store: store,
                            registry: registry,
                            codexBroker: codexBroker,
                            projectContextBroker: projectContextBroker
                        )
                        await scheduler.trigger()
                    } catch {
                        print("[OrchardControlPlane] websocket message error: \(error)")
                        closeSocket(socket, code: .unacceptableData)
                    }
                }
            }
        }

        ws.onClose.whenComplete { _ in
            registry.disconnect(deviceID: deviceID, socket: ws)
        }
    }
}

struct OrchardUnlockRequest: Content {
    let accessKey: String
}

private func closeSocket(_ socket: WebSocket, code: WebSocketErrorCode = .goingAway) {
    socket.eventLoop.execute {
        socket.close(code: code, promise: nil)
    }
}

private func parseManagedRunStatuses(_ req: Request) throws -> [ManagedRunStatus] {
    guard let raw = req.query[String.self, at: "status"], !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return []
    }

    var statuses: [ManagedRunStatus] = []
    for part in raw.split(separator: ",") {
        let value = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let status = ManagedRunStatus(rawValue: value) else {
            throw Abort(.badRequest, reason: "无效的 run 状态筛选：\(value)。")
        }
        if !statuses.contains(status) {
            statuses.append(status)
        }
    }
    return statuses
}

private func handleAgentMessage(
    _ message: AgentSocketMessage,
    deviceID: String,
    store: OrchardControlPlaneStore,
    registry: AgentConnectionRegistry,
    codexBroker: AgentCodexCommandBroker,
    projectContextBroker: AgentProjectContextCommandBroker
) async throws {
    switch message {
    case let .hello(payload):
        var metrics = payload.metrics ?? DeviceMetrics()
        metrics.runningTasks = payload.runningTaskIDs.count
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: metrics)
        for command in try await store.pendingStopCommands(deviceID: deviceID) {
            _ = await registry.send(.taskStop(command), to: deviceID)
        }
    case let .heartbeat(payload):
        var metrics = payload.metrics
        metrics.runningTasks = payload.runningTaskIDs.count
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: metrics)
        for command in try await store.pendingStopCommands(deviceID: deviceID) {
            _ = await registry.send(.taskStop(command), to: deviceID)
        }
    case let .logBatch(payload):
        try await store.appendLogs(deviceID: deviceID, payload: payload)
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: nil)
    case let .taskUpdate(payload):
        _ = try await store.applyTaskUpdate(deviceID: deviceID, payload: payload)
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: nil)
    case let .codexCommandResult(payload):
        await codexBroker.record(payload)
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: nil)
    case let .projectContextCommandResult(payload):
        await projectContextBroker.record(payload)
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: nil)
    }
}
