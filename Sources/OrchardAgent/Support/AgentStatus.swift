import Foundation
import OrchardCore

enum AgentStatusOutputFormat: String, Sendable {
    case text
    case json
}

struct AgentStatusOptions: Sendable {
    var configURL: URL
    var stateURL: URL
    var tasksDirectoryURL: URL
    var outputFormat: AgentStatusOutputFormat
    var includeRemote: Bool
    var accessKey: String?
    var limit: Int
    var serve: Bool
    var bindHost: String
    var port: Int

    init(
        configURL: URL? = nil,
        stateURL: URL? = nil,
        tasksDirectoryURL: URL? = nil,
        outputFormat: AgentStatusOutputFormat = .text,
        includeRemote: Bool = true,
        accessKey: String? = ProcessInfo.processInfo.environment["ORCHARD_ACCESS_KEY"],
        limit: Int = 8,
        serve: Bool = false,
        bindHost: String = "127.0.0.1",
        port: Int = 5419
    ) throws {
        self.configURL = try configURL ?? OrchardAgentPaths.configURL()
        self.stateURL = try stateURL ?? OrchardAgentPaths.stateURL()
        self.tasksDirectoryURL = try tasksDirectoryURL ?? OrchardAgentPaths.tasksDirectory()
        self.outputFormat = outputFormat
        self.includeRemote = includeRemote
        self.accessKey = accessKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.limit = max(1, limit)
        self.serve = serve
        self.bindHost = bindHost.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "127.0.0.1"
        self.port = min(max(port, 1), 65535)
    }
}

struct AgentLocalManagedRunRequest: Codable, Sendable {
    var title: String?
    var workspaceID: String
    var relativePath: String?
    var prompt: String
}

struct AgentStatusLocalActions: Sendable {
    var createManagedRun: @Sendable (AgentLocalManagedRunRequest) async throws -> TaskRecord
    var continueManagedTask: @Sendable (String, String) async throws -> Void
    var interruptManagedTask: @Sendable (String) async throws -> Void
    var stopTask: @Sendable (String) async throws -> Void
}

struct AgentStatusSnapshot: Codable, Sendable {
    var generatedAt: Date
    var deviceID: String
    var deviceName: String
    var hostName: String
    var serverURL: String
    var workspaces: [WorkspaceDefinition]
    var local: AgentLocalStatusSnapshot
    var remote: AgentRemoteStatusSnapshot?
    var remoteSkippedReason: String?
}

struct AgentLocalStatusSnapshot: Codable, Sendable {
    var metrics: DeviceMetrics
    var activeTaskIDs: [String]
    var activeTasks: [AgentLocalTaskSnapshot]
    var pendingUpdates: [AgentTaskUpdatePayload]
    var warnings: [String]
}

struct AgentLocalTaskSnapshot: Codable, Sendable {
    var task: TaskRecord
    var runtimeDirectoryPath: String
    var logPath: String
    var recentLogLines: [String]
    var cwd: String?
    var pid: Int?
    var startedAt: Date?
    var lastSeenAt: Date?
    var stopRequested: Bool
    var codexThreadID: String?
    var activeTurnID: String?
    var managedRunStatus: ManagedRunStatus?
    var lastUserPrompt: String?
    var lastAssistantPreview: String?
    var runtimeWarning: String?
}

struct AgentRemoteStatusSnapshot: Codable, Sendable {
    var device: DeviceRecord?
    var totalManagedRunCount: Int
    var runningManagedRunCount: Int
    var unmanagedRunningTaskCount: Int
    var observedRunningCodexCount: Int
    var totalRunningCount: Int
    var managedRuns: [ManagedRunSummary]
    var totalCodexSessionCount: Int
    var codexSessions: [CodexSessionSummary]
    var fetchError: String?
}

struct AgentStatusService {
    typealias RemoteFetcher = @Sendable (ResolvedAgentConfig, String, Int) async throws -> AgentRemoteStatusSnapshot

    var metricsCollector: SystemMetricsCollector
    var codexDesktopMetricsCollector: CodexDesktopMetricsCollector
    var remoteFetcher: RemoteFetcher

