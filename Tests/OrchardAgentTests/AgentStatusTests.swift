import Darwin
import Foundation
import XCTest
@testable import OrchardAgent
import OrchardCore

final class AgentStatusTests: XCTestCase {
    func testStatusSnapshotLoadsLocalActiveTaskAndPendingUpdate() async throws {
        let directory = try makeStatusTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let tasksDirectory = directory.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

        let configURL = directory.appendingPathComponent("agent.json", isDirectory: false)
        let stateURL = directory.appendingPathComponent("agent-state.json", isDirectory: false)

        try AgentConfigLoader.save(
            AgentConfigFile(
                serverURL: "https://orchard.local",
                enrollmentToken: "token",
                deviceID: "mac-mini-01",
                deviceName: "Mac Mini",
                maxParallelTasks: 2,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path),
                ],
                heartbeatIntervalSeconds: 10,
                codexBinaryPath: "codex"
            ),
            to: configURL
        )

        let stateStore = AgentStateStore(url: stateURL)
        try await stateStore.markTaskStarted("task-running")
        try await stateStore.stageTaskUpdate(AgentTaskUpdatePayload(
            taskID: "task-finished",
            status: .succeeded,
            exitCode: 0,
            summary: "已成功结束"
        ))

        let runtimeDirectory = tasksDirectory.appendingPathComponent("task-running", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let task = TaskRecord(
            id: "task-running",
            title: "检查控制面日志",
            kind: .codex,
            workspaceID: "main",
            relativePath: "Sources/OrchardControlPlane",
            priority: .normal,
            status: .running,
            payload: .codex(CodexTaskPayload(prompt: "检查最近失败原因")),
            preferredDeviceID: "mac-mini-01",
            assignedDeviceID: "mac-mini-01",
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            startedAt: Date(timeIntervalSince1970: 110)
        )
        try OrchardJSON.encoder.encode(task).write(
            to: runtimeDirectory.appendingPathComponent("task.json", isDirectory: false),
            options: .atomic
        )

        let runtime = ManagedCodexRuntimeFixture(
            taskID: "task-running",
            threadID: "thread-123",
            cwd: workspace.appendingPathComponent("Sources/OrchardControlPlane", isDirectory: true).path,
            startedAt: Date(timeIntervalSince1970: 110),
            lastSeenAt: Date(timeIntervalSince1970: 120),
            stopRequested: false,
            pid: 4321,
            activeTurnID: "turn-1",
            emittedTextLengths: [:],
            lastManagedRunStatus: .waitingInput,
            lastUserPrompt: "检查最近失败原因",
            lastAssistantPreview: "已经定位到一个可疑改动"
        )
        try OrchardJSON.encoder.encode(runtime).write(
            to: runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false),
            options: .atomic
        )

        FileManager.default.createFile(
            atPath: runtimeDirectory.appendingPathComponent("combined.log", isDirectory: false).path,
            contents: Data("hello".utf8)
        )

        var options = try AgentStatusOptions(
            configURL: configURL,
            stateURL: stateURL,
            tasksDirectoryURL: tasksDirectory,
            includeRemote: false
        )
        options.outputFormat = .text

        let snapshot = try await AgentStatusService().snapshot(options: options)
        XCTAssertEqual(snapshot.deviceID, "mac-mini-01")
        XCTAssertEqual(snapshot.local.activeTasks.count, 1)
        XCTAssertEqual(snapshot.local.pendingUpdates.count, 1)
        XCTAssertEqual(snapshot.local.activeTasks.first?.codexThreadID, "thread-123")
        XCTAssertEqual(snapshot.local.activeTasks.first?.managedRunStatus, .waitingInput)
        XCTAssertEqual(snapshot.remoteSkippedReason, "已按参数跳过远程状态读取。")

        let rendered = try AgentStatusRenderer.render(snapshot, format: .text)
        XCTAssertTrue(rendered.contains("检查控制面日志"))
        XCTAssertTrue(rendered.contains("thread-123"))
        XCTAssertTrue(rendered.contains("待回传更新"))
    }

    func testStatusPageRendererIncludesLocalAPIAndChineseSections() throws {
        let directory = try makeStatusTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let options = try AgentStatusOptions(
            configURL: directory.appendingPathComponent("agent.json", isDirectory: false),
            stateURL: directory.appendingPathComponent("agent-state.json", isDirectory: false),
            tasksDirectoryURL: directory.appendingPathComponent("tasks", isDirectory: true),
            outputFormat: .text,
            includeRemote: true,
            serve: true,
            bindHost: "127.0.0.1",
            port: 5419
        )

        let html = AgentStatusPageRenderer.render(options: options)
        XCTAssertTrue(html.contains("OrchardAgent 本地状态页"))
        XCTAssertTrue(html.contains("/api/status"))
        XCTAssertTrue(html.contains("本地活动任务"))
        XCTAssertTrue(html.contains("远程托管运行"))
        XCTAssertTrue(html.contains("http://127.0.0.1:5419"))
    }

    func testStatusRendererIncludesRemoteCombinedRunningBreakdown() throws {
        let snapshot = AgentStatusSnapshot(
            generatedAt: Date(timeIntervalSince1970: 200),
            deviceID: "mac-mini-01",
            deviceName: "Mac Mini",
            hostName: "mac-mini",
            serverURL: "https://orchard.local",
            workspaces: [],
            local: AgentLocalStatusSnapshot(
                metrics: DeviceMetrics(),
                activeTaskIDs: [],
                activeTasks: [],
                pendingUpdates: [],
                warnings: []
            ),
            remote: AgentRemoteStatusSnapshot(
                device: nil,
                totalManagedRunCount: 3,
                runningManagedRunCount: 1,
                unmanagedRunningTaskCount: 2,
                observedRunningCodexCount: 1,
                totalRunningCount: 4,
                managedRuns: [],
                totalCodexSessionCount: 5,
                codexSessions: [],
                fetchError: nil
            ),
            remoteSkippedReason: nil
        )

        let rendered = try AgentStatusRenderer.render(snapshot, format: .text)
        XCTAssertTrue(rendered.contains("远程总运行中 4（托管 1 · 独立任务 2 · Codex 推理 1）"))
        XCTAssertTrue(rendered.contains("托管运行 3（其中运行中 1）"))
        XCTAssertTrue(rendered.contains("Codex 会话 5（观测推理中 1）"))
    }

    func testAgentServiceRunStartsEmbeddedLocalStatusPage() async throws {
        let directory = try makeStatusTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let tasksDirectory = directory.appendingPathComponent("tasks", isDirectory: true)
        let configURL = directory.appendingPathComponent("agent.json", isDirectory: false)
        let stateURL = directory.appendingPathComponent("agent-state.json", isDirectory: false)
        let statusPagePort = try makeAvailablePort()

        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

        try AgentConfigLoader.save(
            AgentConfigFile(
                serverURL: "http://127.0.0.1:9",
                enrollmentToken: "token",
                deviceID: "local-status-device",
                deviceName: "Local Status Device",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path),
                ],
                heartbeatIntervalSeconds: 10,
                codexBinaryPath: "codex",
                localStatusPageEnabled: true,
                localStatusPageHost: "127.0.0.1",
                localStatusPagePort: statusPagePort
            ),
            to: configURL
        )

        let config = try AgentConfigLoader.load(from: configURL, hostName: "status-host")
        let service = OrchardAgentService(
            config: config,
            stateStore: AgentStateStore(url: stateURL),
            tasksDirectory: tasksDirectory,
            configURL: configURL,
            stateURL: stateURL
        )

        let runTask = Task {
            try await service.run()
        }
        defer {
            runTask.cancel()
        }

        let statusURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(statusPagePort)/api/status?remote=0"))
        let payload = try await waitForHTTPPayload(url: statusURL, timeout: 5)
        let snapshot = try OrchardJSON.decoder.decode(AgentStatusSnapshot.self, from: payload)

        XCTAssertEqual(snapshot.deviceID, "local-status-device")
        XCTAssertEqual(snapshot.remoteSkippedReason, "已按参数跳过远程状态读取。")

        await service.stop()
        runTask.cancel()
        _ = await runTask.result
    }
}

