import Darwin
import Foundation
import XCTest
@testable import OrchardControlPlane
import OrchardCore
import Vapor
import XCTVapor

final class OrchardControlPlaneTests: XCTestCase {
    func testRootRouteServesLandingPage() async throws {
        let dataDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        try await withTestEnvironment(dataDirectory: dataDirectory) {
            let app = try await makeOrchardControlPlaneApplication(environment: .testing)
            defer { Task { try? await app.asyncShutdown() } }

            try await app.test(.GET, "/", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: .contentType), "text/html; charset=utf-8")

                let body = res.body.getString(at: res.body.readerIndex, length: res.body.readableBytes)
                XCTAssertNotNil(body)
                XCTAssertTrue(body?.contains("Orchard 控制平面") == true)
                XCTAssertTrue(body?.contains("/health") == true)
            })
        }
    }

    func testSchedulerSelectsLeastLoadedConnectedDevice() {
        let task = TaskRecord(
            id: "task-1",
            title: "Test",
            kind: .shell,
            workspaceID: "workspace-a",
            relativePath: nil,
            priority: .normal,
            status: .queued,
            payload: .shell(ShellTaskPayload(command: "echo hi")),
            createdAt: Date(),
            updatedAt: Date()
        )

        let older = Date(timeIntervalSinceNow: -10)
        let devices = [
            DeviceRecord(
                deviceID: "mac-2",
                name: "Mac 2",
                hostName: "mac-2",
                platform: .macOS,
                status: .online,
                capabilities: [.shell],
                maxParallelTasks: 2,
                workspaces: [WorkspaceDefinition(id: "workspace-a", name: "Main", rootPath: "/tmp")],
                metrics: DeviceMetrics(),
                runningTaskCount: 1,
                registeredAt: older,
                lastSeenAt: older
            ),
            DeviceRecord(
                deviceID: "mac-1",
                name: "Mac 1",
                hostName: "mac-1",
                platform: .macOS,
                status: .online,
                capabilities: [.shell],
                maxParallelTasks: 2,
                workspaces: [WorkspaceDefinition(id: "workspace-a", name: "Main", rootPath: "/tmp")],
                metrics: DeviceMetrics(),
                runningTaskCount: 0,
                registeredAt: older,
                lastSeenAt: Date()
            ),
        ]

        let selected = TaskDispatchPlanner.selectDevice(for: task, from: devices, connectedDeviceIDs: ["mac-1", "mac-2"])
        XCTAssertEqual(selected?.deviceID, "mac-1")
    }

    func testQueuedTasksAreOrderedByPriorityThenCreationDate() {
        let now = Date()
        let low = TaskRecord(
            id: "low",
            title: "Low",
            kind: .shell,
            workspaceID: "ws",
            relativePath: nil,
            priority: .low,
            status: .queued,
            payload: .shell(ShellTaskPayload(command: "echo low")),
            createdAt: now,
            updatedAt: now
        )
        let high = TaskRecord(
            id: "high",
            title: "High",
            kind: .shell,
            workspaceID: "ws",
            relativePath: nil,
            priority: .high,
            status: .queued,
            payload: .shell(ShellTaskPayload(command: "echo high")),
            createdAt: now.addingTimeInterval(5),
            updatedAt: now.addingTimeInterval(5)
        )
        let normalOld = TaskRecord(
            id: "normal-old",
            title: "Normal old",
            kind: .shell,
            workspaceID: "ws",
            relativePath: nil,
            priority: .normal,
            status: .queued,
            payload: .shell(ShellTaskPayload(command: "echo normal")),
            createdAt: now.addingTimeInterval(-5),
            updatedAt: now.addingTimeInterval(-5)
        )

        let ordered = TaskDispatchPlanner.orderedQueuedTasks([low, high, normalOld]).map(\.id)
        XCTAssertEqual(ordered, ["high", "normal-old", "low"])
    }

    func testQueuedTaskStopCancelsImmediately() async throws {
        let dataDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        try await withTestEnvironment(dataDirectory: dataDirectory) {
            let app = try await makeOrchardControlPlaneApplication(environment: .testing)
            defer { Task { try? await app.asyncShutdown() } }

            let create = CreateTaskRequest(
                title: "Stop me",
                kind: .shell,
                workspaceID: "workspace-a",
                payload: .shell(ShellTaskPayload(command: "echo hi"))
            )

            var taskID = ""
            try await app.test(.POST, "/api/tasks", beforeRequest: { req async throws in
                try req.content.encode(create)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(TaskRecord.self, res) { task in
                    taskID = task.id
                    XCTAssertEqual(task.status, .queued)
                }
            })

            try await app.test(.POST, "/api/tasks/\(taskID)/stop", beforeRequest: { req async throws in
                try req.content.encode(StopTaskRequest(reason: "User requested stop"))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(TaskRecord.self, res) { task in
                    XCTAssertEqual(task.status, .cancelled)
                    XCTAssertEqual(task.summary, "User requested stop")
                }
            })

            try await app.test(.GET, "/api/tasks/\(taskID)", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(TaskDetail.self, res) { detail in
                    XCTAssertEqual(detail.task.status, .cancelled)
                    XCTAssertEqual(detail.task.summary, "User requested stop")
                    XCTAssertTrue(detail.logs.isEmpty)
                }
            })
        }
    }

    func testTasksPersistAcrossRestart() async throws {
        let dataDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        try await withTestEnvironment(dataDirectory: dataDirectory) {
            let create = CreateTaskRequest(
                title: "Persist me",
                kind: .shell,
                workspaceID: "workspace-a",
                payload: .shell(ShellTaskPayload(command: "echo persisted"))
            )

            var taskID = ""

            do {
                let app = try await makeOrchardControlPlaneApplication(environment: .testing)
                try await app.test(.POST, "/api/tasks", beforeRequest: { req async throws in
                    try req.content.encode(create)
                }, afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .ok)
                    XCTAssertContent(TaskRecord.self, res) { task in
                        taskID = task.id
                        XCTAssertEqual(task.status, .queued)
                    }
                })
                try await app.asyncShutdown()
            }

            let restarted = try await makeOrchardControlPlaneApplication(environment: .testing)
            defer { Task { try? await restarted.asyncShutdown() } }

            try await restarted.test(.GET, "/api/tasks/\(taskID)", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(TaskDetail.self, res) { detail in
                    XCTAssertEqual(detail.task.id, taskID)
                    XCTAssertEqual(detail.task.title, "Persist me")
                    XCTAssertEqual(detail.task.status, .queued)
                }
            })
        }
    }

    func testProtectedRoutesRequireAccessKeyWhenConfigured() async throws {
        let dataDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        try await withTestEnvironment(dataDirectory: dataDirectory, accessKey: "browser-secret") {
            let app = try await makeOrchardControlPlaneApplication(environment: .testing)
            defer { Task { try? await app.asyncShutdown() } }

            try await app.test(.GET, "/", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.getString(at: res.body.readerIndex, length: res.body.readableBytes)
                XCTAssertTrue(body?.contains("请输入访问密钥。") == true)
            })

            try await app.test(.GET, "/api/snapshot", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized)
            })

            try await app.test(.POST, "/unlock", beforeRequest: { req async throws in
                try req.content.encode(OrchardUnlockRequest(accessKey: "browser-secret"), as: .urlEncodedForm)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .seeOther)
                XCTAssertEqual(res.headers.first(name: .location), "/")
                XCTAssertEqual(res.headers.setCookie?[OrchardAccessControl.cookieName]?.string, "browser-secret")
            })

            try await app.test(.GET, "/", beforeRequest: { req async throws in
                var cookies = HTTPCookies()
                cookies[OrchardAccessControl.cookieName] = .init(string: "browser-secret")
                req.headers.cookie = cookies
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                let body = res.body.getString(at: res.body.readerIndex, length: res.body.readableBytes)
                XCTAssertTrue(body?.contains("Orchard 控制平面") == true)
            })

            try await app.test(.GET, "/api/snapshot", beforeRequest: { req async throws in
                req.headers.replaceOrAdd(name: OrchardAccessControl.headerName, value: "browser-secret")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })
        }
    }

    func testAgentRegistrationStillUsesEnrollmentTokenWhenAccessKeyEnabled() async throws {
        let dataDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        try await withTestEnvironment(dataDirectory: dataDirectory, token: "orchard-test-token", accessKey: "browser-secret") {
            let app = try await makeOrchardControlPlaneApplication(environment: .testing)
            defer { Task { try? await app.asyncShutdown() } }

            let registration = AgentRegistrationRequest(
                enrollmentToken: "orchard-test-token",
                deviceID: "device-1",
                name: "Device 1",
                hostName: "device-1.local",
                platform: .macOS,
                capabilities: [.shell],
                maxParallelTasks: 1,
                workspaces: [WorkspaceDefinition(id: "workspace-a", name: "Workspace A", rootPath: "/tmp")]
            )

            try await app.test(.POST, "/api/agents/register", beforeRequest: { req async throws in
                try req.content.encode(registration)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
            })
        }
    }
}

