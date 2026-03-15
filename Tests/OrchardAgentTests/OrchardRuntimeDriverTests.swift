import Foundation
import XCTest
@testable import OrchardAgent
import OrchardCore

final class OrchardRuntimeDriverTests: XCTestCase {
    func testConversationDriverSelectionUsesCodexCLIForCodexTasks() throws {
        let task = TaskRecord(
            id: "task-codex",
            title: "验证 Orchard Runtime driver",
            kind: .codex,
            workspaceID: "main",
            relativePath: "Sources",
            priority: .normal,
            status: .queued,
            payload: .codex(CodexTaskPayload(prompt: "做第一轮 Runtime 抽象")),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let selection = try XCTUnwrap(OrchardRuntimeConversationDriverFactory.selection(for: task))
        XCTAssertEqual(selection.kind, .codexCLI)
        XCTAssertEqual(selection.displayName, "Codex CLI")
        XCTAssertTrue(selection.reason.contains("Codex CLI"))
    }

    func testConversationDriverSelectionHonorsExplicitDriverInPayload() throws {
        let task = TaskRecord(
            id: "task-claude",
            title: "验证显式 driver",
            kind: .codex,
            workspaceID: "main",
            relativePath: "Sources",
            priority: .normal,
            status: .queued,
            payload: .codex(CodexTaskPayload(prompt: "预留 Claude Code driver", driver: .claudeCode)),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        let selection = try XCTUnwrap(OrchardRuntimeConversationDriverFactory.selection(for: task))
        XCTAssertEqual(selection.kind, .claudeCode)
        XCTAssertEqual(selection.displayName, "Claude Code")
        XCTAssertTrue(selection.reason.contains("显式"))
    }

    func testConversationDriverFactoryRejectsUnavailableClaudeDriver() throws {
        let task = TaskRecord(
            id: "task-claude",
            title: "验证未接入 driver",
            kind: .codex,
            workspaceID: "main",
            relativePath: nil,
            priority: .normal,
            status: .queued,
            payload: .codex(CodexTaskPayload(prompt: "试一下 Claude Code", driver: .claudeCode)),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let config = ResolvedAgentConfig(
            serverURL: try XCTUnwrap(URL(string: "https://orchard.local")),
            enrollmentToken: "token",
            deviceID: "device-1",
            deviceName: "Device 1",
            hostName: "host-1",
            maxParallelTasks: 1,
            workspaceRoots: [WorkspaceDefinition(id: "main", name: "Main", rootPath: "/tmp/workspace")],
            heartbeatIntervalSeconds: 10,
            codexBinaryPath: "codex"
        )

        XCTAssertThrowsError(try OrchardRuntimeConversationDriverFactory.driver(for: task, config: config)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Claude Code"))
        }
    }

    func testConversationDriverSelectionSkipsShellTasks() {
        let task = TaskRecord(
            id: "task-shell",
            title: "普通 shell 任务",
            kind: .shell,
            workspaceID: "main",
            relativePath: nil,
            priority: .normal,
            status: .queued,
            payload: .shell(ShellTaskPayload(command: "echo hello")),
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(OrchardRuntimeConversationDriverFactory.selection(for: task))
    }
}
