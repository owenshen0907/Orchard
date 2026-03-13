import Foundation
import XCTest
@testable import OrchardAgent
import OrchardCore

final class OrchardAgentStateStoreTests: XCTestCase {
    func testBootstrapPreservesActiveTasksForRuntimeRecovery() async throws {
        let stateURL = try makeStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let store = AgentStateStore(url: stateURL)
        try await store.markTaskStarted("task-a")
        try await store.markTaskStarted("task-b")

        let bootstrap = try await store.bootstrap()

        XCTAssertEqual(bootstrap.activeTaskIDs, ["task-a", "task-b"])
        XCTAssertTrue(bootstrap.pendingTaskUpdates.isEmpty)
    }

    func testStagedTaskUpdatePersistsUntilDelivered() async throws {
        let stateURL = try makeStateURL()
        defer { try? FileManager.default.removeItem(at: stateURL.deletingLastPathComponent()) }

        let store = AgentStateStore(url: stateURL)
        try await store.markTaskStarted("task-a")
        try await store.stageTaskUpdate(AgentTaskUpdatePayload(
            taskID: "task-a",
            status: .succeeded,
            exitCode: 0,
            summary: "Task completed successfully."
        ))

        let pendingBeforeDelivery = try await store.bootstrap()
        XCTAssertEqual(pendingBeforeDelivery.pendingTaskUpdates.count, 1)
        XCTAssertEqual(pendingBeforeDelivery.pendingTaskUpdates.first?.taskID, "task-a")
        XCTAssertEqual(pendingBeforeDelivery.pendingTaskUpdates.first?.status, .succeeded)

        try await store.markTaskUpdateDelivered("task-a")
        let pendingAfterDelivery = try await store.bootstrap()
        XCTAssertTrue(pendingAfterDelivery.pendingTaskUpdates.isEmpty)
        XCTAssertTrue(pendingAfterDelivery.activeTaskIDs.isEmpty)
    }
}

private func makeStateURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("orchard-agent-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("agent-state.json", isDirectory: false)
}