    init(
        metricsCollector: SystemMetricsCollector = SystemMetricsCollector(),
        codexDesktopMetricsCollector: CodexDesktopMetricsCollector = CodexDesktopMetricsCollector(),
        remoteFetcher: @escaping RemoteFetcher = AgentStatusService.defaultRemoteFetcher
    ) {
        self.metricsCollector = metricsCollector
        self.codexDesktopMetricsCollector = codexDesktopMetricsCollector
        self.remoteFetcher = remoteFetcher
    }

    func snapshot(options: AgentStatusOptions) async throws -> AgentStatusSnapshot {
        let config = try AgentConfigLoader.load(from: options.configURL)
        let stateStore = AgentStateStore(url: options.stateURL)
        let bootstrap = try await stateStore.bootstrap()
        let local = try loadLocalSnapshot(config: config, bootstrap: bootstrap, tasksDirectory: options.tasksDirectoryURL)

        var remote: AgentRemoteStatusSnapshot?
        var remoteSkippedReason: String?
        if options.includeRemote {
            if let accessKey = options.accessKey {
                do {
                    remote = try await remoteFetcher(config, accessKey, options.limit)
                } catch {
                    remote = AgentRemoteStatusSnapshot(
                        device: nil,
                        totalManagedRunCount: 0,
                        runningManagedRunCount: 0,
                        unmanagedRunningTaskCount: 0,
                        observedRunningCodexCount: 0,
                        totalRunningCount: 0,
                        managedRuns: [],
                        totalCodexSessionCount: 0,
                        codexSessions: [],
                        fetchError: error.localizedDescription
                    )
                }
            } else {
                remoteSkippedReason = "未提供 ORCHARD_ACCESS_KEY 或 --access-key，已跳过远程状态读取。"
            }
        } else {
            remoteSkippedReason = "已按参数跳过远程状态读取。"
        }

        return AgentStatusSnapshot(
            generatedAt: Date(),
            deviceID: config.deviceID,
            deviceName: config.deviceName,
            hostName: config.hostName,
            serverURL: config.serverURL.absoluteString,
            workspaces: config.workspaceRoots,
            local: local,
            remote: remote,
            remoteSkippedReason: remoteSkippedReason
        )
    }

    private func loadLocalSnapshot(
        config: ResolvedAgentConfig,
        bootstrap: AgentBootstrapState,
        tasksDirectory: URL
    ) throws -> AgentLocalStatusSnapshot {
        let codexDesktop = codexDesktopMetricsCollector.snapshot()
        let metrics = metricsCollector.snapshot(
            runningTasks: bootstrap.activeTaskIDs.count,
            codexDesktop: codexDesktop
        )

        var warnings: [String] = []
        let activeTasks = try bootstrap.activeTaskIDs.map { taskID in
            try loadLocalTaskSnapshot(taskID: taskID, tasksDirectory: tasksDirectory, warnings: &warnings)
        }

        return AgentLocalStatusSnapshot(
            metrics: metrics,
            activeTaskIDs: bootstrap.activeTaskIDs,
            activeTasks: activeTasks,
            pendingUpdates: bootstrap.pendingTaskUpdates.sorted { lhs, rhs in
                lhs.taskID < rhs.taskID
            },
            warnings: warnings
        )
    }

