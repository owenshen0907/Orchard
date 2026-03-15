import Foundation
import Network
import OrchardCore

final class AgentStatusHTTPServer: @unchecked Sendable {
    private let options: AgentStatusOptions
    private let statusService: AgentStatusService
    private let localActions: AgentStatusLocalActions?
    private let localCodexActions: AgentStatusLocalCodexActions?
    private let queue = DispatchQueue(label: "orchard.agent.status-http")
    private var listener: NWListener?

    init(
        options: AgentStatusOptions,
        statusService: AgentStatusService = AgentStatusService(),
        localActions: AgentStatusLocalActions? = nil,
        localCodexActions: AgentStatusLocalCodexActions? = nil
    ) {
        self.options = options
        self.statusService = statusService
        self.localActions = localActions
        self.localCodexActions = localCodexActions ?? Self.makeLocalCodexActions(configURL: options.configURL)
    }

    func run() async throws {
        guard let port = NWEndpoint.Port(rawValue: UInt16(options.port)) else {
            throw NSError(domain: "AgentStatusHTTPServer", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "状态页端口无效：\(options.port)",
            ])
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(options.bindHost), port: port)

        let listener = try NWListener(using: parameters)
        self.listener = listener
        defer {
            listener.cancel()
            self.listener = nil
        }

        try await withCheckedThrowingContinuation { continuation in
            let startup = ListenerStartupBox(continuation: continuation)

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    startup.resume()
                case let .failed(error):
                    startup.resume(throwing: error)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            listener.start(queue: queue)
        }

        print("本地状态页已启动：http://\(options.bindHost):\(options.port)")

        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.sendResponse(
                    HTTPResponse.internalServerError(message: error.localizedDescription),
                    on: connection
                )
                return
            }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let expectedLength = HTTPRequest.expectedMessageLength(in: nextBuffer) {
                if nextBuffer.count >= expectedLength || isComplete {
                    self.handleRequestData(nextBuffer.prefix(expectedLength), on: connection)
                    return
                }
            } else if isComplete {
                self.handleRequestData(nextBuffer, on: connection)
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func handleRequestData(_ data: some DataProtocol, on connection: NWConnection) {
        guard let request = HTTPRequest(data: data) else {
            sendResponse(.badRequest(message: "无法解析请求"), on: connection)
            return
        }

        Task {
            let response = await buildResponse(for: request)
            sendResponse(response, on: connection)
        }
    }

    private func buildResponse(for request: HTTPRequest) async -> HTTPResponse {
        switch request.method {
        case "GET":
            return await buildGETResponse(for: request)
        case "POST":
            return await buildPOSTResponse(for: request)
        default:
            return .methodNotAllowed(message: "仅支持 GET / POST")
        }
    }

    private func buildGETResponse(for request: HTTPRequest) async -> HTTPResponse {
        switch request.path {
        case "/":
            return .html(AgentStatusPageRenderer.render(
                options: options,
                localActionEnabled: localActions != nil,
                localCodexActionEnabled: localCodexActions != nil
            ))
        case "/api/status":
            var requestOptions = options
            if let remoteFlag = request.queryValue(named: "remote") {
                requestOptions.includeRemote = remoteFlag != "0" && remoteFlag.lowercased() != "false"
            }
            if let limitValue = request.queryValue(named: "limit"), let limit = Int(limitValue) {
                requestOptions.limit = max(1, limit)
            }

            do {
                let snapshot = try await statusService.snapshot(options: requestOptions)
                let payload = try OrchardJSON.encoder.encode(snapshot)
                return .json(payload)
            } catch {
                let errorPayload = [
                    "error": error.localizedDescription,
                ]
                let payload = (try? JSONSerialization.data(withJSONObject: errorPayload, options: [.prettyPrinted])) ?? Data()
                return HTTPResponse(
                    statusCode: 500,
                    reasonPhrase: "Internal Server Error",
                    contentType: "application/json; charset=utf-8",
                    body: payload
                )
            }
        default:
            break
        }

        let components = request.pathComponents
        if components.count == 3,
           components[0] == "api",
           components[1] == "local-codex-sessions" {
            guard let localCodexActions else {
                return .jsonError("当前状态页还没有接通本机 Codex 会话桥接。", statusCode: 400)
            }
            do {
                let detail = try await localCodexActions.readSession(components[2])
                return .json(try OrchardJSON.encoder.encode(detail))
            } catch {
                return .jsonError(error.localizedDescription, statusCode: 400)
            }
        }

        switch request.path {
        case "/healthz":
            return .plainText("ok")
        default:
            return .notFound(message: "未找到页面")
        }
    }

    private func buildPOSTResponse(for request: HTTPRequest) async -> HTTPResponse {
        let components = request.pathComponents

        do {
            if components.count == 2,
               components[0] == "api",
               components[1] == "local-managed-runs" {
                guard let localActions else {
                    throw NSError(domain: "AgentStatusHTTPServer", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "当前状态页未接入运行中的 OrchardAgent，本机创建能力不可用。",
                    ])
                }
                let created = try await localActions.createManagedRun(request.requiredLocalManagedRunRequest())
                let payload = try OrchardJSON.encoder.encode(LocalActionResponse(
                    ok: true,
                    message: "已在宿主机发起本地任务",
                    taskID: created.id
                ))
                return .json(payload)
            }

            if components.count == 4,
               components[0] == "api",
               components[1] == "local-tasks",
               components[3] == "stop" {
                let taskID = components[2]
                if let localActions {
                    try await localActions.stopTask(taskID)
                    return .jsonMessage("已向宿主机发送停止指令")
                }
                _ = try await makeRemoteClient().stopTask(
                    taskID: taskID,
                    reason: "宿主本地状态页请求停止"
                )
                return .jsonMessage("已发送停止指令")
            }

            if components.count == 4,
               components[0] == "api",
               components[1] == "local-managed-runs" {
                let taskID = components[2]
                guard let localActions else {
                    throw NSError(domain: "AgentStatusHTTPServer", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "当前状态页未接入运行中的 OrchardAgent，本机控制能力不可用。",
                    ])
                }
                switch components[3] {
                case "continue":
                    let prompt = try request.requiredPrompt()
                    try await localActions.continueManagedTask(taskID, prompt)
                    return .jsonMessage("已向宿主机发送继续指令")
                case "interrupt":
                    try await localActions.interruptManagedTask(taskID)
                    return .jsonMessage("已向宿主机发送中断指令")
                case "stop":
                    try await localActions.stopTask(taskID)
                    return .jsonMessage("已向宿主机发送停止指令")
                default:
                    break
                }
            }

            if components.count == 4,
               components[0] == "api",
               components[1] == "managed-runs" {
                let runID = components[2]
                switch components[3] {
                case "continue":
                    let prompt = try request.requiredPrompt()
                    _ = try await makeRemoteClient().continueManagedRun(runID: runID, prompt: prompt)
                    return .jsonMessage("已发送继续指令")
                case "interrupt":
                    _ = try await makeRemoteClient().interruptManagedRun(runID: runID)
                    return .jsonMessage("已发送中断指令")
                case "stop":
                    _ = try await makeRemoteClient().stopManagedRun(
                        runID: runID,
                        reason: "宿主本地状态页请求停止"
                    )
                    return .jsonMessage("已发送停止指令")
                default:
                    break
                }
            }

            if components.count == 5,
               components[0] == "api",
               components[1] == "codex-sessions" {
                let deviceID = components[2]
                let sessionID = components[3]
                switch components[4] {
                case "continue":
                    let prompt = try request.requiredPrompt()
                    _ = try await makeRemoteClient().continueCodexSession(
                        deviceID: deviceID,
                        sessionID: sessionID,
                        prompt: prompt
                    )
                    return .jsonMessage("已发送继续指令")
                case "interrupt":
                    _ = try await makeRemoteClient().interruptCodexSession(
                        deviceID: deviceID,
                        sessionID: sessionID
                    )
                    return .jsonMessage("已发送中断指令")
                default:
                    break
                }
            }

            if components.count == 4,
               components[0] == "api",
               components[1] == "local-codex-sessions" {
                guard let localCodexActions else {
                    throw NSError(domain: "AgentStatusHTTPServer", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "当前状态页未接通本机 Codex 会话桥接。",
                    ])
                }
                let sessionID = components[2]
                switch components[3] {
                case "continue":
                    let prompt = try request.requiredPrompt()
                    let detail = try await localCodexActions.continueSession(sessionID, prompt)
                    return .json(try OrchardJSON.encoder.encode(detail))
                case "interrupt":
                    let detail = try await localCodexActions.interruptSession(sessionID)
                    return .json(try OrchardJSON.encoder.encode(detail))
                default:
                    break
                }
            }

            return .notFound(message: "未找到动作接口")
        } catch {
            return .jsonError(error.localizedDescription, statusCode: 400)
        }
    }

    private struct LocalActionResponse: Encodable {
        let ok: Bool
        let message: String
        let taskID: String?
    }

    private static func makeLocalCodexActions(configURL: URL) -> AgentStatusLocalCodexActions? {
        guard let config = try? AgentConfigLoader.load(from: configURL) else {
            return nil
        }

        return AgentStatusLocalCodexActions(
            readSession: { sessionID in
                try await orchardWithTimeout(seconds: 8) {
                    try await CodexAppServerBridge(config: config).readSession(sessionID: sessionID)
                }
            },
            continueSession: { sessionID, prompt in
                try await orchardWithTimeout(seconds: 8) {
                    try await CodexAppServerBridge(config: config).continueSession(sessionID: sessionID, prompt: prompt)
                }
            },
            interruptSession: { sessionID in
                try await orchardWithTimeout(seconds: 8) {
                    try await CodexAppServerBridge(config: config).interruptSession(sessionID: sessionID)
                }
            }
        )
    }

    private func makeRemoteClient() throws -> OrchardAPIClient {
        guard let accessKey = options.accessKey?.nilIfEmpty else {
            throw NSError(domain: "AgentStatusHTTPServer", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "当前未配置访问密钥，无法执行远程操作。",
            ])
        }
        let config = try AgentConfigLoader.load(from: options.configURL)
        return OrchardAPIClient(baseURL: config.serverURL, accessKey: accessKey)
    }

    private func sendResponse(_ response: HTTPResponse, on connection: NWConnection) {
        let headerLines = [
            "HTTP/1.1 \(response.statusCode) \(response.reasonPhrase)",
            "Content-Type: \(response.contentType)",
            "Cache-Control: no-store",
            "Connection: close",
            "Content-Length: \(response.body.count)",
            "",
            "",
        ]
        var payload = Data(headerLines.joined(separator: "\r\n").utf8)
        payload.append(response.body)

        connection.send(content: payload, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class ListenerStartupBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?

    init(continuation: CheckedContinuation<Void, any Error>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume()
    }

    func resume(throwing error: any Error) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(throwing: error)
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [URLQueryItem]
    let body: Data

    init?(data: some DataProtocol) {
        let buffer = Data(data)
        guard let separatorRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = buffer[..<separatorRange.lowerBound]
        let bodyStart = separatorRange.upperBound
        let bodyData = bodyStart <= buffer.endIndex ? buffer[bodyStart...] : Data()

        guard let rawHeaders = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        guard let requestLine = rawHeaders.components(separatedBy: "\r\n").first else {
            return nil
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return nil
        }

        method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let components = URLComponents(string: "http://localhost\(rawTarget)")
        path = components?.path.nilIfEmpty ?? "/"
        queryItems = components?.queryItems ?? []
        body = Data(bodyData)
    }

    func queryValue(named name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }

    var pathComponents: [String] {
        path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
    }

    func requiredPrompt() throws -> String {
        struct PromptBody: Decodable {
            let prompt: String
        }

        let payload = try JSONDecoder().decode(PromptBody.self, from: body)
        let prompt = payload.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            throw NSError(domain: "AgentStatusHTTPServer", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "继续内容不能为空。",
            ])
        }
        return prompt
    }

    func requiredLocalManagedRunRequest() throws -> AgentLocalManagedRunRequest {
        let payload = try JSONDecoder().decode(AgentLocalManagedRunRequest.self, from: body)
        let workspaceID = payload.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = payload.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let relativePath = payload.relativePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        guard !workspaceID.isEmpty else {
            throw NSError(domain: "AgentStatusHTTPServer", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "工作区不能为空。",
            ])
        }

        guard !prompt.isEmpty else {
            throw NSError(domain: "AgentStatusHTTPServer", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "任务说明不能为空。",
            ])
        }

        return AgentLocalManagedRunRequest(
            title: title,
            workspaceID: workspaceID,
            relativePath: relativePath,
            driver: payload.driver,
            prompt: prompt
        )
    }

    static func expectedMessageLength(in data: Data) -> Int? {
        guard let separatorRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data[..<separatorRange.lowerBound]
        guard let rawHeaders = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let contentLength = rawHeaders
            .components(separatedBy: "\r\n")
            .dropFirst()
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { return nil }
                let name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard name == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
            .first ?? 0

        return separatorRange.upperBound + max(contentLength, 0)
    }
}

private struct HTTPResponse {
    let statusCode: Int
    let reasonPhrase: String
    let contentType: String
    let body: Data

    static func html(_ html: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            contentType: "text/html; charset=utf-8",
            body: Data(html.utf8)
        )
    }

    static func json(_ payload: Data) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            contentType: "application/json; charset=utf-8",
            body: payload
        )
    }

    static func jsonMessage(_ message: String) -> HTTPResponse {
        let payload = (try? JSONSerialization.data(
            withJSONObject: ["ok": true, "message": message],
            options: [.prettyPrinted]
        )) ?? Data()
        return HTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            contentType: "application/json; charset=utf-8",
            body: payload
        )
    }

    static func jsonError(_ message: String, statusCode: Int) -> HTTPResponse {
        let payload = (try? JSONSerialization.data(
            withJSONObject: ["ok": false, "error": message],
            options: [.prettyPrinted]
        )) ?? Data()
        return HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: statusCode == 400 ? "Bad Request" : "Error",
            contentType: "application/json; charset=utf-8",
            body: payload
        )
    }

    static func plainText(_ text: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            reasonPhrase: "OK",
            contentType: "text/plain; charset=utf-8",
            body: Data(text.utf8)
        )
    }

    static func badRequest(message: String) -> HTTPResponse {
        messageResponse(statusCode: 400, reasonPhrase: "Bad Request", message: message)
    }

    static func notFound(message: String) -> HTTPResponse {
        messageResponse(statusCode: 404, reasonPhrase: "Not Found", message: message)
    }

    static func methodNotAllowed(message: String) -> HTTPResponse {
        messageResponse(statusCode: 405, reasonPhrase: "Method Not Allowed", message: message)
    }

    static func internalServerError(message: String) -> HTTPResponse {
        messageResponse(statusCode: 500, reasonPhrase: "Internal Server Error", message: message)
    }

    private static func messageResponse(statusCode: Int, reasonPhrase: String, message: String) -> HTTPResponse {
        let body = """
        <!doctype html>
        <html lang="zh-CN">
          <head>
            <meta charset="utf-8">
            <title>OrchardAgent 状态页</title>
          </head>
          <body>
            <pre>\(escapeHTML(message))</pre>
          </body>
        </html>
        """
        return HTTPResponse(
            statusCode: statusCode,
            reasonPhrase: reasonPhrase,
            contentType: "text/html; charset=utf-8",
            body: Data(body.utf8)
        )
    }
}

