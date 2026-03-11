import Foundation
import OrchardCore
import Vapor

@main
enum OrchardControlPlaneMain {
    static func main() throws {
        let app = Application(.detect())
        defer { app.shutdown() }

        app.http.server.configuration.hostname = Environment.get("ORCHARD_BIND") ?? "127.0.0.1"
        app.http.server.configuration.port = Int(Environment.get("ORCHARD_PORT") ?? "") ?? 8080

        let state = OrchardControlPlaneState()

        app.get("health") { _ in
            ["status": "ok", "service": "orchard-control-plane"]
        }

        app.get("api", "snapshot") { _ async in
            await state.snapshot()
        }

        app.get("api", "devices") { _ async in
            await state.listDevices()
        }

        app.post("api", "devices", "register") { req async throws in
            let registration = try req.content.decode(DeviceRegistration.self)
            return await state.registerDevice(registration)
        }

        app.post("api", "devices", ":deviceID", "heartbeat") { req async throws in
            guard let deviceID = req.parameters.get("deviceID") else {
                throw Abort(.badRequest, reason: "Missing deviceID.")
            }
            let heartbeat = try req.content.decode(HeartbeatRequest.self)
            guard let updated = await state.heartbeat(deviceID: deviceID, heartbeat: heartbeat) else {
                throw Abort(.notFound, reason: "Device not registered.")
            }
            return updated
        }

        app.get("api", "tasks") { _ async in
            await state.listTasks()
        }

        app.post("api", "tasks") { req async throws in
            let create = try req.content.decode(CreateTaskRequest.self)
            return await state.createTask(create)
        }

        try app.run()
    }
}
