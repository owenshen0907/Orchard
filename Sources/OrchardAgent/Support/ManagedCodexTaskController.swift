import Foundation
import OrchardCore

struct ManagedCodexTaskSnapshot: Sendable, Equatable {
    let managedRunStatus: ManagedRunStatus
    let summary: String?
    let pid: Int?
    let codexSessionID: String
    let lastUserPrompt: String?
    let lastAssistantPreview: String?
}

struct ManagedCodexTaskTerminalResult: Sendable {
    let executionResult: TaskExecutionResult
    let snapshot: ManagedCodexTaskSnapshot
}

enum ManagedCodexTaskRecovery {
    case attached(ManagedCodexTaskController)
    case finished(ManagedCodexTaskTerminalResult)
    case unavailable
}

private struct ManagedCodexRuntimeRecord: Codable, Sendable {
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

actor ManagedCodexTaskController {
    private let task: TaskRecord
    private let runtimeDirectory: URL
    private let cwd: URL
    private let codexBinaryPath: String
    private let lineHandler: @Sendable (String) -> Void
    private let progressHandler: @Sendable (ManagedCodexTaskSnapshot) -> Void
    private let completion: @Sendable (ManagedCodexTaskTerminalResult) -> Void
    private let taskURL: URL
    private let runtimeURL: URL
    private let logURL: URL

    private var connection: ManagedCodexAppServerConnection?
    private var monitorTask: Task<Void, Never>?
    private var threadID: String?
    private var activeTurnID: String?
    private var startedAt: Date?
    private var stopRequested = false
    private var completionSent = false
    private var emittedTextLengths: [String: Int] = [:]
    private var lastManagedRunStatus: ManagedRunStatus?
    private var lastUserPrompt: String?
    private var lastAssistantPreview: String?
    private var lastSentSnapshot: ManagedCodexTaskSnapshot?
    private var terminalResult: ManagedCodexTaskTerminalResult?
    private var consecutiveReadFailures = 0

    init(
        task: TaskRecord,
        runtimeDirectory: URL,
        cwd: URL,
        codexBinaryPath: String,
        lineHandler: @escaping @Sendable (String) -> Void,
        progressHandler: @escaping @Sendable (ManagedCodexTaskSnapshot) -> Void,
        completion: @escaping @Sendable (ManagedCodexTaskTerminalResult) -> Void
    ) throws {
        self.task = task
        self.runtimeDirectory = runtimeDirectory
        self.cwd = cwd
        self.codexBinaryPath = codexBinaryPath
        self.lineHandler = lineHandler
        self.progressHandler = progressHandler
        self.completion = completion
        self.taskURL = runtimeDirectory.appendingPathComponent("task.json", isDirectory: false)
        self.runtimeURL = runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false)
        self.logURL = runtimeDirectory.appendingPathComponent("combined.log", isDirectory: false)
        try prepareManagedCodexFilesystem(
            runtimeDirectory: runtimeDirectory,
            taskURL: taskURL,
            logURL: logURL,
            task: task
        )
    }