private struct ManagedCodexRuntimeFixture: Codable {
    var taskID: String
    var threadID: String
    var cwd: String
    var startedAt: Date
    var lastSeenAt: Date
    var stopRequested: Bool
    var pid: Int32?
    var activeTurnID: String?
    var emittedTextLengths: [String: Int]
    var lastManagedRunStatus: ManagedRunStatus?
    var lastUserPrompt: String?
    var lastAssistantPreview: String?
}

private func makeStatusTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("orchard-agent-status-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func waitForHTTPPayload(url: URL, timeout: TimeInterval) async throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    var lastError: Error?

    while Date() < deadline {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) {
                return data
            }

            lastError = NSError(domain: "AgentStatusTests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Unexpected HTTP status from \(url.absoluteString)",
            ])
        } catch {
            lastError = error
        }

        try await Task.sleep(nanoseconds: 200_000_000)
    }

    throw lastError ?? NSError(domain: "AgentStatusTests", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Timed out waiting for \(url.absoluteString)",
    ])
}

private func makeAvailablePort() throws -> Int {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "Unable to allocate TCP socket.",
        ])
    }
    defer { close(socketFD) }

    var value: Int32 = 1
    guard setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout.size(ofValue: value))) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "Unable to configure TCP socket.",
        ])
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            bind(socketFD, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "Unable to bind temporary TCP socket.",
        ])
    }

    var boundAddress = address
    var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            getsockname(socketFD, rebound, &addressLength)
        }
    }
    guard nameResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
            NSLocalizedDescriptionKey: "Unable to inspect temporary TCP socket.",
        ])
    }

    return Int(UInt16(bigEndian: boundAddress.sin_port))
}
