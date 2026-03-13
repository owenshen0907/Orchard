import Foundation
import XCTest
@testable import OrchardAgent
import OrchardCore

final class ProjectContextTests: XCTestCase {
    func testCLIParsesProjectContextShowOptions() throws {
        let command = try AgentCLI.parse(arguments: [
            "OrchardAgent",
            "project-context",
            "show",
            "--workspace", "/tmp/workspace",
            "--local-secrets-path", "/tmp/orchard.local.json",
            "--reveal-secrets",
        ])

        guard case let .projectContext(projectCommand) = command else {
            return XCTFail("Expected project-context command")
        }
        guard case let .show(options) = projectCommand else {
            return XCTFail("Expected project-context show command")
        }

        XCTAssertEqual(options.workspaceURL?.path, "/tmp/workspace")
        XCTAssertEqual(options.localSecretsURL?.path, "/tmp/orchard.local.json")
        XCTAssertTrue(options.revealSecrets)
    }

    func testCLIParsesProjectContextLookupOptions() throws {
        let command = try AgentCLI.parse(arguments: [
            "OrchardAgent",
            "project-context",
            "lookup",
            "service",
            "orchard-control-plane",
            "--workspace", "/tmp/workspace",
            "--local-secrets-path", "/tmp/orchard.local.json",
            "--format", "json",
            "--reveal-secrets",
        ])

        guard case let .projectContext(projectCommand) = command else {
            return XCTFail("Expected project-context command")
        }
        guard case let .lookup(options) = projectCommand else {
            return XCTFail("Expected project-context lookup command")
        }

        XCTAssertEqual(options.subject, .service)
        XCTAssertEqual(options.selector, "orchard-control-plane")
        XCTAssertEqual(options.workspaceURL?.path, "/tmp/workspace")
        XCTAssertEqual(options.localSecretsURL?.path, "/tmp/orchard.local.json")
        XCTAssertEqual(options.format, .json)
        XCTAssertTrue(options.revealSecrets)
    }

    func testCLIParsesProjectContextLookupCommandAlias() throws {
        let command = try AgentCLI.parse(arguments: [
            "OrchardAgent",
            "project-context",
            "lookup",
            "cmd",
            "deploy-control-plane",
        ])

        guard case let .projectContext(projectCommand) = command else {
            return XCTFail("Expected project-context command")
        }
        guard case let .lookup(options) = projectCommand else {
            return XCTFail("Expected project-context lookup command")
        }

        XCTAssertEqual(options.subject, .command)
        XCTAssertEqual(options.selector, "deploy-control-plane")
    }

