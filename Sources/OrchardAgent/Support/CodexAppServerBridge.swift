import Foundation
import OrchardCore

actor CodexAppServerBridge {
    private let config: ResolvedAgentConfig
    private let sessionHydrationLimit: Int
    private let rolloutStateInspector: CodexSessionRolloutStateInspector
    private let rolloutReader: CodexSessionRolloutReader

    init(
        config: ResolvedAgentConfig,
        sessionHydrationLimit: Int = 3,
        rolloutStateInspector: CodexSessionRolloutStateInspector = CodexSessionRolloutStateInspector(),
        rolloutReader: CodexSessionRolloutReader = CodexSessionRolloutReader()
    ) {
        self.config = config
        self.sessionHydrationLimit = max(sessionHydrationLimit, 0)
        self.rolloutStateInspector = rolloutStateInspector
        self.rolloutReader = rolloutReader
    }

    func handle(_ request: AgentCodexCommandRequest) async -> AgentCodexCommandResponse {
        do {
            switch request.action {
            case .listSessions:
                let sessions = try await listSessions(limit: min(max(request.limit ?? 20, 1), 50))
                return AgentCodexCommandResponse(requestID: request.requestID, sessions: sessions)
            case .readSession:
                guard let sessionID = request.sessionID, !sessionID.isEmpty else {
                    return AgentCodexCommandResponse(requestID: request.requestID, errorMessage: "缺少 Codex 会话 ID。")
                }
                let detail = try await readSession(sessionID: sessionID)
                return AgentCodexCommandResponse(requestID: request.requestID, detail: detail)
            case .continueSession:
                guard let sessionID = request.sessionID, !sessionID.isEmpty else {
                    return AgentCodexCommandResponse(requestID: request.requestID, errorMessage: "缺少 Codex 会话 ID。")
                }
                let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !prompt.isEmpty else {
                    return AgentCodexCommandResponse(requestID: request.requestID, errorMessage: "继续追问内容不能为空。")
                }
                let detail = try await continueSession(sessionID: sessionID, prompt: prompt)
                return AgentCodexCommandResponse(requestID: request.requestID, detail: detail)
            case .interruptSession:
                guard let sessionID = request.sessionID, !sessionID.isEmpty else {
                    return AgentCodexCommandResponse(requestID: request.requestID, errorMessage: "缺少 Codex 会话 ID。")
                }
                let detail = try await interruptSession(sessionID: sessionID)
                return AgentCodexCommandResponse(requestID: request.requestID, detail: detail)
            }
        } catch {
            return AgentCodexCommandResponse(requestID: request.requestID, errorMessage: error.localizedDescription)
        }
    }

    func listSessions(limit: Int) async throws -> [CodexSessionSummary] {
        try await withConnection { connection in
            let listed: AppServerThreadListResponse = try await connection.request(
                method: "thread/list",
                params: AppServerThreadListParams(
                    archived: false,
                    limit: limit,
                    sortKey: "updated_at",
                    sourceKinds: nil
                )
            )

            var sessions: [CodexSessionSummary] = []
            sessions.reserveCapacity(listed.data.count)
            // `thread/read(includeTurns: true)` can be very slow on large threads, so only hydrate
            // a small prefix and fall back to lightweight list metadata for the rest.
            let enrichedPrefixCount = min(limit, sessionHydrationLimit)

            for (index, thread) in listed.data.enumerated() {
                guard index < enrichedPrefixCount else {
                    sessions.append(mapSummary(thread))
                    continue
                }

                do {
                    let detail = try await readSession(sessionID: thread.id, connection: connection)
                    sessions.append(detail.session)
                } catch {
                    sessions.append(mapSummary(thread))
                }
            }

            return sessions.sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    return lhs.state == .running
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id < rhs.id
            }
        }
    }

    func readSession(sessionID: String) async throws -> CodexSessionDetail {
        try await withConnection { connection in
            try await readSession(sessionID: sessionID, connection: connection)
        }
    }

    func continueSession(sessionID: String, prompt: String) async throws -> CodexSessionDetail {
        try await withConnection { connection in
            let resumed: AppServerThreadResumeResponse = try await connection.request(
                method: "thread/resume",
                params: AppServerThreadResumeParams(
                    threadId: sessionID,
                    persistExtendedHistory: true
                )
            )

            if shouldSteer(resumed.thread), let turnID = resumed.thread.turns.last?.id {
                _ = try await connection.request(
                    method: "turn/steer",
                    params: AppServerTurnSteerParams(
                        threadId: sessionID,
                        input: [
                            AppServerUserInput(type: "text", text: prompt),
                        ],
                        expectedTurnId: turnID
                    )
                ) as AppServerTurnSteerResponse
            } else if resumed.thread.status.type == "active", resumed.thread.turns.last?.status == "inProgress" {
                throw NSError(domain: "CodexAppServerBridge", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "当前会话仍在执行，暂时不能继续追问。",
                ])
            } else {
                _ = try await connection.request(
                    method: "turn/start",
                    params: AppServerTurnStartParams(
                        threadId: sessionID,
                        input: [
                            AppServerUserInput(type: "text", text: prompt),
                        ]
                    )
                ) as AppServerTurnStartResponse
            }

            try await Task.sleep(nanoseconds: 200_000_000)
            return try await readSession(sessionID: sessionID, connection: connection)
        }
    }

    func interruptSession(sessionID: String) async throws -> CodexSessionDetail {
        try await withConnection { connection in
            let resumed: AppServerThreadResumeResponse = try await connection.request(
                method: "thread/resume",
                params: AppServerThreadResumeParams(
                    threadId: sessionID,
                    persistExtendedHistory: true
                )
            )

            let hydratedTurnIDFromResume: String? = {
                if let liveTurnID = resumed.thread.turns.last(where: { $0.status == "inProgress" })?.id {
                    return liveTurnID
                }
                if let lastTurnID = resumed.thread.turns.last?.id {
                    return lastTurnID
                }
                return nil
            }()
            let hydratedTurnID: String?
            if let hydratedTurnIDFromResume {
                hydratedTurnID = hydratedTurnIDFromResume
            } else {
                let fullThread: AppServerThreadReadResponse = try await connection.request(
                    method: "thread/read",
                    params: AppServerThreadReadParams(threadId: sessionID, includeTurns: true)
                )
                hydratedTurnID = fullThread.thread.turns.last(where: { $0.status == "inProgress" })?.id
                    ?? fullThread.thread.turns.last?.id
            }

            let isRunning = resumed.thread.status.type == "active"
                || resumed.thread.turns.last?.status == "inProgress"
            guard isRunning, let turnID = hydratedTurnID else {
                throw NSError(domain: "CodexAppServerBridge", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "当前会话没有可中断的运行中轮次。",
                ])
            }

            _ = try await connection.request(
                method: "turn/interrupt",
                params: AppServerTurnInterruptParams(threadId: sessionID, turnId: turnID)
            ) as AppServerTurnInterruptResponse

            try await Task.sleep(nanoseconds: 200_000_000)
            return try await readSession(sessionID: sessionID, connection: connection)
        }
    }

    private func readSession(
        sessionID: String,
        connection: CodexAppServerConnection
    ) async throws -> CodexSessionDetail {
        let lightweightRead: AppServerThreadReadResponse = try await connection.request(
            method: "thread/read",
            params: AppServerThreadReadParams(threadId: sessionID, includeTurns: false)
        )
        let rollout = rolloutReader.readRecentActivity(for: lightweightRead.thread.path)

        if let rollout, !rollout.items.isEmpty {
            return mapDetail(lightweightRead.thread, rollout: rollout)
        }
        if !lightweightRead.thread.turns.isEmpty {
            return mapDetail(lightweightRead.thread, rollout: rollout)
        }

        let read: AppServerThreadReadResponse = try await connection.request(
            method: "thread/read",
            params: AppServerThreadReadParams(threadId: sessionID, includeTurns: true)
        )
        return mapDetail(read.thread, rollout: rolloutReader.readRecentActivity(for: read.thread.path))
    }

    private func withConnection<T>(
        _ operation: (CodexAppServerConnection) async throws -> T
    ) async throws -> T {
        let connection = try CodexAppServerConnection(codexBinaryPath: config.codexBinaryPath)
        defer { connection.stop() }
        try await connection.initialize()
        return try await operation(connection)
    }

    private func mapDetail(
        _ thread: AppServerThread,
        rollout: CodexSessionRolloutReader.Snapshot? = nil
    ) -> CodexSessionDetail {
        let rollout = rollout ?? rolloutReader.readRecentActivity(for: thread.path)
        let summary = mapSummary(thread, rollout: rollout)
        var turns: [CodexSessionTurn] = []
        turns.reserveCapacity(thread.turns.count)

        var items: [CodexSessionItem] = []
        items.reserveCapacity(thread.turns.reduce(0) { $0 + $1.items.count })

        var sequence = 0
        for turn in thread.turns {
            turns.append(CodexSessionTurn(
                id: turn.id,
                status: turn.status,
                errorMessage: turn.error?.message
            ))

            for item in turn.items {
                items.append(mapItem(item, turnID: turn.id, sequence: sequence))
                sequence += 1
            }
        }

        let mergedItems = mergedItems(threadItems: items, thread: thread, rollout: rollout)
        return CodexSessionDetail(session: summary, turns: turns, items: mergedItems)
    }

    private func mapSummary(
        _ thread: AppServerThread,
        rollout: CodexSessionRolloutReader.Snapshot? = nil
    ) -> CodexSessionSummary {
        let lastTurn = thread.turns.last
        let threadUpdatedAt = Date(timeIntervalSince1970: TimeInterval(thread.updatedAt))
        var summary = CodexSessionSummary(
            id: thread.id,
            deviceID: config.deviceID,
            deviceName: config.deviceName,
            workspaceID: OrchardWorkspaceLocator.bestMatch(for: thread.cwd, workspaces: config.workspaceRoots)?.id,
            name: thread.name,
            preview: SensitiveTextRedactor.redact(thread.preview),
            cwd: thread.cwd,
            source: thread.source,
            modelProvider: thread.modelProvider,
            createdAt: Date(timeIntervalSince1970: TimeInterval(thread.createdAt)),
            updatedAt: max(threadUpdatedAt, rollout?.latestActivityAt ?? threadUpdatedAt),
            state: mapState(thread),
            lastTurnID: lastTurn?.id ?? rollout?.latestTurnID,
            lastTurnStatus: lastTurn?.status ?? rollout?.latestTurnStatus,
            lastUserMessage: SensitiveTextRedactor.redact(lastUserMessage(in: thread.turns) ?? rollout?.latestUserMessage),
            lastAssistantMessage: SensitiveTextRedactor.redact(lastAssistantMessage(in: thread.turns) ?? rollout?.latestAssistantMessage)
        )

        if
            let inferredState = rollout?.inferredState ?? rolloutStateInspector.inferredState(for: thread.path),
            shouldOverrideState(current: summary.state, with: inferredState)
        {
            summary.state = inferredState
        }

        return summary
    }

    private func mergedItems(
        threadItems: [CodexSessionItem],
        thread: AppServerThread,
        rollout: CodexSessionRolloutReader.Snapshot?
    ) -> [CodexSessionItem] {
        guard let rollout, !rollout.items.isEmpty else {
            return resequenced(threadItems)
        }

        if threadItems.isEmpty {
            return resequenced(rollout.items)
        }

        guard rollout.containsExecutionItems else {
            return resequenced(threadItems)
        }

        let latestTurnID = rollout.latestTurnID ?? thread.turns.last?.id ?? threadItems.last?.turnID ?? "rollout"
        let olderThreadItems = threadItems.filter { $0.turnID != latestTurnID }
        let latestThreadItems = threadItems.filter { $0.turnID == latestTurnID }
        let mergedLatestTurnItems = mergeLatestTurnItems(
            threadItems: latestThreadItems,
            rolloutItems: rollout.items
        )

        return resequenced(olderThreadItems + mergedLatestTurnItems)
    }

    private func mergeLatestTurnItems(
        threadItems: [CodexSessionItem],
        rolloutItems: [CodexSessionItem]
    ) -> [CodexSessionItem] {
        guard !rolloutItems.isEmpty else {
            return threadItems
        }

        let rolloutSignatures = Set(rolloutItems.map(itemSignature))
        let leadingThreadItems = threadItems.filter { item in
            item.kind == .userMessage && !rolloutSignatures.contains(itemSignature(item))
        }
        let trailingThreadItems = threadItems.filter { item in
            item.kind != .userMessage && !rolloutSignatures.contains(itemSignature(item))
        }

        return deduplicated(leadingThreadItems + rolloutItems + trailingThreadItems)
    }

    private func deduplicated(_ items: [CodexSessionItem]) -> [CodexSessionItem] {
        var seen: Set<String> = []
        var result: [CodexSessionItem] = []
        result.reserveCapacity(items.count)

        for item in items {
            let signature = itemSignature(item)
            guard seen.insert(signature).inserted else {
                continue
            }
            result.append(item)
        }

        return result
    }

    private func itemSignature(_ item: CodexSessionItem) -> String {
        [
            item.kind.rawValue,
            item.title.trimmingCharacters(in: .whitespacesAndNewlines),
            (item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            item.status ?? "",
        ].joined(separator: "|")
    }

    private func resequenced(_ items: [CodexSessionItem]) -> [CodexSessionItem] {
        items.enumerated().map { offset, item in
            var item = item
            item.sequence = offset
            return item
        }
    }

    private func shouldOverrideState(current: CodexSessionState, with inferredState: CodexSessionState) -> Bool {
        switch inferredState {
        case .running:
            return current != .running
        case .completed, .interrupted, .failed:
            return current == .idle || current == .unknown
        case .idle, .unknown:
            return false
        }
    }

    private func mapState(_ thread: AppServerThread) -> CodexSessionState {
        if let lastTurn = thread.turns.last {
            switch lastTurn.status {
            case "inProgress":
                return .running
            case "failed":
                return .failed
            case "interrupted":
                return .interrupted
            case "completed":
                return .completed
            default:
                break
            }
        }

        switch thread.status.type {
        case "active":
            return .running
        case "idle":
            return .idle
        case "systemError":
            return .failed
        case "notLoaded":
            return thread.turns.isEmpty ? .idle : .unknown
        default:
            return .unknown
        }
    }

    private func lastUserMessage(in turns: [AppServerTurn]) -> String? {
        for turn in turns.reversed() {
            for item in turn.items.reversed() where item.type == "userMessage" {
                if let text = item.userMessageText, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private func lastAssistantMessage(in turns: [AppServerTurn]) -> String? {
        for turn in turns.reversed() {
            for item in turn.items.reversed() where item.type == "agentMessage" {
                if let text = item.text, !text.isEmpty {
                    return text
                }
            }
        }
        return nil
    }

    private func mapItem(_ item: AppServerThreadItem, turnID: String, sequence: Int) -> CodexSessionItem {
        switch item.type {
        case "userMessage":
            return CodexSessionItem(
                id: item.id,
                turnID: turnID,
                sequence: sequence,
                kind: .userMessage,
                title: "用户",
                body: SensitiveTextRedactor.redact(item.userMessageText)
            )
        case "agentMessage":
            return CodexSessionItem(
                id: item.id,
                turnID: turnID,
                sequence: sequence,
                kind: .agentMessage,
                title: item.phase == "final_answer" ? "Codex 回答" : "Codex",
                body: SensitiveTextRedactor.redact(item.text)
            )
        case "plan":
            return CodexSessionItem(
                id: item.id,
                turnID: turnID,
                sequence: sequence,
                kind: .plan,
                title: "计划",
                body: SensitiveTextRedactor.redact(item.text)
            )
        case "reasoning":
            return CodexSessionItem(
                id: item.id,
                turnID: turnID,
                sequence: sequence,
                kind: .reasoning,
                title: "推理摘要",
                body: reasoningBody(for: item)
            )
        case "commandExecution":
            return CodexSessionItem(
                id: item.id,
                turnID: turnID,
                sequence: sequence,
                kind: .commandExecution,
                title: item.command ?? "命令执行",
                body: SensitiveTextRedactor.redact(item.aggregatedOutput),
                status: item.status
            )
        case "fileChange":
            return CodexSessionItem(
                id: item.id,
                turnID: turnID,
                sequence: sequence,
                kind: .fileChange,
                title: "文件变更",
                body: item.changes.map { "共 \($0.count) 条变更" },
                status: item.status
            )
        case "webSearch":
            return CodexSessionItem(
                id: item.id,
                turnID: turnID,
                sequence: sequence,
                kind: .webSearch,
                title: "网页检索",
                body: SensitiveTextRedactor.redact(item.query)
            )
        default:
            return CodexSessionItem(
                id: item.id,
                turnID: turnID,
                sequence: sequence,
                kind: .other,
                title: item.type,
                body: SensitiveTextRedactor.redact(item.text ?? item.command ?? item.query),
                status: item.status
            )
        }
    }

    private func reasoningBody(for item: AppServerThreadItem) -> String? {
        if let summary = item.summary, !summary.isEmpty {
            return summary.joined(separator: "\n")
        }
        return nil
    }

    private func shouldSteer(_ thread: AppServerThread) -> Bool {
        guard thread.turns.last?.status == "inProgress" else {
            return false
        }
        return thread.status.activeFlags.contains("waitingOnUserInput")
            || thread.status.activeFlags.contains("waitingOnApproval")
    }
}

private final class CodexAppServerConnection: @unchecked Sendable {
    private struct RequestEnvelope<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: Params
    }

    private struct IncomingMessage: Decodable {
        let id: Int?
        let method: String?
        let result: AppServerJSONValue?
        let error: IncomingError?
        let params: AppServerJSONValue?
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
    private let ioQueue = DispatchQueue(label: "orchard.codex.appserver")
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
        stdinHandle = stdin.fileHandleForWriting
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
        stderrHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.appendStderr(data)
        }
    }

    deinit {
        stop()
    }

    func initialize() async throws {
        let params = AppServerInitializeParams(
            clientInfo: AppServerClientInfo(name: "orchard-agent", version: "0.1"),
            capabilities: AppServerInitializeCapabilities(experimentalApi: true)
        )
        let _: AppServerInitializeResponse = try await request(method: "initialize", params: params)
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

            guard message.id == requestID else {
                continue
            }

            if let error = message.error {
                throw NSError(domain: "CodexAppServerConnection", code: error.code ?? 1, userInfo: [
                    NSLocalizedDescriptionKey: error.message,
                ])
            }

            guard let resultValue = message.result else {
                throw NSError(domain: "CodexAppServerConnection", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Codex app-server 返回了空结果。",
                ])
            }
            return try resultValue.decode(Result.self)
        }

        throw NSError(domain: "CodexAppServerConnection", code: 3, userInfo: [
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

private struct AppServerInitializeParams: Encodable {
    let clientInfo: AppServerClientInfo
    let capabilities: AppServerInitializeCapabilities?
}

private struct AppServerClientInfo: Encodable {
    let name: String
    let version: String
}

private struct AppServerInitializeCapabilities: Encodable {
    let experimentalApi: Bool
    let optOutNotificationMethods: [String]? = nil
}

private struct AppServerInitializeResponse: Decodable {
    let userAgent: String
}

private struct AppServerThreadListParams: Encodable {
    let archived: Bool
    let limit: Int
    let sortKey: String
    let sourceKinds: [String]?
}

private struct AppServerThreadReadParams: Encodable {
    let threadId: String
    let includeTurns: Bool
}

private struct AppServerThreadResumeParams: Encodable {
    let threadId: String
    let persistExtendedHistory: Bool
}

private struct AppServerTurnStartParams: Encodable {
    let threadId: String
    let input: [AppServerUserInput]
}

private struct AppServerTurnSteerParams: Encodable {
    let threadId: String
    let input: [AppServerUserInput]
    let expectedTurnId: String
}

private struct AppServerTurnInterruptParams: Encodable {
    let threadId: String
    let turnId: String
}

private struct AppServerUserInput: Codable {
    let type: String
    let text: String?
    let textElements: [AppServerTextElement]

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

private struct AppServerTextElement: Codable {}

private struct AppServerThreadListResponse: Decodable {
    let data: [AppServerThread]
    let nextCursor: String?
}

private struct AppServerThreadReadResponse: Decodable {
    let thread: AppServerThread
}

private struct AppServerThreadResumeResponse: Decodable {
    let thread: AppServerThread
}

private struct AppServerTurnStartResponse: Decodable {
    let turn: AppServerTurn
}

private struct AppServerTurnSteerResponse: Decodable {
    let turnId: String
}

private struct AppServerTurnInterruptResponse: Decodable {}

private struct AppServerThread: Decodable {
    let id: String
    let preview: String
    let ephemeral: Bool
    let modelProvider: String
    let createdAt: Int64
    let updatedAt: Int64
    let status: AppServerThreadStatus
    let path: String?
    let cwd: String
    let cliVersion: String
    let source: String
    let name: String?
    let turns: [AppServerTurn]
}

private struct AppServerThreadStatus: Decodable {
    let type: String
    let activeFlags: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        activeFlags = try container.decodeIfPresent([String].self, forKey: .activeFlags) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case activeFlags
    }
}

private struct AppServerTurn: Decodable {
    let id: String
    let items: [AppServerThreadItem]
    let status: String
    let error: AppServerTurnError?
}

private struct AppServerTurnError: Decodable {
    let message: String
}

private struct AppServerThreadItem: Decodable {
    let id: String
    let type: String
    let text: String?
    let phase: String?
    let content: AppServerJSONValue?
    let summary: [String]?
    let command: String?
    let aggregatedOutput: String?
    let status: String?
    let changes: [AppServerJSONValue]?
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
        content = try container.decodeIfPresent(AppServerJSONValue.self, forKey: .content)
        summary = try container.decodeIfPresent([String].self, forKey: .summary)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        aggregatedOutput = try container.decodeIfPresent(String.self, forKey: .aggregatedOutput)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        changes = try container.decodeIfPresent([AppServerJSONValue].self, forKey: .changes)
        query = try container.decodeIfPresent(String.self, forKey: .query)
    }
}

private extension AppServerThreadItem {
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

private enum AppServerJSONValue: Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AppServerJSONValue])
    case array([AppServerJSONValue])
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
        } else if let value = try? container.decode([String: AppServerJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([AppServerJSONValue].self) {
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
