import XCTest
@testable import OrchardCore

final class OrchardCoreTests: XCTestCase {
    func testShellPayloadRoundTrip() throws {
        let payload = TaskPayload.shell(ShellTaskPayload(command: "echo hello"))
        let data = try OrchardJSON.encoder.encode(payload)
        let decoded = try OrchardJSON.decoder.decode(TaskPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.kind, .shell)
    }

    func testCodexPayloadRoundTrip() throws {
        let payload = TaskPayload.codex(CodexTaskPayload(prompt: "Refactor the API client"))
        let data = try OrchardJSON.encoder.encode(payload)
        let decoded = try OrchardJSON.decoder.decode(TaskPayload.self, from: data)
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.kind, .codex)
    }

    func testWorkspacePathRejectsEscape() throws {
        XCTAssertThrowsError(try OrchardWorkspacePath.resolve(rootPath: "/tmp/workspace", relativePath: "../outside"))
    }

    func testWorkspacePathAllowsNestedDirectory() throws {
        let resolved = try OrchardWorkspacePath.resolve(rootPath: "/tmp/workspace", relativePath: "src/module")
        XCTAssertEqual(resolved.path, "/tmp/workspace/src/module")
    }
}
