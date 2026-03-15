import Darwin
import Foundation
import XCTest
@testable import OrchardAgent
import OrchardCore

final class CodexAppServerBridgeTests: XCTestCase {
    func testBridgeCanListSessionsFromFakeAppServer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let codexBinary = try makeBridgeFakeCodexBinary(in: directory, workspace: workspace)

        let config = ResolvedAgentConfig(
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            enrollmentToken: "token",
            deviceID: "bridge-device",
            deviceName: "Bridge Device",
            hostName: "bridge-device.local",
            maxParallelTasks: 1,
            workspaceRoots: [WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)],
            heartbeatIntervalSeconds: 10,
            codexBinaryPath: codexBinary.path
        )

        let bridge = CodexAppServerBridge(config: config)
        let response = try await withTimeout(seconds: 5) {
            await bridge.handle(AgentCodexCommandRequest(
                requestID: UUID().uuidString,
                action: .listSessions,
                limit: 10
            ))
        }

        XCTAssertNil(response.errorMessage)
        XCTAssertEqual(response.sessions?.count, 1)
        XCTAssertEqual(response.sessions?.first?.state, .running)
        XCTAssertEqual(response.sessions?.first?.workspaceID, "main")
    }

    func testBridgeOnlyHydratesBoundedSessionPrefix() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let fixture = try makeBoundedHydrationFakeCodexBinary(in: directory, workspace: workspace)

        let config = ResolvedAgentConfig(
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            enrollmentToken: "token",
            deviceID: "bridge-device",
            deviceName: "Bridge Device",
            hostName: "bridge-device.local",
            maxParallelTasks: 1,
            workspaceRoots: [WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)],
            heartbeatIntervalSeconds: 10,
            codexBinaryPath: fixture.binary.path
        )

        let bridge = CodexAppServerBridge(config: config, sessionHydrationLimit: 3)
        let response = try await withTimeout(seconds: 5) {
            await bridge.handle(AgentCodexCommandRequest(
                requestID: UUID().uuidString,
                action: .listSessions,
                limit: 10
            ))
        }

        XCTAssertNil(response.errorMessage)
        XCTAssertEqual(response.sessions?.count, 5)
        XCTAssertTrue(response.sessions?.allSatisfy { $0.workspaceID == "main" } == true)

        let readCount = try XCTUnwrap(Int(
            String(
                decoding: Data(contentsOf: fixture.readCountURL),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        XCTAssertEqual(readCount, 3)
    }

    func testBridgeInfersRunningStateFromRecentRolloutActivity() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("recent-rollout.jsonl", isDirectory: false)
        try writeRollout(
            [
                [
                    "timestamp": isoTimestamp(secondsAgo: 40),
                    "type": "event_msg",
                    "payload": ["type": "task_started"],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 3),
                    "type": "event_msg",
                    "payload": ["type": "token_count"],
                ],
            ],
            to: rollout
        )

        let codexBinary = try makeRolloutStateFakeCodexBinary(
            in: directory,
            workspace: workspace,
            rolloutPath: rollout.path,
            sessionID: "session-rollout-running"
        )

        let config = ResolvedAgentConfig(
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            enrollmentToken: "token",
            deviceID: "bridge-device",
            deviceName: "Bridge Device",
            hostName: "bridge-device.local",
            maxParallelTasks: 1,
            workspaceRoots: [WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)],
            heartbeatIntervalSeconds: 10,
            codexBinaryPath: codexBinary.path
        )

        let bridge = CodexAppServerBridge(config: config)
        let response = try await withTimeout(seconds: 5) {
            await bridge.handle(AgentCodexCommandRequest(
                requestID: UUID().uuidString,
                action: .listSessions,
                limit: 10
            ))
        }

        XCTAssertNil(response.errorMessage)
        XCTAssertEqual(response.sessions?.first?.state, .running)
    }

    func testBridgeInfersTerminalStateFromRolloutTailWhenThreadIsNotLoaded() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("completed-rollout.jsonl", isDirectory: false)
        try writeRollout(
            [
                [
                    "timestamp": isoTimestamp(secondsAgo: 90),
                    "type": "event_msg",
                    "payload": ["type": "task_started"],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 5),
                    "type": "event_msg",
                    "payload": [
                        "type": "task_complete",
                        "turn_id": "turn-completed",
                    ],
                ],
            ],
            to: rollout
        )

        let codexBinary = try makeRolloutStateFakeCodexBinary(
            in: directory,
            workspace: workspace,
            rolloutPath: rollout.path,
            sessionID: "session-rollout-completed"
        )

        let config = ResolvedAgentConfig(
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            enrollmentToken: "token",
            deviceID: "bridge-device",
            deviceName: "Bridge Device",
            hostName: "bridge-device.local",
            maxParallelTasks: 1,
            workspaceRoots: [WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)],
            heartbeatIntervalSeconds: 10,
            codexBinaryPath: codexBinary.path
        )

        let bridge = CodexAppServerBridge(config: config)
        let response = try await withTimeout(seconds: 5) {
            await bridge.handle(AgentCodexCommandRequest(
                requestID: UUID().uuidString,
                action: .listSessions,
                limit: 10
            ))
        }

        XCTAssertNil(response.errorMessage)
        XCTAssertEqual(response.sessions?.first?.state, .completed)
    }

    func testBridgeUsesRolloutExecutionItemsForSparseSessionDetail() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("detail-rollout.jsonl", isDirectory: false)
        try writeRollout(
            [
                [
                    "timestamp": isoTimestamp(secondsAgo: 70),
                    "type": "event_msg",
                    "payload": [
                        "type": "task_started",
                        "turn_id": "turn-rollout-detail",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 69),
                    "type": "event_msg",
                    "payload": [
                        "type": "user_message",
                        "message": "Show me the latest execution\n",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 68),
                    "type": "response_item",
                    "payload": [
                        "type": "reasoning",
                        "summary": ["Inspecting the current Codex session."],
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 67),
                    "type": "response_item",
                    "payload": [
                        "type": "function_call",
                        "name": "exec_command",
                        "arguments": #"{"cmd":"swift test","workdir":"/tmp/workspace"}"#,
                        "call_id": "call-rollout-detail",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 66),
                    "type": "response_item",
                    "payload": [
                        "type": "function_call_output",
                        "call_id": "call-rollout-detail",
                        "output": "Chunk ID: abc123\nWall time: 0.0000 seconds\nProcess exited with code 0\nOutput:\nBuild complete\n",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 65),
                    "type": "event_msg",
                    "payload": [
                        "type": "agent_message",
                        "phase": "final_answer",
                        "message": "I found the latest execution details.",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 64),
                    "type": "event_msg",
                    "payload": [
                        "type": "task_complete",
                        "turn_id": "turn-rollout-detail",
                        "last_agent_message": "I found the latest execution details.",
                    ],
                ],
            ],
            to: rollout
        )

        let codexBinary = try makeRolloutStateFakeCodexBinary(
            in: directory,
            workspace: workspace,
            rolloutPath: rollout.path,
            sessionID: "session-rollout-detail"
        )

        let config = ResolvedAgentConfig(
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            enrollmentToken: "token",
            deviceID: "bridge-device",
            deviceName: "Bridge Device",
            hostName: "bridge-device.local",
            maxParallelTasks: 1,
            workspaceRoots: [WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)],
            heartbeatIntervalSeconds: 10,
            codexBinaryPath: codexBinary.path
        )

        let bridge = CodexAppServerBridge(config: config)
        let response = try await withTimeout(seconds: 5) {
            await bridge.handle(AgentCodexCommandRequest(
                requestID: UUID().uuidString,
                action: .readSession,
                sessionID: "session-rollout-detail"
            ))
        }

        let detail = try XCTUnwrap(response.detail)
        XCTAssertEqual(detail.session.state, .completed)
        XCTAssertEqual(detail.session.lastTurnID, "turn-rollout-detail")
        XCTAssertEqual(detail.session.lastTurnStatus, "completed")
        XCTAssertEqual(detail.session.lastUserMessage, "Show me the latest execution")
        XCTAssertEqual(detail.session.lastAssistantMessage, "I found the latest execution details.")
        XCTAssertTrue(detail.items.contains { item in
            item.kind == .reasoning && (item.body ?? "").contains("Inspecting the current Codex session.")
        })
        XCTAssertTrue(detail.items.contains { item in
            item.kind == .commandExecution
                && item.title == "exec_command"
                && (item.body ?? "").contains("swift test")
        })
        XCTAssertTrue(detail.items.contains { item in
            item.kind == .commandExecution
                && item.title == "exec_command 输出"
                && (item.body ?? "").contains("Process exited with code 0")
                && item.status == "已完成"
        })
        XCTAssertTrue(detail.items.contains { item in
            item.kind == .agentMessage && (item.body ?? "").contains("latest execution details")
        })
    }

    func testBridgeInterruptSessionFallsBackToResumeTurns() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let codexBinary = try makeInterruptFallbackFakeCodexBinary(in: directory, workspace: workspace)

        let config = ResolvedAgentConfig(
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            enrollmentToken: "token",
            deviceID: "bridge-device",
            deviceName: "Bridge Device",
            hostName: "bridge-device.local",
            maxParallelTasks: 1,
            workspaceRoots: [WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)],
            heartbeatIntervalSeconds: 10,
            codexBinaryPath: codexBinary.path
        )

        let bridge = CodexAppServerBridge(config: config)
        let detail = try await withTimeout(seconds: 5) {
            try await bridge.interruptSession(sessionID: "session-interrupt-fallback")
        }

        XCTAssertEqual(detail.session.id, "session-interrupt-fallback")
        XCTAssertEqual(detail.session.state, .interrupted)
        XCTAssertEqual(detail.session.lastTurnID, "turn-interrupt-fallback")
    }

    func testBridgeKeepsRecentExecutionHistoryWhenNewestTurnIsSparse() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let rollout = directory.appendingPathComponent("history-rollout.jsonl", isDirectory: false)
        try writeRollout(
            [
                [
                    "timestamp": isoTimestamp(secondsAgo: 120),
                    "type": "event_msg",
                    "payload": [
                        "type": "task_started",
                        "turn_id": "turn-rich",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 119),
                    "type": "event_msg",
                    "payload": [
                        "type": "user_message",
                        "message": "show detailed execution",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 118),
                    "type": "response_item",
                    "payload": [
                        "type": "function_call",
                        "name": "exec_command",
                        "arguments": #"{"cmd":"swift build"}"#,
                        "call_id": "call-rich",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 117),
                    "type": "response_item",
                    "payload": [
                        "type": "function_call_output",
                        "call_id": "call-rich",
                        "output": "Chunk ID: rich\nProcess exited with code 0\nOutput:\nCompiled\n",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 116),
                    "type": "event_msg",
                    "payload": [
                        "type": "task_complete",
                        "turn_id": "turn-rich",
                        "last_agent_message": "previous execution complete",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 20),
                    "type": "event_msg",
                    "payload": [
                        "type": "task_started",
                        "turn_id": "turn-sparse",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 19),
                    "type": "event_msg",
                    "payload": [
                        "type": "user_message",
                        "message": "why are there no details?",
                    ],
                ],
                [
                    "timestamp": isoTimestamp(secondsAgo: 18),
                    "type": "event_msg",
                    "payload": [
                        "type": "agent_message",
                        "phase": "commentary",
                        "message": "Checking whether the history was cropped.",
                    ],
                ],
            ],
            to: rollout
        )

        let codexBinary = try makeRolloutStateFakeCodexBinary(
            in: directory,
            workspace: workspace,
            rolloutPath: rollout.path,
            sessionID: "session-rollout-history"
        )

        let config = ResolvedAgentConfig(
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            enrollmentToken: "token",
            deviceID: "bridge-device",
            deviceName: "Bridge Device",
            hostName: "bridge-device.local",
            maxParallelTasks: 1,
            workspaceRoots: [WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)],
            heartbeatIntervalSeconds: 10,
            codexBinaryPath: codexBinary.path
        )

        let bridge = CodexAppServerBridge(config: config)
        let response = try await withTimeout(seconds: 5) {
            await bridge.handle(AgentCodexCommandRequest(
                requestID: UUID().uuidString,
                action: .readSession,
                sessionID: "session-rollout-history"
            ))
        }

        let detail = try XCTUnwrap(response.detail)
        XCTAssertEqual(detail.session.lastUserMessage, "why are there no details?")
        XCTAssertTrue(detail.items.contains { item in
            item.kind == .commandExecution
                && item.title == "exec_command"
                && (item.body ?? "").contains("swift build")
        })
        XCTAssertTrue(detail.items.contains { item in
            item.kind == .commandExecution
                && item.title == "exec_command 输出"
                && (item.body ?? "").contains("Compiled")
        })
        XCTAssertTrue(detail.items.contains { item in
            item.kind == .userMessage
                && (item.body ?? "").contains("why are there no details?")
        })
    }

    func testBridgeRedactsSensitiveContentFromSessionSummaryAndDetail() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let codexBinary = try makeRedactionFakeCodexBinary(in: directory, workspace: workspace)

        let config = ResolvedAgentConfig(
            serverURL: URL(string: "http://127.0.0.1:8080")!,
            enrollmentToken: "token",
            deviceID: "bridge-device",
            deviceName: "Bridge Device",
            hostName: "bridge-device.local",
            maxParallelTasks: 1,
            workspaceRoots: [WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path)],
            heartbeatIntervalSeconds: 10,
            codexBinaryPath: codexBinary.path
        )

        let bridge = CodexAppServerBridge(config: config)
        let listed = try await withTimeout(seconds: 5) {
            await bridge.handle(AgentCodexCommandRequest(
                requestID: UUID().uuidString,
                action: .listSessions,
                limit: 10
            ))
        }

        let summary = try XCTUnwrap(listed.sessions?.first)
        XCTAssertEqual(summary.lastUserMessage, "ORCHARD_ACCESS_KEY=[REDACTED]")
        XCTAssertEqual(summary.lastAssistantMessage, "curl https://orchard.owenshen.top/api/devices?token=[REDACTED]")

        let detailed = try await withTimeout(seconds: 5) {
            await bridge.handle(AgentCodexCommandRequest(
                requestID: UUID().uuidString,
                action: .readSession,
                sessionID: summary.id
            ))
        }

        let detail = try XCTUnwrap(detailed.detail)
        XCTAssertEqual(detail.session.lastUserMessage, "ORCHARD_ACCESS_KEY=[REDACTED]")
        XCTAssertFalse(detail.items.contains { item in
            (item.body ?? "").contains("bGjMSw0GEF022XuRZ3G-SkfUncPK5-hyk0VNhXTeyhY")
        })
        XCTAssertTrue(detail.items.contains { item in
            (item.body ?? "").contains("[REDACTED]")
        })
    }
}

