import Foundation
import OrchardCore

struct CodexSessionRolloutReader: Sendable {
    struct Snapshot: Sendable {
        let latestTurnID: String?
        let latestTurnStatus: String?
        let latestActivityAt: Date?
        let inferredState: CodexSessionState?
        let latestUserMessage: String?
        let latestAssistantMessage: String?
        let items: [CodexSessionItem]

        var containsExecutionItems: Bool {
            items.contains { item in
                switch item.kind {
                case .userMessage, .agentMessage:
                    return false
                case .plan, .reasoning, .commandExecution, .fileChange, .webSearch, .other:
                    return true
                }
            }
        }
    }

    var tailByteCount: Int
    var historyLineCount: Int
    var minimumCurrentTurnItemCount: Int
    var minimumCurrentTurnExecutionCount: Int

    init(
        tailByteCount: Int = 4 * 1024 * 1024,
        historyLineCount: Int = 48,
        minimumCurrentTurnItemCount: Int = 6,
        minimumCurrentTurnExecutionCount: Int = 2
    ) {
        self.tailByteCount = max(tailByteCount, 32 * 1024)
        self.historyLineCount = max(historyLineCount, 12)
        self.minimumCurrentTurnItemCount = max(minimumCurrentTurnItemCount, 1)
        self.minimumCurrentTurnExecutionCount = max(minimumCurrentTurnExecutionCount, 1)
    }

    func readRecentActivity(for path: String?) -> Snapshot? {
        guard let url = rolloutURL(for: path) else {
            return nil
        }
        guard let data = try? tailData(from: url) else {
            return nil
        }

        let lines = parseLines(in: data)
        guard !lines.isEmpty else {
            return nil
        }

        let interestingLines = lines.filter(isInterestingLine)
        guard !interestingLines.isEmpty else {
            return nil
        }

        let latestActivityAt = interestingLines.reversed().compactMap(\.timestamp).first ?? fileModificationDate(for: url)
        let latestControl = latestControlEvent(in: interestingLines)
        let latestTurnID = interestingLines.last(where: { $0.payloadType == "task_started" })?.turnID ?? latestControl?.turnID
        let latestTurnStatus = turnStatus(for: latestControl)
        let inferredState = inferState(control: latestControl, latestActivityAt: latestActivityAt)
        let latestUserMessage = interestingLines.reversed().compactMap { line -> String? in
            guard line.payloadType == "user_message" else {
                return nil
            }
            return sanitizedMessage(line.message)
        }.first
        let latestAssistantMessage = interestingLines.reversed().compactMap { line in
            sanitizedMessage(line.assistantVisibleMessage)
        }.first

        let startIndex = latestTurnStartIndex(in: interestingLines)
        let activeTurnID = latestTurnID ?? "rollout"
        let currentTurnLines = Array(interestingLines[startIndex...])
        let currentTurnItems = mapItems(currentTurnLines, defaultTurnID: activeTurnID)
        let selectedLines: [RolloutLine]
        if shouldIncludeRecentHistory(currentTurnItems) {
            selectedLines = Array(interestingLines.suffix(historyLineCount))
        } else {
            selectedLines = currentTurnLines
        }
        let items = mapItems(selectedLines, defaultTurnID: activeTurnID)

        return Snapshot(
            latestTurnID: latestTurnID,
            latestTurnStatus: latestTurnStatus,
            latestActivityAt: latestActivityAt,
            inferredState: inferredState,
            latestUserMessage: latestUserMessage,
            latestAssistantMessage: latestAssistantMessage,
            items: items
        )
    }

    private func latestTurnStartIndex(in lines: [RolloutLine]) -> Int {
        if let index = lines.lastIndex(where: { $0.payloadType == "task_started" }) {
            return index
        }
        if let index = lines.lastIndex(where: { $0.payloadType == "user_message" }) {
            return index
        }
        return max(lines.count - 48, 0)
    }

