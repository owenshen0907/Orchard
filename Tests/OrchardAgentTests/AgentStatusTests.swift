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
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Sources", isDirectory: true), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Tests", isDirectory: true), withIntermediateDirectories: true)
        try "# Orchard Workspace\n\n状态页专项验证。\n".write(
            to: workspace.appendingPathComponent("README.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try "# Orchard Sources\n\n本地任务卡片项目名。\n".write(
            to: workspace.appendingPathComponent("Sources/README.md", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

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
            relativePath: "Sources",
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
            cwd: workspace.appendingPathComponent("Sources", isDirectory: true).path,
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

        let finishedDirectory = tasksDirectory.appendingPathComponent("task-finished", isDirectory: true)
        try FileManager.default.createDirectory(at: finishedDirectory, withIntermediateDirectories: true)

        let finishedTask = TaskRecord(
            id: "task-finished",
            title: "快速结束的任务",
            kind: .codex,
            workspaceID: "main",
            relativePath: nil,
            priority: .normal,
            status: .running,
            payload: .codex(CodexTaskPayload(prompt: "输出一句话后结束")),
            preferredDeviceID: "mac-mini-01",
            assignedDeviceID: "mac-mini-01",
            createdAt: Date(timeIntervalSince1970: 90),
            updatedAt: Date(timeIntervalSince1970: 95),
            startedAt: Date(timeIntervalSince1970: 95)
        )
        try OrchardJSON.encoder.encode(finishedTask).write(
            to: finishedDirectory.appendingPathComponent("task.json", isDirectory: false),
            options: .atomic
        )

        let finishedRuntime = ManagedCodexRuntimeFixture(
            taskID: "task-finished",
            threadID: "thread-999",
            cwd: workspace.path,
            startedAt: Date(timeIntervalSince1970: 95),
            lastSeenAt: Date(timeIntervalSince1970: 130),
            stopRequested: false,
            pid: 9876,
            activeTurnID: nil,
            emittedTextLengths: [:],
            lastManagedRunStatus: .succeeded,
            lastUserPrompt: "输出一句话后结束",
            lastAssistantPreview: "已经输出完成"
        )
        try OrchardJSON.encoder.encode(finishedRuntime).write(
            to: finishedDirectory.appendingPathComponent("runtime.json", isDirectory: false),
            options: .atomic
        )

        FileManager.default.createFile(
            atPath: finishedDirectory.appendingPathComponent("combined.log", isDirectory: false).path,
            contents: Data("done".utf8)
        )

        var options = try AgentStatusOptions(
            configURL: configURL,
            stateURL: stateURL,
            tasksDirectoryURL: tasksDirectory,
            includeRemote: false
        )
        options.outputFormat = .text

        let snapshot = try await AgentStatusService(
            localCodexSessionsFetcher: { _, _ in
                [
                    CodexSessionSummary(
                        id: "thread-local-standalone",
                        deviceID: "mac-mini-01",
                        deviceName: "Mac Mini",
                        workspaceID: "main",
                        name: "直接在 Codex 打开的会话",
                        preview: "继续检查本地状态页为什么没有列出这条会话",
                        cwd: workspace.path,
                        source: "codex-app",
                        modelProvider: "openai",
                        createdAt: Date(timeIntervalSince1970: 96),
                        updatedAt: Date(timeIntervalSince1970: 140),
                        state: .idle,
                        lastTurnID: "turn-local",
                        lastTurnStatus: "completed",
                        lastUserMessage: "继续检查本地状态页为什么没有列出这条会话",
                        lastAssistantMessage: "已经准备好继续"
                    ),
                ]
            }
        ).snapshot(options: options)
        XCTAssertEqual(snapshot.deviceID, "mac-mini-01")
        XCTAssertEqual(snapshot.workspacePathOptions["main"], ["", "Sources", "Tests"])
        XCTAssertEqual(snapshot.workspaceProjects["main"]?.map(\.name), ["Orchard Workspace", "Orchard Sources", "Tests"])
        XCTAssertEqual(snapshot.local.activeTasks.count, 1)
        XCTAssertEqual(snapshot.local.recentTasks.count, 1)
        XCTAssertEqual(snapshot.local.codexSessions.count, 1)
        XCTAssertEqual(snapshot.local.pendingUpdates.count, 1)
        XCTAssertEqual(snapshot.local.activeTasks.first?.codexThreadID, "thread-123")
        XCTAssertEqual(snapshot.local.activeTasks.first?.managedRunStatus, .waitingInput)
        XCTAssertEqual(snapshot.local.activeTasks.first?.recentLogLines, ["hello"])
        XCTAssertEqual(snapshot.local.activeTasks.first?.project.name, "Orchard Sources")
        XCTAssertEqual(snapshot.local.activeTasks.first?.project.relativePath, "Sources")
        XCTAssertEqual(snapshot.local.recentTasks.first?.task.id, "task-finished")
        XCTAssertEqual(snapshot.local.recentTasks.first?.managedRunStatus, .succeeded)
        XCTAssertEqual(snapshot.local.recentTasks.first?.recentLogLines, ["done"])
        XCTAssertEqual(snapshot.local.recentTasks.first?.project.name, "Orchard Workspace")
        XCTAssertEqual(snapshot.local.codexSessions.first?.session.id, "thread-local-standalone")
        XCTAssertEqual(snapshot.local.codexSessions.first?.project.name, "Orchard Workspace")
        XCTAssertEqual(snapshot.remoteSkippedReason, "已按参数跳过远程状态读取。")

        let rendered = try AgentStatusRenderer.render(snapshot, format: .text)
        XCTAssertTrue(rendered.contains("检查控制面日志"))
        XCTAssertTrue(rendered.contains("thread-123"))
        XCTAssertTrue(rendered.contains("Orchard Sources"))
        XCTAssertTrue(rendered.contains("Orchard Workspace"))
        XCTAssertTrue(rendered.contains("直接在 Codex 打开的会话"))
        XCTAssertTrue(rendered.contains("最近本地任务"))
        XCTAssertTrue(rendered.contains("本机 Codex 会话"))
        XCTAssertTrue(rendered.contains("待回传更新"))
    }

    func testStatusSnapshotFallsBackToDirectoryNameWhenProjectReadmeMissing() async throws {
        let directory = try makeStatusTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        let tasksDirectory = directory.appendingPathComponent("tasks", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("Tests", isDirectory: true), withIntermediateDirectories: true)

        let configURL = directory.appendingPathComponent("agent.json", isDirectory: false)
        let stateURL = directory.appendingPathComponent("agent-state.json", isDirectory: false)

        try AgentConfigLoader.save(
            AgentConfigFile(
                serverURL: "https://orchard.local",
                enrollmentToken: "token",
                deviceID: "mac-mini-01",
                deviceName: "Mac Mini",
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path),
                ],
                heartbeatIntervalSeconds: 10,
                codexBinaryPath: "codex"
            ),
            to: configURL
        )

        let stateStore = AgentStateStore(url: stateURL)
        try await stateStore.markTaskStarted("task-no-readme")

        let runtimeDirectory = tasksDirectory.appendingPathComponent("task-no-readme", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let task = TaskRecord(
            id: "task-no-readme",
            title: "没有 README 的项目",
            kind: .codex,
            workspaceID: "main",
            relativePath: "Tests",
            priority: .normal,
            status: .running,
            payload: .codex(CodexTaskPayload(prompt: "看看项目名会不会回退")),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110)
        )
        try OrchardJSON.encoder.encode(task).write(
            to: runtimeDirectory.appendingPathComponent("task.json", isDirectory: false),
            options: .atomic
        )

        let runtime = ManagedCodexRuntimeFixture(
            taskID: "task-no-readme",
            threadID: "thread-no-readme",
            cwd: workspace.appendingPathComponent("Tests", isDirectory: true).path,
            startedAt: Date(timeIntervalSince1970: 110),
            lastSeenAt: Date(timeIntervalSince1970: 120),
            stopRequested: false,
            pid: 111,
            activeTurnID: nil,
            emittedTextLengths: [:],
            lastManagedRunStatus: .running,
            lastUserPrompt: "看看项目名会不会回退",
            lastAssistantPreview: "正在检查"
        )
        try OrchardJSON.encoder.encode(runtime).write(
            to: runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false),
            options: .atomic
        )

        let snapshot = try await AgentStatusService(
            localCodexSessionsFetcher: { _, _ in [] }
        ).snapshot(options: try AgentStatusOptions(
            configURL: configURL,
            stateURL: stateURL,
            tasksDirectoryURL: tasksDirectory,
            includeRemote: false
        ))

        XCTAssertEqual(snapshot.local.activeTasks.first?.project.name, "Tests")
        XCTAssertEqual(snapshot.local.activeTasks.first?.project.relativePath, "Tests")
    }

    func testStatusSnapshotMarksInactiveStaleManagedTaskAsFailed() async throws {
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
                maxParallelTasks: 1,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path),
                ],
                heartbeatIntervalSeconds: 10,
                codexBinaryPath: "codex"
            ),
            to: configURL
        )

        let runtimeDirectory = tasksDirectory.appendingPathComponent("task-stale", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

        let task = TaskRecord(
            id: "task-stale",
            title: "空 rollout 启动失败",
            kind: .codex,
            workspaceID: "main",
            relativePath: nil,
            priority: .normal,
            status: .running,
            payload: .codex(CodexTaskPayload(prompt: "你能干嘛")),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 110),
            startedAt: Date(timeIntervalSince1970: 110)
        )
        try OrchardJSON.encoder.encode(task).write(
            to: runtimeDirectory.appendingPathComponent("task.json", isDirectory: false),
            options: .atomic
        )

        let runtime = ManagedCodexRuntimeFixture(
            taskID: "task-stale",
            threadID: "thread-stale",
            cwd: workspace.path,
            startedAt: Date(timeIntervalSince1970: 110),
            lastSeenAt: Date(timeIntervalSince1970: 120),
            stopRequested: false,
            pid: 4321,
            activeTurnID: nil,
            emittedTextLengths: [:],
            lastManagedRunStatus: .launching,
            lastUserPrompt: "你能干嘛",
            lastAssistantPreview: nil
        )
        try OrchardJSON.encoder.encode(runtime).write(
            to: runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false),
            options: .atomic
        )

        let snapshot = try await AgentStatusService(
            localCodexSessionsFetcher: { _, _ in [] }
        ).snapshot(options: try AgentStatusOptions(
            configURL: configURL,
            stateURL: stateURL,
            tasksDirectoryURL: tasksDirectory,
            includeRemote: false
        ))

        XCTAssertEqual(snapshot.local.recentTasks.count, 1)
        XCTAssertEqual(snapshot.local.recentTasks.first?.task.status, .failed)
        XCTAssertEqual(snapshot.local.recentTasks.first?.managedRunStatus, .failed)
        XCTAssertEqual(
            snapshot.local.recentTasks.first?.task.summary,
            "本地 Codex 任务已脱离活动列表，但本地状态仍停留在运行中；通常是启动失败或历史残留。"
        )
    }

    func testStatusPageRendererIncludesHostFirstLocalControlWhenAvailable() throws {
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

        let html = AgentStatusPageRenderer.render(
            options: options,
            localActionEnabled: true,
            localCodexActionEnabled: true
        )
        XCTAssertFalse(html.contains("左边只保留项目名。点项目展开任务，点任务名后，右边再看详情和操作。"))
        XCTAssertTrue(html.contains("/api/status"))
        XCTAssertTrue(html.contains("/api/local-managed-runs"))
        XCTAssertTrue(html.contains("workspaceProjects"))
        XCTAssertTrue(html.contains("focus-task-list"))
        XCTAssertTrue(html.contains("task-list-modal"))
        XCTAssertTrue(html.contains("create-modal"))
        XCTAssertTrue(html.contains("在宿主机发起任务"))
        XCTAssertTrue(html.contains("发起新任务"))
        XCTAssertTrue(html.contains("全部项目"))
        XCTAssertTrue(html.contains("查看详情"))
        XCTAssertTrue(html.contains("新建任务"))
        XCTAssertTrue(html.contains("scroll-task-log"))
        XCTAssertTrue(html.contains("open-sidebar-create"))
        XCTAssertTrue(html.contains("open-inline-project-create"))
        XCTAssertTrue(html.contains("toggle-project-tree"))
        XCTAssertTrue(html.contains("cancel-inline-create"))
        XCTAssertTrue(html.contains("发起任务"))
        XCTAssertTrue(html.contains("show-advanced"))
        XCTAssertTrue(html.contains("高级观察（调试 / 恢复时再看）"))
        XCTAssertTrue(html.contains("task-search-modal"))
        XCTAssertTrue(html.contains("data-task-filter=\"waiting\""))
        XCTAssertTrue(html.contains("session-filter"))
        XCTAssertTrue(html.contains("task-status-banner"))
        XCTAssertTrue(html.contains("可继续"))
        XCTAssertTrue(html.contains("renderLogTimeline"))
        XCTAssertTrue(html.contains("task-stage-title"))
        XCTAssertTrue(html.contains("task-stage-meta"))
        XCTAssertTrue(html.contains("更多详情"))
        XCTAssertTrue(html.contains("当前进展"))
        XCTAssertFalse(html.contains("回到最新"))
        XCTAssertFalse(html.contains("默认贴着最新进展"))
        XCTAssertTrue(html.contains("继续输入"))
        XCTAssertTrue(html.contains("这条网页消息会发到"))
        XCTAssertTrue(html.contains("宿主机输出"))
        XCTAssertTrue(html.contains("progress-entry"))
        XCTAssertTrue(html.contains("progressSummaryForItem"))
        XCTAssertTrue(html.contains("captureTimelineViewportBeforeRender"))
        XCTAssertTrue(html.contains("restoreTimelineViewportAfterRender"))
        XCTAssertTrue(html.contains("ResizeObserver"))
        XCTAssertTrue(html.contains("timelineFollowThreshold"))
        XCTAssertTrue(html.contains("conversation-route"))
        XCTAssertTrue(html.contains("composer-inline"))
        XCTAssertTrue(html.contains("<textarea name=\"prompt\" rows=\"4\""))
        XCTAssertTrue(html.contains("Enter 换行，Cmd / Ctrl + Enter 发起任务"))
        XCTAssertTrue(html.contains("requestSubmit"))
        XCTAssertTrue(html.contains("min-height: calc(100vh - 24px)"))
        XCTAssertTrue(html.contains("timelineUsesDocumentScroll"))
        XCTAssertTrue(html.contains("常用路径（根目录 + 一级目录）"))
        XCTAssertTrue(html.contains("执行引擎"))
        XCTAssertTrue(html.contains("create-driver"))
        XCTAssertTrue(html.contains("Codex CLI"))
        XCTAssertTrue(html.contains("项目列表"))
        XCTAssertTrue(html.contains("任务执行区"))
        XCTAssertTrue(html.contains("project-tree"))
        XCTAssertTrue(html.contains("project-tree-status"))
        XCTAssertTrue(html.contains("project-running-indicator"))
        XCTAssertTrue(html.contains("topbar-right"))
        XCTAssertTrue(html.contains("topbar-quick-action"))
        XCTAssertTrue(html.contains("project-action-button"))
        XCTAssertTrue(html.contains("project-task-row"))
        XCTAssertTrue(html.contains("conversation-list-shell"))
        XCTAssertTrue(html.contains("list-summary-bar"))
        XCTAssertTrue(html.contains("本机 Codex 会话"))
        XCTAssertTrue(html.contains("先看这 3 个数字"))
        XCTAssertTrue(html.contains("发送到当前任务"))
        XCTAssertTrue(html.contains("发送到当前会话"))
        XCTAssertTrue(html.contains("远程托管运行"))
        XCTAssertTrue(html.contains("本地任务工作台"))
        XCTAssertTrue(html.contains("const hasLocalControl = true"))
        XCTAssertTrue(html.contains("const hasLocalCodexControl = true"))
        XCTAssertTrue(html.contains("/api/local-codex-sessions/"))
        XCTAssertFalse(html.contains("<input type=\"checkbox\" id=\"remote-toggle\" checked>"))
    }

    func testStatusPageRendererExplainsReadOnlyModeWithoutLocalControl() throws {
        let directory = try makeStatusTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let options = try AgentStatusOptions(
            configURL: directory.appendingPathComponent("agent.json", isDirectory: false),
            stateURL: directory.appendingPathComponent("agent-state.json", isDirectory: false),
            tasksDirectoryURL: directory.appendingPathComponent("tasks", isDirectory: true),
            outputFormat: .text,
            includeRemote: false,
            serve: true,
            bindHost: "127.0.0.1",
            port: 5419
        )

        let html = AgentStatusPageRenderer.render(
            options: options,
            localActionEnabled: false,
            localCodexActionEnabled: false
        )
        XCTAssertTrue(html.contains("只能观察"))
        XCTAssertTrue(html.contains("const hasLocalControl = false"))
        XCTAssertTrue(html.contains("const hasLocalCodexControl = false"))
    }

    func testStatusRendererIncludesRemoteCombinedRunningBreakdown() throws {
        let snapshot = AgentStatusSnapshot(
            generatedAt: Date(timeIntervalSince1970: 200),
            deviceID: "mac-mini-01",
            deviceName: "Mac Mini",
            hostName: "mac-mini",
            serverURL: "https://orchard.local",
            workspaces: [],
            workspacePathOptions: [:],
            workspaceProjects: [:],
            local: AgentLocalStatusSnapshot(
                metrics: DeviceMetrics(),
                activeTaskIDs: [],
                activeTasks: [],
                recentTasks: [],
                codexSessions: [],
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

    func testStatusHTTPServerRoutesLocalManagedActions() async throws {
        let directory = try makeStatusTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let port = try makeAvailablePort()
        let options = try AgentStatusOptions(
            configURL: directory.appendingPathComponent("agent.json", isDirectory: false),
            stateURL: directory.appendingPathComponent("agent-state.json", isDirectory: false),
            tasksDirectoryURL: directory.appendingPathComponent("tasks", isDirectory: true),
            outputFormat: .text,
            includeRemote: false,
            serve: true,
            bindHost: "127.0.0.1",
            port: port
        )

        let recorder = LocalActionRecorder()
        let server = AgentStatusHTTPServer(
            options: options,
            localActions: AgentStatusLocalActions(
                createManagedRun: { request in
                    try await recorder.create(request)
                },
                continueManagedTask: { taskID, prompt in
                    await recorder.recordContinue(taskID: taskID, prompt: prompt)
                },
                interruptManagedTask: { taskID in
                    await recorder.recordInterrupt(taskID: taskID)
                },
                stopTask: { taskID in
                    await recorder.recordStop(taskID: taskID)
                }
            )
        )

        let serverTask = Task {
            try await server.run()
        }
        defer {
            serverTask.cancel()
        }

        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        _ = try await waitForHTTPPayload(url: baseURL.appendingPathComponent("healthz"), timeout: 5)

        let createResponse = try await performJSONRequest(
            url: try XCTUnwrap(URL(string: "api/local-managed-runs", relativeTo: baseURL)),
            method: "POST",
            body: OrchardJSON.encoder.encode(AgentLocalManagedRunRequest(
                title: "本地恢复验证",
                workspaceID: "main",
                relativePath: "Sources/OrchardAgent",
                driver: .codexCLI,
                prompt: "验证断线恢复"
            ))
        )
        XCTAssertEqual(createResponse.statusCode, 200)
        let createPayload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: createResponse.data) as? [String: Any]
        )
        XCTAssertEqual(createPayload["ok"] as? Bool, true)
        XCTAssertEqual(createPayload["taskID"] as? String, "local-managed-task")

        _ = try await performJSONRequest(
            url: try XCTUnwrap(URL(string: "api/local-managed-runs/local-managed-task/continue", relativeTo: baseURL)),
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["prompt": "继续执行"])
        )
        _ = try await performJSONRequest(
            url: try XCTUnwrap(URL(string: "api/local-managed-runs/local-managed-task/interrupt", relativeTo: baseURL)),
            method: "POST"
        )
        _ = try await performJSONRequest(
            url: try XCTUnwrap(URL(string: "api/local-managed-runs/local-managed-task/stop", relativeTo: baseURL)),
            method: "POST"
        )

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.created.count, 1)
        XCTAssertEqual(snapshot.created.first?.workspaceID, "main")
        XCTAssertEqual(snapshot.created.first?.relativePath, "Sources/OrchardAgent")
        XCTAssertEqual(snapshot.created.first?.driver, .codexCLI)
        XCTAssertEqual(snapshot.created.first?.prompt, "验证断线恢复")
        XCTAssertEqual(snapshot.continued.count, 1)
        XCTAssertEqual(snapshot.continued.first?.taskID, "local-managed-task")
        XCTAssertEqual(snapshot.continued.first?.prompt, "继续执行")
        XCTAssertEqual(snapshot.interrupted, ["local-managed-task"])
        XCTAssertEqual(snapshot.stopped, ["local-managed-task"])

        serverTask.cancel()
        _ = await serverTask.result
    }

    func testStatusHTTPServerRoutesLocalCodexSessionActions() async throws {
        let directory = try makeStatusTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let port = try makeAvailablePort()
        let options = try AgentStatusOptions(
            configURL: directory.appendingPathComponent("agent.json", isDirectory: false),
            stateURL: directory.appendingPathComponent("agent-state.json", isDirectory: false),
            tasksDirectoryURL: directory.appendingPathComponent("tasks", isDirectory: true),
            outputFormat: .text,
            includeRemote: false,
            serve: true,
            bindHost: "127.0.0.1",
            port: port
        )

        let recorder = LocalCodexActionRecorder()
        let server = AgentStatusHTTPServer(
            options: options,
            localCodexActions: AgentStatusLocalCodexActions(
                readSession: { sessionID in
                    await recorder.recordRead(sessionID: sessionID)
                    return recorder.makeDetail(sessionID: sessionID, state: .idle, lastTurnStatus: "completed")
                },
                continueSession: { sessionID, prompt in
                    await recorder.recordContinue(sessionID: sessionID, prompt: prompt)
                    return recorder.makeDetail(
                        sessionID: sessionID,
                        state: .running,
                        lastTurnStatus: "inProgress",
                        lastUserMessage: prompt,
                        lastAssistantMessage: "继续执行中"
                    )
                },
                interruptSession: { sessionID in
                    await recorder.recordInterrupt(sessionID: sessionID)
                    return recorder.makeDetail(
                        sessionID: sessionID,
                        state: .interrupted,
                        lastTurnStatus: "interrupted",
                        lastAssistantMessage: "已中断"
                    )
                }
            )
        )

        let serverTask = Task {
            try await server.run()
        }
        defer {
            serverTask.cancel()
        }

        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        _ = try await waitForHTTPPayload(url: baseURL.appendingPathComponent("healthz"), timeout: 5)

        let readResponse = try await performJSONRequest(
            url: try XCTUnwrap(URL(string: "api/local-codex-sessions/thread-local", relativeTo: baseURL)),
            method: "GET"
        )
        XCTAssertEqual(readResponse.statusCode, 200)
        let readDetail = try OrchardJSON.decoder.decode(CodexSessionDetail.self, from: readResponse.data)
        XCTAssertEqual(readDetail.session.id, "thread-local")

        let continueResponse = try await performJSONRequest(
            url: try XCTUnwrap(URL(string: "api/local-codex-sessions/thread-local/continue", relativeTo: baseURL)),
            method: "POST",
            body: try JSONSerialization.data(withJSONObject: ["prompt": "继续检查"])
        )
        XCTAssertEqual(continueResponse.statusCode, 200)
        let continuedDetail = try OrchardJSON.decoder.decode(CodexSessionDetail.self, from: continueResponse.data)
        XCTAssertEqual(continuedDetail.session.lastUserMessage, "继续检查")
        XCTAssertEqual(continuedDetail.session.state, .running)

        let interruptResponse = try await performJSONRequest(
            url: try XCTUnwrap(URL(string: "api/local-codex-sessions/thread-local/interrupt", relativeTo: baseURL)),
            method: "POST"
        )
        XCTAssertEqual(interruptResponse.statusCode, 200)
        let interruptedDetail = try OrchardJSON.decoder.decode(CodexSessionDetail.self, from: interruptResponse.data)
        XCTAssertEqual(interruptedDetail.session.state, .interrupted)

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.read, ["thread-local"])
        XCTAssertEqual(snapshot.continued.count, 1)
        XCTAssertEqual(snapshot.continued.first?.sessionID, "thread-local")
        XCTAssertEqual(snapshot.continued.first?.prompt, "继续检查")
        XCTAssertEqual(snapshot.interrupted, ["thread-local"])

        serverTask.cancel()
        _ = await serverTask.result
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