private func makeBridgeFakeCodexBinary(in root: URL, workspace: URL) throws -> URL {
    let stateURL = root.appendingPathComponent("fake-codex-state.json", isDirectory: false)
    let scriptURL = root.appendingPathComponent("fake-codex", isDirectory: false)

    try """
    {
      "turn_id": "turn-current",
      "turn_status": "inProgress",
      "updated_at": 1773245000,
      "last_prompt": "帮我把 Codex 会话接到 Orchard 里",
      "assistant_message": "我正在整理移动端和控制面的连接方式。"
    }
    """.write(to: stateURL, atomically: true, encoding: .utf8)

    let script = """
    #!/usr/bin/env python3
    import json
    import sys

    STATE_PATH = \(pythonLiteral(stateURL.path))
    WORKSPACE = \(pythonLiteral(workspace.path))
    THREAD_ID = "session-test-001"

    def load_state():
        with open(STATE_PATH, "r", encoding="utf-8") as handle:
            return json.load(handle)

    def thread_payload(include_turns):
        state = load_state()
        return {
            "id": THREAD_ID,
            "preview": "我现在所有的任务都是基于 codex 来发起的。",
            "ephemeral": False,
            "modelProvider": "openai",
            "createdAt": 1773240000,
            "updatedAt": state["updated_at"],
            "status": {"type": "active"},
            "path": WORKSPACE + "/thread.jsonl",
            "cwd": WORKSPACE,
            "cliVersion": "0.108.0-alpha.12",
            "source": "vscode",
            "name": "Orchard 远程控制",
            "turns": [] if not include_turns else [{
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
            }]
        }

    def send(identifier, result):
        sys.stdout.write(json.dumps({"id": identifier, "result": result}, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

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
        else:
            send(identifier, {})
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
    return scriptURL
}

private func makeInterruptFallbackFakeCodexBinary(in root: URL, workspace: URL) throws -> URL {
    let stateURL = root.appendingPathComponent("fake-codex-interrupt-state.json", isDirectory: false)
    let scriptURL = root.appendingPathComponent("fake-codex-interrupt", isDirectory: false)

    try """
    {
      "turn_id": "turn-interrupt-fallback",
      "turn_status": "inProgress",
      "updated_at": 1773245100,
      "assistant_message": "我还在继续生成最新内容。"
    }
    """.write(to: stateURL, atomically: true, encoding: .utf8)

    let script = """
    #!/usr/bin/env python3
    import json
    import sys

    STATE_PATH = \(pythonLiteral(stateURL.path))
    WORKSPACE = \(pythonLiteral(workspace.path))
    THREAD_ID = "session-interrupt-fallback"

    def load_state():
        with open(STATE_PATH, "r", encoding="utf-8") as handle:
            return json.load(handle)

    def save_state(state):
        with open(STATE_PATH, "w", encoding="utf-8") as handle:
            json.dump(state, handle, ensure_ascii=False)

    def thread_payload(include_turns):
        state = load_state()
        turn_status = state["turn_status"]
        thread_status = "active" if turn_status == "inProgress" else "idle"
        turns = []
        if include_turns:
            turns = [{
                "id": state["turn_id"],
                "status": turn_status,
                "error": None,
                "items": [
                    {
                        "id": "item-agent-current",
                        "type": "agentMessage",
                        "phase": "commentary",
                        "text": state["assistant_message"]
                    }
                ]
            }]
        return {
            "id": THREAD_ID,
            "preview": "中断 fallback 测试",
            "ephemeral": False,
            "modelProvider": "openai",
            "createdAt": 1773240000,
            "updatedAt": state["updated_at"],
            "status": {"type": thread_status},
            "path": WORKSPACE + "/thread.jsonl",
            "cwd": WORKSPACE,
            "cliVersion": "0.108.0-alpha.12",
            "source": "vscode",
            "name": "Interrupt Fallback",
            "turns": turns
        }

    def send(identifier, result):
        sys.stdout.write(json.dumps({"id": identifier, "result": result}, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

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
        elif method == "thread/read":
            include_turns = bool(params.get("includeTurns"))
            send(identifier, {"thread": thread_payload(include_turns)})
        elif method == "thread/resume":
            send(identifier, {"thread": thread_payload(True)})
        elif method == "turn/interrupt":
            state = load_state()
            state["turn_status"] = "interrupted"
            state["updated_at"] = state["updated_at"] + 1
            save_state(state)
            send(identifier, {})
        else:
            send(identifier, {})
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
    return scriptURL
}

private func makeRedactionFakeCodexBinary(in root: URL, workspace: URL) throws -> URL {
    let scriptURL = root.appendingPathComponent("fake-codex-redaction", isDirectory: false)

    let script = """
    #!/usr/bin/env python3
    import json
    import sys

    WORKSPACE = \(pythonLiteral(workspace.path))
    THREAD_ID = "session-redaction-001"
    USER_TEXT = "ORCHARD_ACCESS_KEY=bGjMSw0GEF022XuRZ3G-SkfUncPK5-hyk0VNhXTeyhY"
    AGENT_TEXT = "curl https://orchard.owenshen.top/api/devices?token=bGjMSw0GEF022XuRZ3G-SkfUncPK5-hyk0VNhXTeyhY"

    def thread_payload(include_turns):
        return {
            "id": THREAD_ID,
            "preview": "redaction-preview",
            "ephemeral": False,
            "modelProvider": "openai",
            "createdAt": 1773240000,
            "updatedAt": 1773245000,
            "status": {"type": "active"},
            "path": WORKSPACE + "/thread-redaction.jsonl",
            "cwd": WORKSPACE,
            "cliVersion": "0.108.0-alpha.12",
            "source": "vscode",
            "name": "Redaction Session",
            "turns": [] if not include_turns else [{
                "id": "turn-redaction",
                "status": "completed",
                "error": None,
                "items": [
                    {
                        "id": "user-redaction",
                        "type": "userMessage",
                        "content": [{"type": "text", "text": USER_TEXT}]
                    },
                    {
                        "id": "agent-redaction",
                        "type": "agentMessage",
                        "phase": "commentary",
                        "text": AGENT_TEXT
                    }
                ]
            }]
        }

    def send(identifier, result):
        sys.stdout.write(json.dumps({"id": identifier, "result": result}, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

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
        else:
            send(identifier, {})
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
    return scriptURL
}

private func makeBoundedHydrationFakeCodexBinary(in root: URL, workspace: URL) throws -> (binary: URL, readCountURL: URL) {
    let readCountURL = root.appendingPathComponent("fake-codex-read-count.txt", isDirectory: false)
    let scriptURL = root.appendingPathComponent("fake-codex-bounded", isDirectory: false)

    try "0\n".write(to: readCountURL, atomically: true, encoding: .utf8)

    let script = """
    #!/usr/bin/env python3
    import json
    import sys

    READ_COUNT_PATH = \(pythonLiteral(readCountURL.path))
    WORKSPACE = \(pythonLiteral(workspace.path))

    def load_count():
        with open(READ_COUNT_PATH, "r", encoding="utf-8") as handle:
            return int(handle.read().strip() or "0")

    def save_count(value):
        with open(READ_COUNT_PATH, "w", encoding="utf-8") as handle:
            handle.write(str(value) + "\\n")

    def thread_payload(index, include_turns):
        return {
            "id": f"session-{index}",
            "preview": f"session-{index}-preview",
            "ephemeral": False,
            "modelProvider": "openai",
            "createdAt": 1773240000 + index,
            "updatedAt": 1773245000 - index,
            "status": {"type": "notLoaded"},
            "path": WORKSPACE + f"/thread-{index}.jsonl",
            "cwd": WORKSPACE,
            "cliVersion": "0.108.0-alpha.12",
            "source": "vscode",
            "name": f"Session {index}",
            "turns": [] if not include_turns else [{
                "id": f"turn-{index}",
                "status": "completed",
                "error": None,
                "items": [
                    {
                        "id": f"user-{index}",
                        "type": "userMessage",
                        "content": [{"type": "text", "text": f"Prompt {index}"}]
                    }
                ]
            }]
        }

    def send(identifier, result):
        sys.stdout.write(json.dumps({"id": identifier, "result": result}, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

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
            send(identifier, {
                "data": [thread_payload(index, False) for index in range(5)],
                "nextCursor": None
            })
        elif method == "thread/read":
            count = load_count() + 1
            save_count(count)
            index = int((params.get("threadId") or "session-0").split("-")[-1])
            send(identifier, {"thread": thread_payload(index, True)})
        else:
            send(identifier, {})
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
    return (scriptURL, readCountURL)
}

private func makeRolloutStateFakeCodexBinary(
    in root: URL,
    workspace: URL,
    rolloutPath: String,
    sessionID: String
) throws -> URL {
    let scriptURL = root.appendingPathComponent("fake-codex-rollout-state", isDirectory: false)

    let script = """
    #!/usr/bin/env python3
    import json
    import sys

    WORKSPACE = \(pythonLiteral(workspace.path))
    ROLLOUT_PATH = \(pythonLiteral(rolloutPath))
    THREAD_ID = \(pythonLiteral(sessionID))

    def thread_payload():
        return {
            "id": THREAD_ID,
            "preview": "rollout-preview",
            "ephemeral": False,
            "modelProvider": "openai",
            "createdAt": 1773240000,
            "updatedAt": 1773245000,
            "status": {"type": "notLoaded"},
            "path": ROLLOUT_PATH,
            "cwd": WORKSPACE,
            "cliVersion": "0.108.0-alpha.12",
            "source": "vscode",
            "name": "Rollout Session",
            "turns": []
        }

    def send(identifier, result):
        sys.stdout.write(json.dumps({"id": identifier, "result": result}, ensure_ascii=False) + "\\n")
        sys.stdout.flush()

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
            send(identifier, {"data": [thread_payload()], "nextCursor": None})
        elif method == "thread/read":
            send(identifier, {"thread": thread_payload()})
        else:
            send(identifier, {})
    """

    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    XCTAssertEqual(chmod(scriptURL.path, 0o755), 0)
    return scriptURL
}

private func writeRollout(_ lines: [[String: Any]], to url: URL) throws {
    let payload = try lines
        .map { line in
            let data = try JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        .joined(separator: "\n") + "\n"
    try payload.write(to: url, atomically: true, encoding: .utf8)
}

private func isoTimestamp(secondsAgo: TimeInterval) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date().addingTimeInterval(-secondsAgo))
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NSError(domain: "CodexAppServerBridgeTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Timed out waiting for operation.",
            ])
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func pythonLiteral(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("orchard-agent-bridge-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
