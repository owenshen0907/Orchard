import XCTest
@testable import OrchardCore

final class OrchardCoreTests: XCTestCase {
    func testTaskRoundTrip() throws {
        let task = TaskRecord(
            id: "task-1",
            title: "Smoke test",
            command: "echo hello",
            workDirectory: "/tmp",
            kind: .shell,
            priority: .normal,
            status: .queued,
            createdAt: Date(),
            updatedAt: Date()
        )

        let data = try OrchardJSON.encoder.encode(task)
        let decoded = try OrchardJSON.decoder.decode(TaskRecord.self, from: data)
        XCTAssertEqual(decoded.id, task.id)
        XCTAssertEqual(decoded.command, task.command)
        XCTAssertEqual(decoded.kind, .shell)
    }
}