    private func loadLocalTaskSnapshot(
        taskID: String,
        tasksDirectory: URL,
        warnings: inout [String]
    ) throws -> AgentLocalTaskSnapshot {
        let runtimeDirectory = tasksDirectory.appendingPathComponent(taskID, isDirectory: true)
        let logURL = runtimeDirectory.appendingPathComponent("combined.log", isDirectory: false)

        guard FileManager.default.fileExists(atPath: runtimeDirectory.path) else {
            warnings.append("任务 \(taskID) 被标记为活动中，但本地运行目录不存在。")
            return AgentLocalTaskSnapshot(
                task: missingTaskRecord(taskID: taskID),
                runtimeDirectoryPath: runtimeDirectory.path,
                logPath: logURL.path,
                recentLogLines: [],
                cwd: nil,
                pid: nil,
                startedAt: nil,
                lastSeenAt: nil,
                stopRequested: false,
                codexThreadID: nil,
                activeTurnID: nil,
                managedRunStatus: nil,
                lastUserPrompt: nil,
                lastAssistantPreview: nil,
                runtimeWarning: "本地运行目录不存在"
            )
        }

        let task: TaskRecord
        do {
            task = try TaskProcessController.loadPersistedTask(runtimeDirectory: runtimeDirectory)
        } catch {
            warnings.append("任务 \(taskID) 的 task.json 无法读取：\(error.localizedDescription)")
            return AgentLocalTaskSnapshot(
                task: missingTaskRecord(taskID: taskID),
                runtimeDirectoryPath: runtimeDirectory.path,
                logPath: logURL.path,
                recentLogLines: [],
                cwd: nil,
                pid: nil,
                startedAt: nil,
                lastSeenAt: nil,
                stopRequested: false,
                codexThreadID: nil,
                activeTurnID: nil,
                managedRunStatus: nil,
                lastUserPrompt: nil,
                lastAssistantPreview: nil,
                runtimeWarning: "task.json 无法读取"
            )
        }

        switch task.kind {
        case .shell:
            let runtime = try loadShellRuntime(runtimeDirectory: runtimeDirectory)
            let recentLogLines = readRecentLogLines(logURL: logURL)
            return AgentLocalTaskSnapshot(
                task: task,
                runtimeDirectoryPath: runtimeDirectory.path,
                logPath: logURL.path,
                recentLogLines: recentLogLines,
                cwd: runtime?.cwd,
                pid: runtime.map { Int($0.pid) },
                startedAt: runtime?.startedAt,
                lastSeenAt: runtime?.lastSeenAt,
                stopRequested: runtime?.stopRequested ?? false,
                codexThreadID: nil,
                activeTurnID: nil,
                managedRunStatus: nil,
                lastUserPrompt: nil,
                lastAssistantPreview: nil,
                runtimeWarning: runtime == nil ? "runtime.json 缺失或损坏" : nil
            )
        case .codex:
            let runtime = try loadManagedCodexRuntime(runtimeDirectory: runtimeDirectory)
            let recentLogLines = readRecentLogLines(logURL: logURL)
            return AgentLocalTaskSnapshot(
                task: task,
                runtimeDirectoryPath: runtimeDirectory.path,
                logPath: logURL.path,
                recentLogLines: recentLogLines,
                cwd: runtime?.cwd,
                pid: runtime?.pid.map(Int.init),
                startedAt: runtime?.startedAt,
                lastSeenAt: runtime?.lastSeenAt,
                stopRequested: runtime?.stopRequested ?? false,
                codexThreadID: runtime?.threadID,
                activeTurnID: runtime?.activeTurnID,
                managedRunStatus: runtime?.lastManagedRunStatus,
                lastUserPrompt: runtime?.lastUserPrompt,
                lastAssistantPreview: runtime?.lastAssistantPreview,
                runtimeWarning: runtime == nil ? "runtime.json 缺失或损坏" : nil
            )
        }
    }

    private func readRecentLogLines(logURL: URL, limit: Int = 6) -> [String] {
        guard
            FileManager.default.fileExists(atPath: logURL.path),
            let text = try? String(contentsOf: logURL, encoding: .utf8)
        else {
            return []
        }

        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(limit)
            .map { $0 }
    }

