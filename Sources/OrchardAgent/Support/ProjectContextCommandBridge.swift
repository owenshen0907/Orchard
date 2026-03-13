import Foundation
import OrchardCore

actor ProjectContextCommandBridge {
    private let config: ResolvedAgentConfig

    init(config: ResolvedAgentConfig) {
        self.config = config
    }

    func handle(_ request: AgentProjectContextCommandRequest) async -> AgentProjectContextCommandResponse {
        guard let workspace = config.workspaceRoots.first(where: { $0.id == request.workspaceID }) else {
            return AgentProjectContextCommandResponse(
                requestID: request.requestID,
                workspaceID: request.workspaceID,
                available: false,
                errorMessage: "当前设备未配置工作区 \(request.workspaceID)。"
            )
        }

        let workspaceURL = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        guard ProjectContextResolver.locateDefinition(startingAt: workspaceURL) != nil else {
            return AgentProjectContextCommandResponse(
                requestID: request.requestID,
                workspaceID: request.workspaceID,
                available: false
            )
        }

        do {
            switch request.action {
            case .summary:
                return try makeSummaryResponse(request: request, workspace: workspace, workspaceURL: workspaceURL)
            case .lookup:
                return try makeLookupResponse(request: request, workspaceURL: workspaceURL)
            }
        } catch {
            return AgentProjectContextCommandResponse(
                requestID: request.requestID,
                workspaceID: request.workspaceID,
                available: true,
                errorMessage: error.localizedDescription
            )
        }
    }

    private func makeSummaryResponse(
        request: AgentProjectContextCommandRequest,
        workspace: WorkspaceDefinition,
        workspaceURL: URL
    ) throws -> AgentProjectContextCommandResponse {
        let resolved = try ProjectContextResolver.load(workspaceURL: workspaceURL).redactingSensitiveValues()
        return AgentProjectContextCommandResponse(
            requestID: request.requestID,
            workspaceID: request.workspaceID,
            available: true,
            summary: ProjectContextRemoteSummaryRenderer.makeSummary(
                resolved: resolved,
                workspaceID: workspace.id
            )
        )
    }

    private func makeLookupResponse(
        request: AgentProjectContextCommandRequest,
        workspaceURL: URL
    ) throws -> AgentProjectContextCommandResponse {
        guard let subject = request.subject else {
            return AgentProjectContextCommandResponse(
                requestID: request.requestID,
                workspaceID: request.workspaceID,
                available: true,
                errorMessage: "缺少查询 subject。"
            )
        }

        let selector = normalizeSelector(request.selector)
        let options = ProjectContextLookupOptions(
            subject: lookupSubject(from: subject),
            selector: selector,
            workspaceURL: workspaceURL,
            localSecretsURL: nil,
            revealSecrets: false,
            format: .text
        )

        let lookup = try makeLookupResult(subject: subject, options: options)
        return AgentProjectContextCommandResponse(
            requestID: request.requestID,
            workspaceID: request.workspaceID,
            available: true,
            lookup: lookup
        )
    }

    private func lookupSubject(from remoteSubject: ProjectContextRemoteSubject) -> ProjectContextLookupSubject {
        switch remoteSubject {
        case .environment:
            return .environment
        case .host:
            return .host
        case .service:
            return .service
        case .database:
            return .database
        case .command:
            return .command
        case .credential:
            return .credential
        }
    }

    private func makeLookupResult(
        subject: ProjectContextRemoteSubject,
        options: ProjectContextLookupOptions
    ) throws -> ProjectContextRemoteLookupResult {
        switch subject {
        case .environment:
            let result = try ProjectContextResolver.lookupEnvironments(options: options)
            return try renderLookup(subject: subject, selector: options.selector, payload: result)
        case .host:
            let result = try ProjectContextResolver.lookupHosts(options: options)
            return try renderLookup(subject: subject, selector: options.selector, payload: result)
        case .service:
            let result = try ProjectContextResolver.lookupServices(options: options)
            return try renderLookup(subject: subject, selector: options.selector, payload: result)
        case .database:
            let result = try ProjectContextResolver.lookupDatabases(options: options)
            return try renderLookup(subject: subject, selector: options.selector, payload: result)
        case .command:
            let result = try ProjectContextResolver.lookupCommands(options: options)
            return try renderLookup(subject: subject, selector: options.selector, payload: result)
        case .credential:
            let result = try ProjectContextResolver.lookupCredentials(options: options)
            return try renderLookup(subject: subject, selector: options.selector, payload: result)
        }
    }

    private func renderLookup<Payload: Encodable & ProjectContextLookupRenderable>(
        subject: ProjectContextRemoteSubject,
        selector: String?,
        payload: Payload
    ) throws -> ProjectContextRemoteLookupResult {
        let payloadJSON = String(decoding: try OrchardJSON.encoder.encode(payload), as: UTF8.self)
        return ProjectContextRemoteLookupResult(
            subject: subject,
            selector: selector,
            renderedLines: payload.renderedLines,
            payloadJSON: payloadJSON
        )
    }

    private func normalizeSelector(_ selector: String?) -> String? {
        guard let selector else { return nil }
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