    func testProjectContextResolverMergesLocalSecretsAndRedactsSensitiveValues() throws {
        let directory = try makeProjectContextTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repoURL = directory.appendingPathComponent("repo", isDirectory: true)
        let orchardDirectory = repoURL.appendingPathComponent(".orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: orchardDirectory, withIntermediateDirectories: true)

        let definition = ProjectContextFile(
            projectID: "demo",
            projectName: "Demo",
            environments: [
                ProjectEnvironment(id: "prod", name: "生产"),
            ],
            hosts: [
                ProjectHost(id: "host-01", name: "Host 01"),
            ],
            services: [
                ProjectService(
                    id: "control-plane",
                    name: "Control Plane",
                    kind: "web",
                    environmentIDs: ["prod"],
                    hostID: "host-01",
                    credentialIDs: ["ssh-main"]
                ),
            ],
            credentials: [
                ProjectCredentialRequirement(
                    id: "ssh-main",
                    name: "SSH",
                    kind: "ssh",
                    appliesToHostIDs: ["host-01"],
                    fields: [
                        ProjectCredentialField(key: "username", label: "用户名", required: true, isSensitive: false),
                        ProjectCredentialField(key: "privateKeyPath", label: "私钥路径", required: true, isSensitive: true),
                    ]
                ),
            ]
        )

        try OrchardJSON.encoder
            .encode(definition)
            .write(to: orchardDirectory.appendingPathComponent("project-context.json"), options: .atomic)

        let localSecretsURL = directory.appendingPathComponent("demo.local.json", isDirectory: false)
        let localSecrets = ProjectContextSecretsFile(
            projectID: "demo",
            credentials: [
                ProjectCredentialValue(
                    credentialID: "ssh-main",
                    values: [
                        "username": "owenadmin",
                        "privateKeyPath": "~/.ssh/id_demo",
                    ]
                ),
            ]
        )
        try OrchardJSON.encoder.encode(localSecrets).write(to: localSecretsURL, options: .atomic)

        let resolved = try ProjectContextResolver.load(
            workspaceURL: repoURL.appendingPathComponent("nested/path", isDirectory: true),
            localSecretsURL: localSecretsURL
        )

        XCTAssertEqual(resolved.project.projectID, "demo")
        XCTAssertTrue(resolved.localSecretsPresent)
        XCTAssertEqual(resolved.resolvedCredentials.first?.configured, true)
        XCTAssertEqual(resolved.resolvedCredentials.first?.fields.first(where: { $0.key == "username" })?.value, "owenadmin")

        let redacted = resolved.redactingSensitiveValues()
        XCTAssertEqual(redacted.resolvedCredentials.first?.fields.first(where: { $0.key == "username" })?.value, "owenadmin")
        XCTAssertEqual(redacted.resolvedCredentials.first?.fields.first(where: { $0.key == "privateKeyPath" })?.value, "********")
    }

    func testProjectContextLookupServiceIncludesRelatedResourcesAndRedactsSecretsByDefault() throws {
        let directory = try makeProjectContextTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repoURL = directory.appendingPathComponent("repo", isDirectory: true)
        let orchardDirectory = repoURL.appendingPathComponent(".orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: orchardDirectory, withIntermediateDirectories: true)

        let definition = ProjectContextFile(
            projectID: "demo",
            projectName: "Demo",
            environments: [
                ProjectEnvironment(id: "production", name: "生产", hostIDs: ["host-01"], serviceIDs: ["control-plane"]),
            ],
            hosts: [
                ProjectHost(id: "host-01", name: "Host 01", publicAddress: "1.2.3.4"),
            ],
            services: [
                ProjectService(
                    id: "control-plane",
                    name: "Control Plane",
                    kind: "web",
                    environmentIDs: ["production"],
                    hostID: "host-01",
                    deployPath: "/srv/control-plane",
                    configPath: "/etc/control-plane.env",
                    credentialIDs: ["api-main"]
                ),
            ],
            credentials: [
                ProjectCredentialRequirement(
                    id: "api-main",
                    name: "API Key",
                    kind: "apiKey",
                    appliesToServiceIDs: ["control-plane"],
                    fields: [
                        ProjectCredentialField(key: "accessKey", label: "访问密钥", required: true, isSensitive: true),
                    ]
                ),
            ]
        )

        try OrchardJSON.encoder
            .encode(definition)
            .write(to: orchardDirectory.appendingPathComponent("project-context.json"), options: .atomic)

        let localSecretsURL = directory.appendingPathComponent("demo.local.json", isDirectory: false)
        let localSecrets = ProjectContextSecretsFile(
            projectID: "demo",
            credentials: [
                ProjectCredentialValue(
                    credentialID: "api-main",
                    values: [
                        "accessKey": "secret-token",
                    ]
                ),
            ]
        )
        try OrchardJSON.encoder.encode(localSecrets).write(to: localSecretsURL, options: .atomic)

        let lookup = try ProjectContextResolver.lookupServices(
            options: ProjectContextLookupOptions(
                subject: .service,
                selector: "control-plane",
                workspaceURL: repoURL,
                localSecretsURL: localSecretsURL
            )
        )

        XCTAssertEqual(lookup.context.matchCount, 1)
        XCTAssertEqual(lookup.items.count, 1)
        XCTAssertEqual(lookup.items.first?.host?.id, "host-01")
        XCTAssertEqual(lookup.items.first?.environments.first?.id, "production")
        XCTAssertEqual(lookup.items.first?.credentials.first?.id, "api-main")
        XCTAssertEqual(
            lookup.items.first?.credentials.first?.fields.first(where: { $0.key == "accessKey" })?.value,
            "********"
        )
    }

    func testProjectContextLookupCommandIncludesRelatedResourcesAndResolvedCredentials() throws {
        let directory = try makeProjectContextTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repoURL = directory.appendingPathComponent("repo", isDirectory: true)
        let orchardDirectory = repoURL.appendingPathComponent(".orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: orchardDirectory, withIntermediateDirectories: true)

        let definition = ProjectContextFile(
            projectID: "demo",
            projectName: "Demo",
            environments: [
                ProjectEnvironment(id: "production", name: "生产", hostIDs: ["host-01"], serviceIDs: ["control-plane"], databaseIDs: ["db-01"]),
            ],
            hosts: [
                ProjectHost(id: "host-01", name: "Host 01", publicAddress: "1.2.3.4"),
            ],
            services: [
                ProjectService(
                    id: "control-plane",
                    name: "Control Plane",
                    kind: "web",
                    environmentIDs: ["production"],
                    hostID: "host-01"
                ),
            ],
            databases: [
                ProjectDatabase(
                    id: "db-01",
                    name: "SQLite",
                    engine: "sqlite",
                    environmentIDs: ["production"],
                    hostID: "host-01",
                    storagePath: "/srv/control-plane/data.sqlite"
                ),
            ],
            commands: [
                ProjectCommand(
                    id: "deploy-control-plane",
                    name: "部署控制面",
                    runner: "shell",
                    command: "./deploy/deploy-control-plane.sh --env production",
                    workingDirectory: "/workspace/Orchard",
                    environmentIDs: ["production"],
                    hostID: "host-01",
                    serviceIDs: ["control-plane"],
                    databaseIDs: ["db-01"]
                ),
            ],
            credentials: [
                ProjectCredentialRequirement(
                    id: "api-main",
                    name: "API Key",
                    kind: "apiKey",
                    appliesToServiceIDs: ["control-plane"],
                    fields: [
                        ProjectCredentialField(key: "accessKey", label: "访问密钥", required: true, isSensitive: true),
                    ]
                ),
            ]
        )

        try OrchardJSON.encoder
            .encode(definition)
            .write(to: orchardDirectory.appendingPathComponent("project-context.json"), options: .atomic)

        let localSecretsURL = directory.appendingPathComponent("demo.local.json", isDirectory: false)
        let localSecrets = ProjectContextSecretsFile(
            projectID: "demo",
            credentials: [
                ProjectCredentialValue(
                    credentialID: "api-main",
                    values: [
                        "accessKey": "secret-token",
                    ]
                ),
            ]
        )
        try OrchardJSON.encoder.encode(localSecrets).write(to: localSecretsURL, options: .atomic)

        let lookup = try ProjectContextResolver.lookupCommands(
            options: ProjectContextLookupOptions(
                subject: .command,
                selector: "deploy-control-plane",
                workspaceURL: repoURL,
                localSecretsURL: localSecretsURL
            )
        )

        XCTAssertEqual(lookup.context.matchCount, 1)
        XCTAssertEqual(lookup.items.count, 1)
        XCTAssertEqual(lookup.items.first?.host?.id, "host-01")
        XCTAssertEqual(lookup.items.first?.environments.first?.id, "production")
        XCTAssertEqual(lookup.items.first?.services.first?.id, "control-plane")
        XCTAssertEqual(lookup.items.first?.databases.first?.id, "db-01")
        XCTAssertEqual(lookup.items.first?.credentials.first?.id, "api-main")
        XCTAssertEqual(
            lookup.items.first?.credentials.first?.fields.first(where: { $0.key == "accessKey" })?.value,
            "********"
        )
        XCTAssertTrue(lookup.renderedLines.contains(where: { $0.contains("命令模板: ./deploy/deploy-control-plane.sh --env production") }))
    }

    func testProjectContextPromptAugmentorInjectsRedactedContextAndKeepsDisplayPromptClean() throws {
        let directory = try makeProjectContextTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repoURL = directory.appendingPathComponent("repo", isDirectory: true)
        let orchardDirectory = repoURL.appendingPathComponent(".orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: orchardDirectory, withIntermediateDirectories: true)

        let definition = ProjectContextFile(
            projectID: "demo-prompt",
            projectName: "Demo Prompt",
            summary: "演示自动注入到 Codex 首轮 prompt。",
            repository: ProjectRepositoryInfo(
                gitRemote: "https://example.com/demo.git",
                defaultBranch: "main",
                deployRunbook: "deploy/demo.sh"
            ),
            environments: [
                ProjectEnvironment(
                    id: "production",
                    name: "生产",
                    deploymentPath: "/srv/demo",
                    hostIDs: ["host-01"],
                    serviceIDs: ["control-plane"],
                    databaseIDs: ["db-01"],
                    urls: [ProjectEndpoint(label: "主站", url: "https://demo.example.com")]
                ),
            ],
            hosts: [
                ProjectHost(
                    id: "host-01",
                    name: "阿里云主机",
                    provider: "aliyun",
                    region: "cn-hangzhou",
                    publicAddress: "1.2.3.4",
                    roles: ["deploy", "app"]
                ),
            ],
            services: [
                ProjectService(
                    id: "control-plane",
                    name: "Control Plane",
                    kind: "web",
                    environmentIDs: ["production"],
                    hostID: "host-01",
                    deployPath: "/srv/demo",
                    runbook: "deploy/demo.sh",
                    healthURL: "https://demo.example.com/health",
                    configPath: "/etc/demo.env",
                    credentialIDs: ["ssh-main"]
                ),
            ],
            databases: [
                ProjectDatabase(
                    id: "db-01",
                    name: "SQLite",
                    engine: "sqlite",
                    environmentIDs: ["production"],
                    hostID: "host-01",
                    storagePath: "/srv/demo/data/demo.sqlite"
                ),
            ],
            commands: [
                ProjectCommand(
                    id: "deploy-control-plane",
                    name: "部署控制面",
                    runner: "shell",
                    command: "./deploy/demo.sh --target production",
                    workingDirectory: "/Users/owen/MyCodeSpace/DemoPrompt",
                    environmentIDs: ["production"],
                    hostID: "host-01",
                    serviceIDs: ["control-plane"],
                    databaseIDs: ["db-01"]
                ),
            ],
            credentials: [
                ProjectCredentialRequirement(
                    id: "ssh-main",
                    name: "SSH",
                    kind: "ssh",
                    appliesToHostIDs: ["host-01"],
                    fields: [
                        ProjectCredentialField(key: "username", label: "用户名", required: true, isSensitive: false),
                        ProjectCredentialField(key: "privateKeyPath", label: "私钥路径", required: true, isSensitive: true),
                    ]
                ),
            ]
        )

        try OrchardJSON.encoder
            .encode(definition)
            .write(to: orchardDirectory.appendingPathComponent("project-context.json"), options: .atomic)

        let localSecretsURL = directory.appendingPathComponent("demo-prompt.local.json", isDirectory: false)
        let localSecrets = ProjectContextSecretsFile(
            projectID: "demo-prompt",
            credentials: [
                ProjectCredentialValue(
                    credentialID: "ssh-main",
                    values: [
                        "username": "owenadmin",
                        "privateKeyPath": "/Users/owen/.ssh/demo",
                    ]
                ),
            ]
        )
        try OrchardJSON.encoder.encode(localSecrets).write(to: localSecretsURL, options: .atomic)

        let prepared = ProjectContextPromptAugmentor.prepare(
            userPrompt: "请把控制面部署链路补齐",
            workspaceURL: repoURL,
            localSecretsURL: localSecretsURL
        )

        XCTAssertEqual(prepared.displayPrompt, "请把控制面部署链路补齐")
        XCTAssertEqual(prepared.attachedProjectID, "demo-prompt")
        XCTAssertTrue(prepared.executionPrompt.contains("<<<ORCHARD_PROJECT_CONTEXT>>>"))
        XCTAssertTrue(prepared.executionPrompt.contains("control-plane"))
        XCTAssertTrue(prepared.executionPrompt.contains("/srv/demo"))
        XCTAssertTrue(prepared.executionPrompt.contains("标准操作命令:"))
        XCTAssertTrue(prepared.executionPrompt.contains("deploy-control-plane"))
        XCTAssertTrue(prepared.executionPrompt.contains("status=已配置"))
        XCTAssertTrue(prepared.executionPrompt.contains("privateKeyPath[required,sensitive]"))
        XCTAssertFalse(prepared.executionPrompt.contains("/Users/owen/.ssh/demo"))
        XCTAssertEqual(
            ProjectContextPromptAugmentor.extractUserPrompt(from: prepared.executionPrompt),
            "请把控制面部署链路补齐"
        )
    }

    func testProjectContextPromptAugmentorFallsBackWhenNoDefinitionExists() throws {
        let directory = try makeProjectContextTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let prepared = ProjectContextPromptAugmentor.prepare(
            userPrompt: "继续修复移动端问题",
            workspaceURL: directory
        )

        XCTAssertEqual(prepared.displayPrompt, "继续修复移动端问题")
        XCTAssertEqual(prepared.executionPrompt, "继续修复移动端问题")
        XCTAssertNil(prepared.attachedProjectID)
        XCTAssertEqual(
            ProjectContextPromptAugmentor.extractUserPrompt(from: "继续修复移动端问题"),
            "继续修复移动端问题"
        )
    }

    func testProjectContextDoctorReportsMissingRequiredFields() throws {
        let directory = try makeProjectContextTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repoURL = directory.appendingPathComponent("repo", isDirectory: true)
        let orchardDirectory = repoURL.appendingPathComponent(".orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: orchardDirectory, withIntermediateDirectories: true)

        let definition = ProjectContextFile(
            projectID: "demo",
            projectName: "Demo",
            credentials: [
                ProjectCredentialRequirement(
                    id: "api-main",
                    name: "API Key",
                    kind: "apiKey",
                    fields: [
                        ProjectCredentialField(key: "accessKey", label: "访问密钥"),
                    ]
                ),
            ]
        )

        try OrchardJSON.encoder
            .encode(definition)
            .write(to: orchardDirectory.appendingPathComponent("project-context.json"), options: .atomic)

        let report = try ProjectContextResolver.doctor(
            options: ProjectContextDoctorOptions(
                workspaceURL: repoURL,
                localSecretsURL: directory.appendingPathComponent("missing.local.json", isDirectory: false)
            )
        )

        XCTAssertFalse(report.isHealthy)
        XCTAssertTrue(report.issues.contains { $0.contains("Local secrets file is missing") })
        XCTAssertTrue(report.issues.contains { $0.contains("api-main") })
    }

    func testProjectContextValidationRejectsUnknownCommandReferences() throws {
        let directory = try makeProjectContextTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repoURL = directory.appendingPathComponent("repo", isDirectory: true)
        let orchardDirectory = repoURL.appendingPathComponent(".orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: orchardDirectory, withIntermediateDirectories: true)

        let definition = ProjectContextFile(
            projectID: "demo",
            projectName: "Demo",
            commands: [
                ProjectCommand(
                    id: "deploy-control-plane",
                    name: "部署控制面",
                    runner: "shell",
                    command: "./deploy.sh",
                    serviceIDs: ["missing-service"]
                ),
            ]
        )

        try OrchardJSON.encoder
            .encode(definition)
            .write(to: orchardDirectory.appendingPathComponent("project-context.json"), options: .atomic)

        XCTAssertThrowsError(
            try ProjectContextResolver.load(workspaceURL: repoURL, localSecretsURL: directory.appendingPathComponent("demo.local.json"))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("command deploy-control-plane"))
            XCTAssertTrue(error.localizedDescription.contains("missing-service"))
        }
    }
}

private func makeProjectContextTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("orchard-project-context-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
