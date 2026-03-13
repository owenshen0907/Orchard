import Darwin
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
                codexBinaryPath: "/usr/bin/false",
                localStatusPageEnabled: false
            )

            let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state.json", isDirectory: false))
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
            try await withRunningAgent(service: service) {
                let client = OrchardAPIClient(baseURL: context.baseURL, accessKey: context.accessKey)
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
                codexBinaryPath: "/usr/bin/false",
                localStatusPageEnabled: false
            )

            let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state-stop.json", isDirectory: false))
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-stop", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
            try await withRunningAgent(service: service) {
                let client = OrchardAPIClient(baseURL: context.baseURL, accessKey: context.accessKey)
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

    func testCodexSessionsCanBeListedReadInterruptedAndContinued() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let codexBinary = try makeFakeCodexBinary(in: sandbox.root, workspace: workspace)

        try await withRunningControlPlane(in: sandbox.root) { context in
            let config = ResolvedAgentConfig(
                serverURL: context.baseURL,
                enrollmentToken: context.token,
                deviceID: "test-mac-codex-01",
                deviceName: "Test Mac Codex",
                hostName: "test-mac-codex-01",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
                ],
                heartbeatIntervalSeconds: 1,
                codexBinaryPath: codexBinary.path,
                localStatusPageEnabled: false
            )

            let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state-codex.json", isDirectory: false))
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-codex", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
            try await withRunningAgent(service: service) {
                let client = OrchardAPIClient(baseURL: context.baseURL, accessKey: context.accessKey)
                _ = try await poll(timeout: 10) {
                    let devices = try await client.fetchDevices()
                    return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
                }

                let sessions = try await poll(timeout: 10) {
                    let sessions = try await client.fetchCodexSessions(deviceID: config.deviceID, limit: 10)
                    return sessions.isEmpty ? nil : sessions
                }

                XCTAssertEqual(sessions.count, 1)
                XCTAssertEqual(sessions[0].deviceID, config.deviceID)
                XCTAssertEqual(sessions[0].state, .running)
                XCTAssertEqual(sessions[0].workspaceID, "main")

                let detail = try await client.fetchCodexSessionDetail(deviceID: config.deviceID, sessionID: sessions[0].id)
                XCTAssertEqual(detail.session.state, .running)
                XCTAssertEqual(detail.session.workspaceID, "main")
                XCTAssertFalse(detail.items.isEmpty)

                let interrupted = try await client.interruptCodexSession(deviceID: config.deviceID, sessionID: sessions[0].id)
                XCTAssertEqual(interrupted.session.state, .interrupted)
                XCTAssertEqual(interrupted.session.workspaceID, "main")

                let continued = try await client.continueCodexSession(
                    deviceID: config.deviceID,
                    sessionID: sessions[0].id,
                    prompt: "继续把移动端远程操控部分做完"
                )
                XCTAssertEqual(continued.session.state, .running)
                XCTAssertEqual(continued.session.workspaceID, "main")
                XCTAssertTrue(continued.session.lastUserMessage?.contains("移动端远程操控") == true)
            }
        }
    }

    func testRunningTaskSurvivesAgentRestartAndCanReattachLogs() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        try await withRunningControlPlane(in: sandbox.root) { context in
            let config = ResolvedAgentConfig(
                serverURL: context.baseURL,
                enrollmentToken: context.token,
                deviceID: "test-mac-reattach-01",
                deviceName: "Test Mac Reattach",
                hostName: "test-mac-reattach-01",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
                ],
                heartbeatIntervalSeconds: 1,
                codexBinaryPath: "/usr/bin/false",
                localStatusPageEnabled: false
            )

            let stateURL = sandbox.root.appendingPathComponent("agent-state-reattach.json", isDirectory: false)
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-reattach", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let client = OrchardAPIClient(baseURL: context.baseURL, accessKey: context.accessKey)

            let firstService = OrchardAgentService(
                config: config,
                stateStore: AgentStateStore(url: stateURL),
                tasksDirectory: tasksDirectory
            )
            let task = try await withRunningAgent(service: firstService) {
                _ = try await poll(timeout: 10) {
                    let devices = try await client.fetchDevices()
                    return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
                }

                let task = try await client.createTask(CreateTaskRequest(
                    title: "reattach-me",
                    kind: .shell,
                    workspaceID: "main",
                    payload: .shell(ShellTaskPayload(command: "trap 'exit 0' TERM; i=0; while true; do echo tick-$i; i=$((i+1)); sleep 1; done"))
                ))

                _ = try await poll(timeout: 10) {
                    let detail = try await client.fetchTaskDetail(taskID: task.id)
                    return detail.task.status == .running && detail.logs.contains(where: { $0.line == "tick-0" }) ? detail : nil
                }

                return task
            }

            let secondService = OrchardAgentService(
                config: config,
                stateStore: AgentStateStore(url: stateURL),
                tasksDirectory: tasksDirectory
            )

            try await withRunningAgent(service: secondService) {
                let reattached: TaskDetail = try await poll(timeout: 12) {
                    let detail = try await client.fetchTaskDetail(taskID: task.id)
                    guard detail.task.status == .running else { return nil }
                    let tickNumbers = detail.logs.compactMap { line -> Int? in
                        guard line.line.hasPrefix("tick-") else { return nil }
                        return Int(line.line.replacingOccurrences(of: "tick-", with: ""))
                    }
                    return (tickNumbers.max() ?? -1) >= 2 ? detail : nil
                }

                XCTAssertEqual(reattached.task.status, .running)
                XCTAssertTrue(reattached.logs.contains(where: { $0.line == "tick-0" }))
                XCTAssertTrue(reattached.logs.contains(where: { $0.line == "tick-2" }))

                _ = try await client.stopTask(taskID: task.id, reason: "reattach stop")

                let cancelled = try await poll(timeout: 15) {
                    let detail = try await client.fetchTaskDetail(taskID: task.id)
                    return detail.task.status == .cancelled ? detail : nil
                }

                XCTAssertEqual(cancelled.task.status, .cancelled)
            }
        }
    }

    func testStopRequestIsReplayedAfterControlPlaneReconnect() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let port = try reserveLocalPort()
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        var controlPlane = try await startControlPlane(in: sandbox.root, port: port)

        let config = ResolvedAgentConfig(
            serverURL: baseURL,
            enrollmentToken: controlPlane.token,
            deviceID: "test-mac-reconnect-stop-01",
            deviceName: "Test Mac Reconnect Stop",
            hostName: "test-mac-reconnect-stop-01",
            maxParallelTasks: 1,
            workspaceRoots: [
                WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
            ],
            heartbeatIntervalSeconds: 1,
            codexBinaryPath: "/usr/bin/false",
            localStatusPageEnabled: false
        )

        let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state-reconnect-stop.json", isDirectory: false))
        let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-reconnect-stop", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

        let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
        let client = OrchardAPIClient(baseURL: baseURL, accessKey: controlPlane.accessKey)
        let agentTask = Task {
            try await service.run()
        }

        do {
            _ = try await poll(timeout: 10) {
                let devices = try await client.fetchDevices()
                return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
            }

            let task = try await client.createTask(CreateTaskRequest(
                title: "reconnect-stop",
                kind: .shell,
                workspaceID: "main",
                payload: .shell(ShellTaskPayload(command: "trap 'exit 0' TERM; i=0; while true; do echo tick-$i; i=$((i+1)); sleep 1; done"))
            ))

            let _: TaskDetail = try await poll(timeout: 10) {
                let detail = try await client.fetchTaskDetail(taskID: task.id)
                guard detail.task.status == .running else { return nil }
                return detail.logs.contains(where: { $0.line == "tick-0" }) ? detail : nil
            }

            try await controlPlane.app.asyncShutdown()
            try await Task.sleep(nanoseconds: 1_700_000_000)

            controlPlane = try await startControlPlane(in: sandbox.root, port: port)
            _ = try await client.stopTask(taskID: task.id, reason: "disconnect stop")

            let cancelled = try await poll(timeout: 15) {
                let detail = try await client.fetchTaskDetail(taskID: task.id)
                return detail.task.status == .cancelled ? detail : nil
            }

            XCTAssertEqual(cancelled.task.status, .cancelled)
            XCTAssertEqual(cancelled.task.summary, "Task cancelled after stop request.")
            XCTAssertTrue(cancelled.logs.contains(where: { $0.line == "tick-0" }))

            await service.stop()
            agentTask.cancel()
            _ = await agentTask.result
            try await controlPlane.app.asyncShutdown()
        } catch {
            await service.stop()
            agentTask.cancel()
            _ = await agentTask.result
            try? await controlPlane.app.asyncShutdown()
            throw error
        }
    }

    func testManagedCodexProgressIsReplayedAfterControlPlaneReconnect() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let codexBinary = try makeReconnectManagedRunFakeCodexBinary(in: sandbox.root, workspace: workspace)

        let port = try reserveLocalPort()
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!
        var controlPlane = try await startControlPlane(in: sandbox.root, port: port)

        let config = ResolvedAgentConfig(
            serverURL: baseURL,
            enrollmentToken: controlPlane.token,
            deviceID: "test-mac-reconnect-managed-01",
            deviceName: "Test Mac Reconnect Managed",
            hostName: "test-mac-reconnect-managed-01",
            maxParallelTasks: 1,
            workspaceRoots: [
                WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
            ],
            heartbeatIntervalSeconds: 1,
            codexBinaryPath: codexBinary.executableURL.path,
            localStatusPageEnabled: false
        )

        let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state-reconnect-managed.json", isDirectory: false))
        let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-reconnect-managed", isDirectory: true)
        try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

        let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
        let client = OrchardAPIClient(baseURL: baseURL, accessKey: controlPlane.accessKey)
        let agentTask = Task {
            try await service.run()
        }

        do {
            _ = try await poll(timeout: 10) {
                let devices = try await client.fetchDevices()
                return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
            }

            let run = try await client.createManagedRun(CreateManagedRunRequest(
                title: "managed-reconnect",
                workspaceID: "main",
                driver: .codexCLI,
                prompt: "先把断连恢复状态同步补齐"
            ))

            _ = try await poll(timeout: 10) {
                let detail = try await client.fetchManagedRunDetail(runID: run.id)
                return detail.run.status == .running ? detail : nil
            }

            try await controlPlane.app.asyncShutdown()
            try await Task.sleep(nanoseconds: 1_700_000_000)

            controlPlane = try await startControlPlane(in: sandbox.root, port: port)

            let waiting = try await poll(timeout: 15) {
                let detail = try await client.fetchManagedRunDetail(runID: run.id)
                return detail.run.status == .waitingInput ? detail : nil
            }

            XCTAssertEqual(waiting.run.status, .waitingInput)
            XCTAssertTrue(waiting.run.summary?.contains("确认") == true)
            XCTAssertFalse(waiting.run.codexSessionID?.isEmpty ?? true)

            _ = try await client.stopManagedRun(runID: run.id, reason: "cleanup")

            let cancelled = try await poll(timeout: 15) {
                let detail = try await client.fetchManagedRunDetail(runID: run.id)
                return detail.run.status == .cancelled ? detail : nil
            }
            XCTAssertEqual(cancelled.run.status, .cancelled)

            await service.stop()
            agentTask.cancel()
            _ = await agentTask.result
            try await controlPlane.app.asyncShutdown()
        } catch {
            await service.stop()
            agentTask.cancel()
            _ = await agentTask.result
            try? await controlPlane.app.asyncShutdown()
            throw error
        }
    }

    func testManagedCodexRunCanContinueAndInterrupt() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let projectID = "managed-run-integration-\(UUID().uuidString.lowercased())"
        try writeProjectContextFixture(in: workspace, projectID: projectID)
        let codexBinary = try makeManagedRunFakeCodexBinary(in: sandbox.root, workspace: workspace)

        try await withRunningControlPlane(in: sandbox.root) { context in
            let config = ResolvedAgentConfig(
                serverURL: context.baseURL,
                enrollmentToken: context.token,
                deviceID: "test-mac-managed-run-01",
                deviceName: "Test Mac Managed Run",
                hostName: "test-mac-managed-run-01",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
                ],
                heartbeatIntervalSeconds: 1,
                codexBinaryPath: codexBinary.executableURL.path,
                localStatusPageEnabled: false
            )

            let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state-managed-run.json", isDirectory: false))
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-managed-run", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
            try await withRunningAgent(service: service) {
                let client = OrchardAPIClient(baseURL: context.baseURL, accessKey: context.accessKey)
                _ = try await poll(timeout: 10) {
                    let devices = try await client.fetchDevices()
                    return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
                }

                let firstRun = try await client.createManagedRun(CreateManagedRunRequest(
                    title: "继续移动端控制",
                    workspaceID: "main",
                    driver: .codexCLI,
                    prompt: "先把移动端远程控制入口搭起来"
                ))

                let waitingDetail: ManagedRunDetail = try await poll(timeout: 15) {
                    let detail = try await client.fetchManagedRunDetail(runID: firstRun.id)
                    guard detail.run.status == .waitingInput, detail.run.codexSessionID != nil else {
                        return nil
                    }
                    return detail
                }

                XCTAssertEqual(waitingDetail.run.status, .waitingInput)
                XCTAssertFalse(waitingDetail.run.codexSessionID?.isEmpty ?? true)
                XCTAssertEqual(waitingDetail.run.lastUserPrompt, "先把移动端远程控制入口搭起来")

                let fakeState = try loadManagedRunFakeCodexState(from: codexBinary.stateURL)
                let firstPrompt = try XCTUnwrap(fakeState.threads.values.first?.lastPrompt)
                XCTAssertTrue(firstPrompt.contains("<<<ORCHARD_PROJECT_CONTEXT>>>"))
                XCTAssertTrue(firstPrompt.contains(projectID))
                XCTAssertTrue(firstPrompt.contains("orchard-control-plane"))
                XCTAssertTrue(firstPrompt.contains("<<<ORCHARD_USER_TASK>>>"))
                XCTAssertTrue(firstPrompt.contains("先把移动端远程控制入口搭起来"))

                let continued = try await client.continueManagedRun(
                    runID: firstRun.id,
                    prompt: "继续把移动端控制链路做完"
                )
                XCTAssertEqual(continued.run.id, firstRun.id)
                XCTAssertTrue(continued.run.lastUserPrompt?.contains("移动端控制链路") == true)

                let succeeded: ManagedRunDetail = try await poll(timeout: 15) {
                    let detail = try await client.fetchManagedRunDetail(runID: firstRun.id)
                    return detail.run.status == .succeeded ? detail : nil
                }

                XCTAssertEqual(succeeded.run.status, .succeeded)
                XCTAssertTrue(succeeded.run.lastAssistantPreview?.contains("完成") == true)
                XCTAssertFalse(succeeded.logs.isEmpty)

                if let taskID = succeeded.run.taskID {
                    let taskDetail = try await poll(timeout: 10) {
                        let detail = try await client.fetchTaskDetail(taskID: taskID)
                        return detail.task.status == .succeeded ? detail : nil
                    }
                    XCTAssertEqual(taskDetail.task.status, .succeeded)
                } else {
                    XCTFail("managed run 缺少 taskID")
                }

                let secondRun = try await client.createManagedRun(CreateManagedRunRequest(
                    title: "中断移动端控制",
                    workspaceID: "main",
                    driver: .codexCLI,
                    prompt: "先起一个可中断的移动端控制 run"
                ))

                let secondWaitingDetail: ManagedRunDetail = try await poll(timeout: 15) {
                    let detail = try await client.fetchManagedRunDetail(runID: secondRun.id)
                    guard detail.run.status == .waitingInput, detail.run.codexSessionID != nil else {
                        return nil
                    }
                    return detail
                }
                XCTAssertEqual(secondWaitingDetail.run.status, .waitingInput)

                let interrupted = try await client.interruptManagedRun(runID: secondRun.id)
                XCTAssertEqual(interrupted.run.id, secondRun.id)

                let interruptedDetail: ManagedRunDetail = try await poll(timeout: 15) {
                    let detail = try await client.fetchManagedRunDetail(runID: secondRun.id)
                    return detail.run.status == .interrupted ? detail : nil
                }

                XCTAssertEqual(interruptedDetail.run.status, .interrupted)
                XCTAssertTrue(interruptedDetail.run.lastAssistantPreview?.contains("中断") == true)

                if let taskID = interruptedDetail.run.taskID {
                    let taskDetail = try await poll(timeout: 10) {
                        let detail = try await client.fetchTaskDetail(taskID: taskID)
                        return detail.task.status == .cancelled ? detail : nil
                    }
                    XCTAssertEqual(taskDetail.task.status, .cancelled)
                } else {
                    XCTFail("managed run 缺少 taskID")
                }
            }
        }
    }

    func testProjectContextSummaryCanBeFetchedThroughControlPlaneAPI() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let projectID = "project-context-summary-\(UUID().uuidString.lowercased())"
        try writeProjectContextFixture(in: workspace, projectID: projectID)

        try await withRunningControlPlane(in: sandbox.root) { context in
            let config = ResolvedAgentConfig(
                serverURL: context.baseURL,
                enrollmentToken: context.token,
                deviceID: "test-mac-project-context-01",
                deviceName: "Test Mac Project Context",
                hostName: "test-mac-project-context-01",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
                ],
                heartbeatIntervalSeconds: 1,
                codexBinaryPath: "/usr/bin/false",
                localStatusPageEnabled: false
            )

            let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state-project-context.json", isDirectory: false))
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-project-context", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
            try await withRunningAgent(service: service) {
                let client = OrchardAPIClient(baseURL: context.baseURL, accessKey: context.accessKey)
                _ = try await poll(timeout: 10) {
                    let devices = try await client.fetchDevices()
                    return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
                }

                let response = try await client.fetchProjectContextSummary(
                    deviceID: config.deviceID,
                    workspaceID: "main"
                )

                XCTAssertTrue(response.available)
                XCTAssertNil(response.errorMessage)
                XCTAssertEqual(response.workspaceID, "main")
                XCTAssertEqual(response.summary?.projectID, projectID)
                XCTAssertEqual(response.summary?.workspaceID, "main")
                XCTAssertEqual(response.summary?.projectName, "Managed Run Integration")
                XCTAssertTrue(response.summary?.renderedLines.contains(where: { $0.contains("orchard-control-plane") }) == true)
            }
        }
    }

    func testProjectContextLookupCanBeFetchedThroughControlPlaneAPI() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try writeProjectContextFixture(in: workspace, projectID: "project-context-lookup-\(UUID().uuidString.lowercased())")

        try await withRunningControlPlane(in: sandbox.root) { context in
            let config = ResolvedAgentConfig(
                serverURL: context.baseURL,
                enrollmentToken: context.token,
                deviceID: "test-mac-project-context-lookup-01",
                deviceName: "Test Mac Project Context Lookup",
                hostName: "test-mac-project-context-lookup-01",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
                ],
                heartbeatIntervalSeconds: 1,
                codexBinaryPath: "/usr/bin/false",
                localStatusPageEnabled: false
            )

            let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state-project-context-lookup.json", isDirectory: false))
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-project-context-lookup", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
            try await withRunningAgent(service: service) {
                let client = OrchardAPIClient(baseURL: context.baseURL, accessKey: context.accessKey)
                _ = try await poll(timeout: 10) {
                    let devices = try await client.fetchDevices()
                    return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
                }

                let serviceLookup = try await client.lookupProjectContext(
                    deviceID: config.deviceID,
                    workspaceID: "main",
                    subject: .service,
                    selector: "orchard-control-plane"
                )

                XCTAssertTrue(serviceLookup.available)
                XCTAssertEqual(serviceLookup.lookup?.subject.rawValue, ProjectContextRemoteSubject.service.rawValue)
                XCTAssertEqual(serviceLookup.lookup?.selector, "orchard-control-plane")
                XCTAssertTrue(serviceLookup.lookup?.renderedLines.contains(where: { $0.contains("/home/owenadmin/Orchard") }) == true)
                XCTAssertTrue(serviceLookup.lookup?.payloadJSON?.contains("\"service\"") == true)

                let hostLookup = try await client.lookupProjectContext(
                    deviceID: config.deviceID,
                    workspaceID: "main",
                    subject: .host,
                    selector: "aliyun-hangzhou-main"
                )

                XCTAssertTrue(hostLookup.available)
                XCTAssertEqual(hostLookup.lookup?.subject.rawValue, ProjectContextRemoteSubject.host.rawValue)
                XCTAssertTrue(hostLookup.lookup?.renderedLines.contains(where: { $0.contains("阿里云主机") }) == true)

                let commandLookup = try await client.lookupProjectContext(
                    deviceID: config.deviceID,
                    workspaceID: "main",
                    subject: .command,
                    selector: "deploy-control-plane"
                )

                XCTAssertTrue(commandLookup.available)
                XCTAssertEqual(commandLookup.lookup?.subject.rawValue, ProjectContextRemoteSubject.command.rawValue)
                XCTAssertTrue(commandLookup.lookup?.renderedLines.contains(where: { $0.contains("部署控制面") }) == true)
                XCTAssertTrue(commandLookup.lookup?.payloadJSON?.contains("\"command\"") == true)
            }
        }
    }

    func testProjectContextSummaryReturnsUnavailableWhenWorkspaceHasNoDefinition() async throws {
        let sandbox = try makeTemporarySandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let workspace = sandbox.root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        try await withRunningControlPlane(in: sandbox.root) { context in
            let config = ResolvedAgentConfig(
                serverURL: context.baseURL,
                enrollmentToken: context.token,
                deviceID: "test-mac-project-context-empty-01",
                deviceName: "Test Mac Project Context Empty",
                hostName: "test-mac-project-context-empty-01",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)
                ],
                heartbeatIntervalSeconds: 1,
                codexBinaryPath: "/usr/bin/false",
                localStatusPageEnabled: false
            )

            let stateStore = AgentStateStore(url: sandbox.root.appendingPathComponent("agent-state-project-context-empty.json", isDirectory: false))
            let tasksDirectory = sandbox.root.appendingPathComponent("agent-tasks-project-context-empty", isDirectory: true)
            try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)

            let service = OrchardAgentService(config: config, stateStore: stateStore, tasksDirectory: tasksDirectory)
            try await withRunningAgent(service: service) {
                let client = OrchardAPIClient(baseURL: context.baseURL, accessKey: context.accessKey)
                _ = try await poll(timeout: 10) {
                    let devices = try await client.fetchDevices()
                    return devices.first(where: { $0.deviceID == config.deviceID && $0.status == .online })
                }

                let response = try await client.fetchProjectContextSummary(
                    deviceID: config.deviceID,
                    workspaceID: "main"
                )

                XCTAssertFalse(response.available)
                XCTAssertNil(response.summary)
                XCTAssertNil(response.lookup)
                XCTAssertNil(response.errorMessage)
            }
        }
    }
}