private struct LocalActionRecorderSnapshot: Sendable {
    struct ContinuedPrompt: Sendable {
        let taskID: String
        let prompt: String
    }

    var created: [AgentLocalManagedRunRequest]
    var continued: [ContinuedPrompt]
    var interrupted: [String]
    var stopped: [String]
}

private struct LocalCodexActionRecorderSnapshot: Sendable {
    struct ContinuedPrompt: Sendable {
        let sessionID: String
        let prompt: String
    }

    var read: [String]
    var continued: [ContinuedPrompt]
    var interrupted: [String]
}

private actor LocalActionRecorder {
    private var created: [AgentLocalManagedRunRequest] = []
    private var continued: [LocalActionRecorderSnapshot.ContinuedPrompt] = []
    private var interrupted: [String] = []
    private var stopped: [String] = []

    func create(_ request: AgentLocalManagedRunRequest) throws -> TaskRecord {
        created.append(request)
        let now = Date(timeIntervalSince1970: 500)
        return TaskRecord(
            id: "local-managed-task",
            title: request.title ?? "本地任务",
            kind: .codex,
            workspaceID: request.workspaceID,
            relativePath: request.relativePath,
            priority: .normal,
            status: .running,
            payload: .codex(CodexTaskPayload(prompt: request.prompt, driver: request.driver)),
            preferredDeviceID: "device-local",
            assignedDeviceID: "device-local",
            createdAt: now,
            updatedAt: now,
            startedAt: now
        )
    }

    func recordContinue(taskID: String, prompt: String) {
        continued.append(.init(taskID: taskID, prompt: prompt))
    }

    func recordInterrupt(taskID: String) {
        interrupted.append(taskID)
    }

    func recordStop(taskID: String) {
        stopped.append(taskID)
    }

    func snapshot() -> LocalActionRecorderSnapshot {
        LocalActionRecorderSnapshot(
            created: created,
            continued: continued,
            interrupted: interrupted,
            stopped: stopped
        )
    }
}