enum AgentStatusPageRenderer {
    static func render(
        options: AgentStatusOptions,
        localActionEnabled: Bool = false,
        localCodexActionEnabled: Bool = false
    ) -> String {
        let checked = (options.includeRemote && !localActionEnabled) ? "checked" : ""
        let limitOptions = [5, 8, 12, 20].map { value in
            "<option value=\"\(value)\"\(value == options.limit ? " selected" : "")>\(value)</option>"
        }.joined()
        let remoteActionEnabled = options.accessKey?.nilIfEmpty != nil
        let localActionHint = localActionEnabled
            ? "这就是宿主机真正在跑的控制台：可以直接发任务、补充说明、中断、终止，并实时看本地日志。"
            : "当前页面只接了状态读取，没有接到运行中的 OrchardAgent 实例，所以现在只能观察，不能直接发任务或控制本地任务。"
        let createDriverOptions = renderConversationDriverOptions(
            selected: .codexCLI,
            supportedKinds: [.codexCLI]
        )
        let conversationDriverLabelsJSON = makeConversationDriverLabelsJSON()

        return """
        <!doctype html>
        <html lang="zh-CN">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>OrchardAgent 本地状态页</title>
            <style>
              :root {
                --bg: #eeede8;
                --panel: rgba(255, 255, 255, 0.82);
                --panel-strong: #fbfaf7;
                --ink: #0f172a;
                --muted: #667085;
                --line: rgba(15, 23, 42, 0.08);
                --accent: #0f766e;
                --accent-strong: #115e59;
                --accent-soft: rgba(15, 118, 110, 0.10);
                --warn: #b45309;
                --danger: #b91c1c;
                --shadow: 0 18px 48px rgba(15, 23, 42, 0.10);
                --code-bg: #111827;
              }

              * { box-sizing: border-box; }

              body {
                margin: 0;
                min-height: 100vh;
                font-family: "PingFang SC", "Noto Sans SC", "Helvetica Neue", sans-serif;
                color: var(--ink);
                background:
                  radial-gradient(circle at top left, rgba(15, 118, 110, 0.16), transparent 24%),
                  radial-gradient(circle at right 12%, rgba(59, 130, 246, 0.10), transparent 18%),
                  linear-gradient(180deg, #f7f7f4 0%, #ecebe6 100%);
              }

              @keyframes project-running-pulse {
                0% {
                  box-shadow: 0 0 0 0 rgba(15, 118, 110, 0.34);
                  transform: scale(0.92);
                }

                70% {
                  box-shadow: 0 0 0 10px rgba(15, 118, 110, 0);
                  transform: scale(1.02);
                }

                100% {
                  box-shadow: 0 0 0 0 rgba(15, 118, 110, 0);
                  transform: scale(0.92);
                }
              }

              button,
              input,
              textarea,
              select {
                font: inherit;
              }

              button {
                border: 0;
                border-radius: 16px;
                padding: 12px 16px;
                background: var(--accent);
                color: #fff;
                cursor: pointer;
                font-weight: 700;
              }

              button.secondary {
                background: rgba(15, 118, 110, 0.10);
                color: var(--accent-strong);
              }

              button[disabled] {
                opacity: 0.5;
                cursor: not-allowed;
              }

              .app-shell {
                width: min(1720px, calc(100vw - 24px));
                min-height: calc(100vh - 24px);
                height: auto;
                margin: 12px auto 24px;
                display: grid;
                grid-template-columns: 440px minmax(0, 1fr);
                gap: 16px;
                align-items: start;
              }

              .sidebar {
                position: static;
                top: auto;
                height: auto;
                align-self: start;
                display: grid;
                gap: 14px;
                grid-template-rows: auto auto;
              }

              .sidebar-panel,
              .workspace-panel,
              .panel {
                background: var(--panel);
                backdrop-filter: blur(18px);
                border: 1px solid var(--line);
                border-radius: 26px;
                box-shadow: var(--shadow);
              }

              .brand-card {
                position: relative;
                overflow: hidden;
                padding: 16px 18px 14px;
                color: #f8fafc;
                background: linear-gradient(180deg, #0f172a 0%, #172033 100%);
              }

              .brand-card::after {
                content: "";
                position: absolute;
                right: -48px;
                bottom: -84px;
                width: 180px;
                height: 180px;
                border-radius: 999px;
                background: radial-gradient(circle, rgba(20, 184, 166, 0.34), transparent 68%);
              }

              .eyebrow {
                font-size: 11px;
                letter-spacing: 0.18em;
                text-transform: uppercase;
                opacity: 0.74;
                margin-bottom: 8px;
              }

              .brand-card h1 {
                margin: 0;
                font-size: 23px;
                line-height: 1.1;
              }

              body.modal-open {
                overflow: hidden;
              }

              .overlay {
                position: fixed;
                inset: 0;
                display: none;
                align-items: center;
                justify-content: center;
                padding: 18px;
                background: rgba(15, 23, 42, 0.48);
                backdrop-filter: blur(8px);
                z-index: 80;
              }

              .overlay.open {
                display: flex;
              }

              .overlay-card {
                width: min(760px, calc(100vw - 36px));
                max-height: calc(100vh - 36px);
                background: rgba(252, 251, 248, 0.98);
                border: 1px solid rgba(255, 255, 255, 0.5);
                border-radius: 28px;
                box-shadow: 0 28px 90px rgba(15, 23, 42, 0.28);
                display: grid;
                grid-template-rows: auto minmax(0, 1fr);
                overflow: hidden;
              }

              .overlay-card.wide {
                width: min(1280px, calc(100vw - 36px));
              }

              .overlay-head {
                display: flex;
                align-items: flex-start;
                justify-content: space-between;
                gap: 14px;
                padding: 22px 22px 18px;
                border-bottom: 1px solid var(--line);
              }

              .overlay-head h2 {
                margin: 0;
                font-size: 22px;
                line-height: 1.2;
              }

              .overlay-body {
                min-height: 0;
                overflow: auto;
                padding: 20px 22px 22px;
                display: grid;
                gap: 16px;
              }

              .overlay-close {
                flex-shrink: 0;
              }

              .sidebar-section {
                padding: 18px;
                overflow: visible;
              }

              .sidebar-scroll {
                min-height: auto;
                display: grid;
                gap: 14px;
              }

              .sidebar-list-panel {
                display: grid;
                gap: 12px;
              }

              .project-sidebar {
                display: grid;
                gap: 12px;
              }

              .project-sidebar-empty {
                display: grid;
                gap: 6px;
                padding: 14px;
                border-radius: 20px;
                background: rgba(15, 118, 110, 0.06);
                color: var(--muted);
                line-height: 1.6;
              }

              .project-tree-list {
                display: grid;
                gap: 10px;
              }

              .project-tree {
                border: 1px solid rgba(15, 23, 42, 0.07);
                border-radius: 22px;
                background: rgba(255, 255, 255, 0.74);
                overflow: hidden;
              }

              .project-tree.selected {
                border-color: rgba(15, 118, 110, 0.24);
                box-shadow: inset 0 0 0 1px rgba(15, 118, 110, 0.06);
              }

              .project-tree.open {
                background: rgba(255, 255, 255, 0.88);
              }

              .project-tree-head {
                display: grid;
                grid-template-columns: minmax(0, 1fr) auto;
                gap: 10px;
                padding: 10px;
              }

              .project-tree-toggle {
                width: 100%;
                display: flex;
                align-items: center;
                justify-content: space-between;
                gap: 12px;
                padding: 12px 14px;
                border-radius: 18px;
                border: 1px solid rgba(15, 23, 42, 0.06);
                background: rgba(15, 23, 42, 0.03);
                color: var(--ink);
                text-align: left;
              }

              .project-tree-toggle::after {
                content: "›";
                font-size: 20px;
                font-weight: 800;
                color: var(--muted);
                line-height: 1;
                transition: transform 0.16s ease;
              }

              .project-tree.open .project-tree-toggle::after {
                transform: rotate(90deg);
              }

              .project-tree-main {
                width: 100%;
                display: flex;
                align-items: center;
                justify-content: space-between;
                gap: 10px;
                min-width: 0;
              }

              .project-tree-title {
                font-size: 15px;
                font-weight: 800;
                line-height: 1.3;
                color: var(--ink);
                min-width: 0;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
              }

              .project-tree-status {
                flex-shrink: 0;
                display: inline-flex;
                align-items: center;
                gap: 8px;
                padding: 6px 8px;
                border-radius: 999px;
                background: rgba(15, 23, 42, 0.06);
                color: var(--muted);
                font-size: 11px;
                font-weight: 700;
                line-height: 1;
              }

              .project-tree-status.running {
                background: rgba(15, 118, 110, 0.12);
                color: var(--accent-strong);
              }

              .project-tree-status.waiting {
                background: rgba(180, 83, 9, 0.12);
                color: var(--warn);
              }

              .project-running-indicator {
                width: 9px;
                height: 9px;
                border-radius: 999px;
                background: var(--accent);
                animation: project-running-pulse 1.4s ease-out infinite;
              }

              .project-tree-actions {
                display: flex;
                flex-wrap: nowrap;
                justify-content: flex-end;
                gap: 6px;
              }

              .project-tree-path {
                font-size: 12px;
                color: var(--muted);
                line-height: 1.45;
                word-break: break-all;
              }

              .project-tree-detail-panel {
                display: grid;
                gap: 10px;
                margin: 0 10px 10px;
                padding: 12px 14px;
                border-radius: 18px;
                border: 1px solid rgba(15, 23, 42, 0.06);
                background: rgba(15, 23, 42, 0.04);
              }

              .project-tree-detail-copy {
                display: grid;
                gap: 6px;
              }

              .project-tree-detail-label {
                font-size: 11px;
                font-weight: 700;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: var(--muted);
              }

              .project-tree-detail-pills {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .project-tree-detail-pills span {
                padding: 5px 8px;
                border-radius: 999px;
                background: rgba(255, 255, 255, 0.88);
                color: var(--muted);
                font-size: 11px;
                font-weight: 700;
              }

              .project-tree-detail,
              .project-tree-add {
                width: 38px;
                height: 38px;
                padding: 0;
                border-radius: 14px;
                display: inline-flex;
                align-items: center;
                justify-content: center;
              }

              .project-action-button {
                flex-shrink: 0;
              }

              .project-action-button[disabled] {
                opacity: 0.38;
              }

              .project-action-icon {
                display: inline-flex;
                align-items: center;
                justify-content: center;
                width: 18px;
                height: 18px;
                font-size: 16px;
                font-weight: 800;
                line-height: 1;
              }

              .project-action-button.is-open {
                background: rgba(15, 118, 110, 0.16);
                color: var(--accent-strong);
              }

              .project-task-list {
                display: grid;
                gap: 8px;
                padding: 0 10px 10px;
              }

              .project-task-empty {
                padding: 12px 14px;
                border-radius: 16px;
                background: rgba(15, 118, 110, 0.06);
                color: var(--muted);
                font-size: 13px;
                line-height: 1.55;
              }

              .project-task-row {
                width: 100%;
                display: flex;
                align-items: center;
                justify-content: space-between;
                gap: 12px;
                padding: 10px 12px;
                border-radius: 14px;
                background: rgba(15, 23, 42, 0.04);
                color: var(--ink);
                text-align: left;
              }

              .project-task-row:hover {
                transform: translateY(-1px);
                box-shadow: 0 8px 18px rgba(15, 23, 42, 0.06);
              }

              .project-task-row.selected {
                background: rgba(15, 118, 110, 0.10);
                color: var(--accent-strong);
              }

              .project-task-row.selected .project-task-meta {
                color: var(--accent-strong);
              }

              .project-task-main {
                display: flex;
                align-items: center;
                gap: 10px;
                min-width: 0;
              }

              .project-task-title {
                font-size: 14px;
                font-weight: 700;
                line-height: 1.35;
                overflow: hidden;
                text-overflow: ellipsis;
                white-space: nowrap;
              }

              .project-task-meta {
                flex-shrink: 0;
                font-size: 12px;
                color: var(--muted);
                white-space: nowrap;
              }

              .project-task-row .status-dot {
                width: 8px;
                height: 8px;
                box-shadow: none;
                flex-shrink: 0;
              }

              #local-tasks,
              #local-tasks-modal {
                min-height: auto;
                padding-right: 4px;
              }

              #local-tasks {
                overflow: visible;
              }

              #local-tasks-modal {
                overflow: auto;
              }

              #local-tasks-modal .conversation-list-shell {
                gap: 16px;
              }

              #local-tasks-modal .item-list {
                grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
                gap: 14px;
              }

              #local-tasks-modal .item {
                min-height: 214px;
                padding: 14px 15px;
              }

              .workspace {
                min-width: 0;
                display: grid;
                gap: 16px;
                min-height: auto;
                align-content: start;
                grid-template-rows: auto auto auto;
              }

              .topbar {
                padding: 14px 16px;
                display: flex;
                justify-content: space-between;
                gap: 14px;
                align-items: center;
              }

              .topbar-controls {
                display: flex;
                flex-wrap: wrap;
                gap: 10px;
                align-items: center;
              }

              .topbar-right {
                display: flex;
                align-items: center;
                justify-content: flex-end;
                gap: 12px;
                margin-left: auto;
                min-width: 0;
              }

              .topbar-quick-action {
                flex-shrink: 0;
                padding-inline: 14px;
              }

              .toggle {
                display: inline-flex;
                align-items: center;
                gap: 8px;
                color: var(--muted);
                font-size: 14px;
              }

              .toggle input {
                width: 18px;
                height: 18px;
                accent-color: var(--accent);
              }

              .toggle select {
                min-width: 92px;
              }

              .stamp {
                font-size: 13px;
                color: var(--muted);
                text-align: right;
              }

              .start-here-panel {
                padding: 18px 20px;
                display: grid;
                gap: 14px;
              }

              .start-here-top {
                display: flex;
                flex-wrap: wrap;
                align-items: flex-start;
                justify-content: space-between;
                gap: 12px;
              }

              .start-here-top h2 {
                margin: 0;
                font-size: 24px;
                line-height: 1.15;
              }

              .start-here-top p {
                margin: 6px 0 0;
                color: var(--muted);
                line-height: 1.62;
                font-size: 14px;
              }

              .start-here-chips {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .start-here-chips span {
                padding: 7px 10px;
                border-radius: 999px;
                background: rgba(15, 118, 110, 0.08);
                color: var(--accent-strong);
                font-size: 12px;
                font-weight: 700;
              }

              .advanced-section {
                overflow: hidden;
              }

              .advanced-section summary {
                list-style: none;
                cursor: pointer;
                padding: 18px 20px;
                font-weight: 800;
              }

              .advanced-section summary::-webkit-details-marker {
                display: none;
              }

              .advanced-section summary::after {
                content: "展开";
                float: right;
                color: var(--muted);
                font-size: 13px;
                font-weight: 700;
              }

              .advanced-section[open] summary::after {
                content: "收起";
              }

              .advanced-body {
                padding: 0 18px 18px;
                display: grid;
                gap: 16px;
              }

              .advanced-controls {
                display: flex;
                flex-wrap: wrap;
                gap: 10px 14px;
                align-items: center;
                padding: 14px 16px;
                border-radius: 18px;
                background: rgba(15, 23, 42, 0.04);
              }

              .split-head {
                display: flex;
                align-items: flex-start;
                justify-content: space-between;
                gap: 10px;
                margin-bottom: 12px;
              }

              .panel-tag {
                flex-shrink: 0;
                padding: 6px 10px;
                border-radius: 999px;
                background: var(--accent-soft);
                color: var(--accent-strong);
                font-size: 12px;
                font-weight: 700;
              }

              .panel h2,
              .sidebar-section h2,
              .stage-head h2 {
                margin: 0;
                font-size: 18px;
                line-height: 1.25;
              }

              .panel-subtitle {
                margin-top: 6px;
                color: var(--muted);
                line-height: 1.58;
                font-size: 14px;
                display: -webkit-box;
                -webkit-line-clamp: 2;
                -webkit-box-orient: vertical;
                overflow: hidden;
              }

              .form-grid {
                display: grid;
                gap: 12px;
              }

              .field {
                display: grid;
                gap: 8px;
              }

              .field-wide {
                grid-column: 1 / -1;
              }

              .field span {
                font-size: 12px;
                color: var(--muted);
              }

              input,
              textarea,
              select {
                width: 100%;
                padding: 12px 14px;
                border-radius: 16px;
                border: 1px solid var(--line);
                background: #fcfbf8;
                color: var(--ink);
              }

              textarea {
                min-height: 118px;
                resize: vertical;
              }

              fieldset {
                margin: 0;
                padding: 0;
                border: 0;
                min-width: 0;
              }

              .form-actions {
                display: grid;
                gap: 10px;
              }

              .form-actions button {
                width: 100%;
              }

              .hint {
                font-size: 13px;
                color: var(--muted);
                line-height: 1.58;
              }

              .stage-card {
                min-height: 0;
                display: grid;
                grid-template-rows: minmax(0, 1fr);
                overflow: visible;
              }

              .stage-head {
                display: none;
              }

              .stage-head-row {
                display: flex;
                flex-wrap: wrap;
                align-items: flex-start;
                justify-content: space-between;
                gap: 12px 14px;
              }

              .stage-head-copy {
                display: grid;
                gap: 6px;
                min-width: 0;
              }

              .stage-head-copy h2 {
                margin: 0;
                font-size: 18px;
                line-height: 1.25;
                display: -webkit-box;
                -webkit-line-clamp: 2;
                -webkit-box-orient: vertical;
                overflow: hidden;
              }

              .stage-head-meta {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .stage-head-meta span {
                padding: 5px 9px;
                border-radius: 999px;
                background: rgba(15, 23, 42, 0.05);
                color: var(--muted);
                font-size: 12px;
              }

              #local-task-detail {
                min-height: 0;
                height: auto;
                padding: 20px;
                display: flex;
                flex-direction: column;
                overflow: visible;
              }

              .task-dialog-shell,
              .task-dialog-flow,
              .task-dialog-composer,
              .task-dialog-empty {
                display: grid;
                gap: 12px;
              }

              .task-dialog-shell {
                flex: none;
                min-height: 0;
                display: flex;
                flex-direction: column;
                gap: 14px;
              }

              .task-dialog-shell.three-panel {
                display: grid;
                grid-template-rows: auto auto auto;
                gap: 14px;
                overflow: visible;
              }

              .task-dialog-shell.three-panel > .dialog-section {
                min-height: auto;
              }

              .dialog-section {
                display: grid;
                gap: 12px;
                padding: 16px;
                border-radius: 22px;
                border: 1px solid var(--line);
                background: rgba(255, 255, 255, 0.82);
              }

              .dialog-section.compact {
                gap: 10px;
                padding: 14px;
              }

              .dialog-section.fill {
                flex: none;
                min-height: auto;
                overflow: hidden;
              }

              .dialog-section.fill .dialog-section-body {
                flex: none;
                min-height: 0;
                overflow: hidden;
              }

              .dialog-section-head {
                display: flex;
                flex-wrap: wrap;
                align-items: flex-start;
                justify-content: space-between;
                gap: 10px 12px;
              }

              .dialog-section-copy {
                display: grid;
                gap: 6px;
              }

              .section-marker {
                font-size: 12px;
                font-weight: 800;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: var(--accent-strong);
              }

              .section-copy {
                color: var(--muted);
                line-height: 1.58;
                font-size: 14px;
              }

              .dialog-section-body {
                display: flex;
                flex-direction: column;
                gap: 12px;
              }

              .task-dialog-empty {
                flex: 1;
                min-height: 0;
                align-content: center;
                padding: 16px;
                border-radius: 20px;
                background: rgba(15, 118, 110, 0.06);
                color: var(--muted);
                line-height: 1.7;
              }

              .task-dialog-head {
                display: flex;
                flex-wrap: wrap;
                justify-content: space-between;
                align-items: flex-start;
                gap: 10px 12px;
              }

              .task-dialog-title {
                margin: 0;
                font-size: 22px;
                line-height: 1.2;
              }

              .task-dialog-subtitle {
                margin-top: 8px;
                color: var(--muted);
                line-height: 1.6;
                font-size: 14px;
              }

              .task-dialog-timeline {
                flex: none;
                min-height: auto;
                height: clamp(420px, 56vh, 640px);
                max-height: clamp(420px, 56vh, 640px);
                overflow: auto;
                display: grid;
                align-content: end;
                gap: 12px;
                padding-right: 6px;
                overscroll-behavior: contain;
                scrollbar-gutter: stable;
                scroll-padding-bottom: 8px;
              }

              .progress-feed {
                display: grid;
                gap: 10px;
                align-content: start;
              }

              .progress-entry {
                border: 1px solid var(--line);
                border-radius: 18px;
                background: rgba(255, 255, 255, 0.96);
                overflow: hidden;
              }

              .progress-entry.pending {
                border-style: dashed;
                background: rgba(15, 118, 110, 0.06);
              }

              .progress-entry.command {
                background: rgba(15, 23, 42, 0.96);
                border-color: rgba(15, 23, 42, 0.96);
                color: #f8fafc;
              }

              .progress-entry.reasoning {
                background: rgba(59, 130, 246, 0.06);
                border-color: rgba(59, 130, 246, 0.14);
              }

              .progress-entry.file {
                background: rgba(15, 118, 110, 0.06);
                border-color: rgba(15, 118, 110, 0.14);
              }

              .progress-entry.warn {
                background: rgba(180, 83, 9, 0.08);
                border-color: rgba(180, 83, 9, 0.16);
              }

              .progress-entry summary {
                list-style: none;
                cursor: pointer;
                display: grid;
                grid-template-columns: auto minmax(0, 1fr) auto;
                gap: 10px;
                align-items: start;
                padding: 12px 14px;
              }

              .progress-entry summary::-webkit-details-marker {
                display: none;
              }

              .progress-entry[open] summary {
                border-bottom: 1px solid var(--line);
              }

              .progress-entry.command[open] summary {
                border-bottom-color: rgba(255, 255, 255, 0.12);
              }

              .progress-kind {
                padding: 5px 8px;
                border-radius: 999px;
                background: rgba(15, 118, 110, 0.10);
                color: var(--accent-strong);
                font-size: 11px;
                font-weight: 800;
                white-space: nowrap;
              }

              .progress-entry.command .progress-kind {
                background: rgba(255, 255, 255, 0.10);
                color: rgba(248, 250, 252, 0.92);
              }

              .progress-summary {
                min-width: 0;
                display: grid;
                gap: 4px;
              }

              .progress-title {
                font-size: 14px;
                font-weight: 700;
                line-height: 1.45;
                color: var(--ink);
                word-break: break-word;
              }

              .progress-entry.command .progress-title {
                color: rgba(248, 250, 252, 0.94);
              }

              .progress-subtitle {
                font-size: 12px;
                color: var(--muted);
                line-height: 1.45;
              }

              .progress-entry.command .progress-subtitle {
                color: rgba(248, 250, 252, 0.72);
              }

              .progress-state {
                font-size: 12px;
                color: var(--muted);
                white-space: nowrap;
              }

              .progress-entry.command .progress-state {
                color: rgba(248, 250, 252, 0.72);
              }

              .progress-body {
                display: grid;
                gap: 10px;
                padding: 12px 14px 14px;
              }

              .progress-body-copy {
                margin: 0;
                font-size: 13px;
                line-height: 1.7;
                color: var(--muted);
                white-space: pre-wrap;
                word-break: break-word;
              }

              .progress-entry.command .progress-body-copy {
                color: rgba(248, 250, 252, 0.84);
              }

              .timeline-strip {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .timeline-chip {
                display: inline-flex;
                align-items: center;
                gap: 6px;
                padding: 7px 10px;
                border-radius: 999px;
                background: rgba(15, 23, 42, 0.06);
                color: var(--muted);
                font-size: 12px;
                font-weight: 700;
              }

              .timeline-chip.active {
                background: rgba(15, 118, 110, 0.10);
                color: var(--accent-strong);
              }

              .timeline-chip.warn {
                background: rgba(180, 83, 9, 0.12);
                color: var(--warn);
              }

              .conversation-route {
                display: grid;
                gap: 10px;
                padding: 14px 16px;
                border-radius: 20px;
                border: 1px solid rgba(15, 118, 110, 0.16);
                background: linear-gradient(180deg, rgba(240, 253, 250, 0.96), rgba(255, 255, 255, 0.94));
              }

              .conversation-route-kicker {
                font-size: 12px;
                font-weight: 800;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: var(--accent-strong);
              }

              .conversation-route-headline {
                font-size: 15px;
                font-weight: 800;
                line-height: 1.56;
                word-break: break-word;
              }

              .conversation-route-subline {
                color: var(--muted);
                line-height: 1.65;
                font-size: 14px;
                word-break: break-word;
              }

              .conversation-route-pills {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .conversation-route-pills span {
                padding: 6px 10px;
                border-radius: 999px;
                background: rgba(15, 23, 42, 0.05);
                color: var(--muted);
                font-size: 12px;
                font-weight: 700;
              }

              .chat-bubble {
                display: grid;
                gap: 8px;
                width: min(92%, 920px);
                padding: 14px 16px;
                border-radius: 22px;
                border: 1px solid var(--line);
                background: #fff;
                box-shadow: 0 10px 24px rgba(15, 23, 42, 0.04);
              }

              .chat-bubble.user {
                margin-left: auto;
                background: rgba(15, 118, 110, 0.10);
                border-color: rgba(15, 118, 110, 0.18);
              }

              .chat-bubble.system {
                background: #f4f7f6;
              }

              .chat-bubble.warn {
                background: rgba(180, 83, 9, 0.08);
                border-color: rgba(180, 83, 9, 0.18);
              }

              .chat-bubble.command {
                background: rgba(15, 23, 42, 0.96);
                border-color: rgba(15, 23, 42, 0.96);
                color: #f8fafc;
              }

              .chat-bubble.command .chat-label,
              .chat-bubble.command .chat-body {
                color: rgba(248, 250, 252, 0.92);
              }

              .chat-bubble.file {
                background: rgba(15, 118, 110, 0.08);
                border-color: rgba(15, 118, 110, 0.18);
              }

              .chat-bubble.reasoning {
                background: rgba(59, 130, 246, 0.08);
                border-color: rgba(59, 130, 246, 0.16);
              }

              .chat-bubble.pending {
                border-style: dashed;
                background: rgba(15, 118, 110, 0.06);
              }

              .chat-label {
                font-size: 12px;
                font-weight: 700;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: var(--muted);
              }

              .chat-body {
                color: var(--ink);
                line-height: 1.75;
                font-size: 15px;
                white-space: pre-wrap;
                word-break: break-word;
              }

              .execution-event {
                display: grid;
                gap: 10px;
                width: min(96%, 980px);
                padding: 15px 16px;
                border-radius: 20px;
                border: 1px solid var(--line);
                background: rgba(255, 255, 255, 0.94);
                box-shadow: 0 10px 24px rgba(15, 23, 42, 0.04);
              }

              .execution-event.command {
                background: rgba(15, 23, 42, 0.96);
                border-color: rgba(15, 23, 42, 0.96);
                color: #f8fafc;
              }

              .execution-event.file {
                background: rgba(15, 118, 110, 0.08);
                border-color: rgba(15, 118, 110, 0.16);
              }

              .execution-event.reasoning {
                background: rgba(59, 130, 246, 0.08);
                border-color: rgba(59, 130, 246, 0.16);
              }

              .execution-event.other {
                background: rgba(244, 247, 246, 0.96);
              }

              .execution-event-head {
                display: flex;
                flex-wrap: wrap;
                justify-content: space-between;
                align-items: center;
                gap: 8px 12px;
              }

              .execution-event-kicker {
                font-size: 12px;
                font-weight: 800;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: var(--muted);
              }

              .execution-event.command .execution-event-kicker,
              .execution-event.command .execution-event-body,
              .execution-event.command .execution-event-title,
              .execution-event.command .execution-event-status {
                color: rgba(248, 250, 252, 0.92);
              }

              .execution-event-status {
                font-size: 12px;
                font-weight: 700;
                color: var(--muted);
              }

              .execution-event-title {
                font-size: 14px;
                font-weight: 700;
                line-height: 1.55;
                word-break: break-word;
              }

              .execution-event-body {
                color: var(--ink);
                line-height: 1.72;
                font-size: 14px;
                white-space: pre-wrap;
                word-break: break-word;
              }

              .execution-console-card {
                display: grid;
                gap: 10px;
                width: min(96%, 980px);
                padding: 15px 16px;
                border-radius: 20px;
                border: 1px solid rgba(15, 23, 42, 0.96);
                background: rgba(15, 23, 42, 0.96);
                color: #f8fafc;
                box-shadow: 0 10px 24px rgba(15, 23, 42, 0.08);
              }

              .execution-console-head {
                display: flex;
                flex-wrap: wrap;
                justify-content: space-between;
                align-items: center;
                gap: 8px 12px;
              }

              .execution-console-head strong {
                font-size: 14px;
              }

              .execution-console-head span {
                font-size: 12px;
                color: rgba(248, 250, 252, 0.74);
              }

              .execution-console-meta {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .execution-console-meta span {
                padding: 6px 10px;
                border-radius: 999px;
                background: rgba(255, 255, 255, 0.10);
                color: rgba(248, 250, 252, 0.84);
                font-size: 12px;
                font-weight: 700;
              }

              .terminal-box {
                margin: 0;
                padding: 14px;
                border-radius: 18px;
                background: var(--code-bg);
                color: #edf2f7;
                font: 500 12px/1.6 ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
                white-space: pre-wrap;
                word-break: break-word;
                max-height: 320px;
                overflow: auto;
              }

              .execution-console-card .terminal-box,
              .execution-event.command .terminal-box {
                max-height: 220px;
              }

              .task-launcher-shell {
                display: grid;
                gap: 14px;
              }

              .task-launcher-copy {
                display: grid;
                gap: 6px;
              }

              .task-launcher-copy h3 {
                margin: 0;
                font-size: 18px;
                line-height: 1.25;
              }

              .task-launcher-copy p {
                margin: 0;
                color: var(--muted);
                font-size: 14px;
                line-height: 1.6;
              }

              .task-launcher-actions {
                display: flex;
                flex-wrap: wrap;
                gap: 10px;
              }

              .task-launcher-grid {
                display: grid;
                gap: 12px;
              }

              .task-launcher-section {
                display: grid;
                gap: 10px;
              }

              .task-launcher-label {
                font-size: 12px;
                font-weight: 800;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: var(--muted);
              }

              .task-launcher-section .item-list {
                gap: 12px;
              }

              .task-launcher-hint {
                padding: 12px 14px;
                border-radius: 18px;
                background: rgba(15, 118, 110, 0.06);
                color: var(--muted);
                font-size: 13px;
                line-height: 1.6;
              }

              .task-dialog-card {
                padding: 14px 16px;
                border-radius: 18px;
                border: 1px solid var(--line);
                background: #fbfbf8;
              }

              .task-dialog-card h3 {
                margin: 0 0 8px;
                font-size: 15px;
              }

              .task-dialog-card p {
                margin: 0;
                color: var(--muted);
                line-height: 1.58;
                font-size: 14px;
              }

              .task-dialog-toolbar {
                display: flex;
                flex-wrap: wrap;
                align-items: center;
                justify-content: space-between;
                gap: 12px 14px;
                padding: 12px 14px;
                border-radius: 18px;
                border: 1px solid var(--line);
                background: rgba(15, 118, 110, 0.06);
              }

              .task-dialog-toolbar-copy {
                display: grid;
                gap: 4px;
              }

              .task-dialog-toolbar-copy strong {
                font-size: 14px;
              }

              .task-dialog-toolbar-copy span {
                color: var(--muted);
                line-height: 1.58;
                font-size: 13px;
              }

              .task-dialog-toolbar-actions {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .task-dialog-composer {
                gap: 12px;
              }

              .task-dialog-composer.compact {
                display: grid;
                gap: 10px;
              }

              .composer-inline {
                display: grid;
                grid-template-columns: auto minmax(0, 1fr) auto;
                gap: 10px;
                align-items: center;
              }

              .composer-actions {
                display: inline-flex;
                gap: 8px;
                align-items: center;
              }

              .composer-actions button {
                min-width: 96px;
              }

              .composer-kicker {
                display: inline-flex;
                align-items: center;
                padding: 0 10px;
                height: 44px;
                border-radius: 999px;
                background: rgba(15, 118, 110, 0.10);
                color: var(--accent-strong);
                font-size: 12px;
                font-weight: 800;
                letter-spacing: 0.06em;
                text-transform: uppercase;
                white-space: nowrap;
              }

              .composer-inline input,
              .composer-inline textarea {
                min-width: 0;
                padding: 14px 16px;
                border-radius: 18px;
              }

              .composer-inline textarea {
                min-height: 104px;
                line-height: 1.58;
              }

              .composer-inline-create {
                grid-template-columns: minmax(0, 1fr) auto;
                align-items: end;
              }

              .composer-inline-create .composer-kicker {
                grid-column: 1 / -1;
                justify-self: start;
              }

              .composer-inline button {
                width: auto;
                min-width: 108px;
                border-radius: 18px;
              }

              .task-meta-details {
                border: 1px solid rgba(15, 23, 42, 0.08);
                border-radius: 18px;
                background: #fbfbf8;
                overflow: hidden;
              }

              .task-meta-details summary {
                cursor: pointer;
                list-style: none;
                padding: 12px 14px;
                font-weight: 700;
                color: var(--ink);
              }

              .task-meta-details summary::-webkit-details-marker {
                display: none;
              }

              .task-meta-details[open] summary {
                border-bottom: 1px solid var(--line);
              }

              .task-meta-details .meta {
                margin: 0;
                padding: 14px;
              }

              .task-meta-details .meta span {
                background: #fff;
              }

              .task-start-shell,
              .task-start-hero,
              .task-start-form,
              .task-start-grid,
              .task-start-status {
                display: grid;
                gap: 12px;
              }

              .task-start-shell {
                max-width: 920px;
                margin: 0 auto;
                align-content: center;
                min-height: 100%;
              }

              .task-start-hero {
                padding: 18px 20px;
                border-radius: 24px;
                background: linear-gradient(135deg, rgba(15, 23, 42, 0.96), rgba(15, 118, 110, 0.88));
                color: #f8fafc;
                box-shadow: 0 16px 36px rgba(15, 23, 42, 0.18);
              }

              .task-start-hero h3 {
                margin: 0;
                font-size: 28px;
                line-height: 1.12;
              }

              .task-start-hero p {
                margin: 0;
                color: rgba(248, 250, 252, 0.84);
                line-height: 1.68;
              }

              .task-start-chip-row {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .task-start-chip {
                padding: 7px 10px;
                border-radius: 999px;
                background: rgba(255, 255, 255, 0.12);
                border: 1px solid rgba(255, 255, 255, 0.12);
                font-size: 12px;
                color: rgba(248, 250, 252, 0.92);
              }

              .task-start-form {
                padding: 18px;
                border-radius: 24px;
                background: rgba(255, 255, 255, 0.82);
                border: 1px solid var(--line);
              }

              .task-start-grid {
                grid-template-columns: repeat(2, minmax(0, 1fr));
              }

              .task-start-form .field-wide {
                grid-column: 1 / -1;
              }

              .task-start-status[hidden] {
                display: none;
              }

              .session-toolbar {
                display: grid;
                gap: 10px;
                margin-bottom: 14px;
              }

              .session-toolbar input {
                background: rgba(252, 251, 248, 0.92);
              }

              .session-filter-row {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .session-filter {
                padding: 8px 12px;
                border-radius: 999px;
                background: rgba(15, 23, 42, 0.06);
                color: var(--muted);
                font-size: 12px;
                font-weight: 700;
              }

              .session-filter.active {
                background: var(--accent);
                color: #fff;
              }

              .section-stack {
                display: grid;
                gap: 14px;
              }

              .section-caption {
                font-size: 12px;
                font-weight: 700;
                letter-spacing: 0.12em;
                text-transform: uppercase;
                color: var(--muted);
              }

              .conversation-list-shell {
                display: grid;
                gap: 12px;
              }

              .project-group {
                display: grid;
                gap: 10px;
                padding: 12px;
                border-radius: 22px;
                background: rgba(255, 255, 255, 0.52);
                border: 1px solid rgba(15, 23, 42, 0.06);
              }

              .project-group-head {
                display: flex;
                flex-wrap: wrap;
                justify-content: space-between;
                gap: 10px 14px;
                align-items: flex-start;
              }

              .project-group-copy {
                display: grid;
                gap: 4px;
                min-width: 0;
              }

              .project-group-title {
                font-size: 15px;
                font-weight: 700;
                color: var(--ink);
              }

              .project-group-subline {
                font-size: 12px;
                color: var(--muted);
                line-height: 1.5;
                word-break: break-all;
              }

              .project-group-pills {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
                justify-content: flex-end;
              }

              .project-group-pills span {
                padding: 6px 10px;
                border-radius: 999px;
                background: rgba(15, 23, 42, 0.05);
                color: var(--muted);
                font-size: 12px;
                font-weight: 700;
              }

              .list-summary-bar {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
              }

              .list-summary-pill {
                display: inline-flex;
                align-items: center;
                gap: 6px;
                padding: 7px 10px;
                border-radius: 999px;
                background: rgba(15, 23, 42, 0.06);
                color: var(--muted);
                font-size: 12px;
                font-weight: 700;
              }

              .list-summary-pill.accent {
                background: rgba(15, 118, 110, 0.10);
                color: var(--accent-strong);
              }

              .list-summary-pill.warn {
                background: rgba(180, 83, 9, 0.12);
                color: var(--warn);
              }

              .item-list {
                display: grid;
                gap: 10px;
              }

              .item {
                background: rgba(255, 255, 255, 0.74);
                border: 1px solid rgba(15, 23, 42, 0.07);
                border-radius: 18px;
                padding: 12px 13px;
                transition: transform 0.16s ease, border-color 0.16s ease, box-shadow 0.16s ease;
              }

              .item[data-task-select="1"] {
                cursor: pointer;
              }

              .item[data-task-select="1"]:hover {
                transform: translateY(-1px);
                border-color: rgba(15, 118, 110, 0.24);
                box-shadow: 0 8px 24px rgba(15, 23, 42, 0.06);
              }

              .item.selected {
                border-color: rgba(15, 118, 110, 0.36);
                box-shadow: inset 0 0 0 1px rgba(15, 118, 110, 0.08), 0 8px 24px rgba(15, 23, 42, 0.04);
                background: rgba(240, 253, 250, 0.85);
              }

              .item.waiting-turn {
                border-color: rgba(180, 83, 9, 0.26);
                background: rgba(255, 247, 237, 0.88);
                box-shadow: inset 0 0 0 1px rgba(180, 83, 9, 0.08);
              }

              .item.waiting-turn.selected {
                border-color: rgba(180, 83, 9, 0.34);
                box-shadow: inset 0 0 0 1px rgba(180, 83, 9, 0.10), 0 8px 24px rgba(180, 83, 9, 0.08);
              }

              .item-kicker {
                display: flex;
                flex-wrap: wrap;
                align-items: center;
                gap: 6px 8px;
                margin-bottom: 8px;
                color: var(--muted);
                font-size: 12px;
              }

              .item-project-line {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
                align-items: center;
                margin-bottom: 9px;
              }

              .project-chip {
                display: inline-flex;
                align-items: center;
                padding: 6px 10px;
                border-radius: 999px;
                background: rgba(15, 118, 110, 0.10);
                color: var(--accent-strong);
                font-size: 12px;
                font-weight: 700;
              }

              .project-path {
                color: var(--muted);
                font-size: 12px;
                line-height: 1.4;
                word-break: break-all;
              }

              .status-dot {
                width: 9px;
                height: 9px;
                border-radius: 999px;
                background: var(--accent);
                box-shadow: 0 0 0 4px rgba(15, 118, 110, 0.10);
              }

              .status-dot.warn {
                background: var(--warn);
                box-shadow: 0 0 0 4px rgba(180, 83, 9, 0.10);
              }

              .status-dot.danger {
                background: var(--danger);
                box-shadow: 0 0 0 4px rgba(185, 28, 28, 0.10);
              }

              .item-head {
                display: flex;
                justify-content: space-between;
                gap: 10px;
                align-items: flex-start;
                margin-bottom: 8px;
              }

              .item-title {
                font-size: 15px;
                font-weight: 700;
                line-height: 1.35;
              }

              .badge {
                flex-shrink: 0;
                border-radius: 999px;
                padding: 6px 10px;
                font-size: 12px;
                font-weight: 700;
                background: var(--accent-soft);
                color: var(--accent-strong);
              }

              .badge.warn {
                background: rgba(180, 83, 9, 0.12);
                color: var(--warn);
              }

              .badge.danger {
                background: rgba(185, 28, 28, 0.12);
                color: var(--danger);
              }

              .meta {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
                margin-bottom: 6px;
              }

              .meta span {
                padding: 5px 9px;
                border-radius: 999px;
                background: rgba(15, 23, 42, 0.05);
                color: var(--muted);
                font-size: 12px;
              }

              .item p {
                margin: 0;
                color: var(--muted);
                line-height: 1.58;
                font-size: 13px;
              }

              .item-summary {
                margin: 0;
                color: var(--ink);
                line-height: 1.62;
                font-size: 14px;
                display: -webkit-box;
                -webkit-line-clamp: 3;
                -webkit-box-orient: vertical;
                overflow: hidden;
              }

              .item-foot {
                display: flex;
                flex-wrap: wrap;
                justify-content: space-between;
                gap: 10px;
                align-items: center;
                margin-top: 10px;
              }

              .item-foot .hint {
                margin: 0;
              }

              .task-status-banner {
                display: grid;
                gap: 4px;
                padding: 14px 16px;
                border-radius: 18px;
                border: 1px solid rgba(15, 118, 110, 0.14);
                background: rgba(15, 118, 110, 0.08);
              }

              .task-status-banner strong {
                font-size: 15px;
              }

              .task-status-banner span {
                color: var(--muted);
                line-height: 1.6;
                font-size: 14px;
              }

              .task-status-banner.waiting {
                border-color: rgba(180, 83, 9, 0.18);
                background: rgba(180, 83, 9, 0.10);
              }

              .task-status-banner.running {
                border-color: rgba(15, 118, 110, 0.18);
                background: rgba(15, 118, 110, 0.08);
              }

              .task-status-banner.warn {
                border-color: rgba(185, 28, 28, 0.16);
                background: rgba(185, 28, 28, 0.08);
              }

              .waiting-pill {
                display: inline-flex;
                align-items: center;
                gap: 6px;
                padding: 6px 10px;
                border-radius: 999px;
                background: rgba(180, 83, 9, 0.12);
                color: var(--warn);
                font-size: 12px;
                font-weight: 700;
              }

              .guide-panel {
                display: grid;
                gap: 14px;
                padding: 16px 18px;
                border-radius: 20px;
                border: 1px solid rgba(15, 118, 110, 0.16);
                background: linear-gradient(180deg, rgba(240, 253, 250, 0.92), rgba(255, 255, 255, 0.92));
              }

              .guide-panel h3 {
                margin: 0;
                font-size: 17px;
                line-height: 1.3;
              }

              .guide-panel p {
                margin: 0;
                color: var(--muted);
                line-height: 1.65;
                font-size: 14px;
              }

              .guide-steps {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
                gap: 10px;
              }

              .guide-step {
                display: grid;
                gap: 6px;
                padding: 12px 14px;
                border-radius: 16px;
                background: rgba(255, 255, 255, 0.84);
                border: 1px solid rgba(15, 23, 42, 0.06);
              }

              .guide-step strong {
                font-size: 13px;
              }

              .guide-step span {
                color: var(--muted);
                line-height: 1.55;
                font-size: 13px;
              }

              .guide-actions {
                display: flex;
                flex-wrap: wrap;
                gap: 10px;
              }

              .guide-button {
                width: auto;
                padding: 12px 16px;
                border-radius: 16px;
                font-size: 14px;
                font-weight: 800;
                box-shadow: 0 10px 24px rgba(15, 23, 42, 0.08);
              }

              .guide-button.primary {
                background: var(--accent);
                color: #fff;
              }

              .guide-button.secondary {
                background: rgba(15, 23, 42, 0.08);
                color: var(--ink);
              }

              .guide-button.danger {
                background: rgba(185, 28, 28, 0.12);
                color: var(--danger);
              }

              .item-actions {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
                margin-top: 10px;
              }

              .action-button {
                padding: 8px 12px;
                border-radius: 999px;
                border: 0;
                background: rgba(15, 118, 110, 0.12);
                color: var(--accent-strong);
                font-size: 12px;
                font-weight: 700;
                cursor: pointer;
              }

              .action-button.primary {
                background: var(--accent);
                color: #fff;
              }

              .action-button.secondary {
                background: rgba(15, 23, 42, 0.06);
                color: var(--muted);
              }

              .action-button.danger {
                background: rgba(185, 28, 28, 0.10);
                color: var(--danger);
              }

              .log-preview {
                margin-top: 10px;
                padding: 10px 12px;
                border-radius: 14px;
                background: var(--code-bg);
                color: #dbeafe;
                font: 500 12px/1.55 ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
                white-space: pre-wrap;
                word-break: break-word;
              }

              .empty {
                padding: 16px;
                border-radius: 18px;
                background: rgba(15, 118, 110, 0.06);
                color: var(--muted);
                line-height: 1.7;
              }

              .notice {
                margin-top: 12px;
                padding: 12px 14px;
                border-radius: 16px;
                background: rgba(180, 83, 9, 0.10);
                color: #92400e;
                line-height: 1.58;
                border: 1px solid rgba(180, 83, 9, 0.12);
              }

              .notice.error {
                background: rgba(185, 28, 28, 0.10);
                color: var(--danger);
                border-color: rgba(185, 28, 28, 0.12);
              }

              .metrics {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
                gap: 12px;
                margin: 0;
              }

              .metric-card {
                padding: 14px;
                border-radius: 18px;
                background: #fbfbf8;
                border: 1px solid var(--line);
              }

              .metric-label {
                color: var(--muted);
                font-size: 13px;
                margin-bottom: 8px;
              }

              .metric-value {
                font-size: 28px;
                font-weight: 700;
                line-height: 1;
              }

              .metric-detail {
                margin-top: 8px;
                font-size: 13px;
                color: var(--muted);
              }

              .diagnostics-grid {
                display: grid;
                grid-template-columns: repeat(2, minmax(280px, 1fr));
                gap: 16px;
              }

              .panel {
                padding: 18px;
              }

              .panel.wide {
                grid-column: 1 / -1;
              }

              .advanced-notes {
                display: grid;
                gap: 10px;
              }

              .advanced-stack {
                display: grid;
                gap: 12px;
              }

              .advanced-nested {
                border: 1px solid var(--line);
                border-radius: 18px;
                background: #fbfbf8;
                overflow: hidden;
              }

              .advanced-nested summary {
                cursor: pointer;
                list-style: none;
                padding: 14px 16px;
                font-weight: 700;
              }

              .advanced-nested summary::-webkit-details-marker {
                display: none;
              }

              .advanced-nested > div,
              .advanced-nested > pre {
                margin: 0;
                padding: 0 16px 16px;
              }

              .raw-json {
                max-height: 340px;
                overflow: auto;
                padding: 14px;
                border-radius: 18px;
                background: var(--code-bg);
                color: #dbeafe;
                font: 500 12px/1.6 ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
              }

              pre {
                margin: 0;
                white-space: pre-wrap;
                word-break: break-word;
              }

              @media (max-width: 1180px) {
                .app-shell {
                  height: auto;
                  grid-template-columns: 1fr;
                }

                .sidebar {
                  position: static;
                  height: auto;
                  grid-template-rows: auto;
                }

                .workspace {
                  grid-template-rows: auto auto auto;
                }
              }

              @media (max-height: 900px) {
                .task-dialog-summary-grid {
                  grid-template-columns: 1fr;
                }

                .dialog-section {
                  padding: 14px;
                }
              }

              @media (max-width: 820px) {
                .topbar {
                  flex-direction: column;
                  align-items: flex-start;
                }

                .topbar-right {
                  width: 100%;
                  justify-content: space-between;
                  margin-left: 0;
                }

                .stamp {
                  text-align: left;
                }

                .diagnostics-grid {
                  grid-template-columns: 1fr;
                }

                .chat-bubble,
                .chat-bubble.user {
                  width: 100%;
                  margin-left: 0;
                }

                .task-dialog-title {
                  font-size: 20px;
                }

                .task-start-grid {
                  grid-template-columns: 1fr;
                }

                .task-start-hero h3 {
                  font-size: 24px;
                }

                .start-here-top h2 {
                  font-size: 20px;
                }
              }
            </style>
          </head>
          <body>
            <div class="app-shell">
              <aside class="sidebar">
                <section class="sidebar-panel brand-card">
                  <div class="eyebrow">OrchardAgent</div>
                  <h1>本地任务工作台</h1>
                </section>

                <section class="sidebar-section sidebar-panel sidebar-scroll sidebar-list-panel" id="task-list-panel">
                  <div class="split-head">
                    <div>
                      <h2>项目列表</h2>
                      <div class="panel-subtitle">只保留项目名和状态；点项目名展开任务，右侧按钮用来查看详情或新建任务。</div>
                    </div>
                    <span class="panel-tag">Local</span>
                  </div>
                  <div id="local-tasks"></div>
                </section>
              </aside>

              <main class="workspace">
                <section class="topbar workspace-panel">
                  <div class="topbar-controls">
                    <button id="refresh-button">立即刷新</button>
                    <button id="show-advanced" class="secondary" type="button">高级观察</button>
                  </div>
                  <div class="topbar-right">
                    <button id="focus-task-list" class="secondary topbar-quick-action" type="button">全部项目</button>
                    <div class="stamp" id="stamp">等待首次刷新…</div>
                  </div>
                </section>

                <section class="stage-card workspace-panel" id="local-task-detail-panel">
                  <div class="stage-head">
                    <div class="eyebrow" id="task-stage-kicker">Task Chat</div>
                    <div class="stage-head-row">
                      <div class="stage-head-copy">
                        <h2 id="task-stage-title">任务执行区</h2>
                        <div class="panel-subtitle" id="task-stage-subtitle">右边只看当前任务的最新进展；要继续追问，直接在最下面输入。</div>
                      </div>
                      <span id="task-stage-badge" class="badge" hidden>未选择</span>
                    </div>
                    <div class="stage-head-meta" id="task-stage-meta"></div>
                  </div>
                  <div id="local-task-detail"></div>
                </section>

                <details class="advanced-section workspace-panel" id="advanced-section">
                  <summary>高级观察（调试 / 恢复时再看）</summary>
                  <div class="advanced-body">
                    <div id="advanced-notes" class="advanced-notes"></div>
                    <div class="advanced-controls">
                      <label class="toggle">
                        <input type="checkbox" id="remote-toggle" \(checked)>
                        <span>顺便查看控制面视角</span>
                      </label>
                      <label class="toggle">
                        <span>列表上限</span>
                        <select id="limit-select">\(limitOptions)</select>
                      </label>
                      <button id="copy-button" class="secondary">复制 JSON</button>
                    </div>

                    <section class="diagnostics-grid">
                      <article class="panel">
                        <div class="split-head">
                          <div>
                            <h2>先看这 3 个数字</h2>
                            <div class="panel-subtitle">只保留日常最有用的几个指标。</div>
                          </div>
                          <span class="panel-tag">Simple</span>
                        </div>
                        <div class="metrics" id="metrics"></div>
                      </article>

                      <article class="panel">
                        <div class="split-head">
                          <div>
                            <h2>待回传更新</h2>
                            <div class="panel-subtitle">断网 / 断连接恢复时，这里最关键。</div>
                          </div>
                          <span class="panel-tag">Recovery</span>
                        </div>
                        <div id="pending-updates"></div>
                      </article>

                      <article class="panel wide">
                        <div class="advanced-stack">
                          <details class="advanced-nested">
                            <summary>远程托管运行（控制面分给本机的任务）</summary>
                            <div id="remote-managed-runs"></div>
                          </details>

                          <details class="advanced-nested">
                            <summary>远程 Codex 会话（拿来对照远端是否跟上）</summary>
                            <div id="remote-codex-sessions"></div>
                          </details>

                          <details class="advanced-nested">
                            <summary>原始 JSON（看不懂 UI 时再打开）</summary>
                            <pre id="raw-json" class="raw-json">等待首次刷新…</pre>
                          </details>
                        </div>
                      </article>
                    </section>
                  </div>
                </details>
              </main>
            </div>

            <div class="overlay" id="task-list-modal" hidden>
              <div class="overlay-card wide">
                <div class="overlay-head">
                  <div>
                    <h2>任务卡片</h2>
                    <div class="panel-subtitle">这里集中看全部任务和 Codex Session；点一张卡片，右边会话就切过去。</div>
                  </div>
                  <button type="button" class="secondary overlay-close" data-action="close-modal" data-modal="task-list">关闭</button>
                </div>
                <div class="overlay-body">
                  <div class="session-toolbar">
                    <input id="task-search-modal" type="search" placeholder="搜索标题、任务号、工作区、摘要">
                    <div class="session-filter-row">
                      <button type="button" class="session-filter active" data-task-filter="all">全部</button>
                      <button type="button" class="session-filter" data-task-filter="active">进行中</button>
                      <button type="button" class="session-filter" data-task-filter="waiting">等我回复</button>
                      <button type="button" class="session-filter" data-task-filter="recent">最近结束</button>
                    </div>
                  </div>
                  <div id="local-tasks-modal"></div>
                </div>
              </div>
            </div>

            <div class="overlay" id="create-modal" hidden>
              <div class="overlay-card">
                <div class="overlay-head">
                  <div>
                    <h2>发起新任务</h2>
                    <div class="panel-subtitle">按顺序选工作区、路径，再写一句你想让 Codex 做什么。</div>
                  </div>
                  <button type="button" class="secondary overlay-close" data-action="close-modal" data-modal="create">关闭</button>
                </div>
                <div class="overlay-body">
                  <form id="local-create-form">
                    <fieldset id="local-create-fieldset">
                      <div class="form-grid">
                        <label class="field">
                          <span>任务标题（可选）</span>
                          <input id="create-title" type="text" placeholder="不填就自动用提示词第一行">
                        </label>
                        <label class="field">
                          <span>工作区</span>
                          <select id="create-workspace">
                            <option value="">等待状态刷新…</option>
                          </select>
                        </label>
                        <label class="field">
                          <span>常用路径（根目录 + 一级目录）</span>
                          <select id="create-relative-path-select">
                            <option value="">工作区根目录</option>
                          </select>
                        </label>
                        <label class="field">
                          <span>执行引擎</span>
                          <select id="create-driver">
                            \(createDriverOptions)
                          </select>
                        </label>
                        <label class="field field-wide">
                          <span>更深路径（可选）</span>
                          <input id="create-relative-path" type="text" placeholder="例如 Sources/OrchardAgent；如果不填，就用上面的下拉选择">
                        </label>
                        <div class="hint field-wide" id="create-path-hint">先从下拉里选工作区根目录或一级目录；如果要更深路径，再在上面的输入框补全。</div>
                        <label class="field field-wide">
                          <span>要 Codex 做什么</span>
                          <textarea id="create-prompt" placeholder="例如：验证断网 / 断连接恢复闭环，并给出修复建议"></textarea>
                        </label>
                        <div class="hint field-wide">Enter 换行，Cmd / Ctrl + Enter 发起任务。</div>
                        <div class="form-actions">
                          <button id="create-submit" type="submit">在宿主机发起任务</button>
                          <span class="hint" id="create-hint">\(escapeHTML(localActionHint))</span>
                        </div>
                        <div id="create-status" class="notice field-wide" hidden>等待发起任务…</div>
                      </div>
                    </fieldset>
                  </form>
                </div>
              </div>
            </div>

            <script>
              const hasLocalControl = \(localActionEnabled ? "true" : "false");
              const hasLocalCodexControl = \(localCodexActionEnabled ? "true" : "false");
              const hasRemoteActions = \(remoteActionEnabled ? "true" : "false");
              const defaultConversationDriver = "\(ConversationDriverKind.codexCLI.rawValue)";
              const conversationDriverLabels = \(conversationDriverLabelsJSON);

              const stamp = document.getElementById('stamp');
              const advancedNotes = document.getElementById('advanced-notes');
              const metrics = document.getElementById('metrics');
              const localTasks = document.getElementById('local-tasks');
              const localTasksModal = document.getElementById('local-tasks-modal');
              const localTaskDetail = document.getElementById('local-task-detail');
              const localTaskDetailPanel = document.getElementById('local-task-detail-panel');
              const taskStageKicker = document.getElementById('task-stage-kicker');
              const taskStageTitle = document.getElementById('task-stage-title');
              const taskStageSubtitle = document.getElementById('task-stage-subtitle');
              const taskStageBadge = document.getElementById('task-stage-badge');
              const taskStageMeta = document.getElementById('task-stage-meta');
              const pendingUpdates = document.getElementById('pending-updates');
              const remoteManagedRuns = document.getElementById('remote-managed-runs');
              const remoteCodexSessions = document.getElementById('remote-codex-sessions');
              const rawJSON = document.getElementById('raw-json');
              const refreshButton = document.getElementById('refresh-button');
              const copyButton = document.getElementById('copy-button');
              const remoteToggle = document.getElementById('remote-toggle');
              const limitSelect = document.getElementById('limit-select');
              const showAdvancedButton = document.getElementById('show-advanced');
              const advancedSection = document.getElementById('advanced-section');
              const localCreateForm = document.getElementById('local-create-form');
              const localCreateFieldset = document.getElementById('local-create-fieldset');
              const createTitleInput = document.getElementById('create-title');
              const createWorkspaceSelect = document.getElementById('create-workspace');
              const createRelativePathSelect = document.getElementById('create-relative-path-select');
              const createDriverSelect = document.getElementById('create-driver');
              const createRelativePathInput = document.getElementById('create-relative-path');
              const createPathHint = document.getElementById('create-path-hint');
              const createPromptInput = document.getElementById('create-prompt');
              const createHint = document.getElementById('create-hint');
              const createStatus = document.getElementById('create-status');
              const taskListModal = document.getElementById('task-list-modal');
              const createModal = document.getElementById('create-modal');
              const focusTaskListButton = document.getElementById('focus-task-list');
              const taskSearchInput = document.getElementById('task-search');
              const taskSearchModalInput = document.getElementById('task-search-modal');
              const taskSearchInputs = [taskSearchInput, taskSearchModalInput].filter(Boolean);
              const taskFilterButtons = Array.from(document.querySelectorAll('[data-task-filter]'));
              const modals = [taskListModal, createModal].filter(Boolean);

              localCreateFieldset.disabled = !hasLocalControl;
              if (!hasLocalControl) {
                createHint.textContent = '当前页面没有接到运行中的 OrchardAgent，所以现在只能观察，不能直接发本地任务。';
              }

              let lastPayload = null;
              let selectedLocalTaskID = null;
              let selectedLocalCodexSessionID = null;
              let selectedConversationKind = 'task';
              let localTaskFilter = 'all';
              let localTaskQuery = '';
              let timelineAutoFollow = true;
              let timelineAutoFollowPaused = false;
              let lastTimelineTaskID = null;
              let lastTimelineSignature = '';
              const pendingTimelineRestore = { state: null };
              const programmaticTimelineScroll = { active: false, timer: null };
              const timelineContentObserver = { timeline: null, content: null, observer: null };
              const timelineFollowThreshold = 120;
              const terminalBoxFollowState = { entryKey: '', autoFollow: true };
              const detailRenderCache = { key: '', frameSignature: '', timelineMarkup: '' };
              let suppressProgressEntryToggleTracking = false;
              const conversationDrafts = new Map();
              const pendingConversationMessages = new Map();
              let deferSelectedConversationRefresh = false;
              const localCodexSessionDetails = new Map();
              const localCodexSessionRequests = new Map();
              const expandedProjectKeys = new Set();
              const expandedProjectDetailKeys = new Set();
              let inlineCreateDraft = null;

              function escapeHTML(value) {
                return String(value ?? '')
                  .replaceAll('&', '&amp;')
                  .replaceAll('<', '&lt;')
                  .replaceAll('>', '&gt;')
                  .replaceAll('"', '&quot;')
                  .replaceAll("'", '&#39;');
              }

              function formatDate(value) {
                if (!value) return '—';
                const date = new Date(value);
                if (Number.isNaN(date.getTime())) return value;
                return new Intl.DateTimeFormat('zh-CN', {
                  year: 'numeric',
                  month: '2-digit',
                  day: '2-digit',
                  hour: '2-digit',
                  minute: '2-digit',
                  second: '2-digit'
                }).format(date);
              }

              function parseTimestamp(value) {
                if (!value) return 0;
                const date = new Date(value);
                return Number.isNaN(date.getTime()) ? 0 : date.getTime();
              }

              function formatRelativeTime(value) {
                const timestamp = parseTimestamp(value);
                if (!timestamp) return '时间未知';
                const deltaSeconds = Math.round((Date.now() - timestamp) / 1000);
                if (deltaSeconds < 45) return '刚刚';
                if (deltaSeconds < 3600) return `${Math.max(1, Math.round(deltaSeconds / 60))} 分钟前`;
                if (deltaSeconds < 86400) return `${Math.max(1, Math.round(deltaSeconds / 3600))} 小时前`;
                if (deltaSeconds < 172800) return '昨天';
                const date = new Date(timestamp);
                return new Intl.DateTimeFormat('zh-CN', {
                  month: '2-digit',
                  day: '2-digit',
                  hour: '2-digit',
                  minute: '2-digit'
                }).format(date);
              }

              function normalizeRelativePath(value) {
                const trimmed = String(value || '').trim();
                if (!trimmed || trimmed === '.' || trimmed === './') return '';
                return trimmed.startsWith('./') ? trimmed.slice(2) : trimmed;
              }

              function defaultLocalTaskTitle(prompt) {
                const firstLine = String(prompt || '')
                  .split(/\\r?\\n/)
                  .map((line) => line.trim())
                  .find((line) => line.length > 0) || '新的本地 Codex 任务';
                return firstLine.length <= 28 ? firstLine : `${firstLine.slice(0, 28)}...`;
              }

              function normalizeConversationDriverKind(value) {
                const normalized = String(value || '').trim();
                return Object.prototype.hasOwnProperty.call(conversationDriverLabels, normalized)
                  ? normalized
                  : defaultConversationDriver;
              }

              function conversationDriverLabel(value) {
                const normalized = normalizeConversationDriverKind(value);
                return conversationDriverLabels[normalized] || conversationDriverLabels[defaultConversationDriver] || 'Codex CLI';
              }

              function localTaskDriverLabel(task) {
                if (task?.task?.kind !== 'codex') {
                  return 'Shell';
                }
                return conversationDriverLabel(task?.task?.payload?.driver);
              }

              function selectedCreateDriverKind() {
                const normalized = normalizeConversationDriverKind(createDriverSelect?.value);
                return createDriverSelect?.querySelector(`option[value="${normalized}"]`)
                  ? normalized
                  : defaultConversationDriver;
              }

              function metricCard(label, value, detail) {
                return `
                  <article class="metric-card">
                    <div class="metric-label">${escapeHTML(label)}</div>
                    <div class="metric-value">${escapeHTML(value)}</div>
                    <div class="metric-detail">${escapeHTML(detail)}</div>
                  </article>
                `;
              }

              function badgeClass(status) {
                const danger = ['失败', '已取消', '已中断'];
                const warn = ['等待输入', '停止中', '中断中', '排队中', '启动中'];
                if (danger.includes(status)) return 'badge danger';
                if (warn.includes(status)) return 'badge warn';
                return 'badge';
              }

              function renderStageMetaChips(items = []) {
                return items
                  .filter((item) => String(item || '').trim().length > 0)
                  .map((item) => `<span>${escapeHTML(item)}</span>`)
                  .join('');
              }

              function updateTaskStageHeader({
                kicker = 'Task Chat',
                title = '右侧任务会话',
                subtitle = '选中左侧任务后，这里优先显示标题、当前状态和最新执行过程。',
                badge = '',
                meta = []
              } = {}) {
                if (taskStageKicker) taskStageKicker.textContent = kicker;
                if (taskStageTitle) taskStageTitle.textContent = title;
                if (taskStageSubtitle) taskStageSubtitle.textContent = subtitle;
                if (taskStageMeta) taskStageMeta.innerHTML = renderStageMetaChips(meta);
                if (taskStageBadge) {
                  const trimmed = String(badge || '').trim();
                  taskStageBadge.hidden = !trimmed;
                  taskStageBadge.textContent = trimmed;
                  taskStageBadge.className = trimmed ? badgeClass(trimmed) : 'badge';
                }
              }

              function conversationDraftKey(kind, id) {
                return id ? `${kind}:${id}` : '';
              }

              function conversationDraftValue(kind, id) {
                const key = conversationDraftKey(kind, id);
                return key ? (conversationDrafts.get(key) || '') : '';
              }

              function setConversationDraft(kind, id, value) {
                const key = conversationDraftKey(kind, id);
                if (!key) return;
                const next = String(value || '');
                if (next.length) {
                  conversationDrafts.set(key, next);
                } else {
                  conversationDrafts.delete(key);
                }
              }

              function shortInlineCopy(value, fallback = '') {
                const text = String(value || '').replace(/\\s+/g, ' ').trim();
                if (!text) return fallback;
                return text.length > 110 ? `${text.slice(0, 110)}...` : text;
              }

              function latestInlineCopy(value, fallback = '') {
                const lines = String(value || '')
                  .split(/\\r?\\n/)
                  .map((line) => line.trim())
                  .filter(Boolean);
                if (!lines.length) return fallback;
                const latest = lines[lines.length - 1];
                return latest.length > 110 ? `${latest.slice(0, 110)}...` : latest;
              }

              function pendingConversationKey(kind, id) {
                return id ? `${kind}:${id}` : '';
              }

              function addPendingConversationMessage(kind, id, body) {
                const key = pendingConversationKey(kind, id);
                if (!key) return null;
                const entry = {
                  id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
                  body: String(body || '').trim(),
                  createdAt: new Date().toISOString()
                };
                const existing = pendingConversationMessages.get(key) || [];
                pendingConversationMessages.set(key, [...existing, entry]);
                return entry.id;
              }

              function removePendingConversationMessage(kind, id, entryID = null) {
                const key = pendingConversationKey(kind, id);
                if (!key) return;
                const existing = pendingConversationMessages.get(key) || [];
                const filtered = entryID
                  ? existing.filter((entry) => entry.id !== entryID)
                  : [];
                if (filtered.length) {
                  pendingConversationMessages.set(key, filtered);
                } else {
                  pendingConversationMessages.delete(key);
                }
              }

              function pendingConversationEntries(kind, id, acknowledgedBodies = []) {
                const key = pendingConversationKey(kind, id);
                if (!key) return [];
                const acknowledged = new Set(
                  acknowledgedBodies
                    .map((body) => String(body || '').trim())
                    .filter(Boolean)
                );
                const existing = pendingConversationMessages.get(key) || [];
                const remaining = existing.filter((entry) => !acknowledged.has(String(entry.body || '').trim()));
                if (remaining.length) {
                  pendingConversationMessages.set(key, remaining);
                } else {
                  pendingConversationMessages.delete(key);
                }
                return remaining;
              }

              function activeComposerContext() {
                const activeElement = document.activeElement;
                if (!activeElement) return null;
                const form = activeElement.closest('form[data-form="local-task-dialog"], form[data-form="local-codex-session-dialog"], form[data-form="inline-create-task"]');
                if (!form) return null;
                if (form.dataset.form === 'local-task-dialog') {
                  return {
                    kind: 'task',
                    id: form.dataset.taskId || '',
                    composing: activeElement.dataset.composing === '1'
                  };
                }
                if (form.dataset.form === 'local-codex-session-dialog') {
                  return {
                    kind: 'codex',
                    id: form.dataset.sessionId || '',
                    composing: activeElement.dataset.composing === '1'
                  };
                }
                if (form.dataset.form === 'inline-create-task') {
                  return {
                    kind: 'draft',
                    id: inlineCreateDraft?.project?.key || '',
                    composing: activeElement.dataset.composing === '1'
                  };
                }
                return null;
              }

              function selectedConversationContext() {
                if (inlineCreateDraft?.project?.key) {
                  return { kind: 'draft', id: inlineCreateDraft.project.key };
                }
                if (selectedConversationKind === 'codex' && selectedLocalCodexSessionID) {
                  return { kind: 'codex', id: selectedLocalCodexSessionID };
                }
                if (selectedConversationKind === 'task' && selectedLocalTaskID) {
                  return { kind: 'task', id: selectedLocalTaskID };
                }
                return null;
              }

              function selectedLocalTaskCodexSessionID(snapshot = lastPayload) {
                if (selectedConversationKind !== 'task' || !selectedLocalTaskID) return '';
                return localTaskByID(selectedLocalTaskID, snapshot)?.codexThreadID || '';
              }

              function shouldDeferSelectedConversationRender() {
                const active = activeComposerContext();
                const selected = selectedConversationContext();
                if (!active || !selected) return false;
                return active.kind === selected.kind && active.id === selected.id;
              }

              function flushDeferredSelectedConversationRender() {
                if (!deferSelectedConversationRefresh || !lastPayload) return;
                if (shouldDeferSelectedConversationRender()) return;
                deferSelectedConversationRefresh = false;
                renderSelectedLocalTaskDetail(lastPayload);
              }

              function renderItemList(items, emptyTitle, renderItem) {
                if (!items || items.length === 0) {
                  return `<div class="empty">${escapeHTML(emptyTitle)}</div>`;
                }
                return `<div class="item-list">${items.map(renderItem).join('')}</div>`;
              }

              function actionButton(label, action, attrs = {}, tone = '', enabled = true) {
                const attributes = Object.entries(attrs)
                  .map(([key, value]) => `data-${key}="${escapeHTML(value)}"`)
                  .join(' ');
                const toneClass = tone ? ` ${tone}` : '';
                const disabled = enabled ? '' : ' disabled';
                return `<button class="action-button${toneClass}" data-action="${escapeHTML(action)}" ${attributes}${disabled}>${escapeHTML(label)}</button>`;
              }

              function populateWorkspaceOptions(workspaces) {
                const items = Array.isArray(workspaces) ? workspaces : [];
                const previous = createWorkspaceSelect.value;
                if (!items.length) {
                  createWorkspaceSelect.innerHTML = '<option value="">未检测到工作区</option>';
                  populateRelativePathOptions('', null);
                  return;
                }

                createWorkspaceSelect.innerHTML = items.map((workspace) => `
                  <option value="${escapeHTML(workspace.id)}">${escapeHTML(workspace.name || workspace.id)} · ${escapeHTML(workspace.id)}</option>
                `).join('');

                const fallback = items[0].id;
                createWorkspaceSelect.value = items.some((workspace) => workspace.id === previous) ? previous : fallback;
                populateRelativePathOptions(createWorkspaceSelect.value);
              }

              function workspaceByID(workspaceID, snapshot = lastPayload) {
                return (snapshot?.workspaces || []).find((workspace) => workspace?.id === workspaceID) || null;
              }

              function relativePathOptionLabel(relativePath) {
                return relativePath ? `一级目录 / ${relativePath}` : '工作区根目录';
              }

              function updateCreatePathHint(workspaceID, snapshot = lastPayload) {
                if (!createPathHint) return;
                const workspace = workspaceByID(workspaceID, snapshot);
                createPathHint.textContent = workspace
                  ? `当前工作区根目录：${workspace.rootPath}。下拉里直接列出根目录和一级目录；如果你要进入更深层，再在上面的输入框补全。`
                  : '先选择工作区；下拉里会直接列出工作区根目录和一级目录。';
              }

              function populateRelativePathOptions(workspaceID, snapshot = lastPayload) {
                const options = snapshot?.workspacePathOptions?.[workspaceID] || [''];
                const previous = normalizeRelativePath(createRelativePathSelect?.value);
                if (createRelativePathSelect) {
                  createRelativePathSelect.innerHTML = options.map((relativePath) => `
                    <option value="${escapeHTML(relativePath)}">${escapeHTML(relativePathOptionLabel(relativePath))}</option>
                  `).join('');
                  createRelativePathSelect.value = options.includes(previous) ? previous : '';
                }
                updateCreatePathHint(workspaceID, snapshot);
              }

              function setCreateStatus(message, tone = 'info') {
                if (!createStatus) return;
                const text = String(message || '').trim();
                createStatus.hidden = !text;
                createStatus.textContent = text;
                createStatus.classList.toggle('error', tone === 'error');
              }

              function setInlineNotice(element, message, tone = 'info') {
                if (!element) return;
                const text = String(message || '').trim();
                element.hidden = !text;
                element.textContent = text;
                element.classList.toggle('error', tone === 'error');
              }

              function syncModalState() {
                document.body.classList.toggle('modal-open', modals.some((modal) => !modal.hidden));
              }

              function setModalOpen(modal, open) {
                if (!modal) return;
                modal.hidden = !open;
                modal.classList.toggle('open', open);
                syncModalState();
              }

              function closeAllModals() {
                modals.forEach((modal) => setModalOpen(modal, false));
              }

              function openCreateModal(focusPrompt = false) {
                setModalOpen(createModal, true);
                if (focusPrompt) {
                  setTimeout(() => createPromptInput?.focus(), 80);
                }
              }

              function openTaskListModal() {
                setModalOpen(taskListModal, true);
                setTimeout(() => (taskSearchModalInput || taskSearchInput)?.focus(), 80);
              }

              function lastPathSegment(path) {
                const normalized = String(path || '').trim().replace(/\\/+$/, '');
                if (!normalized) return '';
                const segments = normalized.split('/').filter(Boolean);
                return segments.length ? segments[segments.length - 1] : normalized;
              }

              function projectNameLabel(project, fallback = '') {
                return String(project?.name || fallback || '').trim() || '未识别项目';
              }

              function projectPathLabel(project, fallbackPath = '') {
                const workspaceID = String(project?.workspaceID || '').trim();
                const relativePath = String(project?.relativePath || '').trim();
                if (workspaceID && relativePath) return `${workspaceID} / ${relativePath}`;
                if (workspaceID) return `${workspaceID} / 工作区根目录`;
                return String(project?.path || fallbackPath || '').trim() || '未识别路径';
              }

              function taskProjectSummary(task) {
                if (task?.project) return task.project;
                const path = task?.cwd || task?.task?.relativePath || task?.task?.workspaceID || task?.task?.id || '';
                return {
                  key: path,
                  name: lastPathSegment(path) || '未识别项目',
                  path,
                  workspaceID: task?.task?.workspaceID || '',
                  relativePath: task?.task?.relativePath || ''
                };
              }

              function codexSessionProjectSummary(session) {
                if (session?.project) return session.project;
                const path = session?.cwd || session?.workspaceID || session?.id || '';
                return {
                  key: path,
                  name: lastPathSegment(path) || '未识别项目',
                  path,
                  workspaceID: session?.workspaceID || '',
                  relativePath: ''
                };
              }

              function normalizeLocalCodexSession(entry) {
                if (!entry) return null;
                if (entry.session) {
                  return { ...entry.session, project: entry.project || null };
                }
                return entry;
              }

              function localTaskCollection(snapshot = lastPayload) {
                const active = Array.isArray(snapshot?.local?.activeTasks) ? snapshot.local.activeTasks : [];
                const recent = Array.isArray(snapshot?.local?.recentTasks) ? snapshot.local.recentTasks : [];
                return [...active, ...recent];
              }

              function managedCodexThreadIDs(snapshot = lastPayload) {
                return new Set(
                  localTaskCollection(snapshot)
                    .map((task) => task?.codexThreadID)
                    .filter(Boolean)
                );
              }

              function localCodexSessionCollection(snapshot = lastPayload) {
                const sessions = Array.isArray(snapshot?.local?.codexSessions) ? snapshot.local.codexSessions : [];
                const managedThreadIDs = managedCodexThreadIDs(snapshot);
                return sessions
                  .map(normalizeLocalCodexSession)
                  .filter((session) => session?.id && !managedThreadIDs.has(session.id));
              }

              function localCodexSessionByID(sessionID, snapshot = lastPayload) {
                return localCodexSessionCollection(snapshot).find((session) => session?.id === sessionID) || null;
              }

              function selectLocalTask(taskID) {
                inlineCreateDraft = null;
                selectedConversationKind = 'task';
                selectedLocalTaskID = taskID || null;
                selectedLocalCodexSessionID = null;
                const projectKey = taskID ? taskProjectSummary(localTaskByID(taskID, lastPayload))?.key : null;
                if (projectKey) {
                  expandedProjectKeys.add(String(projectKey));
                }
              }

              function selectLocalCodexSession(sessionID) {
                inlineCreateDraft = null;
                selectedConversationKind = 'codex';
                selectedLocalCodexSessionID = sessionID || null;
                selectedLocalTaskID = null;
                const projectKey = sessionID ? codexSessionProjectSummary(localCodexSessionByID(sessionID, lastPayload))?.key : null;
                if (projectKey) {
                  expandedProjectKeys.add(String(projectKey));
                }
              }

              function localCodexSessionActivityTimestamp(session) {
                return parseTimestamp(session?.updatedAt)
                  || parseTimestamp(session?.createdAt);
              }

              function localCodexSessionStatusKey(session) {
                if (session?.lastTurnStatus === 'inProgress' || session?.state === 'running') {
                  return 'running';
                }
                return session?.state || 'unknown';
              }

              function isRunningLocalCodexSession(session) {
                return localCodexSessionStatusKey(session) === 'running';
              }

              function canContinueLocalCodexSession(session) {
                return hasLocalCodexControl
                  && Boolean(session?.id)
                  && !isRunningLocalCodexSession(session);
              }

              function canInterruptLocalCodexSession(session) {
                return hasLocalCodexControl
                  && Boolean(session?.id)
                  && isRunningLocalCodexSession(session);
              }

              function codexSessionSortPriority(session) {
                if (isRunningLocalCodexSession(session)) return 1;
                if (canContinueLocalCodexSession(session)) return 2;
                return 3;
              }

              function localCodexSessionMatchesQuery(session, query = localTaskQuery) {
                const normalizedQuery = String(query || '').trim().toLowerCase();
                if (!normalizedQuery) return true;
                const project = codexSessionProjectSummary(session);
                const haystack = [
                  session?.name,
                  session?.id,
                  session?.workspaceID,
                  session?.cwd,
                  project?.name,
                  project?.path,
                  project?.relativePath,
                  session?.preview,
                  session?.lastUserMessage,
                  session?.lastAssistantMessage,
                  session?.source,
                  session?.modelProvider
                ].filter(Boolean).join('\\n').toLowerCase();
                return haystack.includes(normalizedQuery);
              }

              function localCodexSessionMatchesFilter(session, filter = localTaskFilter) {
                switch (filter) {
                  case 'active':
                    return isRunningLocalCodexSession(session);
                  case 'waiting':
                    return canContinueLocalCodexSession(session);
                  case 'recent':
                    return !isRunningLocalCodexSession(session);
                  default:
                    return true;
                }
              }

              function visibleLocalCodexSessionCollection(snapshot = lastPayload) {
                return [...localCodexSessionCollection(snapshot)]
                  .filter((session) => localCodexSessionMatchesFilter(session, localTaskFilter) && localCodexSessionMatchesQuery(session, localTaskQuery))
                  .sort((lhs, rhs) => {
                    const leftPriority = codexSessionSortPriority(lhs);
                    const rightPriority = codexSessionSortPriority(rhs);
                    if (leftPriority !== rightPriority) return leftPriority - rightPriority;
                    const left = localCodexSessionActivityTimestamp(lhs);
                    const right = localCodexSessionActivityTimestamp(rhs);
                    if (left !== right) return right - left;
                    return String(lhs?.id || '').localeCompare(String(rhs?.id || ''), 'zh-CN');
                  });
              }

              function conversationCandidates(snapshot = lastPayload, visibleOnly = true) {
                const tasks = (visibleOnly ? visibleLocalTaskCollection(snapshot) : sortTasksByActivity(localTaskCollection(snapshot)))
                  .map((task) => ({
                    kind: 'task',
                    id: task?.task?.id || '',
                    priority: taskSortPriority(task, snapshot),
                    timestamp: taskActivityTimestamp(task)
                  }));
                const sessions = (visibleOnly ? visibleLocalCodexSessionCollection(snapshot) : localCodexSessionCollection(snapshot))
                  .map((session) => ({
                    kind: 'codex',
                    id: session?.id || '',
                    priority: codexSessionSortPriority(session),
                    timestamp: localCodexSessionActivityTimestamp(session)
                  }));
                return [...tasks, ...sessions]
                  .filter((candidate) => candidate.id)
                  .sort((lhs, rhs) => {
                    if (lhs.priority !== rhs.priority) return lhs.priority - rhs.priority;
                    if (lhs.timestamp !== rhs.timestamp) return rhs.timestamp - lhs.timestamp;
                    if (lhs.kind !== rhs.kind) return lhs.kind.localeCompare(rhs.kind, 'zh-CN');
                    return lhs.id.localeCompare(rhs.id, 'zh-CN');
                  });
              }

              function conversationProjectSummary(candidate, snapshot = lastPayload) {
                if (candidate?.kind === 'task') {
                  return taskProjectSummary(localTaskByID(candidate.id, snapshot));
                }
                return codexSessionProjectSummary(localCodexSessionByID(candidate.id, snapshot));
              }

              function groupedConversationCandidates(candidates, snapshot = lastPayload) {
                const groups = new Map();
                (candidates || []).forEach((candidate) => {
                  if (!candidate?.id) return;
                  const project = conversationProjectSummary(candidate, snapshot);
                  const groupKey = String(project?.key || project?.path || `${candidate.kind}:${candidate.id}`);
                  if (!groups.has(groupKey)) {
                    groups.set(groupKey, {
                      key: groupKey,
                      project,
                      items: [],
                      latestAt: 0,
                      runningCount: 0,
                      waitingCount: 0
                    });
                  }
                  const group = groups.get(groupKey);
                  group.items.push(candidate);
                  group.latestAt = Math.max(group.latestAt, Number(candidate.timestamp) || 0);

                  if (candidate.kind === 'task') {
                    const task = localTaskByID(candidate.id, snapshot);
                    if (isActiveLocalTask(candidate.id, snapshot)) group.runningCount += 1;
                    if (localTaskStatusKey(task) === 'waitingInput' && isActiveLocalTask(candidate.id, snapshot)) {
                      group.waitingCount += 1;
                    }
                  } else {
                    const session = localCodexSessionByID(candidate.id, snapshot);
                    if (isRunningLocalCodexSession(session)) group.runningCount += 1;
                    if (canContinueLocalCodexSession(session)) group.waitingCount += 1;
                  }
                });

                return Array.from(groups.values()).sort((lhs, rhs) => {
                  if (lhs.latestAt !== rhs.latestAt) return rhs.latestAt - lhs.latestAt;
                  return projectNameLabel(lhs.project).localeCompare(projectNameLabel(rhs.project), 'zh-CN');
                });
              }

              function workspaceProjectEntries(snapshot = lastPayload) {
                const workspaces = Array.isArray(snapshot?.workspaces) ? snapshot.workspaces : [];
                const projectMap = snapshot?.workspaceProjects || {};
                const fallbackPathMap = snapshot?.workspacePathOptions || {};
                const entries = [];

                workspaces.forEach((workspace) => {
                  const providedProjects = Array.isArray(projectMap?.[workspace.id]) ? projectMap[workspace.id] : [];
                  if (providedProjects.length) {
                    entries.push(...providedProjects);
                    return;
                  }

                  const fallbackPaths = Array.isArray(fallbackPathMap?.[workspace.id]) ? fallbackPathMap[workspace.id] : [''];
                  fallbackPaths.forEach((relativePath) => {
                    entries.push({
                      key: `${workspace.id}:${relativePath || '.'}`,
                      name: relativePath ? lastPathSegment(relativePath) : (workspace.name || workspace.id),
                      path: relativePath ? `${workspace.rootPath}/${relativePath}` : workspace.rootPath,
                      workspaceID: workspace.id,
                      relativePath: relativePath || ''
                    });
                  });
                });

                const deduped = new Map();
                entries.forEach((project) => {
                  const key = String(project?.key || project?.path || `${project?.workspaceID || 'workspace'}:${project?.relativePath || '.'}`);
                  if (!deduped.has(key)) {
                    deduped.set(key, project);
                  }
                });
                return Array.from(deduped.values());
              }

              function activeProjectKey(snapshot = lastPayload) {
                if (inlineCreateDraft?.project?.key) return inlineCreateDraft.project.key;
                if (selectedConversationKind === 'task' && selectedLocalTaskID) {
                  return taskProjectSummary(localTaskByID(selectedLocalTaskID, snapshot))?.key || null;
                }
                if (selectedConversationKind === 'codex' && selectedLocalCodexSessionID) {
                  return codexSessionProjectSummary(localCodexSessionByID(selectedLocalCodexSessionID, snapshot))?.key || null;
                }
                return null;
              }

              function sidebarProjectGroups(snapshot = lastPayload) {
                const groups = groupedConversationCandidates(conversationCandidates(snapshot, false), snapshot);
                const byKey = new Map(groups.map((group) => [String(group.key), group]));
                workspaceProjectEntries(snapshot).forEach((project) => {
                  const key = String(project?.key || project?.path || `${project?.workspaceID || 'workspace'}:${project?.relativePath || '.'}`);
                  if (!byKey.has(key)) {
                    byKey.set(key, {
                      key,
                      project,
                      items: [],
                      latestAt: 0,
                      runningCount: 0,
                      waitingCount: 0
                    });
                  }
                });

                return Array.from(byKey.values()).sort((lhs, rhs) => {
                  const leftSelected = activeProjectKey(snapshot) === lhs.key ? 1 : 0;
                  const rightSelected = activeProjectKey(snapshot) === rhs.key ? 1 : 0;
                  if (leftSelected !== rightSelected) return rightSelected - leftSelected;
                  if (lhs.runningCount !== rhs.runningCount) return rhs.runningCount - lhs.runningCount;
                  if (lhs.waitingCount !== rhs.waitingCount) return rhs.waitingCount - lhs.waitingCount;
                  if (lhs.latestAt !== rhs.latestAt) return rhs.latestAt - lhs.latestAt;
                  return projectNameLabel(lhs.project).localeCompare(projectNameLabel(rhs.project), 'zh-CN');
                });
              }

              function projectSupportsCreate(project) {
                return hasLocalControl && Boolean(project?.workspaceID);
              }

              function ensureExpandedProjectKeys(snapshot = lastPayload) {
                const groups = sidebarProjectGroups(snapshot);
                const availableKeys = new Set(groups.map((group) => String(group.key)));
                [expandedProjectKeys, expandedProjectDetailKeys].forEach((projectKeySet) => {
                  Array.from(projectKeySet).forEach((key) => {
                    if (!availableKeys.has(String(key))) {
                      projectKeySet.delete(String(key));
                    }
                  });
                });

                const activeKey = activeProjectKey(snapshot);
                if (activeKey) {
                  expandedProjectKeys.add(String(activeKey));
                }

                if (!expandedProjectKeys.size) {
                  groups
                    .filter((group) => group.runningCount > 0 || group.waitingCount > 0)
                    .slice(0, 3)
                    .forEach((group) => expandedProjectKeys.add(String(group.key)));
                }

                if (!expandedProjectKeys.size && groups[0]?.key) {
                  expandedProjectKeys.add(String(groups[0].key));
                }
              }

              function projectGroupByKey(projectKey, snapshot = lastPayload) {
                return sidebarProjectGroups(snapshot).find((group) => String(group.key) === String(projectKey)) || null;
              }

              function toggleProjectGroup(projectKey, snapshot = lastPayload) {
                const key = String(projectKey || '');
                if (!key) return;
                if (expandedProjectKeys.has(key)) {
                  expandedProjectKeys.delete(key);
                } else {
                  expandedProjectKeys.add(key);
                }
                if (snapshot) {
                  renderSnapshot(snapshot);
                }
              }

              function toggleProjectDetails(projectKey, snapshot = lastPayload) {
                const key = String(projectKey || '');
                if (!key) return;
                if (expandedProjectDetailKeys.has(key)) {
                  expandedProjectDetailKeys.delete(key);
                } else {
                  expandedProjectDetailKeys.add(key);
                }
                if (snapshot) {
                  renderSnapshot(snapshot);
                }
              }

              function projectItemCount(group) {
                return Array.isArray(group?.items) ? group.items.length : 0;
              }

              function projectStatusSummary(group) {
                const total = projectItemCount(group);
                if ((group?.runningCount || 0) > 0) {
                  return {
                    state: 'running',
                    label: group.runningCount > 1 ? `执行中 ${group.runningCount}` : '执行中',
                    animated: true
                  };
                }
                if ((group?.waitingCount || 0) > 0) {
                  return {
                    state: 'waiting',
                    label: group.waitingCount > 1 ? `待继续 ${group.waitingCount}` : '待继续',
                    animated: false
                  };
                }
                if (total > 0) {
                  return {
                    state: 'history',
                    label: `历史 ${total}`,
                    animated: false
                  };
                }
                return {
                  state: 'empty',
                  label: '暂无任务',
                  animated: false
                };
              }

              function renderProjectStatus(summary) {
                const state = String(summary?.state || 'empty');
                const label = String(summary?.label || '暂无任务');
                const indicator = summary?.animated
                  ? '<span class="project-running-indicator" aria-hidden="true"></span>'
                  : '';
                return `<span class="project-tree-status ${escapeHTML(state)}">${indicator}<span>${escapeHTML(label)}</span></span>`;
              }

              function makeInlineCreateDraft(project, snapshot = lastPayload) {
                if (!project) return null;
                return {
                  project,
                  workspaceID: resolveWorkspaceID(project.workspaceID, snapshot),
                  relativePath: normalizeRelativePath(project.relativePath),
                  driver: defaultConversationDriver,
                  prompt: '',
                  statusMessage: '',
                  tone: 'info'
                };
              }

              function openInlineCreateDraftForProject(project, snapshot = lastPayload) {
                const draft = makeInlineCreateDraft(project, snapshot);
                if (!draft) return;
                inlineCreateDraft = draft;
                expandedProjectKeys.add(String(project.key));
                selectedConversationKind = 'task';
                selectedLocalTaskID = null;
                selectedLocalCodexSessionID = null;
                if (snapshot) {
                  renderSnapshot(snapshot);
                }
                setTimeout(() => {
                  const promptField = localTaskDetail.querySelector('form[data-form="inline-create-task"] [name="prompt"]');
                  promptField?.focus();
                }, 60);
              }

              function closeInlineCreateDraft(snapshot = lastPayload) {
                inlineCreateDraft = null;
                if (snapshot) {
                  syncSelectedLocalTask(snapshot);
                  renderSnapshot(snapshot);
                }
              }

              function updateInlineCreateDraft(nextValues = {}) {
                if (!inlineCreateDraft) return;
                inlineCreateDraft = {
                  ...inlineCreateDraft,
                  ...nextValues
                };
              }

              function inlineCreateProject(snapshot = lastPayload) {
                if (!inlineCreateDraft) return null;
                if (inlineCreateDraft?.project?.key) {
                  const latestProject = projectGroupByKey(inlineCreateDraft.project.key, snapshot)?.project;
                  return latestProject || inlineCreateDraft.project;
                }
                return inlineCreateDraft.project || null;
              }

              function preferredCreateProject(snapshot = lastPayload) {
                const activeKey = activeProjectKey(snapshot);
                if (activeKey) {
                  const activeProject = projectGroupByKey(activeKey, snapshot)?.project;
                  if (activeProject && projectSupportsCreate(activeProject)) {
                    return activeProject;
                  }
                }
                return sidebarProjectGroups(snapshot).find((group) => projectSupportsCreate(group.project))?.project || null;
              }

              function taskActivityTimestamp(task) {
                return parseTimestamp(task?.lastSeenAt)
                  || parseTimestamp(task?.startedAt)
                  || parseTimestamp(task?.task?.updatedAt)
                  || parseTimestamp(task?.task?.createdAt);
              }

              function taskSortPriority(task, snapshot = lastPayload) {
                const status = localTaskStatusKey(task);
                const active = isActiveLocalTask(task?.task?.id, snapshot);
                if (active && status === 'waitingInput') return 0;
                if (active && status === 'running') return 1;
                if (active) return 2;
                return 3;
              }

              function sortTasksByActivity(tasks) {
                return [...tasks].sort((lhs, rhs) => {
                  const leftPriority = taskSortPriority(lhs);
                  const rightPriority = taskSortPriority(rhs);
                  if (leftPriority !== rightPriority) return leftPriority - rightPriority;
                  const left = taskActivityTimestamp(lhs);
                  const right = taskActivityTimestamp(rhs);
                  if (left !== right) return right - left;
                  return String(lhs?.task?.id || '').localeCompare(String(rhs?.task?.id || ''), 'zh-CN');
                });
              }

              function taskStatusTone(status) {
                if (['失败', '已取消', '已中断'].includes(status)) return 'danger';
                if (['等待输入', '停止中', '中断中', '排队中', '启动中'].includes(status)) return 'warn';
                return '';
              }

              function taskMatchesQuery(task, query = localTaskQuery) {
                const normalizedQuery = String(query || '').trim().toLowerCase();
                if (!normalizedQuery) return true;
                const project = taskProjectSummary(task);
                const haystack = [
                  task?.task?.title,
                  task?.task?.id,
                  task?.task?.workspaceID,
                  task?.task?.relativePath,
                  project?.name,
                  project?.path,
                  project?.relativePath,
                  task?.lastAssistantPreview,
                  task?.lastUserPrompt,
                  task?.cwd,
                  task?.runtimeWarning,
                  task?.managedRunStatus
                ].filter(Boolean).join('\\n').toLowerCase();
                return haystack.includes(normalizedQuery);
              }

              function taskMatchesFilter(task, filter = localTaskFilter, snapshot = lastPayload) {
                const taskID = task?.task?.id;
                const isActive = isActiveLocalTask(taskID, snapshot);
                const status = localTaskStatusKey(task);
                switch (filter) {
                  case 'active':
                    return isActive;
                  case 'waiting':
                    return isActive && status === 'waitingInput';
                  case 'recent':
                    return !isActive;
                  default:
                    return true;
                }
              }

              function visibleLocalTaskCollection(snapshot = lastPayload) {
                return sortTasksByActivity(
                  localTaskCollection(snapshot).filter((task) => taskMatchesFilter(task, localTaskFilter, snapshot) && taskMatchesQuery(task, localTaskQuery))
                );
              }

              function resolveWorkspaceID(preferredID, snapshot = lastPayload) {
                const items = Array.isArray(snapshot?.workspaces) ? snapshot.workspaces : [];
                if (preferredID && items.some((workspace) => workspace?.id === preferredID)) {
                  return preferredID;
                }
                return items[0]?.id || '';
              }

              function renderWorkspaceOptions(selectedID = '', snapshot = lastPayload) {
                const items = Array.isArray(snapshot?.workspaces) ? snapshot.workspaces : [];
                return items.map((workspace) => `
                  <option value="${escapeHTML(workspace.id)}"${workspace.id === selectedID ? ' selected' : ''}>${escapeHTML(workspace.name || workspace.id)} · ${escapeHTML(workspace.id)}</option>
                `).join('');
              }

              function renderRelativePathOptions(workspaceID, selectedPath = '', snapshot = lastPayload) {
                const options = snapshot?.workspacePathOptions?.[workspaceID] || [''];
                const normalizedSelected = normalizeRelativePath(selectedPath);
                return options.map((relativePath) => `
                  <option value="${escapeHTML(relativePath)}"${normalizeRelativePath(relativePath) === normalizedSelected ? ' selected' : ''}>${escapeHTML(relativePathOptionLabel(relativePath))}</option>
                `).join('');
              }

              function syncSidebarCreateInputs({ title, workspaceID, relativePath, driver, prompt }) {
                if (typeof title === 'string') {
                  createTitleInput.value = title;
                }
                if (workspaceID) {
                  createWorkspaceSelect.value = workspaceID;
                  populateRelativePathOptions(workspaceID);
                }
                if (typeof relativePath === 'string') {
                  const normalizedPath = normalizeRelativePath(relativePath);
                  const options = lastPayload?.workspacePathOptions?.[workspaceID || createWorkspaceSelect.value] || [''];
                  if (options.includes(normalizedPath)) {
                    createRelativePathSelect.value = normalizedPath;
                    createRelativePathInput.value = '';
                  } else {
                    createRelativePathSelect.value = '';
                    createRelativePathInput.value = normalizedPath;
                  }
                }
                if (createDriverSelect) {
                  createDriverSelect.value = normalizeConversationDriverKind(driver || selectedCreateDriverKind());
                  if (!createDriverSelect.value) {
                    createDriverSelect.value = defaultConversationDriver;
                  }
                }
                if (typeof prompt === 'string') {
                  createPromptInput.value = prompt;
                }
              }

              async function createLocalTask(values) {
                const prompt = String(values?.prompt || '').trim();
                const workspaceID = resolveWorkspaceID(values?.workspaceID);
                const relativePath = normalizeRelativePath(values?.relativePath);
                const driver = normalizeConversationDriverKind(values?.driver || selectedCreateDriverKind());
                const title = (String(values?.title || '').trim() || defaultLocalTaskTitle(prompt)).trim();

                syncSidebarCreateInputs({ title, workspaceID, relativePath, driver, prompt });

                const payload = await postJSON('/api/local-managed-runs', {
                  title,
                  workspaceID,
                  relativePath: relativePath || null,
                  driver,
                  prompt
                });

                if (payload?.taskID) {
                  inlineCreateDraft = null;
                  selectLocalTask(payload.taskID);
                }
                stamp.textContent = payload?.taskID
                  ? `已在宿主机发起任务 ${payload.taskID}`
                  : '已在宿主机发起任务';
                createPromptInput.value = '';
                setModalOpen(createModal, false);
                await refreshSnapshot();
                return payload;
              }

              function afterLocalTaskCreated(payload) {
                const createdTaskID = payload?.taskID || '';
                if (createdTaskID && localTaskByID(createdTaskID, lastPayload)) {
                  setCreateStatus(
                    isActiveLocalTask(createdTaskID, lastPayload)
                      ? `任务 ${createdTaskID} 已发起；任务卡片里已经自动选中，现在中间会话可以直接观察、追问或终止。`
                      : `任务 ${createdTaskID} 已发起，但它已经很快执行结束；打开任务卡片后，在“最近结束”里可以直接点进去看过程和结果。`
                  );
                } else {
                  setCreateStatus(payload?.taskID
                    ? `任务 ${payload.taskID} 已发起；如果任务卡片里暂时没出现，点一次“立即刷新”即可。`
                    : '任务已发起；任务卡片会在下一次刷新后出现。'
                  );
                }
                scrollTaskDialogIntoView();
              }

              function localTaskByID(taskID, snapshot = lastPayload) {
                return localTaskCollection(snapshot).find((task) => task?.task?.id === taskID) || null;
              }

              function pendingUpdateByTaskID(taskID, snapshot = lastPayload) {
                return (snapshot?.local?.pendingUpdates || []).find((update) => update?.taskID === taskID) || null;
              }

              function isActiveLocalTask(taskID, snapshot = lastPayload) {
                return (snapshot?.local?.activeTasks || []).some((task) => task?.task?.id === taskID);
              }

              function localTaskStatusKey(task) {
                return task?.managedRunStatus || task?.task?.status || '';
              }

              function localTaskStatusLabel(task) {
                return task?.managedRunStatus
                  ? statusTitleForManagedRun(task.managedRunStatus)
                  : statusTitleForTask(task?.task?.status);
              }

              function canSendLocalInstruction(task) {
                const status = localTaskStatusKey(task);
                return hasLocalControl
                  && isActiveLocalTask(task?.task?.id)
                  && task?.task?.kind === 'codex'
                  && Boolean(task?.task?.id)
                  && status
                  && !['interrupting', 'stopRequested', 'succeeded', 'failed', 'interrupted', 'cancelled'].includes(status);
              }

              function canContinueLocalTask(task) {
                return canSendLocalInstruction(task) && task?.managedRunStatus === 'waitingInput';
              }

              function canInterruptLocalTask(task) {
                return hasLocalControl
                  && isActiveLocalTask(task?.task?.id)
                  && task?.task?.kind === 'codex'
                  && ['running', 'waitingInput', 'interrupting'].includes(task?.managedRunStatus)
                  && Boolean(task?.task?.id);
              }

              function canStopLocalTask(task) {
                const status = localTaskStatusKey(task);
                return Boolean(task?.task?.id)
                  && isActiveLocalTask(task?.task?.id)
                  && (hasLocalControl || hasRemoteActions)
                  && status
                  && !['succeeded', 'failed', 'interrupted', 'cancelled', 'stopRequested'].includes(status);
              }

              function localStopAction(task) {
                if (task?.task?.kind === 'codex' && hasLocalControl) {
                  return 'stop-local-managed';
                }
                return 'stop-local-task';
              }

              function syncSelectedLocalTask(snapshot) {
                if (inlineCreateDraft) {
                  const currentProject = inlineCreateProject(snapshot);
                  if (currentProject?.key) {
                    expandedProjectKeys.add(String(currentProject.key));
                  }
                  return;
                }

                const selectedTaskStillVisible = selectedConversationKind === 'task'
                  && selectedLocalTaskID
                  && (visibleLocalTaskCollection(snapshot).some((task) => task?.task?.id === selectedLocalTaskID)
                    || pendingUpdateByTaskID(selectedLocalTaskID, snapshot));
                if (selectedTaskStillVisible) {
                  return;
                }

                const selectedSessionStillVisible = selectedConversationKind === 'codex'
                  && selectedLocalCodexSessionID
                  && visibleLocalCodexSessionCollection(snapshot).some((session) => session?.id === selectedLocalCodexSessionID);
                if (selectedSessionStillVisible) {
                  return;
                }

                const visibleCandidates = conversationCandidates(snapshot, true);
                if (visibleCandidates.length) {
                  const next = visibleCandidates[0];
                  if (next.kind === 'task') {
                    selectLocalTask(next.id);
                  } else {
                    selectLocalCodexSession(next.id);
                    requestLocalCodexSessionDetail(next.id);
                  }
                  return;
                }

                if (selectedConversationKind === 'task' && selectedLocalTaskID && pendingUpdateByTaskID(selectedLocalTaskID, snapshot)) {
                  return;
                }

                if (localTaskFilter !== 'all' || localTaskQuery) {
                  selectLocalTask(null);
                  return;
                }

                const fallbackCandidates = conversationCandidates(snapshot, false);
                const next = fallbackCandidates[0];
                if (!next) {
                  selectLocalTask(null);
                  return;
                }
                if (next.kind === 'task') {
                  selectLocalTask(next.id);
                } else {
                  selectLocalCodexSession(next.id);
                  requestLocalCodexSessionDetail(next.id);
                }
              }

              function localTaskDialogHint(task, snapshot = lastPayload) {
                const status = localTaskStatusKey(task);
                if (!task) {
                  return '先从左边选一个本地任务，这里就会切到它的对话与控制视图。';
                }
                if (!isActiveLocalTask(task?.task?.id, snapshot)) {
                  return '这条任务已经结束，所以这里主要用来复盘刚才发生了什么；如果要继续，请重新发起一条新任务。';
                }
                if (task?.task?.kind !== 'codex') {
                  return '这是 Shell 任务，所以这里只能观察执行过程并在需要时终止。';
                }
                if (status === 'waitingInput') {
                  return '当前最适合直接发下一句补充说明；发送后这里会继续滚动执行过程。';
                }
                if (status === 'running') {
                  return '当前还在执行中；你可以先继续观察日志，必要时点“中断”后再补充说明。';
                }
                if (status === 'interrupting') {
                  return '中断已经发出，先等这轮真正停下来，再决定要不要继续补充说明。';
                }
                if (status === 'stopRequested') {
                  return '终止已经发出，先观察这条任务是否收敛并从活动列表移出。';
                }
                return '这里会持续展示最近输入、最新回复摘要和日志滚动。';
              }

              function compactConversationTitle(value, fallback = '未命名任务', limit = 10) {
                const text = String(value || '').trim() || fallback;
                return text.length > limit ? `${text.slice(0, limit)}…` : text;
              }

              function renderSidebarConversationRow(candidate, snapshot = lastPayload) {
                if (candidate?.kind === 'task') {
                  const task = localTaskByID(candidate.id, snapshot);
                  if (!task) return '';
                  const status = localTaskStatusLabel(task);
                  const selectedClass = selectedConversationKind === 'task' && selectedLocalTaskID === candidate.id ? ' selected' : '';
                  const tone = taskStatusTone(status);
                  const title = compactConversationTitle(task?.task?.title, task?.task?.id || '未命名任务', 18);
                  return `
                    <button type="button" class="project-task-row${selectedClass}" data-task-select="1" data-task-id="${escapeHTML(candidate.id)}">
                      <span class="project-task-main">
                        <span class="status-dot ${escapeHTML(tone)}"></span>
                        <span class="project-task-title">${escapeHTML(title)}</span>
                      </span>
                      <span class="project-task-meta">${escapeHTML(status)}</span>
                    </button>`;
                }

                const session = localCodexSessionByID(candidate.id, snapshot);
                if (!session) return '';
                const status = statusTitleForSession(session);
                const selectedClass = selectedConversationKind === 'codex' && selectedLocalCodexSessionID === candidate.id ? ' selected' : '';
                const tone = taskStatusTone(status);
                const title = compactConversationTitle(session?.name || session?.preview || session?.id, session?.id || '会话', 18);
                return `
                  <button type="button" class="project-task-row${selectedClass}" data-codex-session-select="1" data-session-id="${escapeHTML(candidate.id)}">
                    <span class="project-task-main">
                      <span class="status-dot ${escapeHTML(tone)}"></span>
                      <span class="project-task-title">${escapeHTML(title)}</span>
                    </span>
                    <span class="project-task-meta">${escapeHTML(status)}</span>
                  </button>`;
              }

              function renderLocalProjectSidebar(snapshot) {
                const groups = sidebarProjectGroups(snapshot);
                ensureExpandedProjectKeys(snapshot);

                if (!groups.length) {
                  return `
                    <div class="project-sidebar-empty">
                      <strong>还没有项目任务</strong>
                      <span>点“新任务”，或者等本机任务刷新出来。</span>
                    </div>`;
                }

                const summary = [
                  `<span class="list-summary-pill accent">项目 ${groups.length}</span>`,
                  `<span class="list-summary-pill">进行中 ${localRunningConversationCount(snapshot)}</span>`,
                  `<span class="list-summary-pill">等你继续 ${localWaitingConversationCount(snapshot)}</span>`
                ].join('');

                const body = groups.map((group) => {
                  const projectName = projectNameLabel(group.project);
                  const projectPath = projectPathLabel(group.project);
                  const projectStatus = projectStatusSummary(group);
                  const open = expandedProjectKeys.has(String(group.key));
                  const detailOpen = expandedProjectDetailKeys.has(String(group.key));
                  const selected = activeProjectKey(snapshot) === group.key ? ' selected' : '';
                  const itemsHTML = group.items.length
                    ? group.items.map((candidate) => renderSidebarConversationRow(candidate, snapshot)).join('')
                    : '<div class="project-task-empty">这个项目下还没有任务，点右侧“新建任务”就能直接开始。</div>';
                  const detailPills = [
                    `<span>累计 ${escapeHTML(String(projectItemCount(group)))}</span>`,
                    `<span>进行中 ${escapeHTML(String(group.runningCount || 0))}</span>`,
                    group.waitingCount ? `<span>等你继续 ${escapeHTML(String(group.waitingCount))}</span>` : '',
                    group.project?.workspaceID ? `<span>工作区 ${escapeHTML(group.project.workspaceID)}</span>` : '',
                    group.project?.workspaceID ? `<span>目录 ${escapeHTML(group.project?.relativePath || '工作区根目录')}</span>` : ''
                  ].filter(Boolean).join('');
                  return `
                    <section class="project-tree${selected}${open ? ' open' : ''}">
                      <div class="project-tree-head">
                        <button type="button" class="project-tree-toggle" data-action="toggle-project-tree" data-project-key="${escapeHTML(group.key)}">
                          <span class="project-tree-main">
                            <span class="project-tree-title">${escapeHTML(projectName)}</span>
                            ${renderProjectStatus(projectStatus)}
                          </span>
                        </button>
                        <div class="project-tree-actions">
                          <button
                            type="button"
                            class="project-tree-detail secondary project-action-button${detailOpen ? ' is-open' : ''}"
                            data-action="toggle-project-details"
                            data-project-key="${escapeHTML(group.key)}"
                            aria-label="${escapeHTML(detailOpen ? '收起详情' : '查看详情')}"
                            title="${escapeHTML(detailOpen ? '收起详情' : '查看详情')}"
                          ><span class="project-action-icon" aria-hidden="true">i</span></button>
                          <button
                            type="button"
                            class="project-tree-add secondary project-action-button"
                            data-action="open-inline-project-create"
                            data-project-key="${escapeHTML(group.key)}"
                            aria-label="新建任务"
                            title="新建任务"
                            ${projectSupportsCreate(group.project) ? '' : 'disabled'}
                          ><span class="project-action-icon" aria-hidden="true">+</span></button>
                        </div>
                      </div>
                      ${detailOpen ? `
                        <div class="project-tree-detail-panel">
                          <div class="project-tree-detail-copy">
                            <span class="project-tree-detail-label">项目路径</span>
                            <span class="project-tree-path">${escapeHTML(projectPath)}</span>
                          </div>
                          <div class="project-tree-detail-pills">${detailPills}</div>
                        </div>` : ''}
                      ${open ? `<div class="project-task-list">${itemsHTML}</div>` : ''}
                    </section>`;
                }).join('');

                return `
                  <div class="project-sidebar">
                    <div class="list-summary-bar">${summary}</div>
                    <div class="project-tree-list">${body}</div>
                  </div>`;
              }

              function renderLocalTask(task) {
                const status = localTaskStatusLabel(task);
                const taskID = task?.task?.id || '';
                const tone = taskStatusTone(status);
                const activityAt = task?.lastSeenAt || task?.startedAt || task?.task?.updatedAt || task?.task?.createdAt;
                const activityLabel = isActiveLocalTask(taskID) ? '最近活动' : '最近完成';
                const summary = task.lastAssistantPreview || task.lastUserPrompt || task.cwd || task.runtimeWarning || '当前没有额外摘要。';
                const waitingReply = canContinueLocalTask(task);
                const selectedClass = selectedConversationKind === 'task' && selectedLocalTaskID === taskID ? ' selected' : '';
                const waitingClass = waitingReply ? ' waiting-turn' : '';
                const replyHint = waitingReply ? '<span class="waiting-pill">等你回复</span>' : '';
                const project = taskProjectSummary(task);
                const projectName = projectNameLabel(project, task?.task?.workspaceID || taskID);
                const projectPath = projectPathLabel(project, task?.cwd || task?.task?.relativePath || '');

                return `
                  <article class="item${selectedClass}${waitingClass}" data-task-select="1" data-task-id="${escapeHTML(taskID)}">
                    <div class="item-kicker">
                      <span class="status-dot ${escapeHTML(tone)}"></span>
                      <span>${escapeHTML(status)}</span>
                      <span>${escapeHTML(activityLabel)} ${escapeHTML(formatRelativeTime(activityAt))}</span>
                    </div>
                    <div class="item-project-line">
                      <span class="project-chip">${escapeHTML(projectName)}</span>
                      <span class="project-path">${escapeHTML(projectPath)}</span>
                    </div>
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(task.task?.title || taskID || '未命名任务')}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      <span>${escapeHTML(localTaskDriverLabel(task))}</span>
                      <span>任务 ${escapeHTML(taskID)}</span>
                      ${task.pid ? `<span>PID ${escapeHTML(task.pid)}</span>` : ''}
                      ${task.codexThreadID ? `<span>线程 ${escapeHTML(task.codexThreadID)}</span>` : ''}
                    </div>
                    <p class="item-summary">${escapeHTML(summary)}</p>
                    <div class="item-foot">
                      <span class="hint">${escapeHTML(task.lastSeenAt ? formatDate(task.lastSeenAt) : formatDate(task.startedAt || task.task?.updatedAt || task.task?.createdAt))}</span>
                      ${replyHint}
                    </div>
                  </article>
                `;
              }

              function renderLocalCodexSession(session) {
                const status = statusTitleForSession(session);
                const tone = taskStatusTone(status);
                const summary = session?.lastAssistantMessage || session?.lastUserMessage || session?.preview || session?.cwd || '当前没有额外摘要。';
                const selectedClass = selectedConversationKind === 'codex' && selectedLocalCodexSessionID === session?.id ? ' selected' : '';
                const waitingClass = canContinueLocalCodexSession(session) ? ' waiting-turn' : '';
                const replyHint = canContinueLocalCodexSession(session) ? '<span class="waiting-pill">可继续</span>' : '';
                const activityLabel = isRunningLocalCodexSession(session) ? '最近活动' : '最近停下';
                const project = codexSessionProjectSummary(session);
                const projectName = projectNameLabel(project, session?.workspaceID || session?.id || '未识别项目');
                const projectPath = projectPathLabel(project, session?.cwd || '');

                return `
                  <article class="item${selectedClass}${waitingClass}" data-codex-session-select="1" data-session-id="${escapeHTML(session?.id || '')}">
                    <div class="item-kicker">
                      <span class="status-dot ${escapeHTML(tone)}"></span>
                      <span>${escapeHTML(status)}</span>
                      <span>${escapeHTML(activityLabel)} ${escapeHTML(formatRelativeTime(session?.updatedAt || session?.createdAt))}</span>
                    </div>
                    <div class="item-project-line">
                      <span class="project-chip">${escapeHTML(projectName)}</span>
                      <span class="project-path">${escapeHTML(projectPath)}</span>
                    </div>
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(session?.name || session?.preview || session?.id || '未命名会话')}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      <span>Codex 会话</span>
                      <span>会话 ${escapeHTML(session?.id || '—')}</span>
                      <span>${escapeHTML(session?.source || '本机')}</span>
                    </div>
                    <p class="item-summary">${escapeHTML(summary)}</p>
                    <div class="item-foot">
                      <span class="hint">${escapeHTML(formatDate(session?.updatedAt || session?.createdAt))}</span>
                      ${replyHint}
                    </div>
                  </article>
                `;
              }

              function updateTaskFilterButtons(snapshot) {
                const allTasks = localTaskCollection(snapshot);
                const allCodexSessions = localCodexSessionCollection(snapshot);
                const counts = {
                  all: allTasks.length + allCodexSessions.length,
                  active: (Array.isArray(snapshot?.local?.activeTasks) ? snapshot.local.activeTasks : []).length
                    + allCodexSessions.filter((session) => isRunningLocalCodexSession(session)).length,
                  waiting: allTasks.filter((task) => isActiveLocalTask(task?.task?.id, snapshot) && localTaskStatusKey(task) === 'waitingInput').length
                    + allCodexSessions.filter((session) => canContinueLocalCodexSession(session)).length,
                  recent: allTasks.filter((task) => !isActiveLocalTask(task?.task?.id, snapshot)).length
                    + allCodexSessions.filter((session) => !isRunningLocalCodexSession(session)).length
                };

                taskFilterButtons.forEach((button) => {
                  const filter = button.dataset.taskFilter || 'all';
                  const labels = {
                    all: '全部',
                    active: '进行中',
                    waiting: '等我回复',
                    recent: '最近结束'
                  };
                  button.textContent = `${labels[filter] || filter} ${counts[filter] ?? 0}`;
                  button.classList.toggle('active', filter === localTaskFilter);
                });
              }

              function renderLocalTaskSections(snapshot) {
                const querySuffix = localTaskQuery ? `；当前搜索：${localTaskQuery}` : '';
                const visibleSessions = visibleLocalCodexSessionCollection(snapshot);
                const allCandidates = conversationCandidates(snapshot, true);
                const groupedCandidates = groupedConversationCandidates(allCandidates, snapshot);
                const activeTaskCount = (Array.isArray(snapshot?.local?.activeTasks) ? snapshot.local.activeTasks : [])
                  .filter((task) => taskMatchesFilter(task, localTaskFilter, snapshot) && taskMatchesQuery(task, localTaskQuery))
                  .length;
                const recentTaskCount = (Array.isArray(snapshot?.local?.recentTasks) ? snapshot.local.recentTasks : [])
                  .filter((task) => !isActiveLocalTask(task?.task?.id, snapshot))
                  .filter((task) => taskMatchesFilter(task, localTaskFilter, snapshot) && taskMatchesQuery(task, localTaskQuery))
                  .length;
                const waitingCount = (Array.isArray(snapshot?.local?.activeTasks) ? snapshot.local.activeTasks : [])
                  .filter((task) => localTaskStatusKey(task) === 'waitingInput' && taskMatchesFilter(task, localTaskFilter, snapshot) && taskMatchesQuery(task, localTaskQuery)).length
                  + visibleSessions.filter((session) => canContinueLocalCodexSession(session)).length;

                if (!allCandidates.length) {
                  const emptyMessage = {
                    all: `当前宿主机本地还没有任务或 Codex 会话记录${querySuffix}。`,
                    active: `当前没有进行中的任务或会话${querySuffix}。`,
                    waiting: `当前没有等待你继续的任务或会话${querySuffix}。`,
                    recent: `当前没有最近结束或停下来的任务 / 会话${querySuffix}。`
                  };
                  return `<div class="empty">${escapeHTML(emptyMessage[localTaskFilter] || emptyMessage.all)}</div>`;
                }

                const summaryPills = [
                  `<span class="list-summary-pill accent">可见 ${allCandidates.length}</span>`,
                  `<span class="list-summary-pill">项目 ${groupedCandidates.length}</span>`,
                  `<span class="list-summary-pill">进行中 ${activeTaskCount}</span>`,
                  `<span class="list-summary-pill">最近 ${recentTaskCount}</span>`,
                  waitingCount ? `<span class="list-summary-pill warn">等你继续 ${waitingCount}</span>` : '',
                  visibleSessions.length ? `<span class="list-summary-pill">本机 Codex 会话 ${visibleSessions.length}</span>` : ''
                ].filter(Boolean).join('');

                const renderedItems = groupedCandidates.map((group) => {
                  const projectName = projectNameLabel(group.project);
                  const projectPath = projectPathLabel(group.project);
                  const groupItems = group.items.map((candidate) => {
                    if (candidate.kind === 'task') {
                      return renderLocalTask(localTaskByID(candidate.id, snapshot));
                    }
                    return renderLocalCodexSession(localCodexSessionByID(candidate.id, snapshot));
                  }).join('');
                  const groupPills = [
                    `<span>${group.items.length} 条会话</span>`,
                    group.runningCount ? `<span>进行中 ${group.runningCount}</span>` : '',
                    group.waitingCount ? `<span>等你继续 ${group.waitingCount}</span>` : ''
                  ].filter(Boolean).join('');
                  return `
                    <section class="project-group">
                      <div class="project-group-head">
                        <div class="project-group-copy">
                          <div class="project-group-title">${escapeHTML(projectName)}</div>
                          <div class="project-group-subline">${escapeHTML(projectPath)}</div>
                        </div>
                        <div class="project-group-pills">${groupPills}</div>
                      </div>
                      <div class="item-list">${groupItems}</div>
                    </section>`;
                }).join('');

                return `
                  <div class="conversation-list-shell">
                    <div class="list-summary-bar">${summaryPills}</div>
                    ${renderedItems}
                  </div>`;
              }

              function renderTaskLauncherPanel(snapshot) {
                const visibleCandidates = conversationCandidates(snapshot, true);
                const projectCount = groupedConversationCandidates(visibleCandidates, snapshot).length;
                const runningCount = localRunningConversationCount(snapshot);
                const waitingCount = localWaitingConversationCount(snapshot);
                const codexCount = localCodexSessionCollection(snapshot).length;
                const selectedCandidate = selectedConversationKind === 'codex' && selectedLocalCodexSessionID
                  ? { kind: 'codex', id: selectedLocalCodexSessionID }
                  : selectedConversationKind === 'task' && selectedLocalTaskID
                    ? { kind: 'task', id: selectedLocalTaskID }
                    : visibleCandidates[0] || null;
                const selectedCard = selectedCandidate
                  ? selectedCandidate.kind === 'task'
                    ? renderLocalTask(localTaskByID(selectedCandidate.id, snapshot))
                    : renderLocalCodexSession(localCodexSessionByID(selectedCandidate.id, snapshot))
                  : '';
                const quickCandidates = visibleCandidates
                  .filter((candidate) => !(candidate.kind === selectedCandidate?.kind && candidate.id === selectedCandidate?.id))
                  .slice(0, 2);
                const quickCards = quickCandidates.map((candidate) => {
                  if (candidate.kind === 'task') {
                    return renderLocalTask(localTaskByID(candidate.id, snapshot));
                  }
                  return renderLocalCodexSession(localCodexSessionByID(candidate.id, snapshot));
                }).join('');

                return `
                  <div class="task-launcher-shell">
                    <div class="task-launcher-copy">
                      <h3>任务太多时，只从这里进入</h3>
                      <p>点“打开任务卡片”看完整列表；右边只保留当前选中的会话和执行过程。</p>
                    </div>
                    <div class="list-summary-bar">
                      <span class="list-summary-pill accent">可见 ${visibleCandidates.length}</span>
                      <span class="list-summary-pill">项目 ${projectCount}</span>
                      <span class="list-summary-pill">进行中 ${runningCount}</span>
                      <span class="list-summary-pill">等你继续 ${waitingCount}</span>
                      <span class="list-summary-pill">Codex Session ${codexCount}</span>
                    </div>
                    <div class="task-launcher-actions">
                      <button type="button" data-action="open-task-list-modal">打开任务卡片</button>
                      <button type="button" class="secondary" data-action="open-sidebar-create">新任务</button>
                    </div>
                    ${selectedCard ? `
                      <div class="task-launcher-section">
                        <div class="task-launcher-label">当前选中</div>
                        <div class="item-list">${selectedCard}</div>
                      </div>` : `
                      <div class="task-launcher-hint">当前还没有可选任务；先点“新任务”，或者等本机 Codex Session 刷出来。</div>`}
                    ${quickCards ? `
                      <div class="task-launcher-section">
                        <div class="task-launcher-label">快速切换</div>
                        <div class="item-list">${quickCards}</div>
                      </div>` : ''}
                  </div>`;
              }

              function renderPendingUpdate(update) {
                const status = update.managedRunStatus ? statusTitleForManagedRun(update.managedRunStatus) : statusTitleForTask(update.status);
                return `
                  <article class="item">
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(update.taskID)}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      ${update.exitCode !== null && update.exitCode !== undefined ? `<span>exit ${escapeHTML(update.exitCode)}</span>` : ''}
                      ${update.codexSessionID ? `<span>会话 ${escapeHTML(update.codexSessionID)}</span>` : ''}
                      ${update.pid ? `<span>PID ${escapeHTML(update.pid)}</span>` : ''}
                    </div>
                    <p>${escapeHTML(update.summary || '没有摘要')}</p>
                  </article>
                `;
              }

              function chatBubble(role, label, body, extraContent = '') {
                if (!body && !extraContent) return '';
                return `
                  <article class="chat-bubble ${escapeHTML(role)}">
                    <div class="chat-label">${escapeHTML(label)}</div>
                    ${body ? `<div class="chat-body">${escapeHTML(body)}</div>` : ''}
                    ${extraContent}
                  </article>
                `;
              }

              function renderTaskStatusBanner(task, snapshot = lastPayload) {
                if (!task) return '';
                const status = localTaskStatusKey(task);
                if (!isActiveLocalTask(task?.task?.id, snapshot)) {
                  return `
                    <div class="task-status-banner">
                      <strong>这条任务已经结束</strong>
                      <span>如果还要继续，直接新开一条任务。</span>
                    </div>`;
                }
                if (task?.task?.kind !== 'codex') {
                  return `
                    <div class="task-status-banner">
                      <strong>这是 Shell 任务</strong>
                      <span>这里主要看日志；需要时可以终止。</span>
                    </div>`;
                }
                if (status === 'waitingInput') {
                  return `
                    <div class="task-status-banner waiting">
                      <strong>这条任务正在等你输入</strong>
                      <span>直接在底部输入框继续说，它就会沿着这条任务往下执行。</span>
                    </div>`;
                }
                if (status === 'running') {
                  return `
                    <div class="task-status-banner running">
                      <strong>这条任务正在执行</strong>
                      <span>先看最新执行过程；停到等待输入时再补话。</span>
                    </div>`;
                }
                if (status === 'interrupting' || status === 'stopRequested') {
                  return `
                    <div class="task-status-banner warn">
                      <strong>正在收敛</strong>
                      <span>中断 / 终止已经发出，先等这条任务真正停下来，再决定下一步。</span>
                    </div>`;
                }
                return '';
              }

              function conversationRouteSnapshot({ task = null, session = null, status = '' } = {}) {
                const taskID = task?.task?.id || '';
                const sessionID = session?.id || task?.codexThreadID || '';
                const cwd = session?.cwd || task?.cwd || '';
                const workspaceID = session?.workspaceID || task?.task?.workspaceID || '';
                const project = task ? taskProjectSummary(task) : codexSessionProjectSummary(session);
                const projectName = projectNameLabel(project, workspaceID || cwd);
                const projectPath = projectPathLabel(project, cwd);
                const currentStatus = status || (session ? statusTitleForSession(session) : localTaskStatusLabel(task));
                const destination = taskID
                  ? sessionID
                    ? `任务 ${taskID} -> Codex 会话 ${sessionID}`
                    : `任务 ${taskID}`
                  : sessionID
                    ? `本机 Codex 会话 ${sessionID}`
                    : '当前会话';
                const sublineParts = [
                  projectName ? `项目：${projectName}` : '',
                  cwd ? `执行位置：${cwd}` : '',
                  workspaceID ? `工作区：${workspaceID}` : '',
                  currentStatus ? `当前状态：${currentStatus}` : ''
                ].filter(Boolean);
                const pills = [
                  taskID ? `任务 ${taskID}` : '',
                  sessionID ? `会话 ${sessionID}` : '',
                  projectName ? `项目 ${projectName}` : '',
                  projectPath,
                  workspaceID ? `工作区 ${workspaceID}` : '',
                  currentStatus
                ].filter(Boolean);
                return {
                  destination,
                  subline: sublineParts.join(' · '),
                  pills
                };
              }

              function renderConversationRouteBanner(route) {
                if (!route?.destination) return '';
                return `
                  <section class="conversation-route">
                    <div class="conversation-route-kicker">这条网页消息会发到</div>
                    <div class="conversation-route-headline">${escapeHTML(route.destination)}</div>
                    ${route.subline ? `<div class="conversation-route-subline">${escapeHTML(route.subline)}</div>` : ''}
                    ${route.pills?.length ? `<div class="conversation-route-pills">${route.pills.map((pill) => `<span>${escapeHTML(pill)}</span>`).join('')}</div>` : ''}
                  </section>
                `;
              }

              function progressToneForKind(kind) {
                switch (kind) {
                  case 'commandExecution':
                    return 'command';
                  case 'fileChange':
                    return 'file';
                  case 'reasoning':
                  case 'plan':
                  case 'webSearch':
                    return 'reasoning';
                  default:
                    return '';
                }
              }

              function renderProgressEntry({
                kindLabel = '进展',
                summary = '',
                subtitle = '',
                details = '',
                status = '',
                tone = '',
                open = false,
                entryKey = ''
              } = {}) {
                const resolvedSummary = String(summary || '').trim() || '当前没有更多内容。';
                const resolvedSubtitle = String(subtitle || '').trim();
                const resolvedStatus = String(status || '').trim();
                const resolvedDetails = String(details || '').trim();
                const openAttribute = open ? ' open' : '';
                const entryKeyAttribute = entryKey ? ` data-entry-key="${escapeHTML(entryKey)}"` : '';
                const body = resolvedDetails
                  ? `<div class="progress-body">${resolvedDetails}</div>`
                  : '';
                return `
                  <details class="progress-entry ${escapeHTML(tone)}"${entryKeyAttribute}${openAttribute}>
                    <summary>
                      <span class="progress-kind">${escapeHTML(kindLabel)}</span>
                      <span class="progress-summary">
                        <span class="progress-title">${escapeHTML(resolvedSummary)}</span>
                        ${resolvedSubtitle ? `<span class="progress-subtitle">${escapeHTML(resolvedSubtitle)}</span>` : ''}
                      </span>
                      <span class="progress-state">${escapeHTML(resolvedStatus || '展开')}</span>
                    </summary>
                    ${body}
                  </details>
                `;
              }

              function renderLogTimeline(task) {
                const logLines = Array.isArray(task?.recentLogLines) ? task.recentLogLines : [];
                if (!logLines.length) return '';
                const recentLines = logLines.slice(-80);
                const hiddenLineCount = Math.max(0, logLines.length - recentLines.length);
                const latestLine = recentLines[recentLines.length - 1] || '当前没有更多输出。';
                const subtitle = [
                  task?.pid ? `PID ${task.pid}` : '',
                  hiddenLineCount > 0 ? `前面折叠 ${hiddenLineCount} 行` : `共 ${recentLines.length} 行`
                ].filter(Boolean).join(' · ');
                return renderProgressEntry({
                  kindLabel: '宿主机输出',
                  summary: shortInlineCopy(latestLine, '当前没有更多输出。'),
                  subtitle,
                  status: '展开',
                  tone: 'command',
                  entryKey: `task-log:${task?.task?.id || task?.id || 'unknown'}`,
                  details: `<pre class="terminal-box">${escapeHTML(recentLines.join('\\n'))}</pre>`
                });
              }

              function currentTimelineSignature(task) {
                const logLines = Array.isArray(task?.recentLogLines) ? task.recentLogLines : [];
                const lastLogLine = logLines.length ? logLines[logLines.length - 1] : '';
                return [
                  task?.task?.id || '',
                  localTaskStatusKey(task),
                  logLines.length,
                  lastLogLine,
                  task?.lastAssistantPreview || '',
                  task?.lastUserPrompt || ''
                ].join('||');
              }

              function timelineUsesDocumentScroll(timeline) {
                if (!timeline) return false;
                const style = window.getComputedStyle(timeline);
                const overflowY = style.overflowY || style.overflow || 'visible';
                return overflowY === 'visible' || timeline.scrollHeight <= timeline.clientHeight + 8;
              }

              function timelineNearBottom(timeline) {
                if (!timeline) return true;
                if (timelineUsesDocumentScroll(timeline)) {
                  const rect = timeline.getBoundingClientRect();
                  return rect.bottom <= window.innerHeight + timelineFollowThreshold;
                }
                return timeline.scrollTop + timeline.clientHeight >= timeline.scrollHeight - timelineFollowThreshold;
              }

              function latestTimelineTerminalEntry(timeline = localTaskDetail.querySelector('.task-dialog-timeline')) {
                if (!timeline) return null;
                const entries = Array.from(timeline.querySelectorAll('.progress-entry[data-entry-key]'));
                for (let index = entries.length - 1; index >= 0; index -= 1) {
                  if (entries[index].querySelector('.terminal-box')) {
                    return entries[index];
                  }
                }
                return null;
              }

              function latestTimelineTerminalBox(timeline = localTaskDetail.querySelector('.task-dialog-timeline')) {
                return latestTimelineTerminalEntry(timeline)?.querySelector('.terminal-box') || null;
              }

              function terminalBoxNearBottom(terminalBox) {
                if (!terminalBox) return true;
                return terminalBox.scrollTop + terminalBox.clientHeight >= terminalBox.scrollHeight - 12;
              }

              function refreshLatestTerminalBoxAutoFollow(timeline = localTaskDetail.querySelector('.task-dialog-timeline')) {
                const latestEntry = latestTimelineTerminalEntry(timeline);
                if (!latestEntry) {
                  resetTerminalBoxAutoFollow();
                  return true;
                }
                const entryKey = latestEntry.dataset.entryKey || '';
                const terminalBox = latestEntry.querySelector('.terminal-box');
                if (terminalBoxFollowState.entryKey !== entryKey) {
                  terminalBoxFollowState.entryKey = entryKey;
                  terminalBoxFollowState.autoFollow = true;
                  return true;
                }
                terminalBoxFollowState.autoFollow = terminalBoxNearBottom(terminalBox);
                return terminalBoxFollowState.autoFollow;
              }

              function lockTimelineAutoFollowForProgrammaticScroll() {
                programmaticTimelineScroll.active = true;
                if (programmaticTimelineScroll.timer) {
                  window.clearTimeout(programmaticTimelineScroll.timer);
                }
                programmaticTimelineScroll.timer = window.setTimeout(() => {
                  programmaticTimelineScroll.active = false;
                  programmaticTimelineScroll.timer = null;
                }, 180);
              }

              function resetDetailRenderCache() {
                detailRenderCache.key = '';
                detailRenderCache.frameSignature = '';
                detailRenderCache.timelineMarkup = '';
              }

              function rememberDetailRender(key, frameSignature, timelineMarkup = '') {
                detailRenderCache.key = String(key || '');
                detailRenderCache.frameSignature = String(frameSignature || '');
                detailRenderCache.timelineMarkup = String(timelineMarkup || '');
              }

              function resetTerminalBoxAutoFollow() {
                terminalBoxFollowState.entryKey = '';
                terminalBoxFollowState.autoFollow = true;
              }

              function timelineMarkupNodeKey(node) {
                if (!node || node.nodeType !== Node.ELEMENT_NODE) {
                  return '';
                }
                if (node.dataset?.entryKey) {
                  return `entry:${node.dataset.entryKey}`;
                }
                if (node.classList.contains('timeline-strip')) {
                  return 'timeline-strip';
                }
                if (node.classList.contains('progress-feed')) {
                  return 'progress-feed';
                }
                if (node.classList.contains('task-dialog-empty')) {
                  return 'task-dialog-empty';
                }
                if (node.classList.contains('notice')) {
                  return `notice:${node.className}`;
                }
                return '';
              }

              function timelineMarkupNodesCompatible(currentNode, nextNode) {
                if (!currentNode || !nextNode || currentNode.nodeType !== nextNode.nodeType) {
                  return false;
                }
                if (currentNode.nodeType === Node.TEXT_NODE) {
                  return true;
                }
                if (currentNode.nodeType !== Node.ELEMENT_NODE) {
                  return false;
                }
                return currentNode.tagName === nextNode.tagName;
              }

              function syncTimelineElementAttributes(target, source) {
                const preserveUserOpenState = target.tagName === 'DETAILS' && target.hasAttribute('data-entry-key');
                const userOpenState = preserveUserOpenState ? (target.dataset.userOpenState || '') : '';
                const sourceAttributeNames = new Set(source.getAttributeNames());

                Array.from(target.getAttributeNames()).forEach((name) => {
                  if (preserveUserOpenState && (name === 'open' || name === 'data-user-open-state')) {
                    return;
                  }
                  if (!sourceAttributeNames.has(name)) {
                    target.removeAttribute(name);
                  }
                });

                source.getAttributeNames().forEach((name) => {
                  if (preserveUserOpenState && name === 'open') {
                    return;
                  }
                  const nextValue = source.getAttribute(name) || '';
                  if (target.getAttribute(name) !== nextValue) {
                    target.setAttribute(name, nextValue);
                  }
                });

                if (!preserveUserOpenState) {
                  return;
                }

                if (userOpenState) {
                  target.dataset.userOpenState = userOpenState;
                } else {
                  delete target.dataset.userOpenState;
                }

                const shouldBeOpen = userOpenState
                  ? userOpenState === 'open'
                  : source.hasAttribute('open');
                if (shouldBeOpen) {
                  target.setAttribute('open', '');
                } else {
                  target.removeAttribute('open');
                }
              }

              function syncTimelineDOMNode(target, source) {
                if (!timelineMarkupNodesCompatible(target, source)) {
                  target.replaceWith(source.cloneNode(true));
                  return;
                }
                if (target.nodeType === Node.TEXT_NODE) {
                  if (target.textContent !== source.textContent) {
                    target.textContent = source.textContent;
                  }
                  return;
                }
                if (!(target instanceof Element) || !(source instanceof Element)) {
                  return;
                }
                syncTimelineElementAttributes(target, source);
                if (target.tagName === 'PRE' && target.classList.contains('terminal-box')) {
                  if (target.textContent !== source.textContent) {
                    target.textContent = source.textContent || '';
                  }
                  return;
                }
                syncTimelineChildList(target, source);
              }

              function syncTimelineChildList(target, source) {
                const keyedExistingNodes = new Map();
                Array.from(target.childNodes).forEach((node) => {
                  const key = timelineMarkupNodeKey(node);
                  if (key && !keyedExistingNodes.has(key)) {
                    keyedExistingNodes.set(key, node);
                  }
                });

                let cursor = target.firstChild;
                Array.from(source.childNodes).forEach((sourceNode) => {
                  const sourceKey = timelineMarkupNodeKey(sourceNode);
                  let match = null;

                  if (sourceKey) {
                    match = keyedExistingNodes.get(sourceKey) || null;
                    keyedExistingNodes.delete(sourceKey);
                  } else if (cursor && !timelineMarkupNodeKey(cursor) && timelineMarkupNodesCompatible(cursor, sourceNode)) {
                    match = cursor;
                  } else if (cursor && timelineMarkupNodesCompatible(cursor, sourceNode)) {
                    match = cursor;
                  }

                  if (!match) {
                    match = sourceNode.cloneNode(true);
                    target.insertBefore(match, cursor);
                  } else if (match !== cursor) {
                    target.insertBefore(match, cursor);
                  }

                  syncTimelineDOMNode(match, sourceNode);
                  cursor = match.nextSibling;
                });

                while (cursor) {
                  const next = cursor.nextSibling;
                  target.removeChild(cursor);
                  cursor = next;
                }
              }

              function patchTimelineMarkup(timeline, timelineMarkup) {
                if (!timeline) {
                  return false;
                }
                const template = document.createElement('template');
                template.innerHTML = String(timelineMarkup || '');
                suppressProgressEntryToggleTracking = true;
                try {
                  syncTimelineChildList(timeline, template.content);
                } finally {
                  suppressProgressEntryToggleTracking = false;
                }
                return true;
              }

              function patchExistingDetailTimeline(key, frameSignature, timelineMarkup, formSelector) {
                const normalizedKey = String(key || '');
                const normalizedFrame = String(frameSignature || '');
                const normalizedTimeline = String(timelineMarkup || '');
                if (
                  detailRenderCache.key !== normalizedKey
                  || detailRenderCache.frameSignature !== normalizedFrame
                ) {
                  return false;
                }
                if (!localTaskDetail.querySelector(formSelector)) {
                  return false;
                }
                const timeline = localTaskDetail.querySelector('.task-dialog-timeline');
                if (!timeline) {
                  return false;
                }
                if (detailRenderCache.timelineMarkup === normalizedTimeline) {
                  return true;
                }
                patchTimelineMarkup(timeline, normalizedTimeline);
                detailRenderCache.timelineMarkup = normalizedTimeline;
                return true;
              }

              function disconnectTimelineContentObserver() {
                if (timelineContentObserver.observer) {
                  timelineContentObserver.observer.disconnect();
                }
                timelineContentObserver.timeline = null;
                timelineContentObserver.content = null;
                timelineContentObserver.observer = null;
              }

              function bindTimelineContentObserver(timeline) {
                if (!timeline || typeof ResizeObserver === 'undefined') {
                  disconnectTimelineContentObserver();
                  return;
                }
                const content = timeline.firstElementChild || timeline;
                if (
                  timelineContentObserver.timeline === timeline
                  && timelineContentObserver.content === content
                  && timelineContentObserver.observer
                ) {
                  return;
                }
                disconnectTimelineContentObserver();
                const observer = new ResizeObserver(() => {
                  if (!timelineAutoFollow) return;
                  scrollConversationViewportToLatest({ force: true });
                });
                observer.observe(content);
                timelineContentObserver.timeline = timeline;
                timelineContentObserver.content = content;
                timelineContentObserver.observer = observer;
              }

              function refreshTimelineAutoFollow(timeline = localTaskDetail.querySelector('.task-dialog-timeline')) {
                if (!timeline) {
                  timelineAutoFollow = true;
                  timelineAutoFollowPaused = false;
                  return;
                }
                if (timelineAutoFollowPaused) {
                  timelineAutoFollow = false;
                  return;
                }
                timelineAutoFollow = timelineNearBottom(timeline);
              }

              function resumeTimelineAutoFollow() {
                timelineAutoFollowPaused = false;
                timelineAutoFollow = true;
              }

              function pauseTimelineAutoFollow() {
                timelineAutoFollowPaused = true;
                timelineAutoFollow = false;
                pendingTimelineRestore.state = null;
              }

              function captureTimelineViewportBeforeRender() {
                const timeline = localTaskDetail.querySelector('.task-dialog-timeline');
                if (!timeline) {
                  pendingTimelineRestore.state = null;
                  return;
                }
                refreshLatestTerminalBoxAutoFollow(timeline);
                if (!timelineAutoFollowPaused) {
                  refreshTimelineAutoFollow(timeline);
                }
                pendingTimelineRestore.state = {
                  timelineID: lastTimelineTaskID,
                  autoFollow: timelineAutoFollow,
                  usesDocumentScroll: timelineUsesDocumentScroll(timeline),
                  scrollTop: timeline.scrollTop,
                  viewportOffset: timeline.getBoundingClientRect().top
                };
              }

              function restoreTimelineViewportAfterRender(timeline, timelineID) {
                const state = pendingTimelineRestore.state;
                pendingTimelineRestore.state = null;
                if (!timeline || !state || state.timelineID !== timelineID) {
                  return false;
                }
                timelineAutoFollow = state.autoFollow;
                if (state.autoFollow) {
                  return true;
                }

                requestAnimationFrame(() => {
                  if (state.usesDocumentScroll || timelineUsesDocumentScroll(timeline)) {
                    const absoluteTop = timeline.getBoundingClientRect().top + window.scrollY;
                    window.scrollTo({
                      top: Math.max(0, absoluteTop - state.viewportOffset),
                      behavior: 'auto'
                    });
                  } else {
                    const maxTop = Math.max(0, timeline.scrollHeight - timeline.clientHeight);
                    timeline.scrollTop = Math.max(0, Math.min(state.scrollTop, maxTop));
                  }
                });
                return true;
              }

              function bindTaskTimelineTracking(options = {}) {
                const timeline = localTaskDetail.querySelector('.task-dialog-timeline');
                if (!timeline) {
                  disconnectTimelineContentObserver();
                  return timeline;
                }
                if (timeline.dataset.bound !== '1') {
                  timeline.dataset.bound = '1';
                  timeline.addEventListener('wheel', (event) => {
                    if (programmaticTimelineScroll.active) return;
                    const target = event.target instanceof Element ? event.target : null;
                    if (target?.closest('.terminal-box')) return;
                    pauseTimelineAutoFollow();
                  }, { passive: true });
                  timeline.addEventListener('touchmove', (event) => {
                    if (programmaticTimelineScroll.active) return;
                    const target = event.target instanceof Element ? event.target : null;
                    if (target?.closest('.terminal-box')) return;
                    pauseTimelineAutoFollow();
                  }, { passive: true });
                  timeline.addEventListener('scroll', () => {
                    if (programmaticTimelineScroll.active) return;
                    if (timelineAutoFollowPaused) {
                      timelineAutoFollow = false;
                      return;
                    }
                    refreshTimelineAutoFollow(timeline);
                  });
                }
                if (!options.skipRefresh && !timelineAutoFollowPaused) {
                  refreshTimelineAutoFollow(timeline);
                }
                Array.from(timeline.querySelectorAll('.terminal-box')).forEach((terminalBox) => {
                  if (terminalBox.dataset.followBound === '1') {
                    return;
                  }
                  terminalBox.dataset.followBound = '1';
                  terminalBox.addEventListener('scroll', () => {
                    if (programmaticTimelineScroll.active) return;
                    const latestEntry = latestTimelineTerminalEntry(timeline);
                    const latestEntryKey = latestEntry?.dataset.entryKey || '';
                    const entryKey = terminalBox.closest('.progress-entry[data-entry-key]')?.dataset.entryKey || '';
                    const nearBottom = terminalBox.scrollTop + terminalBox.clientHeight >= terminalBox.scrollHeight - 12;
                    if (entryKey && latestEntryKey === entryKey) {
                      terminalBoxFollowState.entryKey = entryKey;
                      terminalBoxFollowState.autoFollow = nearBottom;
                    }
                    if (nearBottom) {
                      if (!timelineAutoFollowPaused) {
                        refreshTimelineAutoFollow(timeline);
                      }
                      return;
                    }
                    pauseTimelineAutoFollow();
                  });
                });
                bindTimelineContentObserver(timeline);
                return timeline;
              }

              function scrollConversationViewportToLatest(options = {}) {
                const force = Boolean(options.force);
                if (!force && !timelineAutoFollow) return;

                requestAnimationFrame(() => {
                  requestAnimationFrame(() => {
                    const activeTimeline = localTaskDetail.querySelector('.task-dialog-timeline');
                    if (!activeTimeline) return;
                    const behavior = 'auto';
                    lockTimelineAutoFollowForProgrammaticScroll();

                    if (timelineUsesDocumentScroll(activeTimeline)) {
                      const latestEntry = activeTimeline.lastElementChild || activeTimeline;
                      latestEntry.scrollIntoView({ behavior: behavior, block: 'end' });
                    } else {
                      activeTimeline.scrollTo({ top: activeTimeline.scrollHeight, behavior: behavior });
                    }
                    timelineAutoFollow = true;
                    if (force) {
                      timelineAutoFollowPaused = false;
                    }

                    const latestTerminalEntry = latestTimelineTerminalEntry(activeTimeline);
                    const latestTerminalKey = latestTerminalEntry?.dataset.entryKey || '';
                    const latestTerminalBox = latestTimelineTerminalBox(activeTimeline);
                    if (latestTerminalKey && terminalBoxFollowState.entryKey !== latestTerminalKey) {
                      terminalBoxFollowState.entryKey = latestTerminalKey;
                      terminalBoxFollowState.autoFollow = true;
                    }
                    if (latestTerminalBox && (force || terminalBoxFollowState.autoFollow)) {
                      latestTerminalBox.scrollTop = latestTerminalBox.scrollHeight;
                      terminalBoxFollowState.entryKey = latestTerminalKey;
                      terminalBoxFollowState.autoFollow = true;
                    }
                  });
                });
              }

              function syncTaskTimeline(task) {
                if (!task) {
                  lastTimelineTaskID = null;
                  lastTimelineSignature = '';
                  timelineAutoFollow = true;
                  timelineAutoFollowPaused = false;
                  pendingTimelineRestore.state = null;
                  disconnectTimelineContentObserver();
                  resetTerminalBoxAutoFollow();
                  resetDetailRenderCache();
                  return;
                }
                syncTimeline(`task:${task?.task?.id || ''}`, currentTimelineSignature(task));
              }

              function syncTimeline(timelineID, signature) {
                const taskChanged = timelineID !== lastTimelineTaskID;
                const contentChanged = signature !== lastTimelineSignature;
                const shouldRestoreViewport = !taskChanged && pendingTimelineRestore.state?.timelineID === timelineID;
                const timeline = bindTaskTimelineTracking({ skipRefresh: shouldRestoreViewport });
                if (taskChanged) {
                  timelineAutoFollow = true;
                  timelineAutoFollowPaused = false;
                  resetTerminalBoxAutoFollow();
                }
                if (shouldRestoreViewport) {
                  restoreTimelineViewportAfterRender(timeline, timelineID);
                } else {
                  pendingTimelineRestore.state = null;
                }
                if (timeline && (taskChanged || contentChanged) && timelineAutoFollow) {
                  scrollConversationViewportToLatest({ force: taskChanged });
                }
                lastTimelineTaskID = timelineID;
                lastTimelineSignature = signature;
              }

              function currentCodexSessionTimelineSignature(detail) {
                const items = Array.isArray(detail?.items) ? detail.items : [];
                const lastItem = items.length ? items[items.length - 1] : null;
                return [
                  detail?.session?.id || '',
                  detail?.session?.updatedAt || '',
                  items.length,
                  lastItem?.id || '',
                  lastItem?.status || '',
                  lastItem?.body || ''
                ].join('||');
              }

              function currentTaskConversationTimelineSignature(task, detail = null) {
                const taskSignature = currentTimelineSignature(task);
                if (!detail?.session?.id) {
                  return taskSignature;
                }
                return `${taskSignature}##${currentCodexSessionTimelineSignature(detail)}`;
              }

              function syncTaskConversationTimeline(task, detail = null) {
                if (!task?.task?.id) {
                  syncTaskTimeline(null);
                  return;
                }
                syncTimeline(`task:${task.task.id}`, currentTaskConversationTimelineSignature(task, detail));
              }

              function syncLocalCodexSessionTimeline(detail) {
                if (!detail?.session?.id) {
                  syncTaskTimeline(null);
                  return;
                }
                syncTimeline(`codex:${detail.session.id}`, currentCodexSessionTimelineSignature(detail));
              }

              function renderManagedCodexTaskTimeline(task, detail, route) {
                const taskID = task?.task?.id || '';
                const acknowledgedBodies = [task?.lastUserPrompt || ''];
                if (detail?.items) {
                  return renderLocalCodexTimeline(detail, {
                    route,
                    logTask: task,
                    pendingKind: 'task',
                    pendingID: taskID,
                    acknowledgedBodies
                  });
                }

                const pendingEntries = pendingConversationEntries('task', taskID, acknowledgedBodies);
                const parts = [
                  renderExecutionSummaryStrip([], pendingEntries, task?.managedRunStatus === 'running', {
                    logLines: task?.recentLogLines || []
                  }),
                  detail?.errorMessage ? `<div class="notice error">${escapeHTML(detail.errorMessage)}</div>` : '',
                  `<div class="progress-feed">
                    ${renderLogTimeline(task)}
                    ${task?.runtimeWarning ? renderProgressEntry({
                      kindLabel: '运行告警',
                      summary: shortInlineCopy(task.runtimeWarning, '运行告警'),
                      subtitle: '点开看完整告警',
                      status: '提醒',
                      tone: 'warn',
                      entryKey: `task-warning:${taskID}`,
                      details: `<div class="progress-body-copy">${escapeHTML(task.runtimeWarning)}</div>`
                    }) : ''}
                    ${pendingEntries.map((entry) => renderPendingConversationBubble(entry, route)).join('')}
                  </div>`
                ].filter(Boolean);

                if (!parts.length || (parts.length === 2 && !task?.recentLogLines?.length && !pendingEntries.length)) {
                  parts.push('<div class="task-dialog-empty">正在读取这条任务关联的 Codex 会话详情…</div>');
                }
                return parts.join('');
              }

              async function fetchJSON(url) {
                const response = await fetch(url, { cache: 'no-store' });
                const text = await response.text();
                let payload = null;
                if (text) {
                  try {
                    payload = JSON.parse(text);
                  } catch {
                    payload = { error: text };
                  }
                }
                if (!response.ok) {
                  throw new Error(payload?.error || payload?.message || `HTTP ${response.status}`);
                }
                return payload;
              }

              function requestLocalCodexSessionDetail(sessionID, force = false) {
                if (!sessionID || !hasLocalCodexControl) return Promise.resolve(null);
                const summary = localCodexSessionByID(sessionID, lastPayload);
                const cached = localCodexSessionDetails.get(sessionID);
                const inflight = localCodexSessionRequests.get(sessionID);
                const summaryUpdatedAt = parseTimestamp(summary?.updatedAt);
                const cachedUpdatedAt = parseTimestamp(cached?.session?.updatedAt);

                if (!force && cached && cachedUpdatedAt >= summaryUpdatedAt) {
                  return Promise.resolve(cached);
                }
                if (inflight) {
                  return inflight;
                }

                const request = fetchJSON(`/api/local-codex-sessions/${encodeURIComponent(sessionID)}`)
                  .then((detail) => {
                    localCodexSessionDetails.set(sessionID, detail);
                    return detail;
                  })
                  .catch((error) => {
                    localCodexSessionDetails.set(sessionID, {
                      errorMessage: error.message || String(error),
                      session: summary || { id: sessionID }
                    });
                    throw error;
                  })
                  .finally(() => {
                    localCodexSessionRequests.delete(sessionID);
                  });

                localCodexSessionRequests.set(sessionID, request);
                return request.then((detail) => {
                  const selectedTaskSessionID = selectedLocalTaskCodexSessionID(lastPayload);
                  if (
                    lastPayload &&
                    (
                      (selectedConversationKind === 'codex' && selectedLocalCodexSessionID === sessionID)
                      || (selectedConversationKind === 'task' && selectedTaskSessionID === sessionID)
                    )
                  ) {
                    renderSelectedLocalTaskDetail(lastPayload);
                  }
                  return detail;
                }).catch((error) => {
                  const selectedTaskSessionID = selectedLocalTaskCodexSessionID(lastPayload);
                  if (
                    lastPayload &&
                    (
                      (selectedConversationKind === 'codex' && selectedLocalCodexSessionID === sessionID)
                      || (selectedConversationKind === 'task' && selectedTaskSessionID === sessionID)
                    )
                  ) {
                    renderSelectedLocalTaskDetail(lastPayload);
                  }
                  throw error;
                });
              }

              function localCodexSessionDialogHint(session) {
                if (!session) {
                  return '先从左边选一条本机 Codex 会话，这里就会切到它的真实对话内容。';
                }
                if (isRunningLocalCodexSession(session)) {
                  return '这条会话还在执行中；先看下面的最新过程，需要时再点中断。';
                }
                if (canContinueLocalCodexSession(session)) {
                  return '这条会话已经停在等待输入；直接在底部输入框补一句即可继续。';
                }
                return '这里主要用来回看整条会话；如果要继续，也可以直接在底部再发一句。';
              }

              function renderLocalCodexSessionStatusBanner(session) {
                if (!session) return '';
                if (isRunningLocalCodexSession(session)) {
                  return `
                    <div class="task-status-banner running">
                      <strong>这条会话正在执行</strong>
                      <span>先观察下面的最新执行过程；需要时可以点中断。</span>
                    </div>`;
                }
                if (canContinueLocalCodexSession(session)) {
                  return `
                    <div class="task-status-banner waiting">
                      <strong>这条会话正在等你输入</strong>
                      <span>直接在底部输入框补一句，它会沿着这条会话继续。</span>
                    </div>`;
                }
                return `
                  <div class="task-status-banner">
                    <strong>这条会话当前主要用于回看</strong>
                    <span>如果需要继续，也可以直接在底部输入框再发一句。</span>
                  </div>`;
              }

              function codexItemKindLabel(kind) {
                switch (kind) {
                  case 'userMessage': return '你刚发送';
                  case 'agentMessage': return 'Codex 回复';
                  case 'plan': return '计划';
                  case 'reasoning': return '推理';
                  case 'commandExecution': return '命令执行';
                  case 'fileChange': return '文件改动';
                  case 'webSearch': return '网页搜索';
                  default: return '事件';
                }
              }

              function renderPendingConversationBubble(entry, route = null) {
                if (!entry?.body) return '';
                const label = route?.destination
                  ? `已发送到 ${route.destination}`
                  : '刚发送';
                const meta = route?.subline
                  ? `${route.subline} · 等待 OrchardAgent 把这句真正送进会话并回显执行过程…`
                  : '等待 OrchardAgent 把这句真正送进会话并回显执行过程…';
                return renderProgressEntry({
                  kindLabel: '刚发送',
                  summary: shortInlineCopy(entry.body, '等待发送内容'),
                  subtitle: label,
                  status: '等待回显',
                  tone: 'pending',
                  open: true,
                  entryKey: entry?.id ? `pending:${entry.id}` : '',
                  details: `<div class="progress-body-copy">${escapeHTML(entry.body)}</div><div class="progress-body-copy">${escapeHTML(meta)}</div>`
                });
              }

              function progressSummaryForItem(item) {
                if (!item) return '当前没有更多内容。';
                switch (item.kind) {
                  case 'commandExecution':
                  case 'other':
                    return latestInlineCopy(item.body || item.title, shortInlineCopy(item.title, '当前没有更多内容。'));
                  case 'fileChange':
                    return shortInlineCopy(item.body || item.title, '当前没有更多内容。');
                  case 'userMessage':
                  case 'agentMessage':
                  case 'plan':
                  case 'reasoning':
                  case 'webSearch':
                  default:
                    return shortInlineCopy(item.body || item.title, '当前没有更多内容。');
                }
              }

              function renderExecutionSummaryStrip(items, pendingEntries = [], isRunning = false, options = {}) {
                const executionItems = items.filter((item) => ['commandExecution', 'fileChange', 'reasoning', 'plan', 'webSearch', 'other'].includes(item?.kind));
                const latestExecution = executionItems.length ? executionItems[executionItems.length - 1] : null;
                const logLines = Array.isArray(options?.logLines) ? options.logLines : [];
                const chips = [];
                if (isRunning) {
                  chips.push('<span class="timeline-chip active">实时执行中</span>');
                }
                if (pendingEntries.length) {
                  chips.push(`<span class="timeline-chip warn">刚发送 ${pendingEntries.length} 条</span>`);
                }
                if (logLines.length) {
                  chips.push(`<span class="timeline-chip">宿主机输出 ${logLines.length} 行</span>`);
                }
                if (latestExecution) {
                  chips.push(`<span class="timeline-chip">最新步骤 · ${escapeHTML(codexItemKindLabel(latestExecution.kind))}</span>`);
                  const latestSummary = progressSummaryForItem(latestExecution);
                  if (latestSummary) {
                    chips.push(`<span class="timeline-chip">${escapeHTML(latestSummary)}</span>`);
                  }
                } else if (logLines.length) {
                  chips.push(`<span class="timeline-chip">${escapeHTML(shortInlineCopy(logLines[logLines.length - 1], '正在等待最新输出'))}</span>`);
                } else if (!pendingEntries.length) {
                  chips.push('<span class="timeline-chip">暂时还没拿到执行项</span>');
                }
                return `<div class="timeline-strip">${chips.join('')}</div>`;
              }

              function renderLocalCodexTimelineItem(item, options = {}) {
                if (!item) return '';
                const isCommandLike = item.kind === 'commandExecution' || item.kind === 'fileChange' || item.kind === 'other';
                const isNarrative = item.kind === 'plan' || item.kind === 'reasoning' || item.kind === 'webSearch';
                const detailsHTML = isCommandLike
                  ? `<pre class="terminal-box">${escapeHTML(item.body || item.title || '当前没有更多输出。')}</pre>`
                  : item.body
                    ? `<div class="progress-body-copy">${escapeHTML(item.body)}</div>`
                    : item.title
                      ? `<div class="progress-body-copy">${escapeHTML(item.title)}</div>`
                      : '';
                const subtitle = item.kind === 'userMessage'
                  ? '你发给这条任务的话'
                  : item.kind === 'agentMessage'
                    ? 'Codex 最新回复'
                    : isNarrative
                      ? '点击可展开完整内容'
                      : '点击可看完整输出';
                return renderProgressEntry({
                  kindLabel: codexItemKindLabel(item.kind),
                  summary: progressSummaryForItem(item),
                  subtitle,
                  status: item.status || (options.open ? '最新' : '展开'),
                  tone: progressToneForKind(item.kind),
                  open: Boolean(options.open),
                  entryKey: item?.id ? `codex:${item.id}` : `codex-seq:${item?.turnID || 'turn'}:${item?.sequence ?? 0}`,
                  details: detailsHTML
                });
              }

              function renderLocalCodexTimeline(detail, options = {}) {
                const items = Array.isArray(detail?.items) ? detail.items : [];
                const sessionID = detail?.session?.id || '';
                const acknowledgedBodies = [
                  ...items
                    .filter((item) => item?.kind === 'userMessage')
                    .map((item) => item?.body || ''),
                  ...(Array.isArray(options?.acknowledgedBodies) ? options.acknowledgedBodies : [])
                ]
                  .map((body) => String(body || '').trim())
                  .filter(Boolean);
                const pendingEntries = pendingConversationEntries(
                  options?.pendingKind || 'codex',
                  options?.pendingID || sessionID,
                  acknowledgedBodies
                );
                const logTimeline = options?.logTask ? renderLogTimeline(options.logTask) : '';
                const summaryStrip = renderExecutionSummaryStrip(
                  items,
                  pendingEntries,
                  isRunningLocalCodexSession(detail?.session),
                  { logLines: options?.logTask?.recentLogLines || [] }
                );
                if (!items.length && !pendingEntries.length && !logTimeline) {
                  return '<div class="task-dialog-empty">这条会话当前还没有可展示的消息或执行项。</div>';
                }
                return [
                  summaryStrip,
                  `<div class="progress-feed">
                    ${items.map((item, index) => renderLocalCodexTimelineItem(item, { open: index === items.length - 1 })).join('')}
                    ${logTimeline}
                    ${pendingEntries.map((entry) => renderPendingConversationBubble(entry, options?.route)).join('')}
                  </div>`
                ].filter(Boolean).join('');
              }

              function renderSelectedLocalCodexSessionDetail(snapshot) {
                const session = localCodexSessionByID(selectedLocalCodexSessionID, snapshot);
                if (!session) {
                  localTaskDetail.innerHTML = `
                    <div class="task-dialog-empty">
                      <strong>这条 Codex 会话暂时不在列表里</strong>
                      <div>可能刚结束、已被新的筛选隐藏，或者下一次刷新后会重新出现。</div>
                    </div>`;
                  syncTaskTimeline(null);
                  return;
                }

                const detail = localCodexSessionDetails.get(session.id);
                const effectiveSession = detail?.session || session;
                const status = statusTitleForSession(effectiveSession);
                const detailStale = isRunningLocalCodexSession(effectiveSession)
                  || parseTimestamp(session?.updatedAt) > parseTimestamp(detail?.session?.updatedAt)
                  || parseTimestamp(effectiveSession?.updatedAt) > parseTimestamp(detail?.session?.updatedAt);
                if (detailStale) {
                  requestLocalCodexSessionDetail(session.id, true);
                }
                const actions = [];
                actions.push(actionButton('刷新内容', 'refresh-local-codex-session', { sessionId: session.id }, 'secondary', hasLocalCodexControl));
                if (canInterruptLocalCodexSession(effectiveSession)) {
                  actions.push(actionButton('中断', 'interrupt-local-codex-session', { sessionId: session.id }, 'secondary', hasLocalCodexControl));
                }

                const composerEnabled = hasLocalCodexControl && Boolean(session.id) && !isRunningLocalCodexSession(effectiveSession);
                const composerDisabled = composerEnabled ? '' : ' disabled';
                const composerHint = !hasLocalCodexControl
                  ? '当前状态页还没有接通本机 Codex 会话桥接，所以这里只能看。'
                  : isRunningLocalCodexSession(effectiveSession)
                    ? '它还在执行，先观察；停下来后再继续追问。'
                    : '直接在这里继续这条本机会话。';
                const subtitle = effectiveSession.lastAssistantMessage || effectiveSession.lastUserMessage || effectiveSession.preview || effectiveSession.cwd || '这里会持续显示这条 Codex 本机会话的真实内容。';
                const detailError = detail?.errorMessage;
                const draftValue = conversationDraftValue('codex', session.id);
                const route = conversationRouteSnapshot({ task: null, session: effectiveSession, status });
                const project = codexSessionProjectSummary(effectiveSession);
                const timelineHTML = detail?.items
                  ? renderLocalCodexTimeline(detail, {
                    route,
                    pendingKind: 'codex',
                    pendingID: session.id
                  })
                  : detailError
                    ? `${renderConversationRouteBanner(route)}<div class="notice error">${escapeHTML(detailError)}</div>`
                    : `${renderConversationRouteBanner(route)}<div class="task-dialog-empty">正在读取这条 Codex 会话的详细内容…</div>`;
                const detailRenderKey = `codex:${session.id}`;
                const frameSignature = [
                  status,
                  actions.join('||'),
                  composerDisabled,
                  composerHint,
                  draftValue
                ].join('||');

                updateTaskStageHeader({
                  kicker: 'Codex Session',
                  title: effectiveSession.name || effectiveSession.preview || effectiveSession.id,
                  subtitle: shortInlineCopy(subtitle, '选中这条 Codex 会话后，这里显示最关键的状态和最新过程。'),
                  badge: status,
                  meta: [
                    projectNameLabel(project, effectiveSession.workspaceID || '项目'),
                    projectPathLabel(project, effectiveSession.cwd || ''),
                    formatRelativeTime(effectiveSession.updatedAt || effectiveSession.createdAt)
                  ]
                });

                const patched = patchExistingDetailTimeline(
                  detailRenderKey,
                  frameSignature,
                  timelineHTML,
                  'form[data-form="local-codex-session-dialog"]'
                );
                if (!patched) {
                  localTaskDetail.innerHTML = `
                    <div class="task-dialog-shell">
                      <section class="dialog-section fill">
                        <div class="dialog-section-head">
                          <div class="section-marker">当前进展</div>
                          <div class="task-dialog-toolbar-actions">${actions.join('')}</div>
                        </div>
                        <div class="dialog-section-body">
                          <div class="task-dialog-timeline">${timelineHTML}</div>
                        </div>
                      </section>

                      <section class="dialog-section compact">
                        <form class="task-dialog-composer compact" data-form="local-codex-session-dialog" data-session-id="${escapeHTML(session.id)}">
                          <div class="composer-inline">
                            <span class="composer-kicker">继续输入</span>
                            <input name="prompt" type="text" value="${escapeHTML(draftValue)}" placeholder="${escapeHTML(composerHint || '直接继续这条会话')}">
                            <span class="composer-actions">
                              ${canInterruptLocalCodexSession(effectiveSession) ? `<button type="button" class="secondary" data-action="interrupt-local-codex-session" data-session-id="${escapeHTML(session.id)}">中断</button>` : ''}
                              <button type="submit"${composerDisabled}>发送</button>
                            </span>
                          </div>
                        </form>
                      </section>
                    </div>`;
                }
                rememberDetailRender(detailRenderKey, frameSignature, timelineHTML);

                if (detail?.items) {
                  syncLocalCodexSessionTimeline(detail);
                } else {
                  syncTaskTimeline(null);
                  requestLocalCodexSessionDetail(session.id);
                }
              }

              function renderInlineCreateProgress(draft, snapshot = lastPayload) {
                const project = inlineCreateProject(snapshot) || draft?.project;
                const projectName = projectNameLabel(project, draft?.workspaceID || '项目');
                const projectPath = projectPathLabel(project);
                return `
                  <div class="progress-feed">
                    ${renderProgressEntry({
                      kindLabel: '准备开始',
                      summary: `将从 ${projectName} 发起新任务`,
                      subtitle: projectPath,
                      status: '待发送',
                      open: true,
                      entryKey: 'inline-create-start',
                      details: '<div class="progress-body-copy">先在底部输入一句任务说明。点击“发起任务”后，右边会自动切到真实执行过程。</div>'
                    })}
                    ${renderProgressEntry({
                      kindLabel: '当前输入',
                      summary: shortInlineCopy(draft?.prompt, '还没有输入任务说明'),
                      subtitle: draft?.prompt ? '继续补充后点击“发起任务”' : '等你在底部输入第一句',
                      status: draft?.prompt ? '可发起' : '待填写',
                      entryKey: 'inline-create-draft',
                      details: draft?.prompt ? `<div class="progress-body-copy">${escapeHTML(draft.prompt)}</div>` : ''
                    })}
                  </div>`;
              }

              function renderInlineCreateComposer(snapshot) {
                const draft = inlineCreateDraft;
                const project = inlineCreateProject(snapshot);
                if (!draft || !project) {
                  return renderTaskStartComposer(snapshot);
                }

                const projectName = projectNameLabel(project, draft.workspaceID || '项目');
                const projectPath = projectPathLabel(project);
                const canCreate = projectSupportsCreate(project);
                const statusMessage = String(draft.statusMessage || '').trim();
                const composerDisabled = canCreate ? '' : ' disabled';

                updateTaskStageHeader({
                  kicker: 'New Task',
                  title: `${projectName} · 新任务`,
                  subtitle: '这是一个空白任务框。你在底部说一句，发起后就会变成真实执行面板。',
                  badge: '',
                  meta: [
                    projectPath,
                    conversationDriverLabel(draft.driver || defaultConversationDriver),
                    canCreate ? '等待发起' : '当前项目不可直接发起'
                  ]
                });

                return `
                  <div class="task-dialog-shell three-panel">
                    <section class="dialog-section compact">
                      <div class="task-dialog-toolbar">
                        <div class="task-dialog-toolbar-copy">
                          <strong>${escapeHTML(`准备在 ${projectName} 发起新任务`)}</strong>
                          <span>${escapeHTML(`项目路径：${projectPath} · 任务发起后会自动切到真实执行过程。`)}</span>
                        </div>
                        <div class="task-dialog-toolbar-actions">
                          <button class="action-button secondary" type="button" data-action="cancel-inline-create">取消</button>
                          <button class="action-button secondary" type="button" disabled>中断</button>
                        </div>
                      </div>
                      ${statusMessage ? `<div class="notice${draft.tone === 'error' ? ' error' : ''}">${escapeHTML(statusMessage)}</div>` : ''}
                    </section>

                    <section class="dialog-section fill">
                      <div class="dialog-section-head">
                        <div class="dialog-section-copy">
                          <div class="section-marker">当前进展</div>
                          <div class="section-copy">任务还没启动，所以这里只保留最关键的准备状态。真正开始后，这里会自动切成执行过程。</div>
                        </div>
                      </div>
                      <div class="dialog-section-body">
                        <div class="task-dialog-timeline">${renderInlineCreateProgress(draft, snapshot)}</div>
                      </div>
                    </section>

                    <section class="dialog-section compact">
                      <form class="task-dialog-composer compact" data-form="inline-create-task">
                        <div class="composer-inline composer-inline-create">
                          <span class="composer-kicker">任务说明</span>
                          <textarea name="prompt" rows="4" placeholder="${escapeHTML(canCreate ? '直接输入一句任务说明，然后发起' : '当前项目还不能直接发起任务')}">${escapeHTML(draft.prompt || '')}</textarea>
                          <div class="hint">Enter 换行，Cmd / Ctrl + Enter 发起任务</div>
                          <button type="submit"${composerDisabled}>发起任务</button>
                        </div>
                      </form>
                    </section>
                  </div>`;
              }

              function renderTaskStartComposer(snapshot) {
                const driverLabel = conversationDriverLabel(selectedCreateDriverKind());
                const hasWorkspaces = Array.isArray(snapshot?.workspaces) && snapshot.workspaces.length > 0;
                updateTaskStageHeader({
                  kicker: 'Task Chat',
                  title: '任务执行区',
                  subtitle: '先从左边选项目，再点项目里的任务；如果还没有任务，就在项目右侧点“新建任务”。',
                  badge: '',
                  meta: ['左边选项目', '右边看进展', '底部继续说']
                });

                if (!hasLocalControl) {
                  return `
                    <div class="task-dialog-empty">
                      <strong>当前页只能观察</strong>
                      <div>这张状态页还没接到可写的 OrchardAgent 实例，所以暂时只能看任务和日志，不能从这里发起新任务。</div>
                    </div>`;
                }

                if (!hasWorkspaces) {
                  return `
                    <div class="task-dialog-empty">
                      <strong>还没有可用工作区</strong>
                      <div>先让 OrchardAgent 读取到工作区后，这里就会变成像 Codex 新建对话那样的起单入口。</div>
                    </div>`;
                }

                return `
                  <div class="task-start-shell">
                    <section class="guide-panel">
                      <h3>先选项目，再选任务</h3>
                      <p>左边按项目收纳任务；项目右侧可以直接查看详情或新建任务。右边只保留当前任务的进展和底部输入框。</p>
                      <div class="guide-steps">
                        <div class="guide-step">
                          <strong>1. 选项目</strong>
                          <span>先点开左边项目，看到这个项目下的任务列表。</span>
                        </div>
                        <div class="guide-step">
                          <strong>2. 选任务</strong>
                          <span>点击任务后，右边马上切到它的最新执行进展。</span>
                        </div>
                        <div class="guide-step">
                          <strong>3. 继续或中断</strong>
                          <span>底部输入框继续说；右上按钮负责中断 / 终止。</span>
                        </div>
                      </div>
                      <div class="start-here-chips">
                        <span>执行引擎 · ${escapeHTML(driverLabel)}</span>
                        <span>项目维度</span>
                        <span>宿主机直发</span>
                      </div>
                      <div class="guide-actions">
                        <button type="button" class="guide-button primary" data-action="open-sidebar-create">新建任务</button>
                        <button type="button" class="guide-button secondary" data-action="open-task-list-modal">全部项目</button>
                      </div>
                    </section>
                  </div>`;
              }

              function renderSelectedLocalTaskDetail(snapshot) {
                captureTimelineViewportBeforeRender();
                if (selectedConversationKind === 'codex' && selectedLocalCodexSessionID) {
                  renderSelectedLocalCodexSessionDetail(snapshot);
                  return;
                }

                if (inlineCreateDraft) {
                  localTaskDetail.innerHTML = renderInlineCreateComposer(snapshot);
                  syncTaskTimeline(null);
                  return;
                }

                const task = localTaskByID(selectedLocalTaskID, snapshot);
                const pending = !task && selectedLocalTaskID ? pendingUpdateByTaskID(selectedLocalTaskID, snapshot) : null;

                if (!task && !pending) {
                  updateTaskStageHeader();
                  if (conversationCandidates(snapshot, false).length && (localTaskFilter !== 'all' || localTaskQuery)) {
                    localTaskDetail.innerHTML = `
                      <div class="task-dialog-empty">
                        <strong>当前筛选没有命中会话</strong>
                        <div>试试清空搜索词，或者把左边筛选切回“全部”，中间就会重新切到一条可看的任务。</div>
                      </div>`;
                    syncTaskTimeline(null);
                    return;
                  }
                  localTaskDetail.innerHTML = renderTaskStartComposer(snapshot);
                  syncTaskTimeline(null);
                  return;
                }

                if (!task && pending) {
                  const pendingStatus = pending.managedRunStatus ? statusTitleForManagedRun(pending.managedRunStatus) : statusTitleForTask(pending.status);
                updateTaskStageHeader({
                  kicker: 'Pending Update',
                  title: pending.taskID,
                  subtitle: shortInlineCopy(pending.summary, '这条任务正在等待把最终状态回传给控制面。'),
                  badge: pendingStatus,
                  meta: [
                      pending.codexSessionID ? `会话 ${pending.codexSessionID}` : '',
                      pending.pid ? `PID ${pending.pid}` : '',
                      pending.exitCode !== null && pending.exitCode !== undefined ? `exit ${pending.exitCode}` : ''
                    ]
                  });
                  localTaskDetail.innerHTML = `
                    <div class="task-dialog-shell">
                      <section class="dialog-section compact">
                        <div class="task-dialog-toolbar">
                          <div class="task-dialog-toolbar-copy">
                            <strong>当前状态</strong>
                            <span>这条任务已经不在本地活动列表里，说明宿主机侧大概率已经收敛；如果网络刚恢复，控制面还会继续等这条待回传更新真正送达。</span>
                          </div>
                        </div>
                        <div class="dialog-section-body">
                          <div class="task-dialog-card">
                            <h3>最后状态</h3>
                            <p>${escapeHTML(pending.summary || '当前没有更多摘要。')}</p>
                          </div>
                          <details class="task-meta-details">
                            <summary>更多详情</summary>
                            <div class="meta">
                              ${pending.exitCode !== null && pending.exitCode !== undefined ? `<span>exit ${escapeHTML(pending.exitCode)}</span>` : ''}
                              ${pending.codexSessionID ? `<span>会话 ${escapeHTML(pending.codexSessionID)}</span>` : ''}
                              ${pending.pid ? `<span>PID ${escapeHTML(pending.pid)}</span>` : ''}
                            </div>
                          </details>
                        </div>
                      </section>
                    </div>`;
                  syncTaskTimeline(null);
                  return;
                }

                const status = localTaskStatusLabel(task);
                const taskID = task?.task?.id || '';
                const logLines = Array.isArray(task?.recentLogLines) ? task.recentLogLines : [];
                const actions = [];
                if (canInterruptLocalTask(task)) {
                  actions.push(actionButton('中断', 'interrupt-local-managed', { taskId: taskID }, 'secondary'));
                }
                if (canStopLocalTask(task)) {
                  actions.push(actionButton('终止', localStopAction(task), { taskId: taskID }, 'danger'));
                }

                const draftValue = conversationDraftValue('task', taskID);
                const linkedSessionID = task?.codexThreadID || '';
                const linkedSessionSummary = linkedSessionID
                  ? (localCodexSessionDetails.get(linkedSessionID)?.session || localCodexSessionByID(linkedSessionID, snapshot))
                  : null;
                const linkedSessionDetail = linkedSessionID ? localCodexSessionDetails.get(linkedSessionID) : null;
                const route = conversationRouteSnapshot({
                  task,
                  session: linkedSessionDetail?.session || linkedSessionSummary,
                  status
                });
                const project = taskProjectSummary(task);
                const shouldHydrateLinkedSession = Boolean(linkedSessionID) && hasLocalCodexControl && task?.task?.kind === 'codex';
                if (shouldHydrateLinkedSession) {
                  const forceLinkedRefresh = isActiveLocalTask(taskID, snapshot)
                    && ['running', 'waitingInput', 'interrupting'].includes(task?.managedRunStatus);
                  if (!linkedSessionDetail || forceLinkedRefresh) {
                    requestLocalCodexSessionDetail(linkedSessionID, forceLinkedRefresh);
                  }
                }
                const timeline = task?.task?.kind === 'codex'
                  ? renderManagedCodexTaskTimeline(task, linkedSessionDetail, route)
                  : [
                    (() => {
                      const pendingEntries = pendingConversationEntries('task', taskID, [task?.lastUserPrompt || '']);
                      return [
                        renderExecutionSummaryStrip([], pendingEntries, localTaskStatusKey(task) === 'running', {
                          logLines: task?.recentLogLines || []
                        }),
                        `<div class="progress-feed">
                          ${renderLogTimeline(task)}
                          ${task?.runtimeWarning ? renderProgressEntry({
                            kindLabel: '运行告警',
                            summary: shortInlineCopy(task.runtimeWarning, '运行告警'),
                            subtitle: '点击可展开完整告警',
                            status: '提醒',
                            tone: 'warn',
                            entryKey: `task-warning:${taskID}`,
                            details: `<div class="progress-body-copy">${escapeHTML(task.runtimeWarning)}</div>`
                          }) : ''}
                          ${pendingEntries.map((entry) => renderPendingConversationBubble(entry, route)).join('')}
                        </div>`
                      ].filter(Boolean).join('');
                    })()
                  ].filter(Boolean).join('');

                const composerEnabled = canSendLocalInstruction(task);
                const composerDisabled = composerEnabled ? '' : ' disabled';
                const composerHint = !hasLocalControl
                  ? '当前页面没有接到运行中的 OrchardAgent，所以这里只能看，不能直接发指令。'
                    : !isActiveLocalTask(taskID, snapshot)
                    ? '这条任务已结束。'
                  : task?.task?.kind !== 'codex'
                    ? '这是 Shell 任务。'
                  : task?.managedRunStatus === 'running'
                      ? '正在执行，先看进展。'
                      : task?.managedRunStatus === 'interrupting' || localTaskStatusKey(task) === 'stopRequested'
                        ? '正在收敛。'
                      : task?.managedRunStatus === 'waitingInput'
                          ? '现在可以直接补一句。'
                        : '直接在这里继续。';
                const detailRenderKey = `task:${taskID}`;
                const frameSignature = [
                  status,
                  actions.join('||'),
                  composerDisabled,
                  composerHint,
                  draftValue
                ].join('||');

                updateTaskStageHeader({
                  kicker: task?.task?.kind === 'codex' ? 'Managed Task' : 'Shell Task',
                  title: task.task?.title || taskID || '未命名任务',
                  subtitle: shortInlineCopy(task.lastAssistantPreview || task.lastUserPrompt || task.cwd, '这里会持续显示这个任务最近的上下文和日志。'),
                  badge: status,
                  meta: [
                    localTaskDriverLabel(task),
                    projectNameLabel(project, task.task?.workspaceID || '项目'),
                    projectPathLabel(project, task.cwd || task.task?.relativePath || ''),
                    task.lastSeenAt ? formatRelativeTime(task.lastSeenAt) : formatRelativeTime(task.startedAt || task.task?.updatedAt || task.task?.createdAt)
                  ]
                });

                const timelineMarkup = timeline || '<div class="task-dialog-empty">当前还没有最新日志或运行告警可展示。</div>';
                const patched = patchExistingDetailTimeline(
                  detailRenderKey,
                  frameSignature,
                  timelineMarkup,
                  'form[data-form="local-task-dialog"]'
                );
                if (!patched) {
                  localTaskDetail.innerHTML = `
                    <div class="task-dialog-shell">
                      <section class="dialog-section fill">
                        <div class="dialog-section-head">
                          <div class="section-marker">当前进展</div>
                          ${actions.length ? `<div class="task-dialog-toolbar-actions">${actions.join('')}</div>` : ''}
                        </div>
                        <div class="dialog-section-body">
                          <div class="task-dialog-timeline">${timelineMarkup}</div>
                        </div>
                      </section>

                      <section class="dialog-section compact">
                        <form class="task-dialog-composer compact" data-form="local-task-dialog" data-task-id="${escapeHTML(taskID)}">
                          <div class="composer-inline">
                            <span class="composer-kicker">继续输入</span>
                            <input name="prompt" type="text" value="${escapeHTML(draftValue)}" placeholder="${escapeHTML(composerHint || '直接继续这条任务')}">
                            <span class="composer-actions">
                              ${canInterruptLocalTask(task) ? `<button type="button" class="secondary" data-action="interrupt-local-managed" data-task-id="${escapeHTML(taskID)}">中断</button>` : canStopLocalTask(task) ? `<button type="button" class="secondary" data-action="${escapeHTML(localStopAction(task))}" data-task-id="${escapeHTML(taskID)}">终止</button>` : ''}
                              <button type="submit"${composerDisabled}>发送</button>
                            </span>
                          </div>
                        </form>
                      </section>
                    </div>`;
                }
                rememberDetailRender(detailRenderKey, frameSignature, timelineMarkup);
                if (task?.task?.kind === 'codex' && linkedSessionDetail?.items) {
                  syncTaskConversationTimeline(task, linkedSessionDetail);
                } else {
                  syncTaskTimeline(task);
                }
              }

              function renderManagedRun(run) {
                const status = statusTitleForManagedRun(run.status);
                const actions = [];
                if (canContinueManagedRun(run)) {
                  actions.push(actionButton('继续', 'continue-managed-run', { runId: run.id }, '', hasRemoteActions));
                }
                if (canInterruptManagedRun(run)) {
                  actions.push(actionButton('中断', 'interrupt-managed-run', { runId: run.id }, 'secondary', hasRemoteActions));
                }
                if (canStopManagedRun(run)) {
                  actions.push(actionButton('停止', 'stop-managed-run', { runId: run.id }, 'danger', hasRemoteActions));
                }
                return `
                  <article class="item">
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(run.title)}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      <span>${escapeHTML(run.workspaceID || '—')}</span>
                      <span>${escapeHTML(run.relativePath || '工作区根目录')}</span>
                      <span>${escapeHTML(run.deviceName || run.deviceID || run.preferredDeviceID || '未指定设备')}</span>
                    </div>
                    <p>${escapeHTML(run.summary || run.lastUserPrompt || run.cwd || '当前没有额外摘要。')}</p>
                    ${actions.length ? `<div class="item-actions">${actions.join('')}</div>` : ''}
                  </article>
                `;
              }

              function renderCodexSession(session) {
                const status = statusTitleForSession(session);
                const actions = [];
                if (canContinueSession(session)) {
                  actions.push(actionButton('继续', 'continue-codex-session', { deviceId: session.deviceID, sessionId: session.id }, '', hasRemoteActions));
                }
                if (canInterruptSession(session)) {
                  actions.push(actionButton('中断', 'interrupt-codex-session', { deviceId: session.deviceID, sessionId: session.id }, 'secondary', hasRemoteActions));
                }
                return `
                  <article class="item">
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(session.name || session.preview || session.id)}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      <span>${escapeHTML(session.workspaceID || '未映射工作区')}</span>
                      <span>${escapeHTML(session.cwd || '—')}</span>
                    </div>
                    <p>${escapeHTML(session.lastAssistantMessage || session.lastUserMessage || session.preview || '当前没有额外摘要。')}</p>
                    ${actions.length ? `<div class="item-actions">${actions.join('')}</div>` : ''}
                  </article>
                `;
              }

              function canContinueManagedRun(run) {
                return hasRemoteActions && run?.status === 'waitingInput' && Boolean(run?.codexSessionID);
              }

              function canInterruptManagedRun(run) {
                return hasRemoteActions && ['running', 'waitingInput', 'interrupting'].includes(run?.status) && Boolean(run?.codexSessionID);
              }

              function canStopManagedRun(run) {
                return hasRemoteActions && run?.status && !['succeeded', 'failed', 'interrupted', 'cancelled', 'stopRequested'].includes(run.status);
              }

              function canContinueSession(session) {
                return hasRemoteActions && Boolean(session?.deviceID) && Boolean(session?.id);
              }

              function canInterruptSession(session) {
                return hasRemoteActions && (session?.lastTurnStatus === 'inProgress' || session?.state === 'running');
              }

              function statusTitleForTask(status) {
                switch (status) {
                  case 'queued': return '排队中';
                  case 'running': return '运行中';
                  case 'succeeded': return '已完成';
                  case 'failed': return '失败';
                  case 'stopRequested': return '停止中';
                  case 'cancelled': return '已取消';
                  default: return status || '未知';
                }
              }

              function statusTitleForManagedRun(status) {
                switch (status) {
                  case 'queued': return '排队中';
                  case 'launching': return '启动中';
                  case 'running': return '运行中';
                  case 'waitingInput': return '等待输入';
                  case 'interrupting': return '中断中';
                  case 'stopRequested': return '停止中';
                  case 'succeeded': return '已完成';
                  case 'failed': return '失败';
                  case 'interrupted': return '已中断';
                  case 'cancelled': return '已取消';
                  default: return status || '未知';
                }
              }

              function statusTitleForSession(session) {
                if (session?.lastTurnStatus === 'inProgress' || session?.state === 'running') return '推理中';
                switch (session?.state) {
                  case 'idle': return '待命';
                  case 'completed': return '已完成';
                  case 'failed': return '失败';
                  case 'interrupted': return '已中断';
                  default: return session?.state || '未知';
                }
              }

              function localRunningConversationCount(snapshot = lastPayload) {
                const activeTaskCount = Array.isArray(snapshot?.local?.activeTasks) ? snapshot.local.activeTasks.length : 0;
                const runningCodexCount = localCodexSessionCollection(snapshot).filter((session) => isRunningLocalCodexSession(session)).length;
                return activeTaskCount + runningCodexCount;
              }

              function localWaitingConversationCount(snapshot = lastPayload) {
                const waitingTasks = (Array.isArray(snapshot?.local?.activeTasks) ? snapshot.local.activeTasks : [])
                  .filter((task) => localTaskStatusKey(task) === 'waitingInput')
                  .length;
                const waitingCodexSessions = localCodexSessionCollection(snapshot).filter((session) => canContinueLocalCodexSession(session)).length;
                return waitingTasks + waitingCodexSessions;
              }

              function renderMetrics(snapshot) {
                metrics.innerHTML = [
                  metricCard('本机正在跑', localRunningConversationCount(snapshot), '宿主机当前真正在执行的任务 / 会话'),
                  metricCard('等你继续', localWaitingConversationCount(snapshot), '现在可以直接在右侧补一句的数量'),
                  metricCard('待回传', snapshot.local?.pendingUpdates?.length || 0, '断线恢复后会先从这里补送')
                ].join('');
              }

              function renderSnapshot(snapshot) {
                lastPayload = snapshot;
                syncSelectedLocalTask(snapshot);
                stamp.textContent = `${snapshot.deviceName} · ${snapshot.deviceID} · 最近刷新 ${formatDate(snapshot.generatedAt)}`;
                showAdvancedButton.textContent = snapshot.local?.warnings?.length
                  ? `高级观察（${snapshot.local.warnings.length} 条提醒）`
                  : '高级观察';
                populateWorkspaceOptions(snapshot.workspaces || []);
                updateTaskFilterButtons(snapshot);
                renderMetrics(snapshot);

                const renderedTaskList = renderLocalTaskSections(snapshot);
                localTasks.innerHTML = renderLocalProjectSidebar(snapshot);
                if (localTasksModal) {
                  localTasksModal.innerHTML = renderedTaskList;
                }
                if (shouldDeferSelectedConversationRender()) {
                  deferSelectedConversationRefresh = true;
                } else {
                  deferSelectedConversationRefresh = false;
                  renderSelectedLocalTaskDetail(snapshot);
                }

                advancedNotes.innerHTML = snapshot.local?.warnings?.length
                  ? `<div class="notice">${snapshot.local.warnings.map(escapeHTML).join('<br>')}</div>`
                  : '<div class="empty">平时不用盯这里；只有排查断网恢复、远端对账或状态不一致时再展开。</div>';

                pendingUpdates.innerHTML = renderItemList(
                  snapshot.local?.pendingUpdates || [],
                  '当前没有待回传更新。',
                  renderPendingUpdate
                );

                remoteManagedRuns.innerHTML = renderItemList(
                  snapshot.remote?.managedRuns || [],
                  snapshot.remoteSkippedReason || snapshot.remote?.fetchError || '当前没有指向本机的托管运行。',
                  renderManagedRun
                );

                remoteCodexSessions.innerHTML = renderItemList(
                  snapshot.remote?.codexSessions || [],
                  snapshot.remoteSkippedReason || snapshot.remote?.fetchError || '当前没有本机 Codex 会话。',
                  renderCodexSession
                );

                if (snapshot.remote?.fetchError) {
                  remoteManagedRuns.insertAdjacentHTML('beforeend', `<div class="notice error">${escapeHTML(snapshot.remote.fetchError)}</div>`);
                }

                rawJSON.textContent = JSON.stringify(snapshot, null, 2);
              }

              async function refreshSnapshot() {
                const remote = remoteToggle.checked ? '1' : '0';
                const limit = encodeURIComponent(limitSelect.value);
                try {
                  const response = await fetch(`/api/status?remote=${remote}&limit=${limit}`, { cache: 'no-store' });
                  if (!response.ok) {
                    throw new Error(`HTTP ${response.status}`);
                  }
                  const snapshot = await response.json();
                  renderSnapshot(snapshot);
                } catch (error) {
                  stamp.textContent = `刷新失败：${error.message || error}`;
                }
              }

              function pollSelectedConversationDetail() {
                if (!lastPayload || shouldDeferSelectedConversationRender()) return;
                if (selectedConversationKind === 'codex' && selectedLocalCodexSessionID) {
                  const session = localCodexSessionByID(selectedLocalCodexSessionID, lastPayload);
                  const detail = localCodexSessionDetails.get(selectedLocalCodexSessionID);
                  const effectiveSession = detail?.session || session;
                  if (!effectiveSession || !isRunningLocalCodexSession(effectiveSession)) return;
                  requestLocalCodexSessionDetail(selectedLocalCodexSessionID, true);
                  return;
                }
                if (selectedConversationKind === 'task' && selectedLocalTaskID) {
                  const task = localTaskByID(selectedLocalTaskID, lastPayload);
                  if (!task || task?.task?.kind !== 'codex' || !task?.codexThreadID) return;
                  if (!isActiveLocalTask(selectedLocalTaskID, lastPayload)) return;
                  requestLocalCodexSessionDetail(task.codexThreadID, true);
                }
              }

              async function postJSON(url, body) {
                const response = await fetch(url, {
                  method: 'POST',
                  headers: body ? { 'Content-Type': 'application/json' } : {},
                  body: body ? JSON.stringify(body) : undefined
                });

                const text = await response.text();
                let payload = null;
                if (text) {
                  try {
                    payload = JSON.parse(text);
                  } catch {
                    payload = { message: text };
                  }
                }

                if (!response.ok || payload?.ok === false) {
                  throw new Error(payload?.error || payload?.message || `HTTP ${response.status}`);
                }

                return payload;
              }

              function scrollTaskDialogIntoView() {
                localTaskDetailPanel?.scrollIntoView({ behavior: 'smooth', block: 'start' });
              }

              window.addEventListener('scroll', () => refreshTimelineAutoFollow(), { passive: true });
              window.addEventListener('resize', () => refreshTimelineAutoFollow());
              document.addEventListener('pointerdown', (event) => {
                const target = event.target instanceof Element ? event.target : null;
                if (!target) return;
                if (target.closest('.task-dialog-timeline')) {
                  pauseTimelineAutoFollow();
                }
              }, true);
              document.addEventListener('toggle', (event) => {
                if (suppressProgressEntryToggleTracking) return;
                const entry = event.target instanceof HTMLDetailsElement ? event.target : null;
                if (!entry?.matches('details.progress-entry[data-entry-key]')) return;
                pauseTimelineAutoFollow();
                entry.dataset.userOpenState = entry.open ? 'open' : 'closed';
              }, true);

              document.addEventListener('click', async (event) => {
                const overlay = event.target.closest('.overlay');
                if (overlay && event.target === overlay) {
                  setModalOpen(overlay, false);
                  return;
                }

                const button = event.target.closest('button[data-action]');
                if (!button) {
                  const taskRow = event.target.closest('[data-task-select="1"]');
                  if (taskRow) {
                    selectLocalTask(taskRow.dataset.taskId || null);
                    setModalOpen(taskListModal, false);
                    if (lastPayload) {
                      renderSnapshot(lastPayload);
                    }
                    scrollTaskDialogIntoView();
                    return;
                  }
                  const sessionRow = event.target.closest('[data-codex-session-select="1"]');
                  if (!sessionRow) return;
                  selectLocalCodexSession(sessionRow.dataset.sessionId || null);
                  requestLocalCodexSessionDetail(sessionRow.dataset.sessionId || null);
                  setModalOpen(taskListModal, false);
                  if (lastPayload) {
                    renderSnapshot(lastPayload);
                  }
                  scrollTaskDialogIntoView();
                  return;
                }

                const action = button.dataset.action;
                if (action === 'select-local-task') {
                  selectLocalTask(button.dataset.taskId || null);
                  setModalOpen(taskListModal, false);
                  if (lastPayload) {
                    renderSnapshot(lastPayload);
                  }
                  scrollTaskDialogIntoView();
                  return;
                }
                if (action === 'select-local-codex-session') {
                  selectLocalCodexSession(button.dataset.sessionId || null);
                  requestLocalCodexSessionDetail(button.dataset.sessionId || null);
                  setModalOpen(taskListModal, false);
                  if (lastPayload) {
                    renderSnapshot(lastPayload);
                  }
                  scrollTaskDialogIntoView();
                  return;
                }
                if (action === 'toggle-project-tree') {
                  toggleProjectGroup(button.dataset.projectKey, lastPayload);
                  return;
                }
                if (action === 'toggle-project-details') {
                  toggleProjectDetails(button.dataset.projectKey, lastPayload);
                  return;
                }
                if (action === 'open-inline-project-create') {
                  const project = projectGroupByKey(button.dataset.projectKey, lastPayload)?.project;
                  if (project) {
                    openInlineCreateDraftForProject(project, lastPayload);
                    scrollTaskDialogIntoView();
                  }
                  return;
                }
                if (action === 'open-sidebar-create') {
                  const project = preferredCreateProject(lastPayload);
                  if (project) {
                    openInlineCreateDraftForProject(project, lastPayload);
                    scrollTaskDialogIntoView();
                  } else {
                    openCreateModal(true);
                  }
                  return;
                }
                if (action === 'cancel-inline-create') {
                  closeInlineCreateDraft(lastPayload);
                  return;
                }
                if (action === 'open-task-list-modal') {
                  openTaskListModal();
                  return;
                }
                if (action === 'close-modal') {
                  setModalOpen(button.dataset.modal === 'create' ? createModal : taskListModal, false);
                  return;
                }
                if (action === 'focus-task-list-search') {
                  openTaskListModal();
                  setTimeout(() => (taskSearchModalInput || taskSearchInput)?.focus(), 120);
                  return;
                }
                if (action === 'focus-task-composer') {
                  const composer = localTaskDetail.querySelector('form[data-form="local-task-dialog"] [name="prompt"], form[data-form="local-codex-session-dialog"] [name="prompt"], form[data-form="inline-create-task"] [name="prompt"]');
                  composer?.focus();
                  composer?.scrollIntoView({ behavior: 'smooth', block: 'center' });
                  return;
                }
                if (action === 'scroll-task-log') {
                  resumeTimelineAutoFollow();
                  pendingTimelineRestore.state = null;
                  resetTerminalBoxAutoFollow();
                  const timeline = localTaskDetail.querySelector('.task-dialog-timeline');
                  if (timeline) {
                    if (timelineUsesDocumentScroll(timeline)) {
                      const latestEntry = timeline.lastElementChild || timeline;
                      latestEntry.scrollIntoView({ behavior: 'smooth', block: 'end' });
                    } else {
                      timeline.scrollTo({ top: timeline.scrollHeight, behavior: 'smooth' });
                    }
                  }
                  const terminalBoxes = Array.from(localTaskDetail.querySelectorAll('.task-dialog-timeline .terminal-box'));
                  const latestTerminalBox = terminalBoxes[terminalBoxes.length - 1];
                  latestTerminalBox?.scrollTo({ top: latestTerminalBox.scrollHeight, behavior: 'smooth' });
                  return;
                }
                const previousLabel = button.textContent;
                button.disabled = true;
                button.textContent = '处理中...';

                try {
                  switch (action) {
                    case 'continue-local-managed': {
                      const prompt = window.prompt('补充说明', '');
                      if (!prompt || !prompt.trim()) return;
                      await postJSON(`/api/local-managed-runs/${encodeURIComponent(button.dataset.taskId)}/continue`, { prompt });
                      break;
                    }
                    case 'interrupt-local-managed': {
                      await postJSON(`/api/local-managed-runs/${encodeURIComponent(button.dataset.taskId)}/interrupt`);
                      break;
                    }
                    case 'stop-local-managed': {
                      await postJSON(`/api/local-managed-runs/${encodeURIComponent(button.dataset.taskId)}/stop`);
                      break;
                    }
                    case 'stop-local-task': {
                      await postJSON(`/api/local-tasks/${encodeURIComponent(button.dataset.taskId)}/stop`);
                      break;
                    }
                    case 'refresh-local-codex-session': {
                      await requestLocalCodexSessionDetail(button.dataset.sessionId, true);
                      break;
                    }
                    case 'interrupt-local-codex-session': {
                      const detail = await postJSON(`/api/local-codex-sessions/${encodeURIComponent(button.dataset.sessionId)}/interrupt`);
                      if (button.dataset.sessionId) {
                        localCodexSessionDetails.set(button.dataset.sessionId, detail);
                      }
                      break;
                    }
                    case 'continue-managed-run': {
                      const prompt = window.prompt('继续内容', '');
                      if (!prompt || !prompt.trim()) return;
                      await postJSON(`/api/managed-runs/${encodeURIComponent(button.dataset.runId)}/continue`, { prompt });
                      break;
                    }
                    case 'interrupt-managed-run': {
                      await postJSON(`/api/managed-runs/${encodeURIComponent(button.dataset.runId)}/interrupt`);
                      break;
                    }
                    case 'stop-managed-run': {
                      await postJSON(`/api/managed-runs/${encodeURIComponent(button.dataset.runId)}/stop`);
                      break;
                    }
                    case 'continue-codex-session': {
                      const prompt = window.prompt('继续内容', '');
                      if (!prompt || !prompt.trim()) return;
                      await postJSON(`/api/codex-sessions/${encodeURIComponent(button.dataset.deviceId)}/${encodeURIComponent(button.dataset.sessionId)}/continue`, { prompt });
                      break;
                    }
                    case 'interrupt-codex-session': {
                      await postJSON(`/api/codex-sessions/${encodeURIComponent(button.dataset.deviceId)}/${encodeURIComponent(button.dataset.sessionId)}/interrupt`);
                      break;
                    }
                    default:
                      throw new Error('未知动作');
                  }

                  stamp.textContent = `操作已发送 · ${new Date().toLocaleTimeString('zh-CN')}`;
                  await refreshSnapshot();
                } catch (error) {
                  stamp.textContent = `操作失败：${error.message || error}`;
                } finally {
                  button.textContent = previousLabel;
                  button.disabled = false;
                }
              });

              document.addEventListener('submit', async (event) => {
                const inlineCreateForm = event.target.closest('form[data-form="inline-create-task"]');
                if (inlineCreateForm) {
                  event.preventDefault();
                  const draft = inlineCreateDraft;
                  const project = inlineCreateProject(lastPayload);
                  const promptInput = inlineCreateForm.querySelector('[name="prompt"]');
                  const submitButton = inlineCreateForm.querySelector('button[type="submit"]');
                  const prompt = promptInput?.value?.trim() || '';

                  if (!draft || !project) {
                    stamp.textContent = '当前没有选中可发起的新任务项目。';
                    return;
                  }
                  if (!projectSupportsCreate(project)) {
                    updateInlineCreateDraft({
                      statusMessage: '当前项目还没有映射到可写工作区，暂时不能直接发起任务。',
                      tone: 'error'
                    });
                    if (lastPayload) renderSelectedLocalTaskDetail(lastPayload);
                    return;
                  }
                  if (!prompt) {
                    updateInlineCreateDraft({
                      prompt: '',
                      statusMessage: '请先输入一句任务说明。',
                      tone: 'error'
                    });
                    if (lastPayload) renderSelectedLocalTaskDetail(lastPayload);
                    promptInput?.focus();
                    return;
                  }

                  const previousLabel = submitButton?.textContent || '发起任务';
                  if (submitButton) {
                    submitButton.disabled = true;
                    submitButton.textContent = '发起中...';
                  }
                  updateInlineCreateDraft({
                    prompt,
                    statusMessage: '正在把任务提交给宿主机…',
                    tone: 'info'
                  });
                  if (lastPayload) {
                    renderSelectedLocalTaskDetail(lastPayload);
                  }

                  try {
                    const payload = await createLocalTask({
                      workspaceID: project.workspaceID,
                      relativePath: project.relativePath || '',
                      driver: draft.driver || defaultConversationDriver,
                      prompt
                    });
                    inlineCreateDraft = null;
                    afterLocalTaskCreated(payload);
                  } catch (error) {
                    updateInlineCreateDraft({
                      prompt,
                      statusMessage: `发起失败：${error.message || error}`,
                      tone: 'error'
                    });
                    if (lastPayload) {
                      renderSelectedLocalTaskDetail(lastPayload);
                    }
                    stamp.textContent = `发起失败：${error.message || error}`;
                  } finally {
                    if (submitButton) {
                      submitButton.disabled = false;
                      submitButton.textContent = previousLabel;
                    }
                  }
                  return;
                }

                const form = event.target.closest('form[data-form="local-task-dialog"]');
                if (!form) {
                  const sessionForm = event.target.closest('form[data-form="local-codex-session-dialog"]');
                  if (!sessionForm) return;

                  event.preventDefault();
                  if (!hasLocalCodexControl) return;

                  const sessionID = sessionForm.dataset.sessionId || '';
                  const promptInput = sessionForm.querySelector('[name="prompt"]');
                  const submitButton = sessionForm.querySelector('button[type="submit"]');
                  const prompt = promptInput?.value?.trim() || '';

                  if (!sessionID) {
                    stamp.textContent = '当前没有选中可继续的 Codex 会话。';
                    return;
                  }
                  if (!prompt) {
                    stamp.textContent = '请先输入要继续给这条会话的话。';
                    promptInput?.focus();
                    return;
                  }

                  const previousLabel = submitButton?.textContent || '发送到当前会话';
                  if (submitButton) {
                    submitButton.disabled = true;
                    submitButton.textContent = '发送中...';
                  }
                  const pendingEntryID = addPendingConversationMessage('codex', sessionID, prompt);
                  if (promptInput) {
                    promptInput.value = '';
                  }
                  setConversationDraft('codex', sessionID, '');
                  if (lastPayload) {
                    renderSelectedLocalTaskDetail(lastPayload);
                    scrollConversationViewportToLatest({ force: true });
                  }

                  try {
                    const detail = await postJSON(`/api/local-codex-sessions/${encodeURIComponent(sessionID)}/continue`, { prompt });
                    localCodexSessionDetails.set(sessionID, detail);
                    const cwd = detail?.session?.cwd || localCodexSessionByID(sessionID, lastPayload)?.cwd || '';
                    stamp.textContent = cwd
                      ? `已把补充说明发给本机会话 ${sessionID} · ${cwd}`
                      : `已把补充说明发给本机会话 ${sessionID}`;
                    if (lastPayload) {
                      renderSelectedLocalTaskDetail(lastPayload);
                      scrollConversationViewportToLatest({ force: true });
                    }
                    await refreshSnapshot();
                  } catch (error) {
                    removePendingConversationMessage('codex', sessionID, pendingEntryID);
                    if (promptInput) {
                      promptInput.value = prompt;
                    }
                    setConversationDraft('codex', sessionID, prompt);
                    if (lastPayload) {
                      renderSelectedLocalTaskDetail(lastPayload);
                    }
                    stamp.textContent = `发送失败：${error.message || error}`;
                  } finally {
                    if (submitButton) {
                      submitButton.disabled = false;
                      submitButton.textContent = previousLabel;
                    }
                  }
                  return;
                }

                event.preventDefault();
                if (!hasLocalControl) return;

                const taskID = form.dataset.taskId || '';
                const promptInput = form.querySelector('[name="prompt"]');
                const submitButton = form.querySelector('button[type="submit"]');
                const prompt = promptInput?.value?.trim() || '';

                if (!taskID) {
                  stamp.textContent = '当前没有选中可发送指令的任务。';
                  return;
                }
                if (!prompt) {
                  stamp.textContent = '请先输入要补充给任务的话。';
                  promptInput?.focus();
                  return;
                }

                const previousLabel = submitButton?.textContent || '发送到当前任务';
                if (submitButton) {
                  submitButton.disabled = true;
                  submitButton.textContent = '发送中...';
                }
                const pendingEntryID = addPendingConversationMessage('task', taskID, prompt);
                if (promptInput) {
                  promptInput.value = '';
                }
                setConversationDraft('task', taskID, '');
                if (lastPayload) {
                  renderSelectedLocalTaskDetail(lastPayload);
                  scrollConversationViewportToLatest({ force: true });
                }

                try {
                  await postJSON(`/api/local-managed-runs/${encodeURIComponent(taskID)}/continue`, { prompt });
                  const selectedTask = lastPayload ? localTaskByID(taskID, lastPayload) : null;
                  const sessionHint = selectedTask?.codexThreadID ? ` -> ${selectedTask.codexThreadID}` : '';
                  const cwdHint = selectedTask?.cwd ? ` · ${selectedTask.cwd}` : '';
                  stamp.textContent = `已把补充说明发给 ${taskID}${sessionHint}${cwdHint}`;
                  if (selectedTask?.codexThreadID) {
                    requestLocalCodexSessionDetail(selectedTask.codexThreadID, true);
                  }
                  await refreshSnapshot();
                } catch (error) {
                  removePendingConversationMessage('task', taskID, pendingEntryID);
                  if (promptInput) {
                    promptInput.value = prompt;
                  }
                  setConversationDraft('task', taskID, prompt);
                  if (lastPayload) {
                    renderSelectedLocalTaskDetail(lastPayload);
                  }
                  stamp.textContent = `发送失败：${error.message || error}`;
                } finally {
                  if (submitButton) {
                    submitButton.disabled = false;
                    submitButton.textContent = previousLabel;
                  }
                }
              });

              localCreateForm.addEventListener('submit', async (event) => {
                event.preventDefault();
                if (!hasLocalControl) return;

                const prompt = createPromptInput.value.trim();
                const workspaceID = createWorkspaceSelect.value;
                const relativePath = normalizeRelativePath(createRelativePathInput.value)
                  || normalizeRelativePath(createRelativePathSelect?.value);
                const title = (createTitleInput.value.trim() || defaultLocalTaskTitle(prompt)).trim();

                if (!workspaceID) {
                  stamp.textContent = '请先选择工作区。';
                  setCreateStatus('请先选择工作区。', 'error');
                  return;
                }
                if (!prompt) {
                  stamp.textContent = '请先输入任务说明。';
                  setCreateStatus('请先输入任务说明。', 'error');
                  return;
                }

                const submitButton = document.getElementById('create-submit');
                const previousLabel = submitButton.textContent;
                submitButton.disabled = true;
                submitButton.textContent = '发起中...';
                setCreateStatus('正在把任务提交给宿主机…');

                try {
                  const payload = await createLocalTask({ title, workspaceID, relativePath, prompt });
                  afterLocalTaskCreated(payload);
                } catch (error) {
                  stamp.textContent = `发起失败：${error.message || error}`;
                  setCreateStatus(`发起失败：${error.message || error}`, 'error');
                } finally {
                  submitButton.disabled = false;
                  submitButton.textContent = previousLabel;
                }
              });

              createWorkspaceSelect.addEventListener('change', () => {
                populateRelativePathOptions(createWorkspaceSelect.value);
              });
              createDriverSelect?.addEventListener('change', () => {
                createDriverSelect.value = selectedCreateDriverKind();
                if (lastPayload) {
                  renderSelectedLocalTaskDetail(lastPayload);
                }
              });
              taskSearchInputs.forEach((input) => {
                input.addEventListener('input', () => {
                  localTaskQuery = input.value.trim();
                  taskSearchInputs.forEach((other) => {
                    if (other !== input) {
                      other.value = input.value;
                    }
                  });
                  if (lastPayload) {
                    renderSnapshot(lastPayload);
                  }
                });
              });
              document.addEventListener('input', (event) => {
                const promptField = event.target.closest('form[data-form="local-task-dialog"] [name="prompt"], form[data-form="local-codex-session-dialog"] [name="prompt"], form[data-form="inline-create-task"] [name="prompt"]');
                if (!promptField) return;
                const form = promptField.closest('form');
                if (form?.dataset.form === 'local-task-dialog') {
                  setConversationDraft('task', form.dataset.taskId || '', promptField.value);
                  return;
                }
                if (form?.dataset.form === 'local-codex-session-dialog') {
                  setConversationDraft('codex', form.dataset.sessionId || '', promptField.value);
                  return;
                }
                if (form?.dataset.form === 'inline-create-task') {
                  updateInlineCreateDraft({
                    prompt: promptField.value,
                    statusMessage: '',
                    tone: 'info'
                  });
                }
              });
              document.addEventListener('compositionstart', (event) => {
                const promptField = event.target.closest('form[data-form="local-task-dialog"] [name="prompt"], form[data-form="local-codex-session-dialog"] [name="prompt"], form[data-form="inline-create-task"] [name="prompt"], #create-prompt');
                if (!promptField) return;
                promptField.dataset.composing = '1';
              });
              document.addEventListener('compositionend', (event) => {
                const promptField = event.target.closest('form[data-form="local-task-dialog"] [name="prompt"], form[data-form="local-codex-session-dialog"] [name="prompt"], form[data-form="inline-create-task"] [name="prompt"], #create-prompt');
                if (!promptField) return;
                promptField.dataset.composing = '0';
                const form = promptField.closest('form');
                if (form?.dataset.form === 'local-task-dialog') {
                  setConversationDraft('task', form.dataset.taskId || '', promptField.value);
                } else if (form?.dataset.form === 'local-codex-session-dialog') {
                  setConversationDraft('codex', form.dataset.sessionId || '', promptField.value);
                } else if (form?.dataset.form === 'inline-create-task') {
                  updateInlineCreateDraft({
                    prompt: promptField.value,
                    statusMessage: '',
                    tone: 'info'
                  });
                }
              });
              document.addEventListener('focusout', (event) => {
                const promptField = event.target.closest('form[data-form="local-task-dialog"] [name="prompt"], form[data-form="local-codex-session-dialog"] [name="prompt"], form[data-form="inline-create-task"] [name="prompt"]');
                if (!promptField) return;
                setTimeout(flushDeferredSelectedConversationRender, 0);
              });
              taskFilterButtons.forEach((button) => {
                button.addEventListener('click', () => {
                  localTaskFilter = button.dataset.taskFilter || 'all';
                  if (lastPayload) {
                    renderSnapshot(lastPayload);
                  } else {
                    updateTaskFilterButtons(lastPayload);
                  }
                });
              });
              focusTaskListButton?.addEventListener('click', () => {
                openTaskListModal();
              });
              showAdvancedButton.addEventListener('click', () => {
                advancedSection.open = true;
                advancedSection.scrollIntoView({ behavior: 'smooth', block: 'start' });
              });
              refreshButton.addEventListener('click', refreshSnapshot);
              remoteToggle.addEventListener('change', refreshSnapshot);
              limitSelect.addEventListener('change', refreshSnapshot);
              copyButton.addEventListener('click', async () => {
                if (!lastPayload) return;
                try {
                  await navigator.clipboard.writeText(JSON.stringify(lastPayload, null, 2));
                  copyButton.textContent = '已复制';
                  setTimeout(() => { copyButton.textContent = '复制 JSON'; }, 1200);
                } catch {
                  copyButton.textContent = '复制失败';
                  setTimeout(() => { copyButton.textContent = '复制 JSON'; }, 1200);
                }
              });

              document.addEventListener('keydown', (event) => {
                const promptField = event.target.closest('form[data-form="local-task-dialog"] [name="prompt"], form[data-form="local-codex-session-dialog"] [name="prompt"], form[data-form="inline-create-task"] [name="prompt"], #create-prompt');
                if (promptField && event.key === 'Enter') {
                  const isTextarea = promptField.tagName === 'TEXTAREA';
                  if (event.isComposing || promptField.dataset.composing === '1') {
                    if (!isTextarea) {
                      event.preventDefault();
                      event.stopPropagation();
                    }
                    return;
                  }
                  if (isTextarea && (event.metaKey || event.ctrlKey)) {
                    event.preventDefault();
                    promptField.closest('form')?.requestSubmit();
                    return;
                  }
                }
                if (event.key === 'Escape') {
                  closeAllModals();
                }
              });

              refreshSnapshot();
              setInterval(refreshSnapshot, 4000);
              setInterval(pollSelectedConversationDetail, 1500);
            </script>
          </body>
        </html>
        """
    }
}

private func escapeHTML(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&#39;")
}

private func renderConversationDriverOptions(
    selected: ConversationDriverKind,
    supportedKinds: [ConversationDriverKind]
) -> String {
    supportedKinds.map { kind in
        let selectedAttribute = kind == selected ? " selected" : ""
        return "<option value=\"\(escapeHTML(kind.rawValue))\"\(selectedAttribute)>\(escapeHTML(kind.displayName))</option>"
    }.joined()
}

private func makeConversationDriverLabelsJSON() -> String {
    let payload = ConversationDriverKind.allCases.reduce(into: [String: String]()) { partialResult, kind in
        partialResult[kind.rawValue] = kind.displayName
    }

    guard
        let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
        let string = String(data: data, encoding: .utf8)
    else {
        return "{}"
    }

    return string
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