private struct IntegrationContext {
    var app: Application
    var baseURL: URL
    var token: String
    var accessKey: String
}

private struct Sandbox {
    var root: URL
}

private func startControlPlane(in root: URL, port: Int = 0) async throws -> IntegrationContext {
    let token = "orchard-integration-token"
    let accessKey = "orchard-integration-access"
    let dataDirectory = root.appendingPathComponent("control-plane-data", isDirectory: true)
    try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)

    return try await withEnvironment([
        "ORCHARD_DATA_DIR": dataDirectory.path,
        "ORCHARD_ENROLLMENT_TOKEN": token,
        "ORCHARD_ACCESS_KEY": accessKey,
        "ORCHARD_BIND": "127.0.0.1",
        "ORCHARD_PORT": String(port),
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
            token: token,
            accessKey: accessKey
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

private func reserveLocalPort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw NSError(domain: "OrchardIntegrationTests", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Failed to allocate a local TCP socket.",
        ])
    }
    defer { close(descriptor) }

    var value: Int32 = 1
    guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw NSError(domain: "OrchardIntegrationTests", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Failed to configure the local TCP socket.",
        ])
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(0).bigEndian
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            Darwin.bind(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        throw NSError(domain: "OrchardIntegrationTests", code: 5, userInfo: [
            NSLocalizedDescriptionKey: "Failed to bind a local TCP socket.",
        ])
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer -> Int32 in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
            getsockname(descriptor, rebound, &length)
        }
    }
    guard nameResult == 0 else {
        throw NSError(domain: "OrchardIntegrationTests", code: 6, userInfo: [
            NSLocalizedDescriptionKey: "Failed to read the local TCP port.",
        ])
    }

    return Int(UInt16(bigEndian: boundAddress.sin_port))
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

