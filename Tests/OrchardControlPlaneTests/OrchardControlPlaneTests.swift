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
                XCTAssertTrue(body?.contains("远程任务控制台") == true)
                XCTAssertTrue(body?.contains("第一次用？先这样走一遍") == true)
                XCTAssertTrue(body?.contains("我现在想做什么") == true)
                XCTAssertTrue(body?.contains("发起新任务") == true)
                XCTAssertTrue(body?.contains("发起任务") == true)
                XCTAssertTrue(body?.contains("别被这些字段吓到") == true)
                XCTAssertTrue(body?.contains("真正必填只有 2 项") == true)
                XCTAssertTrue(body?.contains("先选一个常用目录") == true)
                XCTAssertTrue(body?.contains("筛选") == true)
                XCTAssertTrue(body?.contains("现在最需要处理") == true)
                XCTAssertTrue(body?.contains("本机 Codex 对话") == true)
                XCTAssertTrue(body?.contains("通过 Orchard 发起的任务") == true)
                XCTAssertTrue(body?.contains("仅有简略摘要的对话") == true)
                XCTAssertTrue(body?.contains("桌面活跃对话") == true)
                XCTAssertTrue(body?.contains("尚未映射到控制面") == true)
                XCTAssertTrue(body?.contains("进行中的回答轮次") == true)
                XCTAssertTrue(body?.contains("兼容任务（旧接口）") == true)
                XCTAssertTrue(body?.contains("诊断视图") == true)
                XCTAssertTrue(body?.contains("设备级观测") == true)
                XCTAssertTrue(body?.contains("继续追问") == true)
                XCTAssertTrue(body?.contains("项目上下文") == true)
                XCTAssertTrue(body?.contains("标准操作命令") == true)
                XCTAssertTrue(body?.contains("宿主机控制台") == true)
                XCTAssertTrue(body?.contains("/health") == true)
                XCTAssertTrue(body?.contains("/api/codex/sessions") == true)
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

    func testManagedRunsCanBeCreatedListedDetailedAndStopped() async throws {
        let dataDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        try await withTestEnvironment(dataDirectory: dataDirectory) {
            let app = try await makeOrchardControlPlaneApplication(environment: .testing)
            defer { Task { try? await app.asyncShutdown() } }

            let create = CreateManagedRunRequest(
                title: "实现移动端远程继续",
                workspaceID: "workspace-a",
                relativePath: "mobile",
                preferredDeviceID: "mac-1",
                driver: .codexCLI,
                prompt: "把移动端继续、中断、停止链路补上"
            )

            var runID = ""
            try await app.test(.POST, "/api/runs", beforeRequest: { req async throws in
                try req.content.encode(create)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(ManagedRunSummary.self, res) { run in
                    runID = run.id
                    XCTAssertEqual(run.status, .queued)
                    XCTAssertEqual(run.driver, .codexCLI)
                    XCTAssertEqual(run.preferredDeviceID, "mac-1")
                    XCTAssertEqual(run.lastUserPrompt, "把移动端继续、中断、停止链路补上")
                    XCTAssertFalse(run.taskID?.isEmpty ?? true)
                }
            })

            try await app.test(.GET, "/api/runs", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent([ManagedRunSummary].self, res) { runs in
                    XCTAssertEqual(runs.count, 1)
                    XCTAssertEqual(runs.first?.id, runID)
                    XCTAssertEqual(runs.first?.preferredDeviceID, "mac-1")
                }
            })

            try await app.test(.GET, "/api/runs/\(runID)", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(ManagedRunDetail.self, res) { detail in
                    XCTAssertEqual(detail.run.id, runID)
                    XCTAssertEqual(detail.run.preferredDeviceID, "mac-1")
                    XCTAssertEqual(detail.events.count, 1)
                    XCTAssertEqual(detail.events.first?.kind, .runCreated)
                    XCTAssertTrue(detail.logs.isEmpty)
                }
            })

            try await app.test(.GET, "/api/snapshot", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(DashboardSnapshot.self, res) { snapshot in
                    XCTAssertEqual(snapshot.managedRuns.count, 1)
                    XCTAssertEqual(snapshot.managedRuns.first?.id, runID)
                    XCTAssertEqual(snapshot.managedRuns.first?.preferredDeviceID, "mac-1")
                    XCTAssertEqual(snapshot.tasks.count, 1)
                    guard let task = snapshot.tasks.first else {
                        return XCTFail("Expected task in snapshot")
                    }
                    guard case let .codex(payload) = task.payload else {
                        return XCTFail("Expected codex payload")
                    }
                    XCTAssertEqual(payload.driver, .codexCLI)
                }
            })

            try await app.test(.POST, "/api/runs/\(runID)/stop", beforeRequest: { req async throws in
                try req.content.encode(ManagedRunStopRequest(reason: "先取消"))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(ManagedRunSummary.self, res) { run in
                    XCTAssertEqual(run.id, runID)
                    XCTAssertEqual(run.status, .cancelled)
                    XCTAssertEqual(run.summary, "先取消")
                }
            })
        }
    }

    func testManagedRunRetryCreatesNewQueuedRun() async throws {
        let dataDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        try await withTestEnvironment(dataDirectory: dataDirectory) {
            let app = try await makeOrchardControlPlaneApplication(environment: .testing)
            defer { Task { try? await app.asyncShutdown() } }

            let create = CreateManagedRunRequest(
                title: "原始 run",
                workspaceID: "workspace-a",
                driver: .codexCLI,
                prompt: "先做第一版"
            )

            var originalRunID = ""
            try await app.test(.POST, "/api/runs", beforeRequest: { req async throws in
                try req.content.encode(create)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(ManagedRunSummary.self, res) { run in
                    originalRunID = run.id
                }
            })

            try await app.test(.POST, "/api/runs/\(originalRunID)/retry", beforeRequest: { req async throws in
                try req.content.encode(ManagedRunRetryRequest(prompt: "重试并补上日志链路"))
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(ManagedRunSummary.self, res) { retried in
                    XCTAssertNotEqual(retried.id, originalRunID)
                    XCTAssertEqual(retried.status, .queued)
                    XCTAssertEqual(retried.lastUserPrompt, "重试并补上日志链路")
                }
            })

            try await app.test(.GET, "/api/runs?status=queued", afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent([ManagedRunSummary].self, res) { runs in
                    XCTAssertEqual(runs.count, 2)
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
                workspaces: [WorkspaceDefinition(id: "workspace-a", name: "Workspace A", rootPath: "/tmp")],
                localStatusPageHost: "127.0.0.1",
                localStatusPagePort: 5419
            )

            try await app.test(.POST, "/api/agents/register", beforeRequest: { req async throws in
                try req.content.encode(registration)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                XCTAssertContent(DeviceRecord.self, res) { device in
                    XCTAssertEqual(device.localStatusPageHost, "127.0.0.1")
                    XCTAssertEqual(device.localStatusPagePort, 5419)
                }
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
