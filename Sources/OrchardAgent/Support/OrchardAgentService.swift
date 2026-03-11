import Darwin
import Foundation
import OrchardCore

actor OrchardAgentService {
    private let config: ResolvedAgentConfig
    private let client: OrchardAPIClient
    private let stateStore: AgentStateStore
    private let session: URLSession
    private let tasksDirectory: URL
    private let metricsCollector: SystemMetricsCollector
    private var webSocketTask: URLSessionWebSocketTask?
    private var runningTasks: [String: TaskProcessController] = [:]
    private var pendingLogs: [String: [String]] = [:]
    private var logFlushTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pendingTaskUpdates: [String: AgentTaskUpdatePayload]
    private var shouldRun = true

    init(config: ResolvedAgentConfig, stateStore: AgentStateStore, tasksDirectory: URL) {
        self.config = config
        self.client = OrchardAPIClient(baseURL: config.serverURL)
        self.stateStore = stateStore
        self.session = URLSession(configuration: .default)
        self.tasksDirectory = tasksDirectory
        self.metricsCollector = SystemMetricsCollector()
        self.pendingTaskUpdates = [:]
    }

    func run() async throws {
        pendingTaskUpdates = Dictionary(uniqueKeysWithValues: try await stateStore.bootstrap().map { ($0.taskID, $0) })
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
        for controller in runningTasks.values {
            controller.requestStop()
        }
        logFlushTask?.cancel()
        logFlushTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
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
                workspaces: config.workspaceRoots
            )
        )
    }

    private func connectAndServe() async throws {
        let url = try client.makeAgentSessionURL(deviceID: config.deviceID, enrollmentToken: config.enrollmentToken)
        let socket = session.webSocketTask(with: url)
        webSocketTask = socket
        socket.resume()

        try await sendMessage(.hello(AgentHelloPayload(runningTaskIDs: runningTaskIDs())))
        try await flushPendingTaskUpdates()
        await flushPendingLogs()

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
            runningTasks[command.taskID]?.requestStop()
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

        runningTasks[task.id] = controller
        try await stateStore.markTaskStarted(task.id)
        do {
            try controller.start()
        } catch {
            runningTasks.removeValue(forKey: task.id)
            try await sendTerminalUpdate(AgentTaskUpdatePayload(taskID: task.id, status: .failed, summary: String(describing: error)))
        }
    }

    private func completeTask(taskID: String, result: TaskExecutionResult) async {
        runningTasks.removeValue(forKey: taskID)
        do {
            await flushLogs(for: taskID)
            try await sendTerminalUpdate(AgentTaskUpdatePayload(
                taskID: taskID,
                status: result.status,
                exitCode: result.exitCode,
                summary: result.summary
            ))
        } catch {
            print("[OrchardAgent] failed to send completion for \(taskID): \(error)")
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
            print("[OrchardAgent] log flush failed for \(taskID): \(error)")
        }
    }

    private func flushPendingLogs() async {
        let taskIDs = pendingLogs.keys.sorted()
        for taskID in taskIDs {
            await flushLogs(for: taskID)
        }
        logFlushTask = nil
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
                metrics: metricsCollector.snapshot(runningTasks: runningTasks.count),
                runningTaskIDs: runningTaskIDs()
            )))
            try await flushPendingTaskUpdates()
            await flushPendingLogs()
        } catch {
            guard !shouldStop(for: error), !isExpectedDisconnect(error) else {
                return
            }
            print("[OrchardAgent] heartbeat failed: \(error)")
        }
    }

    private func sendTerminalUpdate(_ payload: AgentTaskUpdatePayload) async throws {
        try await stateStore.stageTaskUpdate(payload)
        pendingTaskUpdates[payload.taskID] = payload
        try await flushPendingTaskUpdates()
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

    private func runningTaskIDs() -> [String] {
        runningTasks.keys.sorted()
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
}