private func withTestEnvironment<T>(
    dataDirectory: URL,
    token: String = "orchard-test-token",
    accessKey: String? = nil,
    operation: () async throws -> T
) async throws -> T {
    let previousDataDirectory = currentEnvironmentValue(for: "ORCHARD_DATA_DIR")
    let previousToken = currentEnvironmentValue(for: "ORCHARD_ENROLLMENT_TOKEN")
    let previousAccessKey = currentEnvironmentValue(for: "ORCHARD_ACCESS_KEY")

    setenv("ORCHARD_DATA_DIR", dataDirectory.path, 1)
    setenv("ORCHARD_ENROLLMENT_TOKEN", token, 1)
    if let accessKey {
        setenv("ORCHARD_ACCESS_KEY", accessKey, 1)
    } else {
        unsetenv("ORCHARD_ACCESS_KEY")
    }

    defer {
        restoreEnvironmentValue(previousDataDirectory, for: "ORCHARD_DATA_DIR")
        restoreEnvironmentValue(previousToken, for: "ORCHARD_ENROLLMENT_TOKEN")
        restoreEnvironmentValue(previousAccessKey, for: "ORCHARD_ACCESS_KEY")
    }

    return try await operation()
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("orchard-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func currentEnvironmentValue(for key: String) -> String? {
    guard let value = getenv(key) else { return nil }
    return String(cString: value)
}

private func restoreEnvironmentValue(_ value: String?, for key: String) {
    if let value {
        setenv(key, value, 1)
    } else {
        unsetenv(key)
    }
}