    private func loadShellRuntime(runtimeDirectory: URL) throws -> PersistedShellRuntimeRecord? {
        let runtimeURL = runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            return nil
        }
        do {
            return try OrchardJSON.decoder.decode(PersistedShellRuntimeRecord.self, from: Data(contentsOf: runtimeURL))
        } catch {
            return nil
        }
    }

    private func loadManagedCodexRuntime(runtimeDirectory: URL) throws -> PersistedManagedCodexRuntimeRecord? {
        let runtimeURL = runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            return nil
        }
        do {
            return try OrchardJSON.decoder.decode(PersistedManagedCodexRuntimeRecord.self, from: Data(contentsOf: runtimeURL))
        } catch {
            return nil
        }
    }

    private func missingTaskRecord(taskID: String) -> TaskRecord {
        TaskRecord(
            id: taskID,
            title: "无法读取任务定义",
            kind: .shell,
            workspaceID: "-",
            relativePath: nil,
            priority: .normal,
            status: .running,
            payload: .shell(ShellTaskPayload(command: "")),
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func defaultRemoteFetcher(
        config: ResolvedAgentConfig,
        accessKey: String,
        limit: Int
    ) async throws -> AgentRemoteStatusSnapshot {
        let client = OrchardAPIClient(baseURL: config.serverURL, accessKey: accessKey)

        async let snapshot = client.fetchSnapshot()
        async let codexSessions = client.fetchCodexSessions(deviceID: config.deviceID, limit: limit)

        let dashboard = try await snapshot
        let device = dashboard.devices.first { $0.deviceID == config.deviceID }
        let managedRuns = dashboard.managedRuns
            .filter { run in
                run.deviceID == config.deviceID || run.preferredDeviceID == config.deviceID
            }
            .sorted(by: compareManagedRuns)
        let sessions = try await codexSessions
            .sorted(by: compareCodexSessions)
        let runningManagedRunCount = managedRuns.filter { $0.status.occupiesSlot }.count
        let activeManagedTaskIDs = Set(
            managedRuns.compactMap { run -> String? in
                guard run.status.occupiesSlot else { return nil }
                return run.taskID?.trimmedOrEmpty.nilIfEmpty
            }
        )
        let unmanagedRunningTaskCount = dashboard.tasks.filter { task in
            guard task.assignedDeviceID == config.deviceID else { return false }
            guard task.status == .running || task.status == .stopRequested else { return false }
            return !activeManagedTaskIDs.contains(task.id)
        }.count
        let observedRunningCodexCount = max(
            sessions.filter(\.isRunningLike).count,
            device?.metrics.codexDesktop?.inflightThreadCount ?? 0
        )
        let totalRunningCount = runningManagedRunCount + unmanagedRunningTaskCount + observedRunningCodexCount

        return AgentRemoteStatusSnapshot(
            device: device,
            totalManagedRunCount: managedRuns.count,
            runningManagedRunCount: runningManagedRunCount,
            unmanagedRunningTaskCount: unmanagedRunningTaskCount,
            observedRunningCodexCount: observedRunningCodexCount,
            totalRunningCount: totalRunningCount,
            managedRuns: Array(managedRuns.prefix(limit)),
            totalCodexSessionCount: sessions.count,
            codexSessions: Array(sessions.prefix(limit)),
            fetchError: nil
        )
    }
}

enum AgentStatusRenderer {
    static func render(_ snapshot: AgentStatusSnapshot, format: AgentStatusOutputFormat) throws -> String {
        switch format {
        case .json:
            return String(decoding: try OrchardJSON.encoder.encode(snapshot), as: UTF8.self)
        case .text:
            return renderText(snapshot)
        }
    }

    private static func renderText(_ snapshot: AgentStatusSnapshot) -> String {
        var lines: [String] = []

        lines.append("宿主概览")
        lines.append("设备: \(snapshot.deviceName) (\(snapshot.deviceID))")
        lines.append("主机: \(snapshot.hostName)")
        lines.append("控制面: \(snapshot.serverURL)")
        lines.append("生成时间: \(formatDate(snapshot.generatedAt))")
        if snapshot.workspaces.isEmpty {
            lines.append("工作区: 未配置")
        } else {
            lines.append("工作区:")
            snapshot.workspaces.forEach { workspace in
                lines.append("  - \(workspace.name) [\(workspace.id)] -> \(workspace.rootPath)")
            }
        }

        let metrics = snapshot.local.metrics
        var metricLineParts: [String] = [
            "本地活动任务 \(snapshot.local.activeTasks.count)",
            "待回传更新 \(snapshot.local.pendingUpdates.count)"
        ]
        if let runningTasks = metrics.codexDesktop?.activeThreadCount {
            metricLineParts.append("桌面活跃线程 \(runningTasks)")
        }
        if let inflightTurns = metrics.codexDesktop?.inflightTurnCount {
            metricLineParts.append("进行中轮次 \(inflightTurns)")
        }
        if let load = metrics.loadAverage {
            metricLineParts.append(String(format: "负载 %.2f", load))
        }
        if let memory = metrics.memoryPercent {
            metricLineParts.append(String(format: "内存 %.0f%%", memory))
        }
        lines.append(metricLineParts.joined(separator: " · "))

        lines.append("")
        lines.append("本地活动任务")
        if snapshot.local.activeTasks.isEmpty {
            lines.append("- 当前没有本地活动任务。")
        } else {
            snapshot.local.activeTasks.forEach { task in
                lines.append(contentsOf: renderLocalTask(task))
            }
        }

        lines.append("")
        lines.append("待回传更新")
        if snapshot.local.pendingUpdates.isEmpty {
            lines.append("- 当前没有待回传的状态更新。")
        } else {
            snapshot.local.pendingUpdates.forEach { update in
                lines.append("- \(update.taskID) · \(update.status.statusTitle) · \(update.summary?.trimmedOrEmpty.nilIfEmpty ?? "无摘要")")
            }
        }

        if !snapshot.local.warnings.isEmpty {
            lines.append("")
            lines.append("本地告警")
            snapshot.local.warnings.forEach { warning in
                lines.append("- \(warning)")
            }
        }

        lines.append("")
        lines.append("远程视角")
        if let remote = snapshot.remote {
            if let fetchError = remote.fetchError?.trimmedOrEmpty.nilIfEmpty {
                lines.append("- 远程状态读取失败：\(fetchError)")
            } else {
                if let device = remote.device {
                    lines.append("- 设备状态：\(device.status.statusTitle) · 最近心跳 \(formatDate(device.lastSeenAt)) · 槽位 \(device.runningTaskCount)/\(device.maxParallelTasks)")
                } else {
                    lines.append("- 控制面里暂未找到当前设备记录。")
                }

                lines.append("- 远程总运行中 \(remote.totalRunningCount)（托管 \(remote.runningManagedRunCount) · 独立任务 \(remote.unmanagedRunningTaskCount) · Codex 推理 \(remote.observedRunningCodexCount)）")
                lines.append("- 托管运行 \(remote.totalManagedRunCount)（其中运行中 \(remote.runningManagedRunCount)）")
                if remote.managedRuns.isEmpty {
                    lines.append("  - 当前没有指向本机的托管运行。")
                } else {
                    remote.managedRuns.forEach { run in
                        let path = run.relativePath?.trimmedOrEmpty.nilIfEmpty ?? "工作区根目录"
                        lines.append("  - [\(run.status.statusTitle)] \(run.title) · \(run.workspaceID)/\(path) · \(run.deviceID ?? "待分配")")
                    }
                }

                lines.append("- Codex 会话 \(remote.totalCodexSessionCount)（观测推理中 \(remote.observedRunningCodexCount)）")
                if remote.codexSessions.isEmpty {
                    lines.append("  - 当前没有属于本机的 Codex 会话。")
                } else {
                    remote.codexSessions.forEach { session in
                        lines.append("  - [\(session.state.statusTitle(lastTurnStatus: session.lastTurnStatus))] \(session.name?.trimmedOrEmpty.nilIfEmpty ?? session.preview.displaySnippet(limit: 48)) · \(session.cwd)")
                    }
                }
            }
        } else if let reason = snapshot.remoteSkippedReason {
            lines.append("- \(reason)")
        } else {
            lines.append("- 当前没有远程状态。")
        }

        return lines.joined(separator: "\n")
    }

    private static func renderLocalTask(_ task: AgentLocalTaskSnapshot) -> [String] {
        var lines: [String] = []
        let title = task.task.title.trimmedOrEmpty.nilIfEmpty ?? task.task.id
        lines.append("- [\(localTaskStatusTitle(task))] \(title)")
        lines.append("  任务: \(task.task.id) · \(task.task.kind.displayName) · 工作区 \(task.task.workspaceID)")
        if let relativePath = task.task.relativePath?.trimmedOrEmpty.nilIfEmpty {
            lines.append("  目录: \(relativePath)")
        }
        if let cwd = task.cwd?.trimmedOrEmpty.nilIfEmpty {
            lines.append("  绝对路径: \(cwd)")
        }
        if let pid = task.pid {
            lines.append("  PID: \(pid)")
        }
        if let threadID = task.codexThreadID?.trimmedOrEmpty.nilIfEmpty {
            lines.append("  Codex 线程: \(threadID)")
        }
        if let managedRunStatus = task.managedRunStatus {
            lines.append("  托管状态: \(managedRunStatus.statusTitle)")
        }
        if task.stopRequested {
            lines.append("  停止请求: 已发出")
        }
        if let startedAt = task.startedAt {
            lines.append("  启动时间: \(formatDate(startedAt))")
        }
        if let lastSeenAt = task.lastSeenAt {
            lines.append("  最近刷新: \(formatDate(lastSeenAt))")
        }
        if let warning = task.runtimeWarning?.trimmedOrEmpty.nilIfEmpty {
            lines.append("  运行告警: \(warning)")
        }
        lines.append("  日志: \(task.logPath)")
        return lines
    }

    private static func localTaskStatusTitle(_ task: AgentLocalTaskSnapshot) -> String {
        if let managedRunStatus = task.managedRunStatus {
            return managedRunStatus.statusTitle
        }
        if task.stopRequested {
            return "停止中"
        }
        return task.task.status.statusTitle
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

private struct PersistedShellRuntimeRecord: Codable, Sendable {
    var taskID: String
    var pid: Int32
    var cwd: String
    var startedAt: Date
    var lastSeenAt: Date
    var logOffset: UInt64
    var stopRequested: Bool
}

private struct PersistedManagedCodexRuntimeRecord: Codable, Sendable {
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

private func compareManagedRuns(lhs: ManagedRunSummary, rhs: ManagedRunSummary) -> Bool {
    if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
    }
    return lhs.createdAt > rhs.createdAt
}

private func compareCodexSessions(lhs: CodexSessionSummary, rhs: CodexSessionSummary) -> Bool {
    if lhs.updatedAt != rhs.updatedAt {
        return lhs.updatedAt > rhs.updatedAt
    }
    return lhs.createdAt > rhs.createdAt
}

private extension CodexSessionSummary {
    var isRunningLike: Bool {
        state == .running || lastTurnStatus == "inProgress"
    }
}

private extension TaskKind {
    var displayName: String {
        switch self {
        case .shell:
            return "Shell"
        case .codex:
            return "Codex"
        }
    }
}

private extension TaskStatus {
    var statusTitle: String {
        switch self {
        case .queued:
            return "排队中"
        case .running:
            return "运行中"
        case .succeeded:
            return "已完成"
        case .failed:
            return "失败"
        case .stopRequested:
            return "停止中"
        case .cancelled:
            return "已取消"
        }
    }
}

private extension ManagedRunStatus {
    var statusTitle: String {
        switch self {
        case .queued:
            return "排队中"
        case .launching:
            return "启动中"
        case .running:
            return "运行中"
        case .waitingInput:
            return "等待输入"
        case .interrupting:
            return "中断中"
        case .stopRequested:
            return "停止中"
        case .succeeded:
            return "已完成"
        case .failed:
            return "失败"
        case .interrupted:
            return "已中断"
        case .cancelled:
            return "已取消"
        }
    }
}

private extension DeviceStatus {
    var statusTitle: String {
        switch self {
        case .online:
            return "在线"
        case .offline:
            return "离线"
        }
    }
}

private extension CodexSessionState {
    func statusTitle(lastTurnStatus: String?) -> String {
        if lastTurnStatus == "inProgress" || self == .running {
            return "推理中"
        }

        switch self {
        case .idle:
            return "待命"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        case .interrupted:
            return "已中断"
        case .running:
            return "推理中"
        case .unknown:
            return "未知"
        }
    }
}

private extension String {
    var trimmedOrEmpty: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func displaySnippet(limit: Int) -> String {
        guard count > limit else {
            return self
        }
        return String(prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