private func makeFakeCodexBinary(in root: URL, workspace: URL) throws -> URL {
    let stateURL = root.appendingPathComponent("fake-codex-state.json", isDirectory: false)
    let scriptURL = root.appendingPathComponent("fake-codex", isDirectory: false)

    let initialState = """
    {
      "turn_id": "turn-current",
      "turn_status": "inProgress",
      "updated_at": 1773245000,
      "last_prompt": "帮我把 Codex 会话接到 Orchard 里",
      "assistant_message": "我正在整理移动端和控制面的连接方式。"
    }
    """
    try initialState.write(to: stateURL, atomically: true, encoding: .utf8)

    let script = """
    #!/usr/bin/env python3
    import json
    import os
    import sys

    STATE_PATH = \(pythonLiteral(stateURL.path))
    WORKSPACE = \(pythonLiteral(workspace.path))
    THREAD_ID = "session-test-001"

    def load_state():
        with open(STATE_PATH, "r", encoding="utf-8") as handle:
            return json.load(handle)

    def save_state(state):
        with open(STATE_PATH, "w", encoding="utf-8") as handle:
            json.dump(state, handle)

    def thread_payload(include_turns):
        state = load_state()
        turns = [
            {
                "id": "turn-base",
                "status": "completed",
                "error": None,
                "items": [
                    {
                        "id": "item-user-base",
                        "type": "userMessage",
                        "content": [{"type": "text", "text": "先把 Orchard 中文化"}]
                    },
                    {
                        "id": "item-agent-base",
                        "type": "agentMessage",
                        "phase": "final_answer",
                        "text": "中文化已经完成。"
                    }
                ]
            },
            {
                "id": state["turn_id"],
                "status": state["turn_status"],
                "error": None,
                "items": [
                    {
                        "id": "item-user-current",
                        "type": "userMessage",
                        "content": [{"type": "text", "text": state["last_prompt"]}]
                    },
                    {
                        "id": "item-agent-current",
                        "type": "agentMessage",
                        "phase": "commentary",
                        "text": state["assistant_message"]
                    }
                ]
            }
        ]
        return {
            "id": THREAD_ID,
            "preview": "我现在所有的任务都是基于 codex 来发起的。",
            "ephemeral": False,
            "modelProvider": "openai",
            "createdAt": 1773240000,
            "updatedAt": state["updated_at"],
            "status": {"type": "active" if state["turn_status"] == "inProgress" else "idle"},
            "path": os.path.join(WORKSPACE, "thread.jsonl"),
            "cwd": WORKSPACE,
            "cliVersion": "0.108.0-alpha.12",
            "source": "vscode",
            "name": "Orchard 远程控制",
            "turns": turns if include_turns else []
        }

    def send(identifier, result):
        payload = {"id": identifier, "result": result}
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

    def main():
        args = sys.argv[1:]
        if not args or args[0] != "app-server":
            sys.exit(1)

        experimental_enabled = False
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            message = json.loads(raw)
            method = message.get("method")
            params = message.get("params") or {}
            identifier = message.get("id")

            if method == "initialize":
                capabilities = params.get("capabilities") or {}
                if not capabilities.get("experimentalApi"):
                    sys.stdout.write(json.dumps({
                        "id": identifier,
                        "error": {"code": 400, "message": "experimentalApi capability is required"}
                    }, ensure_ascii=False) + "\\n")
                    sys.stdout.flush()
                    continue
                experimental_enabled = True
                send(identifier, {"userAgent": "fake-codex"})
            elif not experimental_enabled:
                sys.stdout.write(json.dumps({
                    "id": identifier,
                    "error": {"code": 400, "message": "initialize must enable experimentalApi"}
                }, ensure_ascii=False) + "\\n")
                sys.stdout.flush()
            elif method == "thread/list":
                send(identifier, {"data": [thread_payload(False)], "nextCursor": None})
            elif method == "thread/read":
                send(identifier, {"thread": thread_payload(True)})
            elif method == "thread/resume":
                send(identifier, {
                    "thread": thread_payload(True),
                    "approvalPolicy": "on-request",
                    "cwd": WORKSPACE,
                    "model": "gpt-5.4",
                    "modelProvider": "openai",
                    "sandbox": {"type": "workspaceWrite", "writableRoots": [WORKSPACE]}
                })
            elif method == "turn/start":
                state = load_state()
                text_input = ""
                for item in params.get("input", []):
                    if item.get("type") == "text":
                        text_input = item.get("text", "")
                        break
                state["turn_id"] = "turn-continued"
                state["turn_status"] = "inProgress"
                state["last_prompt"] = text_input
                state["assistant_message"] = "我继续处理远程控制部分。"
                state["updated_at"] += 1
                save_state(state)
                send(identifier, {"turn": {"id": state["turn_id"], "status": "inProgress", "items": [], "error": None}})
            elif method == "turn/interrupt":
                state = load_state()
                state["turn_status"] = "interrupted"
                state["assistant_message"] = "会话已被远程中断。"
                state["updated_at"] += 1
                save_state(state)
                send(identifier, {})
            else:
                sys.stdout.write(json.dumps({
                    "id": identifier,
                    "error": {"code": 400, "message": "unsupported method: " + str(method)}
                }, ensure_ascii=False) + "\\n")
                sys.stdout.flush()

    if __name__ == "__main__":
        main()
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
    return scriptURL
}

private struct ManagedRunFakeCodexBinary {
    var executableURL: URL
    var stateURL: URL
}

private struct ManagedRunFakeCodexState: Decodable {
    var threads: [String: ManagedRunFakeCodexThreadState]
}

private struct ManagedRunFakeCodexThreadState: Decodable {
    var lastPrompt: String

    private enum CodingKeys: String, CodingKey {
        case lastPrompt = "last_prompt"
    }
}

private func makeManagedRunFakeCodexBinary(in root: URL, workspace: URL) throws -> ManagedRunFakeCodexBinary {
    let stateURL = root.appendingPathComponent("managed-run-fake-codex-state.json", isDirectory: false)
    let scriptURL = root.appendingPathComponent("managed-run-fake-codex", isDirectory: false)

    try """
    {
      "next_thread": 1,
      "threads": {}
    }
    """.write(to: stateURL, atomically: true, encoding: .utf8)

    let script = """
    #!/usr/bin/env python3
    import json
    import os
    import sys

    STATE_PATH = \(pythonLiteral(stateURL.path))
    WORKSPACE = \(pythonLiteral(workspace.path))

    def load_state():
        with open(STATE_PATH, "r", encoding="utf-8") as handle:
            return json.load(handle)

    def save_state(state):
        with open(STATE_PATH, "w", encoding="utf-8") as handle:
            json.dump(state, handle)

    def status_payload(thread):
        if thread["thread_type"] == "active":
            return {"type": "active", "activeFlags": thread["active_flags"]}
        return {"type": "idle"}

    def turn_items(thread):
        return [
            {
                "id": f"{thread['turn_id']}-user",
                "type": "userMessage",
                "content": [{"type": "text", "text": thread["last_prompt"]}]
            },
            {
                "id": f"{thread['turn_id']}-agent",
                "type": "agentMessage",
                "phase": "final_answer" if thread["turn_status"] == "completed" else "commentary",
                "text": thread["assistant_message"]
            }
        ]

    def thread_payload(thread_id, thread, include_turns):
        if thread.get("pending_complete"):
            thread["reads_after_continue"] = thread.get("reads_after_continue", 0) + 1
            if thread["reads_after_continue"] >= 2:
                thread["pending_complete"] = False
                thread["reads_after_continue"] = 0
                thread["thread_type"] = "idle"
                thread["active_flags"] = []
                thread["turn_status"] = "completed"
                thread["assistant_message"] = "我继续处理远程控制链路，现已完成。"
                thread["updated_at"] += 1

        turns = []
        if include_turns and thread.get("turn_id"):
            turns.append({
                "id": thread["turn_id"],
                "status": thread["turn_status"],
                "error": None,
                "items": turn_items(thread)
            })

        return {
            "id": thread_id,
            "preview": thread["last_prompt"],
            "ephemeral": False,
            "modelProvider": "openai",
            "createdAt": thread["created_at"],
            "updatedAt": thread["updated_at"],
            "status": status_payload(thread),
            "path": os.path.join(WORKSPACE, thread_id + ".jsonl"),
            "cwd": WORKSPACE,
            "cliVersion": "0.108.0-alpha.12",
            "source": "appServer",
            "name": thread["name"],
            "turns": turns
        }

    def create_thread(state):
        index = state["next_thread"]
        state["next_thread"] += 1
        thread_id = f"managed-thread-{index:03d}"
        state["threads"][thread_id] = {
            "name": f"Managed Run {index}",
            "created_at": 1773250000 + index,
            "updated_at": 1773250000 + index,
            "turn_id": None,
            "turn_status": "completed",
            "thread_type": "idle",
            "active_flags": [],
            "last_prompt": "空白线程",
            "assistant_message": "",
            "pending_complete": False,
            "reads_after_continue": 0
        }
        return thread_id

    def send(identifier, result):
        sys.stdout.write(json.dumps({"id": identifier, "result": result}, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

    def main():
        args = sys.argv[1:]
        if not args or args[0] != "app-server":
            sys.exit(1)

        experimental_enabled = False
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            message = json.loads(raw)
            method = message.get("method")
            params = message.get("params") or {}
            identifier = message.get("id")
            state = load_state()

            if method == "initialize":
                capabilities = params.get("capabilities") or {}
                if not capabilities.get("experimentalApi"):
                    sys.stdout.write(json.dumps({
                        "id": identifier,
                        "error": {"code": 400, "message": "experimentalApi capability is required"}
                    }, ensure_ascii=False) + "\\n")
                    sys.stdout.flush()
                    continue
                experimental_enabled = True
                send(identifier, {"userAgent": "managed-run-fake-codex"})
                continue

            if not experimental_enabled:
                sys.stdout.write(json.dumps({
                    "id": identifier,
                    "error": {"code": 400, "message": "initialize must enable experimentalApi"}
                }, ensure_ascii=False) + "\\n")
                sys.stdout.flush()
                continue

            if method == "thread/start":
                thread_id = create_thread(state)
                save_state(state)
                send(identifier, {"thread": thread_payload(thread_id, state["threads"][thread_id], False)})
                continue

            if method == "thread/list":
                data = [
                    thread_payload(thread_id, thread, False)
                    for thread_id, thread in sorted(state["threads"].items())
                ]
                save_state(state)
                send(identifier, {"data": data, "nextCursor": None})
                continue

            thread_id = params.get("threadId")
            thread = state["threads"].get(thread_id)
            if thread is None:
                sys.stdout.write(json.dumps({
                    "id": identifier,
                    "error": {"code": 404, "message": "thread not found"}
                }, ensure_ascii=False) + "\\n")
                sys.stdout.flush()
                continue

            if method == "turn/start":
                text_input = ""
                for item in params.get("input", []):
                    if item.get("type") == "text":
                        text_input = item.get("text", "")
                        break
                thread["turn_id"] = thread["turn_id"] or f"{thread_id}-turn-001"
                thread["turn_status"] = "inProgress"
                thread["thread_type"] = "active"
                thread["active_flags"] = ["waitingOnUserInput"]
                thread["last_prompt"] = text_input
                thread["assistant_message"] = "请确认是否继续开放移动端远程控制。"
                thread["pending_complete"] = False
                thread["reads_after_continue"] = 0
                thread["updated_at"] += 1
                save_state(state)
                send(identifier, {"turn": {"id": thread["turn_id"], "status": "inProgress", "items": [], "error": None}})
            elif method == "thread/read":
                payload = thread_payload(thread_id, thread, True)
                save_state(state)
                send(identifier, {"thread": payload})
            elif method == "thread/resume":
                payload = thread_payload(thread_id, thread, True)
                save_state(state)
                send(identifier, {
                    "thread": payload,
                    "approvalPolicy": "never",
                    "cwd": WORKSPACE,
                    "model": "gpt-5.4",
                    "modelProvider": "openai",
                    "sandbox": {"type": "workspaceWrite", "writableRoots": [WORKSPACE], "readOnlyAccess": {"type": "full-access"}, "networkAccess": True, "excludeTmpdirEnvVar": False, "excludeSlashTmp": False}
                })
            elif method == "turn/steer":
                text_input = ""
                for item in params.get("input", []):
                    if item.get("type") == "text":
                        text_input = item.get("text", "")
                        break
                thread["turn_status"] = "inProgress"
                thread["thread_type"] = "active"
                thread["active_flags"] = []
                thread["last_prompt"] = text_input
                thread["assistant_message"] = "我继续处理远程控制链路。"
                thread["pending_complete"] = True
                thread["reads_after_continue"] = 0
                thread["updated_at"] += 1
                save_state(state)
                send(identifier, {"turnId": thread["turn_id"]})
            elif method == "turn/interrupt":
                thread["turn_status"] = "interrupted"
                thread["thread_type"] = "idle"
                thread["active_flags"] = []
                thread["assistant_message"] = "会话已被远程中断。"
                thread["pending_complete"] = False
                thread["reads_after_continue"] = 0
                thread["updated_at"] += 1
                save_state(state)
                send(identifier, {})
            else:
                sys.stdout.write(json.dumps({
                    "id": identifier,
                    "error": {"code": 400, "message": "unsupported method: " + str(method)}
                }, ensure_ascii=False) + "\\n")
                sys.stdout.flush()

    if __name__ == "__main__":
        main()
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
    return ManagedRunFakeCodexBinary(executableURL: scriptURL, stateURL: stateURL)
}

private func makeReconnectManagedRunFakeCodexBinary(in root: URL, workspace: URL) throws -> ManagedRunFakeCodexBinary {
    let stateURL = root.appendingPathComponent("reconnect-managed-run-fake-codex-state.json", isDirectory: false)
    let scriptURL = root.appendingPathComponent("reconnect-managed-run-fake-codex", isDirectory: false)

    try """
    {
      "next_thread": 1,
      "threads": {}
    }
    """.write(to: stateURL, atomically: true, encoding: .utf8)

    let script = """
    #!/usr/bin/env python3
    import json
    import os
    import sys

    STATE_PATH = \(pythonLiteral(stateURL.path))
    WORKSPACE = \(pythonLiteral(workspace.path))

    def load_state():
        with open(STATE_PATH, "r", encoding="utf-8") as handle:
            return json.load(handle)

    def save_state(state):
        with open(STATE_PATH, "w", encoding="utf-8") as handle:
            json.dump(state, handle)

    def status_payload(thread):
        if thread["thread_type"] == "active":
            return {"type": "active", "activeFlags": thread["active_flags"]}
        return {"type": "idle", "activeFlags": []}

    def turn_items(thread):
        return [
            {
                "id": f"{thread['turn_id']}-user",
                "type": "userMessage",
                "content": [{"type": "text", "text": thread["last_prompt"]}]
            },
            {
                "id": f"{thread['turn_id']}-agent",
                "type": "agentMessage",
                "phase": "commentary" if thread["turn_status"] == "inProgress" else "final_answer",
                "text": thread["assistant_message"]
            }
        ]

    def maybe_transition_to_waiting(thread):
        if not thread.get("pending_waiting"):
            return
        thread["read_count"] += 1
        if thread["read_count"] >= 3:
            thread["pending_waiting"] = False
            thread["thread_type"] = "active"
            thread["active_flags"] = ["waitingOnUserInput"]
            thread["assistant_message"] = "请确认是否继续开放 Orchard 直发 Codex。"
            thread["updated_at"] += 1

    def thread_payload(thread_id, thread, include_turns):
        maybe_transition_to_waiting(thread)
        turns = []
        if include_turns and thread.get("turn_id"):
            turns.append({
                "id": thread["turn_id"],
                "status": thread["turn_status"],
                "error": None,
                "items": turn_items(thread)
            })

        return {
            "id": thread_id,
            "preview": thread["last_prompt"],
            "ephemeral": False,
            "modelProvider": "openai",
            "createdAt": thread["created_at"],
            "updatedAt": thread["updated_at"],
            "status": status_payload(thread),
            "path": os.path.join(WORKSPACE, thread_id + ".jsonl"),
            "cwd": WORKSPACE,
            "cliVersion": "0.108.0-alpha.12",
            "source": "appServer",
            "name": thread["name"],
            "turns": turns
        }

    def create_thread(state):
        index = state["next_thread"]
        state["next_thread"] += 1
        thread_id = f"reconnect-thread-{index:03d}"
        state["threads"][thread_id] = {
            "name": f"Reconnect Run {index}",
            "created_at": 1773260000 + index,
            "updated_at": 1773260000 + index,
            "turn_id": None,
            "turn_status": "completed",
            "thread_type": "idle",
            "active_flags": [],
            "last_prompt": "空白线程",
            "assistant_message": "",
            "pending_waiting": False,
            "read_count": 0
        }
        return thread_id

    def send(identifier, result):
        sys.stdout.write(json.dumps({"id": identifier, "result": result}, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

    def main():
        args = sys.argv[1:]
        if not args or args[0] != "app-server":
            sys.exit(1)

        experimental_enabled = False
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            message = json.loads(raw)
            method = message.get("method")
            params = message.get("params") or {}
            identifier = message.get("id")
            state = load_state()

            if method == "initialize":
                capabilities = params.get("capabilities") or {}
                if not capabilities.get("experimentalApi"):
                    sys.stdout.write(json.dumps({
                        "id": identifier,
                        "error": {"code": 400, "message": "experimentalApi capability is required"}
                    }, ensure_ascii=False) + "\\n")
                    sys.stdout.flush()
                    continue
                experimental_enabled = True
                send(identifier, {"userAgent": "reconnect-managed-run-fake-codex"})
                continue

            if not experimental_enabled:
                sys.stdout.write(json.dumps({
                    "id": identifier,
                    "error": {"code": 400, "message": "initialize must enable experimentalApi"}
                }, ensure_ascii=False) + "\\n")
                sys.stdout.flush()
                continue

            if method == "thread/start":
                thread_id = create_thread(state)
                save_state(state)
                send(identifier, {"thread": thread_payload(thread_id, state["threads"][thread_id], False)})
                continue

            thread_id = params.get("threadId")
            thread = state["threads"].get(thread_id)
            if thread is None:
                sys.stdout.write(json.dumps({
                    "id": identifier,
                    "error": {"code": 404, "message": "thread not found"}
                }, ensure_ascii=False) + "\\n")
                sys.stdout.flush()
                continue

            if method == "turn/start":
                text_input = ""
                for item in params.get("input", []):
                    if item.get("type") == "text":
                        text_input = item.get("text", "")
                        break
                thread["turn_id"] = thread["turn_id"] or f"{thread_id}-turn-001"
                thread["turn_status"] = "inProgress"
                thread["thread_type"] = "active"
                thread["active_flags"] = []
                thread["last_prompt"] = text_input
                thread["assistant_message"] = "我正在处理 Orchard 断连恢复。"
                thread["pending_waiting"] = True
                thread["read_count"] = 0
                thread["updated_at"] += 1
                save_state(state)
                send(identifier, {"turn": {"id": thread["turn_id"], "status": "inProgress", "items": [], "error": None}})
            elif method == "thread/read":
                payload = thread_payload(thread_id, thread, True)
                save_state(state)
                send(identifier, {"thread": payload})
            elif method == "thread/resume":
                payload = thread_payload(thread_id, thread, True)
                save_state(state)
                send(identifier, {
                    "thread": payload,
                    "approvalPolicy": "never",
                    "cwd": WORKSPACE,
                    "model": "gpt-5.4",
                    "modelProvider": "openai",
                    "sandbox": {"type": "workspaceWrite", "writableRoots": [WORKSPACE], "readOnlyAccess": {"type": "full-access"}, "networkAccess": True, "excludeTmpdirEnvVar": False, "excludeSlashTmp": False}
                })
            elif method == "turn/interrupt":
                thread["turn_status"] = "interrupted"
                thread["thread_type"] = "idle"
                thread["active_flags"] = []
                thread["assistant_message"] = "会话已被停止。"
                thread["pending_waiting"] = False
                thread["read_count"] = 0
                thread["updated_at"] += 1
                save_state(state)
                send(identifier, {})
            else:
                sys.stdout.write(json.dumps({
                    "id": identifier,
                    "error": {"code": 400, "message": "unsupported method: " + str(method)}
                }, ensure_ascii=False) + "\\n")
                sys.stdout.flush()

    if __name__ == "__main__":
        main()
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
    return ManagedRunFakeCodexBinary(executableURL: scriptURL, stateURL: stateURL)
}

private func loadManagedRunFakeCodexState(from url: URL) throws -> ManagedRunFakeCodexState {
    try JSONDecoder().decode(ManagedRunFakeCodexState.self, from: Data(contentsOf: url))
}

private func writeProjectContextFixture(in workspace: URL, projectID: String) throws {
    let orchardDirectory = workspace.appendingPathComponent(".orchard", isDirectory: true)
    try FileManager.default.createDirectory(at: orchardDirectory, withIntermediateDirectories: true)

    let definition = ProjectContextFile(
        projectID: projectID,
        projectName: "Managed Run Integration",
        summary: "用于验证托管 Codex run 会自动收到项目上下文摘要。",
        repository: ProjectRepositoryInfo(
            gitRemote: "https://example.com/orchard.git",
            defaultBranch: "main",
            deployRunbook: "deploy/deploy-control-plane.sh"
        ),
        environments: [
            ProjectEnvironment(
                id: "production",
                name: "生产",
                deploymentPath: "/home/owenadmin/Orchard",
                hostIDs: ["aliyun-hangzhou-main"],
                serviceIDs: ["orchard-control-plane"],
                databaseIDs: ["control-plane-sqlite"],
                urls: [
                    ProjectEndpoint(label: "主站", url: "https://orchard.example.com"),
                    ProjectEndpoint(label: "健康检查", url: "https://orchard.example.com/health"),
                ]
            ),
        ],
        hosts: [
            ProjectHost(
                id: "aliyun-hangzhou-main",
                name: "阿里云主机",
                provider: "aliyun",
                region: "cn-hangzhou",
                publicAddress: "8.8.8.8",
                roles: ["deploy", "app", "database"]
            ),
        ],
        services: [
            ProjectService(
                id: "orchard-control-plane",
                name: "OrchardControlPlane",
                kind: "web",
                environmentIDs: ["production"],
                hostID: "aliyun-hangzhou-main",
                deployPath: "/home/owenadmin/Orchard",
                runbook: "deploy/deploy-control-plane.sh",
                healthURL: "https://orchard.example.com/health",
                configPath: "/home/owenadmin/orchard-config/control-plane.env",
                credentialIDs: ["orchard-control-plane-api"]
            ),
        ],
        databases: [
            ProjectDatabase(
                id: "control-plane-sqlite",
                name: "Control Plane SQLite",
                engine: "sqlite",
                environmentIDs: ["production"],
                hostID: "aliyun-hangzhou-main",
                storagePath: "/home/owenadmin/Orchard/data/control-plane.sqlite"
            ),
        ],
        commands: [
            ProjectCommand(
                id: "deploy-control-plane",
                name: "部署控制面",
                runner: "shell",
                command: "./deploy/deploy-control-plane.sh --env production",
                workingDirectory: "/Users/owen/MyCodeSpace/Orchard",
                environmentIDs: ["production"],
                hostID: "aliyun-hangzhou-main",
                serviceIDs: ["orchard-control-plane"],
                databaseIDs: ["control-plane-sqlite"]
            ),
        ],
        credentials: [
            ProjectCredentialRequirement(
                id: "orchard-control-plane-api",
                name: "控制面 API 密钥",
                kind: "apiKey",
                appliesToServiceIDs: ["orchard-control-plane"],
                fields: [
                    ProjectCredentialField(
                        key: "accessKey",
                        label: "控制面访问密钥",
                        required: true,
                        isSensitive: true
                    ),
                ]
            ),
        ]
    )

    try OrchardJSON.encoder
        .encode(definition)
        .write(to: orchardDirectory.appendingPathComponent("project-context.json"), options: .atomic)
}

private func pythonLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}