private actor LocalCodexActionRecorder {
    private var read: [String] = []
    private var continued: [LocalCodexActionRecorderSnapshot.ContinuedPrompt] = []
    private var interrupted: [String] = []

    func recordRead(sessionID: String) {
        read.append(sessionID)
    }

    func recordContinue(sessionID: String, prompt: String) {
        continued.append(.init(sessionID: sessionID, prompt: prompt))
    }

    func recordInterrupt(sessionID: String) {
        interrupted.append(sessionID)
    }

    nonisolated func makeDetail(
        sessionID: String,
        state: CodexSessionState,
        lastTurnStatus: String,
        lastUserMessage: String? = "继续检查",
        lastAssistantMessage: String? = nil
    ) -> CodexSessionDetail {
        let now = Date(timeIntervalSince1970: 900)
        let summary = CodexSessionSummary(
            id: sessionID,
            deviceID: "device-local",
            deviceName: "Local Device",
            workspaceID: "main",
            name: "本地 Codex 会话",
            preview: "继续检查本地会话桥接",
            cwd: "/tmp/orchard",
            source: "codex-app",
            modelProvider: "openai",
            createdAt: now,
            updatedAt: now,
            state: state,
            lastTurnID: "turn-local",
            lastTurnStatus: lastTurnStatus,
            lastUserMessage: lastUserMessage,
            lastAssistantMessage: lastAssistantMessage
        )
        return CodexSessionDetail(
            session: summary,
            turns: [
                CodexSessionTurn(id: "turn-local", status: lastTurnStatus),
            ],
            items: [
                CodexSessionItem(
                    id: "item-user",
                    turnID: "turn-local",
                    sequence: 0,
                    kind: .userMessage,
                    title: "用户",
                    body: lastUserMessage
                ),
                CodexSessionItem(
                    id: "item-agent",
                    turnID: "turn-local",
                    sequence: 1,
                    kind: .agentMessage,
                    title: "Codex 回答",
                    body: lastAssistantMessage ?? "正在处理"
                ),
            ]
        )
    }

    func snapshot() -> LocalCodexActionRecorderSnapshot {
        LocalCodexActionRecorderSnapshot(
            read: read,
            continued: continued,
            interrupted: interrupted
        )
    }
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

private func performJSONRequest(
    url: URL,
    method: String,
    body: Data? = nil
) async throws -> (statusCode: Int, data: Data) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    if let body {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    return (http.statusCode, data)
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