    private func mapItems(_ lines: [RolloutLine], defaultTurnID: String) -> [CodexSessionItem] {
        var items: [CodexSessionItem] = []
        items.reserveCapacity(lines.count)

        var callNamesByID: [String: String] = [:]
        var activeTurnID = defaultTurnID
        for line in lines {
            if let lineTurnID = line.turnID {
                activeTurnID = lineTurnID
            }
            switch (line.lineType, line.payloadType) {
            case ("event_msg", "task_started"):
                items.append(makeItem(
                    id: line.syntheticID,
                    turnID: activeTurnID,
                    kind: .other,
                    title: "开始执行",
                    body: line.turnID.map { "Turn \($0) 已开始执行。" } ?? "这轮任务已开始执行。",
                    status: "运行中"
                ))
            case ("event_msg", "user_message"):
                guard let message = sanitizedMessage(line.message) else {
                    continue
                }
                items.append(makeItem(
                    id: line.syntheticID,
                    turnID: activeTurnID,
                    kind: .userMessage,
                    title: "用户",
                    body: message
                ))
            case ("event_msg", "agent_message"):
                guard
                    let message = sanitizedMessage(line.message),
                    !isToolEcho(message, phase: line.phase)
                else {
                    continue
                }
                items.append(makeItem(
                    id: line.syntheticID,
                    turnID: activeTurnID,
                    kind: .agentMessage,
                    title: agentTitle(for: line.phase),
                    body: message
                ))
            case ("event_msg", "task_complete"):
                items.append(makeItem(
                    id: line.syntheticID,
                    turnID: activeTurnID,
                    kind: .other,
                    title: "执行完成",
                    body: "这轮任务已经完成。",
                    status: "已完成"
                ))
            case ("event_msg", "turn_aborted"):
                items.append(makeItem(
                    id: line.syntheticID,
                    turnID: activeTurnID,
                    kind: .other,
                    title: line.reason == "interrupted" ? "已中断" : "执行终止",
                    body: abortedBody(for: line),
                    status: line.reason == "interrupted" ? "已中断" : "失败"
                ))
            case ("response_item", "reasoning"):
                guard let summary = reasoningBody(for: line) else {
                    continue
                }
                items.append(makeItem(
                    id: line.syntheticID,
                    turnID: activeTurnID,
                    kind: .reasoning,
                    title: "推理摘要",
                    body: summary
                ))
            case ("response_item", "function_call"):
                let name = line.functionName ?? "工具调用"
                if let callID = line.callID {
                    callNamesByID[callID] = name
                }

                let kind = kindForTool(name)
                items.append(makeItem(
                    id: line.syntheticID,
                    turnID: activeTurnID,
                    kind: kind,
                    title: titleForTool(name, isOutput: false),
                    body: formattedArguments(line.arguments),
                    status: kind == .commandExecution ? "已发起" : nil
                ))
            case ("response_item", "function_call_output"):
                let name = line.callID.flatMap { callNamesByID[$0] } ?? "工具调用"
                let kind = kindForTool(name)
                items.append(makeItem(
                    id: line.syntheticID,
                    turnID: activeTurnID,
                    kind: kind,
                    title: titleForTool(name, isOutput: true),
                    body: formattedOutput(line.output),
                    status: kind == .commandExecution ? inferredExecutionStatus(from: line.output) : nil
                ))
            default:
                continue
            }
        }

        return resequenced(deduplicated(items))
    }

    private func shouldIncludeRecentHistory(_ currentTurnItems: [CodexSessionItem]) -> Bool {
        if currentTurnItems.count < minimumCurrentTurnItemCount {
            return true
        }

        let executionCount = currentTurnItems.reduce(into: 0) { partial, item in
            switch item.kind {
            case .plan, .reasoning, .commandExecution, .fileChange, .webSearch, .other:
                partial += 1
            case .userMessage, .agentMessage:
                break
            }
        }
        return executionCount < minimumCurrentTurnExecutionCount
    }

    private func makeItem(
        id: String,
        turnID: String,
        kind: CodexSessionItemKind,
        title: String,
        body: String?,
        status: String? = nil
    ) -> CodexSessionItem {
        CodexSessionItem(
            id: id,
            turnID: turnID,
            sequence: 0,
            kind: kind,
            title: title,
            body: body,
            status: status
        )
    }

