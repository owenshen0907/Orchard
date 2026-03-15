import Darwin
import Foundation
import OrchardCore

private enum RunningTaskHandle {
    case process(TaskProcessController)
    case conversation(OrchardRuntimeConversationController)

    func requestStop() async {
        switch self {
        case let .process(controller):
            controller.requestStop()
        case let .conversation(controller):
            await controller.requestStop()
        }
    }

    var conversationController: OrchardRuntimeConversationController? {
        switch self {
        case .process:
            return nil
        case let .conversation(controller):
            return controller
        }
    }
}

actor OrchardAgentService {
    private let config: ResolvedAgentConfig
    private let configURL: URL?
    private let stateURL: URL?
    private let client: OrchardAPIClient
    private let stateStore: AgentStateStore
    private let session: URLSession
    private let tasksDirectory: URL
    private let metricsCollector: SystemMetricsCollector
    private let codexDesktopMetricsCollector: CodexDesktopMetricsCollector
    private let codexBridge: CodexAppServerBridge
    private let projectContextBridge: ProjectContextCommandBridge
    private var webSocketTask: URLSessionWebSocketTask?
    private var runningTasks: [String: RunningTaskHandle] = [:]
    private var pendingLogs: [String: [String]] = [:]
    private var pendingManagedConversationProgress: [String: ManagedCodexTaskSnapshot] = [:]
    private var logFlushTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var statusPageTask: Task<Void, Never>?
    private var pendingTaskUpdates: [String: AgentTaskUpdatePayload]
    private var shouldRun = true

    init(
        config: ResolvedAgentConfig,
        stateStore: AgentStateStore,
        tasksDirectory: URL,
        configURL: URL? = nil,
        stateURL: URL? = nil,
        metricsCollector: SystemMetricsCollector = SystemMetricsCollector(),
        codexDesktopMetricsCollector: CodexDesktopMetricsCollector = CodexDesktopMetricsCollector()
    ) {
        self.config = config
        self.configURL = configURL
        self.stateURL = stateURL
        self.client = OrchardAPIClient(baseURL: config.serverURL)
        self.stateStore = stateStore
        self.session = URLSession(configuration: .default)
        self.tasksDirectory = tasksDirectory
        self.metricsCollector = metricsCollector
        self.codexDesktopMetricsCollector = codexDesktopMetricsCollector
        self.codexBridge = CodexAppServerBridge(config: config)
        self.projectContextBridge = ProjectContextCommandBridge(config: config)
        self.pendingTaskUpdates = [:]
    }

    func run() async throws {
        try FileManager.default.createDirectory(at: tasksDirectory, withIntermediateDirectories: true, attributes: nil)
        startLocalStatusPageIfNeeded()
        defer { stopLocalStatusPage() }

        let bootstrap = try await stateStore.bootstrap()
        pendingTaskUpdates = Dictionary(uniqueKeysWithValues: bootstrap.pendingTaskUpdates.map { ($0.taskID, $0) })
        try await restoreActiveTasks(taskIDs: bootstrap.activeTaskIDs)
        var backoff: UInt64 = 1

        while shouldRun && !Task.isCancelled {
            do {
                try await registerAgent()
                try await connectAndServe()
                backoff = 1
            } catch {
                if shouldStop(for: error) {
                    break
                }
                print("[OrchardAgent] session error: \(error)")
                try await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = nextBackoff(from: backoff)
            }
        }
    }

    func stop() {
        shouldRun = false
        logFlushTask?.cancel()
        logFlushTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopLocalStatusPage()
        webSocketTask?.cancel(with: .goingAway, reason: nil)
    }

    private func registerAgent() async throws {
        _ = try await client.registerAgent(
            AgentRegistrationRequest(
                enrollmentToken: config.enrollmentToken,
                deviceID: config.deviceID,
                name: config.deviceName,
                hostName: config.hostName,
                platform: .macOS,
                capabilities: [.shell, .filesystem, .git, .codex],
                maxParallelTasks: config.maxParallelTasks,
                workspaces: config.workspaceRoots,
                localStatusPageHost: config.localStatusPageEnabled ? config.localStatusPageHost : nil,
                localStatusPagePort: config.localStatusPageEnabled ? config.localStatusPagePort : nil
            )
        )
    }

    private func connectAndServe() async throws {
        let url = try client.makeAgentSessionURL(deviceID: config.deviceID, enrollmentToken: config.enrollmentToken)
        let socket = session.webSocketTask(with: url)
        webSocketTask = socket
        socket.resume()

        try await sendMessage(.hello(AgentHelloPayload(
            metrics: currentDeviceMetrics(),
            runningTaskIDs: runningTaskIDs()
        )))
        try await flushPendingTaskUpdates()
        await flushPendingLogs()
        await sendHeartbeat()
        await flushPendingManagedConversationProgress()
        await replayRunningTaskState()

        heartbeatTask = Task { [heartbeatInterval = config.heartbeatIntervalSeconds] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(heartbeatInterval) * 1_000_000_000)
                await self.sendHeartbeat()
            }
        }
        defer {
            heartbeatTask?.cancel()
            heartbeatTask = nil
            webSocketTask = nil
            socket.cancel(with: .goingAway, reason: nil)
        }

        while shouldRun && !Task.isCancelled {
            let message = try await socket.receive()
            try await handle(message)
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) async throws {
        let data: Data
        switch message {
        case let .string(text):
            data = Data(text.utf8)
        case let .data(raw):
            data = raw
        @unknown default:
            return
        }

        switch try OrchardJSON.decoder.decode(ServerSocketMessage.self, from: data) {
        case let .taskAssigned(task):
            try await startTask(task)
        case let .taskStop(command):
            if let controller = runningTasks[command.taskID] {
                await controller.requestStop()
            }
        case let .codexCommand(command):
            let response = await codexBridge.handle(command)
            try await sendMessage(.codexCommandResult(response))
        case let .projectContextCommand(command):
            let response = await projectContextBridge.handle(command)
            try await sendMessage(.projectContextCommandResult(response))
        }
    }

    private func startTask(_ task: TaskRecord) async throws {
        if runningTasks[task.id] != nil {
            return
        }
        guard runningTasks.count < config.maxParallelTasks else {
            try await sendTerminalUpdate(AgentTaskUpdatePayload(taskID: task.id, status: .failed, summary: "Agent at capacity."))
            return
        }
        guard let workspace = config.workspaceRoots.first(where: { $0.id == task.workspaceID }) else {
            try await sendTerminalUpdate(AgentTaskUpdatePayload(taskID: task.id, status: .failed, summary: "Workspace \(task.workspaceID) is not configured on this device."))
            return
        }

        let cwd = try OrchardWorkspacePath.resolve(rootPath: workspace.rootPath, relativePath: task.relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            try await sendTerminalUpdate(AgentTaskUpdatePayload(taskID: task.id, status: .failed, summary: "Working directory does not exist: \(cwd.path)"))
            return
        }

        switch task.kind {
        case .shell:
            try await startProcessBackedTask(task, cwd: cwd)
        case .codex:
            try await startManagedConversationTask(task, cwd: cwd)
        }
    }

    private func completeTask(
        taskID: String,
        result: TaskExecutionResult,
        managedSnapshot: ManagedCodexTaskSnapshot? = nil
    ) async {
        runningTasks.removeValue(forKey: taskID)
        pendingManagedConversationProgress.removeValue(forKey: taskID)
        persistTerminalTaskRecord(
            taskID: taskID,
            result: result
        )
        do {
            await flushLogs(for: taskID)
            try await sendTerminalUpdate(AgentTaskUpdatePayload(
                taskID: taskID,
                status: result.status,
                exitCode: result.exitCode,
                summary: result.summary,
                managedRunStatus: managedSnapshot?.managedRunStatus,
                pid: managedSnapshot?.pid,
                codexSessionID: managedSnapshot?.codexSessionID,
                lastUserPrompt: managedSnapshot?.lastUserPrompt,
                lastAssistantPreview: managedSnapshot?.lastAssistantPreview
            ))
        } catch {
            handleSocketSendFailure(error, context: "failed to send completion for \(taskID)")
        }
    }

    private func persistTerminalTaskRecord(
        taskID: String,
        result: TaskExecutionResult
    ) {
        let runtimeDirectory = tasksDirectory.appendingPathComponent(taskID, isDirectory: true)
        guard var task = try? TaskProcessController.loadPersistedTask(runtimeDirectory: runtimeDirectory) else {
            return
        }

        let now = Date()
        task.status = result.status
        task.updatedAt = now
        task.finishedAt = task.finishedAt ?? now
        task.exitCode = result.exitCode
        task.summary = result.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? task.summary : result.summary
        if result.status == .cancelled {
            task.stopRequestedAt = task.stopRequestedAt ?? now
        }

        let taskURL = runtimeDirectory.appendingPathComponent("task.json", isDirectory: false)
        guard let data = try? OrchardJSON.encoder.encode(task) else {
            return
        }
        try? data.write(to: taskURL, options: .atomic)
    }

    private func restoreActiveTasks(taskIDs: [String]) async throws {
        for taskID in taskIDs.sorted() {
            let runtimeDirectory = tasksDirectory.appendingPathComponent(taskID, isDirectory: true)

            do {
                let task = try TaskProcessController.loadPersistedTask(runtimeDirectory: runtimeDirectory)
                guard let workspace = config.workspaceRoots.first(where: { $0.id == task.workspaceID }) else {
                    try await stageRestoreFailure(taskID: taskID, summary: "agent restarted: workspace missing")
                    continue
                }

                let cwd = try OrchardWorkspacePath.resolve(rootPath: workspace.rootPath, relativePath: task.relativePath)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    try await stageRestoreFailure(taskID: taskID, summary: "agent restarted: working directory missing")
                    continue
                }

                switch task.kind {
                case .shell:
                    let runner = TaskRunnerFactory.runner(for: task.kind)
                    let launchSpec = try runner.makeLaunchSpec(task: task, cwd: cwd, config: config)
                    let recovery = try TaskProcessController.recover(
                        task: task,
                        runtimeDirectory: runtimeDirectory,
                        launchSpec: launchSpec,
                        lineHandler: { line in
                            Task { await self.enqueueLog(taskID: task.id, line: line) }
                        },
                        completion: { result in
                            Task { await self.completeTask(taskID: task.id, result: result) }
                        }
                    )

                    switch recovery {
                    case let .attached(controller):
                        runningTasks[task.id] = .process(controller)
                    case let .finished(result):
                        await completeTask(taskID: task.id, result: result)
                    case .unavailable:
                        try await stageRestoreFailure(taskID: taskID, summary: "agent restarted")
                    }
                case .codex:
                    let driver = try OrchardRuntimeConversationDriverFactory.driver(for: task, config: config)
                    let recovery = try await driver.recoverController(context: OrchardRuntimeConversationLaunchContext(
                        task: task,
                        runtimeDirectory: runtimeDirectory,
                        cwd: cwd,
                        lineHandler: { line in
                            Task { await self.enqueueLog(taskID: task.id, line: line) }
                        },
                        progressHandler: { snapshot in
                            Task { await self.sendManagedConversationProgress(taskID: task.id, snapshot: snapshot) }
                        },
                        completion: { terminal in
                            Task {
                                await self.completeTask(
                                    taskID: task.id,
                                    result: terminal.executionResult,
                                    managedSnapshot: terminal.snapshot
                                )
                            }
                        }
                    ))

                    switch recovery {
                    case let .attached(controller):
                        runningTasks[task.id] = .conversation(controller)
                    case let .finished(terminal):
                        await completeTask(
                            taskID: task.id,
                            result: terminal.executionResult,
                            managedSnapshot: terminal.snapshot
                        )
                    case .unavailable:
                        try await stageRestoreFailure(taskID: taskID, summary: "agent restarted")
                    }
                }
            } catch {
                try await stageRestoreFailure(taskID: taskID, summary: "agent restarted: \(error.localizedDescription)")
            }
        }
    }

    private func enqueueLog(taskID: String, line: String) {
        pendingLogs[taskID, default: []].append(String(line.prefix(4096)))

        if pendingLogs[taskID, default: []].count >= 20 {
            Task { await self.flushLogs(for: taskID) }
            return
        }

        if logFlushTask == nil {
            logFlushTask = Task {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.flushPendingLogs()
            }
        }
    }

    private func flushLogs(for taskID: String) async {
        guard let lines = pendingLogs[taskID], !lines.isEmpty else { return }
        do {
            try await sendMessage(.logBatch(AgentLogBatchPayload(taskID: taskID, lines: lines)))
            pendingLogs.removeValue(forKey: taskID)
        } catch {
            handleSocketSendFailure(error, context: "log flush failed for \(taskID)")
        }
    }

    private func flushPendingLogs() async {
        let taskIDs = pendingLogs.keys.sorted()
        for taskID in taskIDs {
            await flushLogs(for: taskID)
        }
        logFlushTask = nil
    }

    private func flushPendingManagedConversationProgress() async {
        let snapshots = pendingManagedConversationProgress
        for taskID in snapshots.keys.sorted() {
            guard let snapshot = snapshots[taskID] else { continue }
            await sendManagedConversationProgress(taskID: taskID, snapshot: snapshot)
        }
    }

    private func flushPendingTaskUpdates() async throws {
        guard !pendingTaskUpdates.isEmpty else { return }
        for taskID in pendingTaskUpdates.keys.sorted() {
            guard let payload = pendingTaskUpdates[taskID] else { continue }
            try await sendMessage(.taskUpdate(payload))
            pendingTaskUpdates.removeValue(forKey: taskID)
            try await stateStore.markTaskUpdateDelivered(taskID)
        }
    }

    private func sendHeartbeat() async {
        do {
            try await sendMessage(.heartbeat(AgentHeartbeatPayload(
                metrics: currentDeviceMetrics(),
                runningTaskIDs: runningTaskIDs()
            )))
            try await flushPendingTaskUpdates()
            await flushPendingLogs()
            await flushPendingManagedConversationProgress()
        } catch {
            guard !shouldStop(for: error), !isExpectedDisconnect(error) else {
                return
            }
            handleSocketSendFailure(error, context: "heartbeat failed")
        }
    }

    private func sendTerminalUpdate(_ payload: AgentTaskUpdatePayload) async throws {
        try await stagePendingTaskUpdate(payload)
        try await flushPendingTaskUpdates()
    }

    private func sendManagedConversationProgress(taskID: String, snapshot: ManagedCodexTaskSnapshot) async {
        pendingManagedConversationProgress[taskID] = snapshot
        let payload = AgentTaskUpdatePayload(
            taskID: taskID,
            status: .running,
            summary: snapshot.summary,
            managedRunStatus: snapshot.managedRunStatus,
            pid: snapshot.pid,
            codexSessionID: snapshot.codexSessionID,
            lastUserPrompt: snapshot.lastUserPrompt,
            lastAssistantPreview: snapshot.lastAssistantPreview
        )

        do {
            try await sendMessage(.taskUpdate(payload))
        } catch {
            guard !shouldStop(for: error), !isExpectedDisconnect(error) else {
                return
            }
            handleSocketSendFailure(error, context: "managed codex progress update failed for \(taskID)")
        }
    }

    private func stagePendingTaskUpdate(_ payload: AgentTaskUpdatePayload) async throws {
        try await stateStore.stageTaskUpdate(payload)
        pendingTaskUpdates[payload.taskID] = payload
    }

    private func stageRestoreFailure(taskID: String, summary: String) async throws {
        persistTerminalTaskRecord(
            taskID: taskID,
            result: TaskExecutionResult(status: .failed, exitCode: nil, summary: summary)
        )
        try await stagePendingTaskUpdate(AgentTaskUpdatePayload(
            taskID: taskID,
            status: .failed,
            summary: summary
        ))
    }

    private func sendMessage(_ message: AgentSocketMessage) async throws {
        guard let webSocketTask else {
            throw NSError(domain: "OrchardAgent", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "WebSocket is not connected.",
            ])
        }
        let text = String(decoding: try OrchardJSON.encoder.encode(message), as: UTF8.self)
        try await webSocketTask.send(.string(text))
    }

    private func handleSocketSendFailure(_ error: Error, context: String) {
        print("[OrchardAgent] \(context): \(error)")
        disconnectCurrentSession()
    }

    private func disconnectCurrentSession() {
        guard let socket = webSocketTask else {
            return
        }
        webSocketTask = nil
        socket.cancel(with: .goingAway, reason: nil)
    }

    private func runningTaskIDs() -> [String] {
        runningTasks.keys.sorted()
    }

    private func currentDeviceMetrics() -> DeviceMetrics {
        metricsCollector.snapshot(
            runningTasks: runningTasks.count,
            codexDesktop: codexDesktopMetricsCollector.snapshot()
        )
    }

    private func replayRunningTaskState() async {
        let tasks = runningTasks
        for taskID in tasks.keys.sorted() {
            guard
                let handle = tasks[taskID],
                let controller = handle.conversationController,
                let snapshot = await controller.currentSnapshot()
            else {
                continue
            }
            await sendManagedConversationProgress(taskID: taskID, snapshot: snapshot)
        }
    }

    private func startProcessBackedTask(_ task: TaskRecord, cwd: URL) async throws {
        let runner = TaskRunnerFactory.runner(for: task.kind)
        let launchSpec = try runner.makeLaunchSpec(task: task, cwd: cwd, config: config)
        let controller = try TaskProcessController(
            task: task,
            runtimeDirectory: tasksDirectory.appendingPathComponent(task.id, isDirectory: true),
            launchSpec: launchSpec,
            lineHandler: { line in
                Task { await self.enqueueLog(taskID: task.id, line: line) }
            },
            completion: { result in
                Task { await self.completeTask(taskID: task.id, result: result) }
            }
        )

        runningTasks[task.id] = .process(controller)
        try await stateStore.markTaskStarted(task.id)
        do {
            try controller.start()
        } catch {
            runningTasks.removeValue(forKey: task.id)
            persistTerminalTaskRecord(
                taskID: task.id,
                result: TaskExecutionResult(status: .failed, exitCode: nil, summary: String(describing: error))
            )
            try await sendTerminalUpdate(AgentTaskUpdatePayload(taskID: task.id, status: .failed, summary: String(describing: error)))
        }
    }

    @discardableResult
    private func startManagedConversationTask(_ task: TaskRecord, cwd: URL) async throws -> Bool {
        let driver = try OrchardRuntimeConversationDriverFactory.driver(for: task, config: config)
        let controller = try driver.makeController(context: OrchardRuntimeConversationLaunchContext(
            task: task,
            runtimeDirectory: tasksDirectory.appendingPathComponent(task.id, isDirectory: true),
            cwd: cwd,
            lineHandler: { line in
                Task { await self.enqueueLog(taskID: task.id, line: line) }
            },
            progressHandler: { snapshot in
                Task { await self.sendManagedConversationProgress(taskID: task.id, snapshot: snapshot) }
            },
            completion: { terminal in
                Task {
                    await self.completeTask(
                        taskID: task.id,
                        result: terminal.executionResult,
                        managedSnapshot: terminal.snapshot
                    )
                }
            }
        ))

        runningTasks[task.id] = .conversation(controller)
        try await stateStore.markTaskStarted(task.id)
        do {
            try await controller.start()
            return true
        } catch {
            runningTasks.removeValue(forKey: task.id)
            persistTerminalTaskRecord(
                taskID: task.id,
                result: TaskExecutionResult(status: .failed, exitCode: nil, summary: String(describing: error))
            )
            try await sendTerminalUpdate(AgentTaskUpdatePayload(taskID: task.id, status: .failed, summary: String(describing: error)))
            return false
        }
    }

    func createLocalManagedRun(_ request: AgentLocalManagedRunRequest) async throws -> TaskRecord {
        guard runningTasks.count < config.maxParallelTasks else {
            throw NSError(domain: "OrchardAgent", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "当前宿主机已达到并发上限，请先停止或等待已有任务结束。",
            ])
        }

        let workspaceID = request.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace = config.workspaceRoots.first(where: { $0.id == workspaceID }) else {
            throw NSError(domain: "OrchardAgent", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "当前设备没有配置工作区 \(workspaceID)。",
            ])
        }

        let trimmedRelativePath = request.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let relativePath = trimmedRelativePath.isEmpty ? nil : trimmedRelativePath
        let prompt = request.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw NSError(domain: "OrchardAgent", code: 33, userInfo: [
                NSLocalizedDescriptionKey: "任务说明不能为空。",
            ])
        }

        let cwd = try OrchardWorkspacePath.resolve(rootPath: workspace.rootPath, relativePath: relativePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NSError(domain: "OrchardAgent", code: 34, userInfo: [
                NSLocalizedDescriptionKey: "工作目录不存在：\(cwd.path)",
            ])
        }

        let trimmedTitle = request.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = (trimmedTitle.isEmpty ? nil : trimmedTitle)
            ?? defaultLocalManagedTaskTitle(from: prompt)
        let now = Date()
        let task = TaskRecord(
            id: UUID().uuidString.lowercased(),
            title: title,
            kind: .codex,
            workspaceID: workspaceID,
            relativePath: relativePath,
            priority: .normal,
            status: .running,
            payload: .codex(CodexTaskPayload(prompt: prompt, driver: request.driver)),
            preferredDeviceID: config.deviceID,
            assignedDeviceID: config.deviceID,
            createdAt: now,
            updatedAt: now,
            startedAt: now
        )

        let didStart = try await startManagedConversationTask(task, cwd: cwd)
        guard didStart else {
            throw NSError(domain: "OrchardAgent", code: 35, userInfo: [
                NSLocalizedDescriptionKey: "本地任务启动失败，请查看待回传更新或本地日志。",
            ])
        }

        return task
    }

    func continueLocalManagedTask(taskID: String, prompt: String) async throws {
        let trimmedTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw NSError(domain: "OrchardAgent", code: 36, userInfo: [
                NSLocalizedDescriptionKey: "继续内容不能为空。",
            ])
        }
        guard let controller = runningTasks[trimmedTaskID]?.conversationController else {
            throw NSError(domain: "OrchardAgent", code: 37, userInfo: [
                NSLocalizedDescriptionKey: "没有找到运行中的本地 Codex 任务：\(trimmedTaskID)",
            ])
        }
        try await controller.continue(with: trimmedPrompt)
    }

    func interruptLocalManagedTask(taskID: String) async throws {
        let trimmedTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let controller = runningTasks[trimmedTaskID]?.conversationController else {
            throw NSError(domain: "OrchardAgent", code: 38, userInfo: [
                NSLocalizedDescriptionKey: "没有找到运行中的本地 Codex 任务：\(trimmedTaskID)",
            ])
        }
        try await controller.requestInterrupt()
    }

    func stopLocalTask(taskID: String) async throws {
        let trimmedTaskID = taskID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let handle = runningTasks[trimmedTaskID] else {
            throw NSError(domain: "OrchardAgent", code: 39, userInfo: [
                NSLocalizedDescriptionKey: "没有找到运行中的本地任务：\(trimmedTaskID)",
            ])
        }
        await handle.requestStop()
    }

    private func nextBackoff(from current: UInt64) -> UInt64 {
        switch current {
        case ..<1:
            return 1
        case 1:
            return 2
        case 2:
            return 5
        case 5:
            return 10
        default:
            return 30
        }
    }

    private func shouldStop(for error: Error) -> Bool {
        !shouldRun || Task.isCancelled || error is CancellationError
    }

    private func isExpectedDisconnect(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func startLocalStatusPageIfNeeded() {
        guard config.localStatusPageEnabled, statusPageTask == nil else {
            return
        }

        do {
            let server = AgentStatusHTTPServer(
                options: try makeLocalStatusPageOptions(),
                localActions: AgentStatusLocalActions(
                    createManagedRun: { request in
                        try await self.createLocalManagedRun(request)
                    },
                    continueManagedTask: { taskID, prompt in
                        try await self.continueLocalManagedTask(taskID: taskID, prompt: prompt)
                    },
                    interruptManagedTask: { taskID in
                        try await self.interruptLocalManagedTask(taskID: taskID)
                    },
                    stopTask: { taskID in
                        try await self.stopLocalTask(taskID: taskID)
                    }
                )
            )
            statusPageTask = Task {
                do {
                    try await server.run()
                } catch is CancellationError {
                    return
                } catch {
                    print("[OrchardAgent] local status page failed: \(error.localizedDescription)")
                }
            }
        } catch {
            print("[OrchardAgent] local status page failed: \(error.localizedDescription)")
        }
    }

    private func stopLocalStatusPage() {
        statusPageTask?.cancel()
        statusPageTask = nil
    }

    private func makeLocalStatusPageOptions() throws -> AgentStatusOptions {
        try AgentStatusOptions(
            configURL: configURL ?? OrchardAgentPaths.configURL(),
            stateURL: stateURL ?? OrchardAgentPaths.stateURL(),
            tasksDirectoryURL: tasksDirectory,
            includeRemote: true,
            accessKey: config.controlPlaneAccessKey ?? ProcessInfo.processInfo.environment["ORCHARD_ACCESS_KEY"],
            serve: true,
            bindHost: config.localStatusPageHost,
            port: config.localStatusPagePort
        )
    }

    private func defaultLocalManagedTaskTitle(from prompt: String) -> String {
        let firstLine = prompt
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "新的本地 Codex 任务"
        if firstLine.count <= 28 {
            return firstLine
        }
        return String(firstLine.prefix(28)) + "..."
    }
}