    private init(
        task: TaskRecord,
        runtimeDirectory: URL,
        cwd: URL,
        codexBinaryPath: String,
        restoredRuntime: ManagedCodexRuntimeRecord,
        lineHandler: @escaping @Sendable (String) -> Void,
        progressHandler: @escaping @Sendable (ManagedCodexTaskSnapshot) -> Void,
        completion: @escaping @Sendable (ManagedCodexTaskTerminalResult) -> Void
    ) throws {
        self.task = task
        self.runtimeDirectory = runtimeDirectory
        self.cwd = cwd
        self.codexBinaryPath = codexBinaryPath
        self.lineHandler = lineHandler
        self.progressHandler = progressHandler
        self.completion = completion
        self.taskURL = runtimeDirectory.appendingPathComponent("task.json", isDirectory: false)
        self.runtimeURL = runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false)
        self.logURL = runtimeDirectory.appendingPathComponent("combined.log", isDirectory: false)
        self.threadID = restoredRuntime.threadID
        self.activeTurnID = restoredRuntime.activeTurnID
        self.startedAt = restoredRuntime.startedAt
        self.stopRequested = restoredRuntime.stopRequested
        self.emittedTextLengths = restoredRuntime.emittedTextLengths
        self.lastManagedRunStatus = restoredRuntime.lastManagedRunStatus
        self.lastUserPrompt = restoredRuntime.lastUserPrompt
        self.lastAssistantPreview = restoredRuntime.lastAssistantPreview
        try prepareManagedCodexFilesystem(
            runtimeDirectory: runtimeDirectory,
            taskURL: taskURL,
            logURL: logURL,
            task: task
        )
    }

    static func recover(
        task: TaskRecord,
        runtimeDirectory: URL,
        cwd: URL,
        codexBinaryPath: String,
        lineHandler: @escaping @Sendable (String) -> Void,
        progressHandler: @escaping @Sendable (ManagedCodexTaskSnapshot) -> Void,
        completion: @escaping @Sendable (ManagedCodexTaskTerminalResult) -> Void
    ) async throws -> ManagedCodexTaskRecovery {
        let runtimeURL = runtimeDirectory.appendingPathComponent("runtime.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: runtimeURL.path) else {
            return .unavailable
        }

        let runtime = try OrchardJSON.decoder.decode(ManagedCodexRuntimeRecord.self, from: Data(contentsOf: runtimeURL))
        let controller = try ManagedCodexTaskController(
            task: task,
            runtimeDirectory: runtimeDirectory,
            cwd: cwd,
            codexBinaryPath: codexBinaryPath,
            restoredRuntime: runtime,
            lineHandler: lineHandler,
            progressHandler: progressHandler,
            completion: completion
        )
        return try await controller.resumeFromPersistedThread()
    }

    func start() async throws {
        do {
            let connection = try ManagedCodexAppServerConnection(codexBinaryPath: codexBinaryPath)
            self.connection = connection
            try await connection.initialize()
            let preparedPrompt = ProjectContextPromptAugmentor.prepare(
                userPrompt: currentPrompt(),
                workspaceURL: cwd
            )

            let startedThread: ManagedCodexThreadStartResponse = try await connection.request(
                method: "thread/start",
                params: ManagedCodexThreadStartParams(
                    cwd: cwd.path,
                    approvalPolicy: "never",
                    sandbox: "workspace-write",
                    experimentalRawEvents: false,
                    persistExtendedHistory: true
                )
            )

            let now = Date()
            threadID = startedThread.thread.id
            startedAt = now
            lastManagedRunStatus = .launching
            try persistRuntime(now: now)
            emitProgressIfNeeded(force: true)

            try await startTurn(
                executionPrompt: preparedPrompt.executionPrompt,
                displayPrompt: preparedPrompt.displayPrompt
            )
            try await pollOnce()

            if !completionSent {
                beginMonitoring()
            }
        } catch {
            connection?.stop()
            connection = nil
            throw error
        }
    }

    func requestStop() async {
        guard !completionSent else { return }
        stopRequested = true
        try? persistRuntime(now: Date())

        guard
            let connection,
            let threadID,
            let activeTurnID
        else {
            finish(with: cancelledResult(summary: "Task cancelled after stop request."))
            return
        }

        do {
            _ = try await connection.request(
                method: "turn/interrupt",
                params: ManagedCodexTurnInterruptParams(threadId: threadID, turnId: activeTurnID)
            ) as ManagedCodexTurnInterruptResponse
        } catch {
            finish(with: cancelledResult(summary: "Task cancelled after stop request."))
            return
        }

        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await self.forceCancelIfNeeded()
        }
    }

    private func resumeFromPersistedThread() async throws -> ManagedCodexTaskRecovery {
        guard let threadID, !threadID.isEmpty else {
            return .unavailable
        }

        do {
            let connection = try ManagedCodexAppServerConnection(codexBinaryPath: codexBinaryPath)
            self.connection = connection
            try await connection.initialize()
            let resumed: ManagedCodexThreadResumeResponse = try await connection.request(
                method: "thread/resume",
                params: ManagedCodexThreadResumeParams(
                    threadId: threadID,
                    cwd: cwd.path,
                    approvalPolicy: "never",
                    sandbox: "workspace-write",
                    persistExtendedHistory: true
                )
            )

            try handle(thread: resumed.thread, at: Date())
            if let terminalResult {
                return .finished(terminalResult)
            }

            emitProgressIfNeeded(force: true)
            beginMonitoring()
            return .attached(self)
        } catch {
            connection?.stop()
            connection = nil
            return .unavailable
        }
    }

    private func beginMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task {
            while !Task.isCancelled {
                await self.monitorIteration()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    private func monitorIteration() async {
        guard !completionSent else { return }
        do {
            try await pollOnce()
            consecutiveReadFailures = 0
        } catch {
            consecutiveReadFailures += 1
            if stopRequested {
                finish(with: cancelledResult(summary: "Task cancelled after stop request."))
            } else if consecutiveReadFailures >= 3 {
                finish(with: failedResult(summary: "Codex app-server 轮询失败：\(error.localizedDescription)"))
            }
        }
    }

    private func pollOnce() async throws {
        guard let connection, let threadID else { return }
        let response: ManagedCodexThreadReadResponse = try await connection.request(
            method: "thread/read",
            params: ManagedCodexThreadReadParams(threadId: threadID, includeTurns: true)
        )
        try handle(thread: response.thread, at: Date())
    }

    private func startTurn(
        executionPrompt: String,
        displayPrompt: String
    ) async throws {
        guard let connection, let threadID else {
            throw NSError(domain: "ManagedCodexTaskController", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Codex 线程尚未初始化。",
            ])
        }

        lastUserPrompt = displayPrompt
        _ = try await connection.request(
            method: "turn/start",
            params: ManagedCodexTurnStartParams(
                threadId: threadID,
                input: [ManagedCodexUserInput(type: "text", text: executionPrompt)]
            )
        ) as ManagedCodexTurnStartResponse
    }

    private func handle(thread: ManagedCodexThread, at timestamp: Date) throws {
        threadID = thread.id
        activeTurnID = thread.turns.last?.id
        let redactedUserMessage = SensitiveTextRedactor.redact(lastUserMessage(in: thread.turns))
        let redactedAssistantMessage = SensitiveTextRedactor.redact(lastAssistantMessage(in: thread.turns))
        lastUserPrompt = ProjectContextPromptAugmentor.extractUserPrompt(from: redactedUserMessage) ?? lastUserPrompt
        lastAssistantPreview = redactedAssistantMessage ?? lastAssistantPreview

        try emitNewLogLines(from: thread)

        let managedStatus = managedStatus(for: thread)
        lastManagedRunStatus = managedStatus
        try persistRuntime(now: timestamp)

        let snapshot = ManagedCodexTaskSnapshot(
            managedRunStatus: managedStatus,
            summary: summary(for: thread, managedStatus: managedStatus),
            pid: connection.map { Int($0.processIdentifier) },
            codexSessionID: thread.id,
            lastUserPrompt: lastUserPrompt,
            lastAssistantPreview: lastAssistantPreview
        )

        if managedStatus.isTerminal {
            finish(with: terminalResult(for: snapshot))
            return
        }

        if !stopRequested {
            emitProgressIfNeeded(snapshot)
        }
    }

    private func managedStatus(for thread: ManagedCodexThread) -> ManagedRunStatus {
        let waitingFlags = Set(thread.status.activeFlags)
        let isWaiting = waitingFlags.contains("waitingOnUserInput") || waitingFlags.contains("waitingOnApproval")

        if let turn = thread.turns.last {
            switch turn.status {
            case "failed":
                return .failed
            case "interrupted":
                return stopRequested ? .cancelled : .interrupted
            case "completed":
                return thread.status.type == "active" ? .running : .succeeded
            case "inProgress":
                if stopRequested {
                    return .stopRequested
                }
                return isWaiting ? .waitingInput : .running
            default:
                break
            }
        }

        if stopRequested {
            return .stopRequested
        }
        if thread.status.type == "active" {
            return isWaiting ? .waitingInput : .running
        }
        if lastManagedRunStatus == .launching {
            return .launching
        }
        return .running
    }

    private func summary(for thread: ManagedCodexThread, managedStatus: ManagedRunStatus) -> String? {
        if let message = thread.turns.last?.error?.message, !message.isEmpty {
            return message
        }
        switch managedStatus {
        case .launching:
            return "Codex 会话已创建，正在启动。"
        case .running:
            return lastAssistantPreview ?? "Codex 正在执行。"
        case .waitingInput:
            return lastAssistantPreview ?? "Codex 正等待下一步输入。"
        case .stopRequested:
            return "已向 Codex 请求停止。"
        case .succeeded:
            return lastAssistantPreview ?? "Codex 任务已完成。"
        case .failed:
            return lastAssistantPreview ?? "Codex 任务执行失败。"
        case .interrupted:
            return lastAssistantPreview ?? "Codex 会话已被中断。"
        case .cancelled:
            return "Task cancelled after stop request."
        case .interrupting:
            return "正在中断 Codex 会话。"
        case .queued:
            return "等待启动。"
        }
    }

    private func terminalResult(for snapshot: ManagedCodexTaskSnapshot) -> ManagedCodexTaskTerminalResult {
        switch snapshot.managedRunStatus {
        case .succeeded:
            return ManagedCodexTaskTerminalResult(
                executionResult: TaskExecutionResult(
                    status: .succeeded,
                    exitCode: 0,
                    summary: snapshot.summary ?? "Task completed successfully."
                ),
                snapshot: snapshot
            )
        case .failed:
            return ManagedCodexTaskTerminalResult(
                executionResult: TaskExecutionResult(
                    status: .failed,
                    exitCode: 1,
                    summary: snapshot.summary ?? "Codex task failed."
                ),
                snapshot: snapshot
            )
        case .interrupted:
            return ManagedCodexTaskTerminalResult(
                executionResult: TaskExecutionResult(
                    status: .cancelled,
                    exitCode: nil,
                    summary: snapshot.summary ?? "Run interrupted remotely."
                ),
                snapshot: snapshot
            )
        case .cancelled:
            return cancelledResult(summary: snapshot.summary ?? "Task cancelled after stop request.")
        default:
            return failedResult(summary: snapshot.summary ?? "Codex task ended unexpectedly.")
        }
    }

    private func cancelledResult(summary: String) -> ManagedCodexTaskTerminalResult {
        ManagedCodexTaskTerminalResult(
            executionResult: TaskExecutionResult(status: .cancelled, exitCode: nil, summary: summary),
            snapshot: ManagedCodexTaskSnapshot(
                managedRunStatus: .cancelled,
                summary: summary,
                pid: connection.map { Int($0.processIdentifier) },
                codexSessionID: threadID ?? "",
                lastUserPrompt: lastUserPrompt,
                lastAssistantPreview: lastAssistantPreview
            )
        )
    }

    private func failedResult(summary: String) -> ManagedCodexTaskTerminalResult {
        ManagedCodexTaskTerminalResult(
            executionResult: TaskExecutionResult(status: .failed, exitCode: 1, summary: summary),
            snapshot: ManagedCodexTaskSnapshot(
                managedRunStatus: .failed,
                summary: summary,
                pid: connection.map { Int($0.processIdentifier) },
                codexSessionID: threadID ?? "",
                lastUserPrompt: lastUserPrompt,
                lastAssistantPreview: lastAssistantPreview
            )
        )
    }

    private func finish(with result: ManagedCodexTaskTerminalResult) {
        guard !completionSent else { return }
        completionSent = true
        terminalResult = result
        lastManagedRunStatus = result.snapshot.managedRunStatus
        lastAssistantPreview = result.snapshot.lastAssistantPreview
        lastUserPrompt = result.snapshot.lastUserPrompt
        lastSentSnapshot = result.snapshot
        try? persistRuntime(now: Date())
        monitorTask?.cancel()
        monitorTask = nil
        connection?.stop()
        connection = nil
        completion(result)
    }

    private func forceCancelIfNeeded() async {
        guard stopRequested, !completionSent else { return }
        finish(with: cancelledResult(summary: "Task cancelled after stop request."))
    }

    private func emitProgressIfNeeded(_ snapshot: ManagedCodexTaskSnapshot) {
        guard snapshot != lastSentSnapshot else { return }
        lastSentSnapshot = snapshot
        progressHandler(snapshot)
    }

    private func emitProgressIfNeeded(force: Bool) {
        guard
            let threadID,
            let managedRunStatus = lastManagedRunStatus
        else {
            return
        }

        let snapshot = ManagedCodexTaskSnapshot(
            managedRunStatus: managedRunStatus,
            summary: summary(for: managedRunStatus),
            pid: connection.map { Int($0.processIdentifier) },
            codexSessionID: threadID,
            lastUserPrompt: lastUserPrompt,
            lastAssistantPreview: lastAssistantPreview
        )

        if force || snapshot != lastSentSnapshot {
            lastSentSnapshot = snapshot
            progressHandler(snapshot)
        }
    }

    private func summary(for managedRunStatus: ManagedRunStatus) -> String? {
        switch managedRunStatus {
        case .launching:
            return "Codex 会话已创建，正在启动。"
        case .running:
            return lastAssistantPreview ?? "Codex 正在执行。"
        case .waitingInput:
            return lastAssistantPreview ?? "Codex 正等待下一步输入。"
        case .stopRequested:
            return "已向 Codex 请求停止。"
        case .succeeded:
            return lastAssistantPreview ?? "Codex 任务已完成。"
        case .failed:
            return lastAssistantPreview ?? "Codex 任务执行失败。"
        case .interrupted:
            return lastAssistantPreview ?? "Codex 会话已被中断。"
        case .cancelled:
            return "Task cancelled after stop request."
        case .interrupting:
            return "正在中断 Codex 会话。"
        case .queued:
            return "等待启动。"
        }
    }

    private func emitNewLogLines(from thread: ManagedCodexThread) throws {
        for turn in thread.turns {
            for item in turn.items {
                guard let text = renderedLogText(for: item), !text.isEmpty else { continue }
                let previousLength = emittedTextLengths[item.id] ?? 0
                let delta: String
                if previousLength == 0 {
                    delta = text
                } else if text.count > previousLength {
                    let start = text.index(text.startIndex, offsetBy: previousLength)
                    delta = String(text[start...])
                } else {
                    delta = ""
                }
                emittedTextLengths[item.id] = text.count
                if !delta.isEmpty {
                    emitLog(text: delta)
                }
            }
        }
    }

    private func emitLog(text: String) {
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        for line in lines {
            appendLogLine(line)
            lineHandler(line)
        }
    }

    private func appendLogLine(_ line: String) {
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private func persistRuntime(now: Date) throws {
        guard let threadID else { return }
        let runtime = ManagedCodexRuntimeRecord(
            taskID: task.id,
            threadID: threadID,
            cwd: cwd.path,
            startedAt: startedAt ?? now,
            lastSeenAt: now,
            stopRequested: stopRequested,
            pid: connection?.processIdentifier,
            activeTurnID: activeTurnID,
            emittedTextLengths: emittedTextLengths,
            lastManagedRunStatus: lastManagedRunStatus,
            lastUserPrompt: lastUserPrompt,
            lastAssistantPreview: lastAssistantPreview
        )
        let data = try OrchardJSON.encoder.encode(runtime)
        try data.write(to: runtimeURL, options: .atomic)
    }

    private func currentPrompt() -> String {
        guard case let .codex(payload) = task.payload else {
            return ""
        }
        return payload.prompt
    }

    func currentSnapshot() -> ManagedCodexTaskSnapshot? {
        guard
            let threadID,
            let managedRunStatus = lastManagedRunStatus
        else {
            return nil
        }

        return ManagedCodexTaskSnapshot(
            managedRunStatus: managedRunStatus,
            summary: summary(for: managedRunStatus),
            pid: connection.map { Int($0.processIdentifier) },
            codexSessionID: threadID,
            lastUserPrompt: lastUserPrompt,
            lastAssistantPreview: lastAssistantPreview
        )
    }
}

private func renderedLogText(for item: ManagedCodexThreadItem) -> String? {
    switch item.type {
    case "userMessage":
        return item.userMessageText.map { "用户: \($0)" }
    case "agentMessage":
        return item.text.map { "Codex: \($0)" }
    case "plan":
        return item.text.map { "计划: \($0)" }
    case "reasoning":
        if let summary = item.summary, !summary.isEmpty {
            return "推理摘要: \(summary.joined(separator: "\\n"))"
        }
        return nil
    case "commandExecution":
        let body = item.aggregatedOutput?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let body, !body.isEmpty {
            return body
        }
        return item.command
    case "fileChange":
        if let changes = item.changes, !changes.isEmpty {
            return "文件变更：共 \(changes.count) 条"
        }
        return nil
    case "webSearch":
        return item.query.map { "网页检索: \($0)" }
    default:
        return item.text ?? item.command ?? item.query
    }
}

private func lastUserMessage(in turns: [ManagedCodexTurn]) -> String? {
    for turn in turns.reversed() {
        for item in turn.items.reversed() where item.type == "userMessage" {
            if let text = item.userMessageText, !text.isEmpty {
                return text
            }
        }
    }
    return nil
}

private func lastAssistantMessage(in turns: [ManagedCodexTurn]) -> String? {
    for turn in turns.reversed() {
        for item in turn.items.reversed() where item.type == "agentMessage" {
            if let text = item.text, !text.isEmpty {
                return text
            }
        }
    }
    return nil
}

private final class ManagedCodexAppServerConnection: @unchecked Sendable {
    private struct RequestEnvelope<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: Params
    }

    private struct IncomingMessage: Decodable {
        let id: Int?
        let method: String?
        let result: ManagedCodexJSONValue?
        let error: IncomingError?
    }

    private struct IncomingError: Decodable {
        let code: Int?
        let message: String
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let ioQueue = DispatchQueue(label: "orchard.managed-codex.appserver")
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var stderrLines: [String] = []
    private var nextRequestID = 1

    init(codexBinaryPath: String) throws {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexBinaryPath)
        process.arguments = ["app-server"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        self.process = process
        self.stdinHandle = stdin.fileHandleForWriting
        self.stdoutHandle = stdout.fileHandleForReading
        self.stderrHandle = stderr.fileHandleForReading
        self.stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.appendStderr(data)
        }
    }

    deinit {
        stop()
    }

    var processIdentifier: Int32 {
        process.processIdentifier
    }

    func initialize() async throws {
        let _: ManagedCodexInitializeResponse = try await request(
            method: "initialize",
            params: ManagedCodexInitializeParams(
                clientInfo: ManagedCodexClientInfo(name: "orchard-agent", version: "0.1"),
                capabilities: ManagedCodexInitializeCapabilities(experimentalApi: true)
            )
        )
    }

    func request<Params: Encodable, Result: Decodable>(method: String, params: Params) async throws -> Result {
        let requestID = nextRequestID
        nextRequestID += 1

        let envelope = RequestEnvelope(id: requestID, method: method, params: params)
        let encoded = try Self.encoder.encode(envelope)
        try stdinHandle.write(contentsOf: encoded)
        try stdinHandle.write(contentsOf: Data("\n".utf8))

        while let line = try await nextStdoutLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let message = try OrchardJSON.decoder.decode(IncomingMessage.self, from: Data(trimmed.utf8))
            guard message.id == requestID else { continue }

            if let error = message.error {
                throw NSError(domain: "ManagedCodexAppServerConnection", code: error.code ?? 1, userInfo: [
                    NSLocalizedDescriptionKey: error.message,
                ])
            }

            guard let resultValue = message.result else {
                throw NSError(domain: "ManagedCodexAppServerConnection", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Codex app-server 返回了空结果。",
                ])
            }
            return try resultValue.decode(Result.self)
        }

        throw NSError(domain: "ManagedCodexAppServerConnection", code: 3, userInfo: [
            NSLocalizedDescriptionKey: buildTerminationMessage(),
        ])
    }

    func stop() {
        stderrHandle.readabilityHandler = nil
        try? stdinHandle.close()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        if process.isRunning {
            process.terminate()
        }
    }

    private func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)

        while let newline = stderrBuffer.firstIndex(of: 0x0A) {
            let lineData = stderrBuffer.prefix(upTo: newline)
            stderrLines.append(String(decoding: lineData, as: UTF8.self))
            stderrBuffer.removeSubrange(...newline)
        }

        if stderrLines.count > 10 {
            stderrLines.removeFirst(stderrLines.count - 10)
        }
    }

    private func buildTerminationMessage() -> String {
        let suffix = stderrLines.isEmpty ? "" : " stderr: \(stderrLines.joined(separator: " | "))"
        if process.terminationReason == .exit {
            return "Codex app-server 已退出，状态码 \(process.terminationStatus)。\(suffix)"
        }
        return "Codex app-server 被信号 \(process.terminationStatus) 终止。\(suffix)"
    }

    private func nextStdoutLine() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    let line = try self.blockingReadLine()
                    continuation.resume(returning: line)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func blockingReadLine() throws -> String? {
        while true {
            if let newline = stdoutBuffer.firstIndex(of: 0x0A) {
                let lineData = stdoutBuffer.prefix(upTo: newline)
                stdoutBuffer.removeSubrange(...newline)
                return String(decoding: lineData, as: UTF8.self)
            }

            let chunk = stdoutHandle.availableData
            if chunk.isEmpty {
                if stdoutBuffer.isEmpty {
                    return nil
                }
                defer { stdoutBuffer.removeAll(keepingCapacity: false) }
                return String(decoding: stdoutBuffer, as: UTF8.self)
            }
            stdoutBuffer.append(chunk)
        }
    }
}