    private func kindForTool(_ name: String) -> CodexSessionItemKind {
        switch name {
        case "update_plan":
            return .plan
        case "search_query", "image_query", "open", "click", "find":
            return .webSearch
        default:
            return .commandExecution
        }
    }

    private func titleForTool(_ name: String, isOutput: Bool) -> String {
        switch name {
        case "update_plan":
            return isOutput ? "计划结果" : "计划更新"
        default:
            return isOutput ? "\(name) 输出" : name
        }
    }

    private func agentTitle(for phase: String?) -> String {
        switch phase {
        case "final_answer":
            return "Codex 回答"
        case "commentary":
            return "Codex 进展"
        default:
            return "Codex"
        }
    }

    private func reasoningBody(for line: RolloutLine) -> String? {
        let summary = line.summary
            .map { SensitiveTextRedactor.redact($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !summary.isEmpty else {
            return nil
        }
        return summary.joined(separator: "\n")
    }

    private func abortedBody(for line: RolloutLine) -> String? {
        if let reason = line.reason?.trimmingCharacters(in: .whitespacesAndNewlines), !reason.isEmpty {
            if reason == "interrupted" {
                return "这轮任务被手动中断。"
            }
            return "终止原因：\(reason)"
        }
        return "这轮任务已终止。"
    }

    private func formattedArguments(_ raw: String?) -> String? {
        guard let sanitized = sanitizedMessage(raw) else {
            return nil
        }
        if
            let data = sanitized.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            JSONSerialization.isValidJSONObject(object),
            let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let pretty = String(data: prettyData, encoding: .utf8)
        {
            return clippedText(SensitiveTextRedactor.redact(pretty), maxLength: 6000, keepTail: false)
        }
        return clippedText(SensitiveTextRedactor.redact(sanitized), maxLength: 6000, keepTail: false)
    }

    private func formattedOutput(_ raw: String?) -> String? {
        guard let sanitized = sanitizedMessage(raw) else {
            return nil
        }
        return clippedText(SensitiveTextRedactor.redact(sanitized), maxLength: 10000, keepTail: true)
    }

    private func inferredExecutionStatus(from output: String?) -> String? {
        guard let output = output?.lowercased() else {
            return nil
        }
        if output.contains("process running with session id") {
            return "运行中"
        }
        if output.contains("process exited with code 0") {
            return "已完成"
        }
        if output.contains("process exited with code") || output.contains("failed:") {
            return "失败"
        }
        return nil
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

    private func resequenced(_ items: [CodexSessionItem]) -> [CodexSessionItem] {
        items.enumerated().map { offset, item in
            var item = item
            item.sequence = offset
            return item
        }
    }

    private func itemSignature(_ item: CodexSessionItem) -> String {
        [
            item.kind.rawValue,
            item.title.trimmingCharacters(in: .whitespacesAndNewlines),
            (item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            item.status ?? "",
        ].joined(separator: "|")
    }

    private func sanitizedMessage(_ text: String?) -> String? {
        guard let text else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        return SensitiveTextRedactor.redact(trimmed)
    }

    private func clippedText(_ text: String, maxLength: Int, keepTail: Bool) -> String {
        guard text.count > maxLength else {
            return text
        }

        let omittedCount = text.count - maxLength
        if keepTail {
            let start = text.index(text.endIndex, offsetBy: -maxLength)
            return "... [已截断前 \(omittedCount) 个字符]\n" + text[start...]
        }

        let end = text.index(text.startIndex, offsetBy: maxLength)
        return String(text[..<end]) + "\n... [已截断后 \(omittedCount) 个字符]"
    }

    private func isToolEcho(_ message: String, phase: String?) -> Bool {
        guard phase == "commentary" else {
            return false
        }
        return message.contains("to=functions.") || message.contains("to=multi_tool_use.")
    }

    private func turnStatus(for latestControl: RolloutLine?) -> String? {
        switch latestControl?.payloadType {
        case "task_started":
            return "inProgress"
        case "task_complete":
            return "completed"
        case "turn_aborted":
            if latestControl?.reason == "interrupted" {
                return "interrupted"
            }
            return "failed"
        default:
            return nil
        }
    }

    private func inferState(control: RolloutLine?, latestActivityAt: Date?) -> CodexSessionState? {
        switch control?.payloadType {
        case "task_complete":
            return .completed
        case "turn_aborted":
            if control?.reason == "interrupted" {
                return .interrupted
            }
            return .failed
        case "task_started":
            return .running
        default:
            _ = latestActivityAt
            return nil
        }
    }

    private func latestControlEvent(in lines: [RolloutLine]) -> RolloutLine? {
        lines.reversed().first { line in
            switch line.payloadType {
            case "task_complete", "turn_aborted", "task_started":
                return true
            default:
                return false
            }
        }
    }

    private func isInterestingLine(_ line: RolloutLine) -> Bool {
        switch (line.lineType, line.payloadType) {
        case ("event_msg", "task_started"),
             ("event_msg", "user_message"),
             ("event_msg", "agent_message"),
             ("event_msg", "task_complete"),
             ("event_msg", "turn_aborted"),
             ("response_item", "reasoning"),
             ("response_item", "function_call"),
             ("response_item", "function_call_output"):
            return true
        default:
            return false
        }
    }

    private func rolloutURL(for path: String?) -> URL? {
        guard let path else {
            return nil
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func tailData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else {
            return Data()
        }

        let readLength = min(UInt64(tailByteCount), fileSize)
        try handle.seek(toOffset: fileSize - readLength)
        var data = handle.readDataToEndOfFile()

        if readLength < fileSize, let newlineIndex = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newlineIndex)...]
        }

        return data
    }

    private func parseLines(in data: Data) -> [RolloutLine] {
        data
            .split(separator: 0x0A)
            .compactMap { parseLine(Data($0)) }
    }

    private func parseLine(_ data: Data) -> RolloutLine? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let payload = object["payload"] as? [String: Any]
        return RolloutLine(
            timestamp: parseDate(object["timestamp"]),
            lineType: object["type"] as? String ?? "unknown",
            payloadType: payload?["type"] as? String,
            turnID: payload?["turn_id"] as? String,
            reason: payload?["reason"] as? String,
            message: payload?["message"] as? String,
            phase: payload?["phase"] as? String,
            role: payload?["role"] as? String,
            summary: payload?["summary"] as? [String] ?? [],
            functionName: payload?["name"] as? String,
            arguments: payload?["arguments"] as? String,
            callID: payload?["call_id"] as? String,
            output: payload?["output"] as? String,
            lastAgentMessage: payload?["last_agent_message"] as? String,
            outputText: extractOutputText(from: payload?["content"])
        )
    }

    private func extractOutputText(from value: Any?) -> String? {
        guard let array = value as? [[String: Any]] else {
            return nil
        }

        let parts = array.compactMap { item -> String? in
            guard item["type"] as? String == "output_text" else {
                return nil
            }
            return item["text"] as? String
        }

        guard !parts.isEmpty else {
            return nil
        }
        return parts.joined(separator: "\n")
    }

    private func fileModificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractionalFormatter.date(from: string) {
            return parsed
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private struct RolloutLine {
        let timestamp: Date?
        let lineType: String
        let payloadType: String?
        let turnID: String?
        let reason: String?
        let message: String?
        let phase: String?
        let role: String?
        let summary: [String]
        let functionName: String?
        let arguments: String?
        let callID: String?
        let output: String?
        let lastAgentMessage: String?
        let outputText: String?

        var syntheticID: String {
            let anchor = message ?? output ?? lastAgentMessage ?? ""
            return [
                lineType,
                payloadType ?? "unknown",
                turnID ?? "rollout",
                callID ?? functionName ?? String(anchor.prefix(24)),
                timestamp?.timeIntervalSince1970.description ?? "0",
            ].joined(separator: ":")
        }

        var assistantVisibleMessage: String? {
            switch payloadType {
            case "agent_message":
                return message
            case "task_complete", "turn_aborted":
                return lastAgentMessage
            case "message":
                guard role == "assistant" else {
                    return nil
                }
                return outputText
            default:
                return nil
            }
        }
    }
}
