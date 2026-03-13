import Foundation
import OrchardCore

enum CompanionPreviewData {
    static let now = Date(timeIntervalSinceReferenceDate: 760_000_000)

    static let workspace = WorkspaceDefinition(
        id: "orchard-main",
        name: "Orchard",
        rootPath: "/Users/owen/MyCodeSpace/Orchard"
    )

    static let onlineDevice = DeviceRecord(
        deviceID: "mac-mini-01",
        name: "Mac mini",
        hostName: "mac-mini.local",
        platform: .macOS,
        status: .online,
        capabilities: [.shell, .git, .codex],
        maxParallelTasks: 3,
        workspaces: [workspace],
        metrics: DeviceMetrics(
            cpuPercentApprox: 31,
            memoryPercent: 62,
            loadAverage: 1.18,
            runningTasks: 2,
            codexDesktop: CodexDesktopMetrics(
                activeThreadCount: 3,
                inflightThreadCount: 1,
                inflightTurnCount: 1,
                loadedThreadCount: 8,
                totalThreadCount: 12,
                lastSnapshotAt: now.addingTimeInterval(-18)
            )
        ),
        runningTaskCount: 2,
        registeredAt: now.addingTimeInterval(-86_400),
        lastSeenAt: now.addingTimeInterval(-40)
    )

    static let offlineDevice = DeviceRecord(
        deviceID: "mbp-14-02",
        name: "MacBook Pro",
        hostName: "mbp.local",
        platform: .macOS,
        status: .offline,
        capabilities: [.shell, .filesystem, .git],
        maxParallelTasks: 2,
        workspaces: [workspace],
        metrics: DeviceMetrics(
            cpuPercentApprox: 0,
            memoryPercent: 0,
            loadAverage: 0.0,
            runningTasks: 0
        ),
        runningTaskCount: 0,
        registeredAt: now.addingTimeInterval(-120_000),
        lastSeenAt: now.addingTimeInterval(-7_200)
    )

    static let runningTask = TaskRecord(
        id: "task-running-001",
        title: "整理本地工作树",
        kind: .shell,
        workspaceID: workspace.id,
        relativePath: "Sources",
        priority: .high,
        status: .running,
        payload: .shell(ShellTaskPayload(command: "git status --short && swift build")),
        preferredDeviceID: onlineDevice.deviceID,
        assignedDeviceID: onlineDevice.deviceID,
        createdAt: now.addingTimeInterval(-900),
        updatedAt: now.addingTimeInterval(-60),
        startedAt: now.addingTimeInterval(-840),
        finishedAt: nil,
        stopRequestedAt: nil,
        exitCode: nil,
        summary: "编译仍在进行中。"
    )

    static let failedTask = TaskRecord(
        id: "task-failed-002",
        title: "回归检查 Vapor 服务",
        kind: .codex,
        workspaceID: workspace.id,
        relativePath: nil,
        priority: .normal,
        status: .failed,
        payload: .codex(CodexTaskPayload(prompt: "检查 Vapor 控制面启动失败原因并给出修复建议")),
        preferredDeviceID: onlineDevice.deviceID,
        assignedDeviceID: onlineDevice.deviceID,
        createdAt: now.addingTimeInterval(-5_400),
        updatedAt: now.addingTimeInterval(-240),
        startedAt: now.addingTimeInterval(-5_200),
        finishedAt: now.addingTimeInterval(-240),
        stopRequestedAt: nil,
        exitCode: 1,
        summary: "依赖拉取完成后，Agent target 仍然报 main entry 和 JSON helper 相关错误。"
    )

    static let queuedTask = TaskRecord(
        id: "task-queued-003",
        title: "生成移动端功能稿",
        kind: .codex,
        workspaceID: workspace.id,
        relativePath: "docs",
        priority: .normal,
        status: .queued,
        payload: .codex(CodexTaskPayload(prompt: "为 Orchard iPhone 端输出功能设计稿和线框结构")),
        preferredDeviceID: nil,
        assignedDeviceID: nil,
        createdAt: now.addingTimeInterval(-120),
        updatedAt: now.addingTimeInterval(-120),
        startedAt: nil,
        finishedAt: nil,
        stopRequestedAt: nil,
        exitCode: nil,
        summary: nil
    )

    static let runningManagedRun = ManagedRunSummary(
        id: "run-running-001",
        taskID: runningTask.id,
        deviceID: onlineDevice.deviceID,
        deviceName: onlineDevice.name,
        title: "把托管运行接到移动端",
        driver: .codexCLI,
        workspaceID: workspace.id,
        relativePath: "Sources/OrchardCompanionApp",
        cwd: workspace.rootPath + "/Sources/OrchardCompanionApp",
        status: .running,
        createdAt: now.addingTimeInterval(-1_200),
        updatedAt: now.addingTimeInterval(-40),
        startedAt: now.addingTimeInterval(-1_120),
        endedAt: nil,
        exitCode: nil,
        summary: "正在切换概览和详情页到 managed runs。",
        pid: 48211,
        lastHeartbeatAt: now.addingTimeInterval(-18),
        codexSessionID: nil,
        lastUserPrompt: "把控制面的运行真相切到 managed runs。"
    )

    static let failedManagedRun = ManagedRunSummary(
        id: "run-failed-002",
        taskID: failedTask.id,
        deviceID: onlineDevice.deviceID,
        deviceName: onlineDevice.name,
        title: "补齐重连恢复链路",
        driver: .codexCLI,
        workspaceID: workspace.id,
        relativePath: "Tests",
        cwd: workspace.rootPath + "/Tests",
        status: .failed,
        createdAt: now.addingTimeInterval(-4_800),
        updatedAt: now.addingTimeInterval(-240),
        startedAt: now.addingTimeInterval(-4_700),
        endedAt: now.addingTimeInterval(-240),
        exitCode: 1,
        summary: "旧的 stop 链路会提前打死 wrapper，导致恢复后无法正确收尾。",
        pid: nil,
        lastHeartbeatAt: now.addingTimeInterval(-260),
        codexSessionID: nil,
        lastUserPrompt: "把 agent 重启恢复测试补上并修到通过。"
    )

