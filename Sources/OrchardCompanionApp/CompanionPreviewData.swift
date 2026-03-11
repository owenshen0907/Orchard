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
            runningTasks: 2
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

    static let snapshot = DashboardSnapshot(
        devices: [onlineDevice, offlineDevice],
        tasks: [failedTask, runningTask, queuedTask]
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
        AppModel.preview(snapshot: snapshot, errorMessage: nil, lastRefreshAt: now.addingTimeInterval(-30))
    }
}

@MainActor
extension AppModel {
    static func preview(
        snapshot: DashboardSnapshot,
        errorMessage: String? = nil,
        lastRefreshAt: Date? = nil
    ) -> AppModel {
        let model = AppModel()
        model.snapshot = snapshot
        model.errorMessage = errorMessage
        model.lastRefreshAt = lastRefreshAt
        return model
    }
}
