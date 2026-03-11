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
    try await app.autoMigrate()
    guard let sqlDatabase = app.db as? any SQLDatabase else {
        throw NSError(domain: "OrchardControlPlane", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Configured database does not expose SQLDatabase.",
        ])
    }
    try await sqlDatabase.raw("PRAGMA journal_mode=WAL;").run()

    let enrollmentToken = Environment.get("ORCHARD_ENROLLMENT_TOKEN") ?? "orchard-dev-token"
    let store = OrchardControlPlaneStore(app: app, enrollmentToken: enrollmentToken)
    let registry = AgentConnectionRegistry()
    let scheduler = TaskScheduler(store: store, registry: registry)

    configureRoutes(app: app, store: store, registry: registry, scheduler: scheduler)
    return app
}

private func configureRoutes(
    app: Application,
    store: OrchardControlPlaneStore,
    registry: AgentConnectionRegistry,
    scheduler: TaskScheduler
) {
    app.get { _ in
        OrchardLandingPage.response()
    }

    app.get("health") { _ in
        ["status": "ok", "service": "orchard-control-plane"]
    }

    app.get("api", "snapshot") { _ async throws in
        try await store.dashboardSnapshot()
    }

    app.get("api", "devices") { _ async throws in
        try await store.listDevices()
    }

    app.get("api", "tasks") { _ async throws in
        try await store.listTasks()
    }

    app.get("api", "tasks", ":taskID") { req async throws in
        guard let taskID = req.parameters.get("taskID") else {
            throw Abort(.badRequest, reason: "Missing taskID.")
        }
        return try await store.fetchTaskDetail(taskID: taskID)
    }

    app.post("api", "agents", "register") { req async throws in
        let registration = try req.content.decode(AgentRegistrationRequest.self)
        let device = try await store.registerAgent(registration)
        await scheduler.trigger()
        return device
    }

    app.post("api", "tasks") { req async throws in
        let create = try req.content.decode(CreateTaskRequest.self)
        let task = try await store.createTask(create)
        await scheduler.trigger()
        return task
    }

    app.post("api", "tasks", ":taskID", "stop") { req async throws in
        guard let taskID = req.parameters.get("taskID") else {
            throw Abort(.badRequest, reason: "Missing taskID.")
        }
        let request = try req.content.decode(StopTaskRequest.self)
        let task = try await store.requestStop(taskID: taskID, reason: request.reason)
        if task.status == .stopRequested, let deviceID = task.assignedDeviceID {
            _ = registry.send(.taskStop(TaskStopCommand(taskID: taskID, reason: request.reason)), to: deviceID)
        }
        await scheduler.trigger()
        return task
    }

    app.webSocket("api", "agents", ":deviceID", "session") { req, ws async in
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
        _ = try? await store.markDeviceSeen(deviceID: deviceID, metrics: nil)
        await scheduler.trigger()

        for command in (try? await store.pendingStopCommands(deviceID: deviceID)) ?? [] {
            _ = registry.send(.taskStop(command), to: deviceID)
        }

        ws.eventLoop.execute {
            ws.onText { socket, text in
                Task {
                    do {
                        let message = try OrchardJSON.decoder.decode(AgentSocketMessage.self, from: Data(text.utf8))
                        try await handleAgentMessage(message, deviceID: deviceID, store: store, registry: registry)
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

private func closeSocket(_ socket: WebSocket, code: WebSocketErrorCode = .goingAway) {
    socket.eventLoop.execute {
        socket.close(code: code, promise: nil)
    }
}

private func handleAgentMessage(
    _ message: AgentSocketMessage,
    deviceID: String,
    store: OrchardControlPlaneStore,
    registry: AgentConnectionRegistry
) async throws {
    switch message {
    case let .hello(payload):
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: DeviceMetrics(runningTasks: payload.runningTaskIDs.count))
        for command in try await store.pendingStopCommands(deviceID: deviceID) {
            _ = registry.send(.taskStop(command), to: deviceID)
        }
    case let .heartbeat(payload):
        var metrics = payload.metrics
        metrics.runningTasks = payload.runningTaskIDs.count
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: metrics)
        for command in try await store.pendingStopCommands(deviceID: deviceID) {
            _ = registry.send(.taskStop(command), to: deviceID)
        }
    case let .logBatch(payload):
        try await store.appendLogs(deviceID: deviceID, payload: payload)
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: nil)
    case let .taskUpdate(payload):
        _ = try await store.applyTaskUpdate(deviceID: deviceID, payload: payload)
        _ = try await store.markDeviceSeen(deviceID: deviceID, metrics: nil)
    }
}