private struct ManagedCodexInitializeParams: Encodable {
    let clientInfo: ManagedCodexClientInfo
    let capabilities: ManagedCodexInitializeCapabilities?
}

private struct ManagedCodexClientInfo: Encodable {
    let name: String
    let version: String
}

private struct ManagedCodexInitializeCapabilities: Encodable {
    let experimentalApi: Bool
    let optOutNotificationMethods: [String]? = nil
}

private struct ManagedCodexInitializeResponse: Decodable {
    let userAgent: String
}

private struct ManagedCodexThreadStartParams: Encodable {
    let model: String? = nil
    let modelProvider: String? = nil
    let serviceTier: String? = nil
    let cwd: String?
    let approvalPolicy: String?
    let sandbox: String?
    let config: [String: ManagedCodexJSONValue]? = nil
    let serviceName: String? = nil
    let baseInstructions: String? = nil
    let developerInstructions: String? = nil
    let personality: String? = nil
    let ephemeral: Bool? = nil
    let experimentalRawEvents: Bool
    let persistExtendedHistory: Bool
}

private struct ManagedCodexThreadResumeParams: Encodable {
    let threadId: String
    let history: [ManagedCodexJSONValue]? = nil
    let path: String? = nil
    let model: String? = nil
    let modelProvider: String? = nil
    let serviceTier: String? = nil
    let cwd: String?
    let approvalPolicy: String?
    let sandbox: String?
    let config: [String: ManagedCodexJSONValue]? = nil
    let baseInstructions: String? = nil
    let developerInstructions: String? = nil
    let personality: String? = nil
    let persistExtendedHistory: Bool
}

