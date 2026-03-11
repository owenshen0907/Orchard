import Darwin
import Foundation
import XCTest
@testable import OrchardAgent
import OrchardCore

final class OrchardAgentCLITests: XCTestCase {
    func testCLIParsesInitConfigOverrides() throws {
        let command = try AgentCLI.parse(arguments: [
            "OrchardAgent",
            "init-config",
            "--server-url", "https://orchard.local",
            "--enrollment-token", "secret",
            "--device-id", "mac-mini-01",
            "--workspace-root", "/tmp/workspace",
            "--overwrite",
        ])

        guard case let .initConfig(options) = command else {
            return XCTFail("Expected init-config command")
        }

        XCTAssertEqual(options.serverURLString, "https://orchard.local")
        XCTAssertEqual(options.enrollmentToken, "secret")
        XCTAssertEqual(options.deviceID, "mac-mini-01")
        XCTAssertEqual(options.workspaceRootPath, "/tmp/workspace")
        XCTAssertTrue(options.overwrite)
    }

    func testInitConfigWritesValidatedConfig() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let configURL = directory.appendingPathComponent("agent.json", isDirectory: false)
        let options = try AgentInitConfigOptions(configURL: configURL, currentDirectoryPath: workspace.path, hostName: "Mac Mini")
        let result = try AgentConfigInitializer.writeConfig(options: options)

        XCTAssertEqual(result.configURL.path, configURL.path)
        XCTAssertEqual(result.resolvedConfig.deviceID, "mac-mini")
        XCTAssertEqual(result.resolvedConfig.workspaceRoots.first?.rootPath, workspace.path)
    }

    func testLaunchAgentRendererSubstitutesPaths() {
        let plist = LaunchAgentInstaller.renderPlist(
            label: "com.example.orchard",
            binaryPath: "/Applications/OrchardAgent",
            workingDirectoryPath: "/Users/owen/Orchard",
            logDirectoryPath: "/Users/owen/Library/Logs/Orchard"
        )

        XCTAssertTrue(plist.contains("com.example.orchard"))
        XCTAssertTrue(plist.contains("/Applications/OrchardAgent"))
        XCTAssertTrue(plist.contains("/Users/owen/Orchard"))
        XCTAssertTrue(plist.contains("/Users/owen/Library/Logs/Orchard/agent.out.log"))
    }

    func testLaunchAgentPlistInfoParsesRenderedPlist() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plistURL = directory.appendingPathComponent("agent.plist", isDirectory: false)
        let plist = LaunchAgentInstaller.renderPlist(
            label: "com.example.orchard",
            binaryPath: "/Applications/OrchardAgent",
            workingDirectoryPath: "/Users/owen/Orchard",
            logDirectoryPath: "/Users/owen/Library/Logs/Orchard"
        )
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)

        let info = try LaunchAgentPlistInfo.load(from: plistURL)

        XCTAssertEqual(info.label, "com.example.orchard")
        XCTAssertEqual(info.programArguments.first, "/Applications/OrchardAgent")
        XCTAssertEqual(info.workingDirectoryURL?.path, "/Users/owen/Orchard")
        XCTAssertEqual(info.standardOutURL?.path, "/Users/owen/Library/Logs/Orchard/agent.out.log")
        XCTAssertEqual(info.standardErrorURL?.path, "/Users/owen/Library/Logs/Orchard/agent.err.log")
    }

    func testDoctorPassesWithSkippedNetworkAndExistingPlist() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = directory.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let codexURL = directory.appendingPathComponent("codex", isDirectory: false)
        FileManager.default.createFile(atPath: codexURL.path, contents: Data("echo codex".utf8))
        XCTAssertEqual(chmod(codexURL.path, 0o755), 0)

        let configURL = directory.appendingPathComponent("agent.json", isDirectory: false)
        let plistURL = directory.appendingPathComponent("com.owen.orchard.agent.plist", isDirectory: false)

        try AgentConfigLoader.save(
            AgentConfigFile(
                serverURL: "http://127.0.0.1:8080",
                enrollmentToken: "token",
                deviceID: "doctor-device",
                deviceName: "Doctor Device",
                maxParallelTasks: 2,
                workspaceRoots: [
                    WorkspaceDefinition(id: "main", name: "Main", rootPath: workspace.path),
                ],
                heartbeatIntervalSeconds: 10,
                codexBinaryPath: codexURL.path
            ),
            to: configURL
        )
        try "plist".write(to: plistURL, atomically: true, encoding: .utf8)

        var options = try AgentDoctorOptions(configURL: configURL)
        options.plistURL = plistURL
        options.skipNetwork = true
        options.skipLaunchAgent = true

        let report = await AgentDoctor.run(options: options)

        XCTAssertTrue(report.isHealthy)
        XCTAssertEqual(report.checks.filter { !$0.isSuccess }.count, 0)
    }
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("orchard-agent-cli-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