    static let queuedManagedRun = ManagedRunSummary(
        id: "run-queued-003",
        taskID: queuedTask.id,
        deviceID: nil,
        preferredDeviceID: onlineDevice.deviceID,
        deviceName: nil,
        title: "接入移动端停止与重试",
        driver: .codexCLI,
        workspaceID: workspace.id,
        relativePath: "Sources/OrchardCompanionApp",
        cwd: workspace.rootPath + "/Sources/OrchardCompanionApp",
        status: .queued,
        createdAt: now.addingTimeInterval(-160),
        updatedAt: now.addingTimeInterval(-160),
        startedAt: nil,
        endedAt: nil,
        exitCode: nil,
        summary: nil,
        pid: nil,
        lastHeartbeatAt: nil,
        codexSessionID: nil,
        lastUserPrompt: "把移动端最小控制链路补上。"
    )

    static let snapshot = DashboardSnapshot(
        devices: [onlineDevice, offlineDevice],
        tasks: [failedTask, runningTask, queuedTask],
        managedRuns: [failedManagedRun, runningManagedRun, queuedManagedRun]
    )

    static let activeCodexSession = CodexSessionSummary(
        id: "codex-session-001",
        deviceID: onlineDevice.deviceID,
        deviceName: onlineDevice.name,
        workspaceID: workspace.id,
        name: "整理 Orchard 的远程控制方案",
        preview: "我现在所有的任务都是基于 codex 来发起的，希望移动端能够持续监控。",
        cwd: workspace.rootPath,
        source: "vscode",
        modelProvider: "openai",
        createdAt: now.addingTimeInterval(-1_800),
        updatedAt: now.addingTimeInterval(-20),
        state: .running,
        lastTurnID: "turn-active-001",
        lastTurnStatus: "inProgress",
        lastUserMessage: "帮我把 Codex 会话接到 Orchard 里。",
        lastAssistantMessage: "我正在整理控制面和移动端的对接方案。"
    )

    static let finishedCodexSession = CodexSessionSummary(
        id: "codex-session-002",
        deviceID: onlineDevice.deviceID,
        deviceName: onlineDevice.name,
        workspaceID: workspace.id,
        name: "修复 Orchard 中文首页",
        preview: "把网页和 App 的中文文案统一。",
        cwd: workspace.rootPath,
        source: "exec",
        modelProvider: "openai",
        createdAt: now.addingTimeInterval(-7_200),
        updatedAt: now.addingTimeInterval(-1_200),
        state: .completed,
        lastTurnID: "turn-done-001",
        lastTurnStatus: "completed",
        lastUserMessage: "把网页和 App 全部中文化。",
        lastAssistantMessage: "已经完成中文文案统一。"
    )

    static let activeCodexSessionDetail = CodexSessionDetail(
        session: activeCodexSession,
        turns: [
            CodexSessionTurn(id: "turn-active-001", status: "inProgress"),
        ],
        items: [
            CodexSessionItem(
                id: "item-user-1",
                turnID: "turn-active-001",
                sequence: 0,
                kind: .userMessage,
                title: "用户",
                body: "帮我把 Codex 会话接到 Orchard 里。"
            ),
            CodexSessionItem(
                id: "item-agent-1",
                turnID: "turn-active-001",
                sequence: 1,
                kind: .agentMessage,
                title: "Codex",
                body: "我正在整理控制面和移动端的对接方案。"
            ),
            CodexSessionItem(
                id: "item-cmd-1",
                turnID: "turn-active-001",
                sequence: 2,
                kind: .commandExecution,
                title: "codex app-server --help",
                body: "Usage: codex app-server [OPTIONS] [COMMAND]",
                status: "completed"
            ),
        ]
    )

    static let failedTaskDetail = TaskDetail(
        task: failedTask,
        logs: [
            TaskLogEntry(
                id: "log-1",
                taskID: failedTask.id,
                deviceID: onlineDevice.deviceID,
                createdAt: now.addingTimeInterval(-380),
                line: "Starting regression check for OrchardControlPlane target."
            ),
            TaskLogEntry(
                id: "log-2",
                taskID: failedTask.id,
                deviceID: onlineDevice.deviceID,
                createdAt: now.addingTimeInterval(-340),
                line: "swift build failed: OrchardAgent main entry conflicts with top-level code."
            ),
            TaskLogEntry(
                id: "log-3",
                taskID: failedTask.id,
                deviceID: onlineDevice.deviceID,
                createdAt: now.addingTimeInterval(-300),
                line: "AgentStateStore.swift cannot find OrchardJSON in scope."
            ),
        ]
    )

    @MainActor
    static var model: AppModel {
        AppModel.preview(
            snapshot: snapshot,
            codexSessions: [activeCodexSession, finishedCodexSession],
            errorMessage: nil,
            lastRefreshAt: now.addingTimeInterval(-30)
        )
    }
}

@MainActor
extension AppModel {
    static func preview(
        snapshot: DashboardSnapshot,
        codexSessions: [CodexSessionSummary] = [],
        errorMessage: String? = nil,
        lastRefreshAt: Date? = nil
    ) -> AppModel {
        let model = AppModel()
        model.snapshot = snapshot
        model.codexSessions = codexSessions
        model.errorMessage = errorMessage
        model.lastRefreshAt = lastRefreshAt
        return model
    }
}
