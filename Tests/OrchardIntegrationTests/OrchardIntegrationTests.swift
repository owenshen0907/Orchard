import Foundation
import XCTest
@testable import OrchardAgent
import OrchardCore
@testable import OrchardControlPlane
import Vapor

final class OrchardIntegrationTests: XCTestCase {
    func testShellTaskRunsEndToEnd() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        try await withRunningControlPlane(in: sandbox.root) { context in
            let config = ResolvedAgentConfig(
                serverURL: context.baseURL,
                enrollmentToken: context.token,
                deviceID: "test-mac-01",
                deviceName: "Test Mac",
                hostName: "test-mac-01",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
                ],
                heartbeatIntervalSeconds: 1,
                codexBinaryPath: "/usr/bin/false"
            )

            let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state.json", isDirectory: false))
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
            try await withRunningAgent(service: service) {
                let client = OrchardAPIClient(baseURL: context.baseURL)
                let device = try await poll(timeout: 10) {
                    let devices = try await client.fetchDevices()
                    return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
                }
                XCTAssertEqual(device.deviceID, config.deviceID)

                let task = try await client.createTask(CreateTaskRequest(
                    title: "echo",
                    kind: .shell,
                    workspaceID: "main",
                    payload: .shell(ShellTaskPayload(command: "printf 'hello orchard\\nsecond line\\n'"))
                ))

                let detail = try await poll(timeout: 15) {
                    let detail = try await client.fetchTaskDetail(taskID: task.id)
                    return detail.task.status == .succeeded ? detail : nil
                }

                XCTAssertEqual(detail.task.assignedDeviceID, config.deviceID)
                XCTAssertEqual(detail.task.status, .succeeded)
                XCTAssertEqual(detail.task.exitCode, 0)
                XCTAssertEqual(detail.logs.map(\.line), ["hello orchard", "second line"])
            }
        }
    }

    func testStopRunningTaskCancelsEndToEnd() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        try await withRunningControlPlane(in: sandbox.root) { context in
            let config = ResolvedAgentConfig(
                serverURL: context.baseURL,
                enrollmentToken: context.token,
                deviceID: "test-mac-stop-01",
                deviceName: "Test Mac Stop",
                hostName: "test-mac-stop-01",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
                ],
                heartbeatIntervalSeconds: 1,
                codexBinaryPath: "/usr/bin/false"
            )

            let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state-stop.json", isDirectory: false))
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-stop", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
            try await withRunningAgent(service: service) {
                let client = OrchardAPIClient(baseURL: context.baseURL)
                _ = try await poll(timeout: 10) {
                    let devices = try await client.fetchDevices()
                    return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
                }

                let task = try await client.createTask(CreateTaskRequest(
                    title: "stop-me",
                    kind: .shell,
                    workspaceID: "main",
                    payload: .shell(ShellTaskPayload(command: "echo starting; trap 'exit 0' TERM; while true; do sleep 1; done"))
                ))

                _ = try await poll(timeout: 10) {
                    let detail = try await client.fetchTaskDetail(taskID: task.id)
                    return detail.task.status == .running && !detail.logs.isEmpty ? detail : nil
                }

                _ = try await client.stopTask(taskID: task.id, reason: "integration stop")

                let cancelled = try await poll(timeout: 15) {
                    let detail = try await client.fetchTaskDetail(taskID: task.id)
                    return detail.task.status == .cancelled ? detail : nil
                }

                XCTAssertEqual(cancelled.task.assignedDeviceID, config.deviceID)
                XCTAssertEqual(cancelled.task.status, .cancelled)
                XCTAssertEqual(cancelled.task.summary, "Task cancelled after stop request.")
                XCTAssertFalse(cancelled.logs.isEmpty)
            }
        }
    }
}

private struct IntegrationContext {
    var app: Application
    var baseURL: URL
    var token: String
}

private struct Sandbox {
    var root: URL
}

private func startControlPlane(in root: URL) async throws -> IntegrationContext {
    let token = "orchard-integration-token"
    let dataDirectory = root.appendingPathComponent("control-plane-data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

    return try await withEnvironment([
        "ORCHARD_DATA_DIR": dataDirectory.path,
        "ORCHARD_ENROLLMENT_TOKEN": token,
        "ORCHARD_BIND": "127.0.0.1",
        "ORCHARD_PORT": "0",
    ]) {
        let app = try await makeOrchardControlPlaneApplication(environment: .testing)
        app.environment.arguments = ["serve"]
        try await app.startup()

        guard
            let localAddress = app.http.server.shared.localAddress,
            let port = localAddress.port
        else {
            throw NSError(domain: "OrchardIntegrationTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Control Plane did not expose a local port.",
            ])
        }

        return IntegrationContext(
            app: app,
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            token: token
        )
    }
}

private func makeTemporarySandbox() throws -> Sandbox {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("orchard-integration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return Sandbox(root: root)
}

private func poll<T>(
    timeout: TimeInterval,
    interval: TimeInterval = 0.2,
    operation: () async throws -> T?
) async throws -> T {
    let deadline = Date().addingTimeInterval(timeout)
    var lastError: Error?

    while Date() < deadline {
        do {
            if let value = try await operation() {
                return value
            }
        } catch {
            lastError = error
        }
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }

    if let lastError {
        throw lastError
    }
    throw NSError(domain: "OrchardIntegrationTests", code: 2, userInfo: [
        NSLocalizedDescriptionKey: "Timed out waiting for condition.",
    ])
}

private func withEnvironment<T>(
    _ values: [String: String],
    operation: () async throws -> T
) async throws -> T {
    var previousValues: [String: String?] = [:]
    for key in values.keys {
        previousValues[key] = currentEnvironmentValue(for: key)
    }
    for (key, value) in values {
        setenv(key, value, 1)
    }
    defer {
        for (key, value) in previousValues {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }
    return try await operation()
}

private func currentEnvironmentValue(for key: String) -> String? {
    guard let value = getenv(key) else { return nil }
    return String(cString: value)
}

private func withRunningControlPlane<T>(
    in root: URL,
    operation: (IntegrationContext) async throws -> T
) async throws -> T {
    let context = try await startControlPlane(in: root)

    do {
        let result = try await operation(context)
        try await context.app.asyncShutdown()
        return result
    } catch {
        try? await context.app.asyncShutdown()
        throw error
    }
}

private func withRunningAgent<T>(
    service: OrchardAgentService,
    operation: () async throws -> T
) async throws -> T {
    let task = Task {
        try await service.run()
    }

    do {
        let result = try await operation()
        await service.stop()
        task.cancel()
        _ = await task.result
        return result
    } catch {
        await service.stop()
        task.cancel()
        _ = await task.result
        throw error
    }
}