private struct ManagedCodexThreadReadParams: Encodable {
    let threadId: String
    let includeTurns: Bool
}

private struct ManagedCodexTurnStartParams: Encodable {
    let threadId: String
    let input: [ManagedCodexUserInput]
}

private struct ManagedCodexTurnInterruptParams: Encodable {
    let threadId: String
    let turnId: String
}

private struct ManagedCodexUserInput: Encodable {
    let type: String
    let text: String?
    let textElements: [ManagedCodexTextElement]

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case textElements = "text_elements"
    }

    init(type: String, text: String? = nil) {
        self.type = type
        self.text = text
        self.textElements = []
    }
}

private struct ManagedCodexTextElement: Codable {}

private struct ManagedCodexThreadStartResponse: Decodable {
    let thread: ManagedCodexThread
}

private struct ManagedCodexThreadResumeResponse: Decodable {
    let thread: ManagedCodexThread
}

private struct ManagedCodexThreadReadResponse: Decodable {
    let thread: ManagedCodexThread
}

private struct ManagedCodexTurnStartResponse: Decodable {
    let turn: ManagedCodexTurn
}

private struct ManagedCodexTurnInterruptResponse: Decodable {}

private struct ManagedCodexThread: Decodable {
    let id: String
    let preview: String
    let ephemeral: Bool
    let modelProvider: String
    let createdAt: Int64
    let updatedAt: Int64
    let status: ManagedCodexThreadStatus
    let path: String?
    let cwd: String
    let cliVersion: String
    let source: String
    let name: String?
    let turns: [ManagedCodexTurn]
}

private struct ManagedCodexThreadStatus: Decodable {
    let type: String
    let activeFlags: [String]

    private enum CodingKeys: String, CodingKey {
        case type
        case activeFlags
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        activeFlags = try container.decodeIfPresent([String].self, forKey: .activeFlags) ?? []
    }
}

private struct ManagedCodexTurn: Decodable {
    let id: String
    let items: [ManagedCodexThreadItem]
    let status: String
    let error: ManagedCodexTurnError?
}

private struct ManagedCodexTurnError: Decodable {
    let message: String
}

private struct ManagedCodexThreadItem: Decodable {
    let id: String
    let type: String
    let text: String?
    let phase: String?
    let content: ManagedCodexJSONValue?
    let summary: [String]?
    let command: String?
    let aggregatedOutput: String?
    let status: String?
    let changes: [ManagedCodexJSONValue]?
    let query: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case text
        case phase
        case content
        case summary
        case command
        case aggregatedOutput
        case status
        case changes
        case query
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(String.self, forKey: .type)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        content = try container.decodeIfPresent(ManagedCodexJSONValue.self, forKey: .content)
        summary = try container.decodeIfPresent([String].self, forKey: .summary)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        aggregatedOutput = try container.decodeIfPresent(String.self, forKey: .aggregatedOutput)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        changes = try container.decodeIfPresent([ManagedCodexJSONValue].self, forKey: .changes)
        query = try container.decodeIfPresent(String.self, forKey: .query)
    }
}

private extension ManagedCodexThreadItem {
    var userMessageText: String? {
        guard let content, case let .array(values) = content else {
            return nil
        }

        let parts = values.compactMap { value -> String? in
            guard case let .object(object) = value else { return nil }
            guard case let .string(type)? = object["type"], type == "text" else { return nil }
            guard case let .string(text)? = object["text"] else { return nil }
            return text
        }

        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: "\n")
    }
}

private enum ManagedCodexJSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: ManagedCodexJSONValue])
    case array([ManagedCodexJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ManagedCodexJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([ManagedCodexJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .bool(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try OrchardJSON.decoder.decode(T.self, from: data)
    }
}

private func prepareManagedCodexFilesystem(
    runtimeDirectory: URL,
    taskURL: URL,
    logURL: URL,
    task: TaskRecord
) throws {
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true, attributes: nil)
    if !FileManager.default.fileExists(atPath: logURL.path) {
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }
    let taskData = try OrchardJSON.encoder.encode(task)
    try taskData.write(to: taskURL, options: .atomic)
}
