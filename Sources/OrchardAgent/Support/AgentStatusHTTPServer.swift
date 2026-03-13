import Foundation
import Network
import OrchardCore

final class AgentStatusHTTPServer: @unchecked Sendable {
    private let options: AgentStatusOptions
    private let statusService: AgentStatusService
    private let localActions: AgentStatusLocalActions?
    private let queue = DispatchQueue(label: "orchard.agent.status-http")
    private var listener: NWListener?

    init(
        options: AgentStatusOptions,
        statusService: AgentStatusService = AgentStatusService(),
        localActions: AgentStatusLocalActions? = nil
    ) {
        self.options = options
        self.statusService = statusService
        self.localActions = localActions
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
                localActionEnabled: localActions != nil
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
    static func render(options: AgentStatusOptions, localActionEnabled: Bool = false) -> String {
        let checked = options.includeRemote ? "checked" : ""
        let limitOptions = [5, 8, 12, 20].map { value in
            "<option value=\"\(value)\"\(value == options.limit ? " selected" : "")>\(value)</option>"
        }.joined()
        let remoteActionEnabled = options.accessKey?.nilIfEmpty != nil
        let localActionStatus = localActionEnabled ? "已启用" : "只读"
        let remoteActionStatus = remoteActionEnabled ? "已启用" : "未启用"
        let localActionHint = localActionEnabled
            ? "这就是宿主机真正在跑的控制台：可以直接发任务、补充说明、中断、终止，并实时看本地日志。"
            : "当前页面只接了状态读取，没有接到运行中的 OrchardAgent 实例，所以现在只能观察，不能直接发任务或控制本地任务。"
        let remoteActionHint = remoteActionEnabled
            ? "如果你打开了控制面访问密钥，这个页面也能顺手对远程托管 run / Codex 会话发继续、中断、停止。"
            : "没有配置访问密钥时，远程区块只做观察；先把宿主机这一层闭环跑通就够了。"

        return """
        <!doctype html>
        <html lang="zh-CN">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>OrchardAgent 本地状态页</title>
            <style>
              :root {
                --bg: #f5efe5;
                --panel: rgba(255, 250, 242, 0.92);
                --panel-strong: #fffaf3;
                --ink: #1f1a17;
                --muted: #6f655e;
                --line: rgba(58, 44, 35, 0.12);
                --accent: #116f61;
                --accent-strong: #0c574c;
                --accent-soft: rgba(17, 111, 97, 0.10);
                --warn: #a35a00;
                --danger: #9a3131;
                --shadow: 0 18px 48px rgba(71, 45, 28, 0.10);
              }

              * { box-sizing: border-box; }

              body {
                margin: 0;
                min-height: 100vh;
                font-family: "PingFang SC", "Noto Sans SC", sans-serif;
                color: var(--ink);
                background:
                  radial-gradient(circle at top left, rgba(17, 111, 97, 0.16), transparent 30%),
                  radial-gradient(circle at right 16%, rgba(163, 90, 0, 0.10), transparent 24%),
                  linear-gradient(180deg, #f7f1e8 0%, #efe6d8 100%);
              }

              .shell {
                width: min(1280px, calc(100vw - 24px));
                margin: 18px auto 32px;
              }

              .hero {
                background: linear-gradient(135deg, rgba(15, 84, 74, 0.98), rgba(28, 49, 43, 0.94));
                color: #f8f6ef;
                padding: 24px;
                border-radius: 28px;
                box-shadow: var(--shadow);
              }

              .hero-top {
                display: flex;
                justify-content: space-between;
                align-items: flex-start;
                gap: 18px;
              }

              .eyebrow {
                font-size: 12px;
                letter-spacing: 0.18em;
                text-transform: uppercase;
                opacity: 0.74;
                margin-bottom: 8px;
              }

              h1 {
                margin: 0;
                font-size: clamp(28px, 4vw, 44px);
                line-height: 1.02;
              }

              .hero p {
                margin: 12px 0 0;
                max-width: 840px;
                line-height: 1.68;
                color: rgba(248, 246, 239, 0.88);
              }

              .hero-side {
                display: grid;
                gap: 8px;
                min-width: 240px;
                text-align: right;
                font-size: 13px;
                color: rgba(248, 246, 239, 0.80);
              }

              .hero-checklist {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
                gap: 10px;
                margin-top: 18px;
              }

              .hero-checklist div {
                padding: 12px 14px;
                border-radius: 16px;
                background: rgba(255, 255, 255, 0.08);
                line-height: 1.55;
                font-size: 14px;
              }

              .toolbar {
                display: flex;
                flex-wrap: wrap;
                justify-content: space-between;
                gap: 12px;
                align-items: center;
                margin: 16px 0;
                padding: 14px 16px;
                border-radius: 20px;
                background: var(--panel);
                border: 1px solid var(--line);
                box-shadow: var(--shadow);
              }

              .toolbar-controls {
                display: flex;
                flex-wrap: wrap;
                gap: 12px;
                align-items: center;
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

              button,
              input,
              textarea,
              select {
                font: inherit;
              }

              button {
                border: 0;
                border-radius: 999px;
                padding: 11px 16px;
                background: var(--accent);
                color: #fff;
                cursor: pointer;
              }

              button.secondary {
                background: rgba(17, 111, 97, 0.12);
                color: var(--accent-strong);
              }

              button[disabled] {
                opacity: 0.5;
                cursor: not-allowed;
              }

              .stamp {
                font-size: 13px;
                color: var(--muted);
              }

              .metrics {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
                gap: 12px;
                margin-bottom: 16px;
              }

              .metric-card,
              .panel {
                background: var(--panel);
                border: 1px solid var(--line);
                border-radius: 22px;
                box-shadow: var(--shadow);
              }

              .metric-card {
                padding: 16px;
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

              .grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
                gap: 14px;
              }

              .panel {
                padding: 18px;
              }

              .panel.feature {
                grid-column: 1 / -1;
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

              .panel h2 {
                margin: 0;
                font-size: 20px;
              }

              .panel-subtitle {
                margin-top: 6px;
                color: var(--muted);
                line-height: 1.58;
              }

              .form-grid {
                display: grid;
                grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
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
                font-size: 13px;
                color: var(--muted);
              }

              input,
              textarea,
              select {
                width: 100%;
                padding: 12px 14px;
                border-radius: 14px;
                border: 1px solid rgba(58, 44, 35, 0.12);
                background: #fffdf9;
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
                display: flex;
                flex-wrap: wrap;
                gap: 12px;
                align-items: center;
                grid-column: 1 / -1;
              }

              .hint {
                font-size: 13px;
                color: var(--muted);
                line-height: 1.55;
              }

              .item-list {
                display: grid;
                gap: 10px;
              }

              .item {
                background: var(--panel-strong);
                border: 1px solid rgba(58, 44, 35, 0.08);
                border-radius: 16px;
                padding: 14px;
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
                background: rgba(163, 90, 0, 0.12);
                color: var(--warn);
              }

              .badge.danger {
                background: rgba(154, 49, 49, 0.12);
                color: var(--danger);
              }

              .meta {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
                margin-bottom: 8px;
              }

              .meta span {
                padding: 5px 9px;
                border-radius: 999px;
                background: rgba(30, 26, 23, 0.06);
                color: var(--muted);
                font-size: 12px;
              }

              .item p {
                margin: 0;
                color: var(--muted);
                line-height: 1.58;
                font-size: 14px;
              }

              .item-actions {
                display: flex;
                flex-wrap: wrap;
                gap: 8px;
                margin-top: 12px;
              }

              .action-button {
                padding: 8px 12px;
                border-radius: 999px;
                border: 0;
                background: rgba(17, 111, 97, 0.12);
                color: var(--accent-strong);
                font-size: 13px;
                font-weight: 700;
                cursor: pointer;
              }

              .action-button.secondary {
                background: rgba(17, 111, 97, 0.08);
                color: var(--muted);
              }

              .action-button.danger {
                background: rgba(154, 49, 49, 0.12);
                color: var(--danger);
              }

              .log-preview {
                margin-top: 10px;
                padding: 10px 12px;
                border-radius: 14px;
                background: rgba(24, 22, 20, 0.92);
                color: #efe8dc;
                font-size: 12px;
                line-height: 1.55;
                white-space: pre-wrap;
                word-break: break-word;
              }

              .empty {
                padding: 16px;
                border-radius: 16px;
                background: rgba(17, 111, 97, 0.06);
                color: var(--muted);
                line-height: 1.6;
              }

              .notice {
                margin-top: 12px;
                padding: 12px 14px;
                border-radius: 16px;
                background: rgba(163, 90, 0, 0.10);
                color: #7c470d;
                line-height: 1.58;
              }

              .notice.error {
                background: rgba(154, 49, 49, 0.10);
                color: var(--danger);
              }

              pre {
                margin: 0;
                white-space: pre-wrap;
                word-break: break-word;
                font-size: 12px;
                color: var(--muted);
              }

              @media (max-width: 760px) {
                .hero-top,
                .split-head {
                  flex-direction: column;
                }

                .hero-side {
                  text-align: left;
                  min-width: 0;
                }
              }
            </style>
          </head>
          <body>
            <div class="shell">
              <section class="hero">
                <div class="hero-top">
                  <div>
                    <div class="eyebrow">Host-First Console</div>
                    <h1>先把宿主机闭环跑通</h1>
                    <p>这页先解决最基础、也最关键的一层：直接在宿主机发 Codex 任务，实时观察执行和日志，在等待时补充说明，需要时中断或终止。等这层稳定后，Orchard 控制平面只需要复用同一条控制链路。</p>
                  </div>
                  <div class="hero-side">
                    <div>监听地址：http://\(escapeHTML(options.bindHost)):\(options.port)</div>
                    <div>宿主机控制：\(escapeHTML(localActionStatus))</div>
                    <div>远程动作：\(escapeHTML(remoteActionStatus))</div>
                    <div>状态接口：`/api/status`</div>
                  </div>
                </div>
                <div class="hero-checklist">
                  <div><strong>1. 发任务</strong><br>直接在本机起一个 Codex managed run，不用先走控制面调度。</div>
                  <div><strong>2. 观察</strong><br>同时看任务状态、最后回复、最近日志，确认执行是否真的活着。</div>
                  <div><strong>3. 补充说明</strong><br>当任务等待输入时，在这里直接追问或补充要求。</div>
                  <div><strong>4. 中断 / 终止</strong><br>区分“打断当前轮次”和“彻底停掉整个任务”，把恢复闭环坐实。</div>
                </div>
                <div class="notice" style="margin-top: 16px; background: rgba(255, 255, 255, 0.08); color: rgba(248, 246, 239, 0.90);">\(escapeHTML(localActionHint))</div>
                <div class="notice" style="margin-top: 10px; background: rgba(255, 255, 255, 0.08); color: rgba(248, 246, 239, 0.90);">\(escapeHTML(remoteActionHint))</div>
              </section>

              <section class="toolbar">
                <div class="toolbar-controls">
                  <label class="toggle">
                    <input type="checkbox" id="remote-toggle" \(checked)>
                    <span>顺便查看控制面视角</span>
                  </label>
                  <label class="toggle">
                    <span>列表上限</span>
                    <select id="limit-select">\(limitOptions)</select>
                  </label>
                  <button id="refresh-button">立即刷新</button>
                  <button id="copy-button" class="secondary">复制 JSON</button>
                </div>
                <div class="stamp" id="stamp">等待首次刷新…</div>
              </section>

              <section class="metrics" id="metrics"></section>

              <section class="grid">
                <article class="panel feature">
                  <div class="split-head">
                    <div>
                      <h2>1. 直接在宿主机发任务</h2>
                      <div class="panel-subtitle">这里发起的任务会直接复用 OrchardAgent 的本地 managed controller。后面控制平面远端要做的，就是调用这同一层能力。</div>
                    </div>
                    <span class="panel-tag">本地直连</span>
                  </div>
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
                        <label class="field field-wide">
                          <span>相对路径（可选）</span>
                          <input id="create-relative-path" type="text" placeholder="例如 Sources/OrchardAgent；留空就是工作区根目录">
                        </label>
                        <label class="field field-wide">
                          <span>要 Codex 做什么</span>
                          <textarea id="create-prompt" placeholder="例如：验证断网 / 断连接恢复闭环，并给出修复建议"></textarea>
                        </label>
                        <div class="form-actions">
                          <button id="create-submit" type="submit">在宿主机发起任务</button>
                          <span class="hint" id="create-hint">\(escapeHTML(localActionHint))</span>
                        </div>
                      </div>
                    </fieldset>
                  </form>
                </article>

                <article class="panel">
                  <div class="split-head">
                    <div>
                      <h2>2. 观察本地任务</h2>
                      <div class="panel-subtitle">这里是宿主机真实运行态：任务状态、最近一句回复、最后几行日志，都直接来自本地运行目录。</div>
                    </div>
                    <span class="panel-tag">最重要</span>
                  </div>
                  <div id="local-tasks"></div>
                </article>

                <article class="panel">
                  <div class="split-head">
                    <div>
                      <h2>3. 看上报是否卡住</h2>
                      <div class="panel-subtitle">如果链路抖动、断网或断连接，这里会保留还没成功同步出去的更新，帮助验证自动恢复是否闭环。</div>
                    </div>
                    <span class="panel-tag">恢复观测</span>
                  </div>
                  <div id="pending-updates"></div>
                </article>

                <article class="panel">
                  <div class="split-head">
                    <div>
                      <h2>4. 远程托管运行（次要）</h2>
                      <div class="panel-subtitle">当宿主机这层已经稳定后，再来看控制面分配到本机的托管 run 是否能继续 / 中断 / 停止。</div>
                    </div>
                    <span class="panel-tag">控制面</span>
                  </div>
                  <div id="remote-managed-runs"></div>
                </article>

                <article class="panel">
                  <div class="split-head">
                    <div>
                      <h2>5. 远程 Codex 会话（次要）</h2>
                      <div class="panel-subtitle">这是控制面聚合出来的本机 Codex 会话，用来对照宿主机真实状态，确认远端观察是否跟得上。</div>
                    </div>
                    <span class="panel-tag">对照</span>
                  </div>
                  <div id="remote-codex-sessions"></div>
                </article>
              </section>

              <section class="panel" style="margin-top: 14px;">
                <div class="split-head">
                  <div>
                    <h2>原始 JSON</h2>
                    <div class="panel-subtitle">如果 UI 还是不够直观，就直接看原始数据；字段含义也能和后端返回一一对上。</div>
                  </div>
                  <span class="panel-tag">排障</span>
                </div>
                <pre id="raw-json">等待首次刷新…</pre>
              </section>
            </div>

            <script>
              const hasLocalControl = \(localActionEnabled ? "true" : "false");
              const hasRemoteActions = \(remoteActionEnabled ? "true" : "false");

              const stamp = document.getElementById('stamp');
              const metrics = document.getElementById('metrics');
              const localTasks = document.getElementById('local-tasks');
              const pendingUpdates = document.getElementById('pending-updates');
              const remoteManagedRuns = document.getElementById('remote-managed-runs');
              const remoteCodexSessions = document.getElementById('remote-codex-sessions');
              const rawJSON = document.getElementById('raw-json');
              const refreshButton = document.getElementById('refresh-button');
              const copyButton = document.getElementById('copy-button');
              const remoteToggle = document.getElementById('remote-toggle');
              const limitSelect = document.getElementById('limit-select');
              const localCreateForm = document.getElementById('local-create-form');
              const localCreateFieldset = document.getElementById('local-create-fieldset');
              const createTitleInput = document.getElementById('create-title');
              const createWorkspaceSelect = document.getElementById('create-workspace');
              const createRelativePathInput = document.getElementById('create-relative-path');
              const createPromptInput = document.getElementById('create-prompt');
              const createHint = document.getElementById('create-hint');

              localCreateFieldset.disabled = !hasLocalControl;
              if (!hasLocalControl) {
                createHint.textContent = '当前页面没有接到运行中的 OrchardAgent，所以现在只能观察，不能直接发本地任务。';
              }

              let lastPayload = null;

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

              function normalizeRelativePath(value) {
                const trimmed = String(value || '').trim();
                if (!trimmed || trimmed === '.' || trimmed === './') return '';
                return trimmed.replace(/^\\.\\//, '');
              }

              function defaultLocalTaskTitle(prompt) {
                const firstLine = String(prompt || '')
                  .split(/\r?\n/)
                  .map((line) => line.trim())
                  .find((line) => line.length > 0) || '新的本地 Codex 任务';
                return firstLine.length <= 28 ? firstLine : `${firstLine.slice(0, 28)}...`;
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
                  return;
                }

                createWorkspaceSelect.innerHTML = items.map((workspace) => `
                  <option value="${escapeHTML(workspace.id)}">${escapeHTML(workspace.name || workspace.id)} · ${escapeHTML(workspace.id)}</option>
                `).join('');

                const fallback = items[0].id;
                createWorkspaceSelect.value = items.some((workspace) => workspace.id === previous) ? previous : fallback;
              }

              function canContinueLocalTask(task) {
                return hasLocalControl
                  && task?.task?.kind === 'codex'
                  && task?.managedRunStatus === 'waitingInput'
                  && Boolean(task?.task?.id);
              }

              function canInterruptLocalTask(task) {
                return hasLocalControl
                  && task?.task?.kind === 'codex'
                  && ['running', 'waitingInput', 'interrupting'].includes(task?.managedRunStatus)
                  && Boolean(task?.task?.id);
              }

              function canStopLocalTask(task) {
                const status = task?.managedRunStatus || task?.task?.status;
                return Boolean(task?.task?.id)
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

              function renderLocalTask(task) {
                const status = task.managedRunStatus ? statusTitleForManagedRun(task.managedRunStatus) : statusTitleForTask(task.task?.status);
                const actions = [];
                if (canContinueLocalTask(task)) {
                  actions.push(actionButton('补充说明', 'continue-local-managed', { taskId: task.task?.id || '' }));
                }
                if (canInterruptLocalTask(task)) {
                  actions.push(actionButton('中断', 'interrupt-local-managed', { taskId: task.task?.id || '' }, 'secondary'));
                }
                if (canStopLocalTask(task)) {
                  actions.push(actionButton('终止', localStopAction(task), { taskId: task.task?.id || '' }, 'danger'));
                }

                const logPreview = Array.isArray(task.recentLogLines) && task.recentLogLines.length
                  ? `<div class="log-preview">${escapeHTML(task.recentLogLines.join('\n'))}</div>`
                  : '';

                return `
                  <article class="item">
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(task.task?.title || task.task?.id || '未命名任务')}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      <span>${escapeHTML(task.task?.kind === 'codex' ? 'Codex' : 'Shell')}</span>
                      <span>${escapeHTML(task.task?.workspaceID || '—')}</span>
                      <span>${escapeHTML(task.task?.relativePath || '工作区根目录')}</span>
                      ${task.pid ? `<span>PID ${escapeHTML(task.pid)}</span>` : ''}
                      ${task.codexThreadID ? `<span>线程 ${escapeHTML(task.codexThreadID)}</span>` : ''}
                    </div>
                    <p>${escapeHTML(task.lastAssistantPreview || task.lastUserPrompt || task.cwd || task.runtimeWarning || '当前没有额外摘要。')}</p>
                    ${actions.length ? `<div class="item-actions">${actions.join('')}</div>` : ''}
                    ${logPreview}
                  </article>
                `;
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

              function renderMetrics(snapshot) {
                const codexDesktop = snapshot.local?.metrics?.codexDesktop || {};
                metrics.innerHTML = [
                  metricCard('本地活动任务', snapshot.local?.activeTasks?.length || 0, '宿主机真实运行中的任务数'),
                  metricCard('待回传更新', snapshot.local?.pendingUpdates?.length || 0, '断线时这里会先积压'),
                  metricCard('桌面活跃线程', codexDesktop.activeThreadCount ?? 0, '来自 Codex sentry 快照'),
                  metricCard('进行中轮次', codexDesktop.inflightTurnCount ?? 0, '用于对照 UI 是否真在跑'),
                  metricCard('远程总运行中', snapshot.remote?.totalRunningCount ?? 0, snapshot.remote ? '控制面看到的总运行量' : '当前未读取远程'),
                  metricCard('远程托管运行', snapshot.remote?.runningManagedRunCount ?? 0, snapshot.remote ? '已占槽的托管 run' : '当前未读取远程'),
                  metricCard('远程独立任务', snapshot.remote?.unmanagedRunningTaskCount ?? 0, snapshot.remote ? '非托管任务数量' : '当前未读取远程'),
                  metricCard('远程 Codex 推理', snapshot.remote?.observedRunningCodexCount ?? 0, snapshot.remote ? '控制面观察到的推理数' : '当前未读取远程')
                ].join('');
              }

              function renderSnapshot(snapshot) {
                lastPayload = snapshot;
                stamp.textContent = `${snapshot.deviceName} · ${snapshot.deviceID} · 最近刷新 ${formatDate(snapshot.generatedAt)}`;
                populateWorkspaceOptions(snapshot.workspaces || []);
                renderMetrics(snapshot);

                localTasks.innerHTML = renderItemList(
                  snapshot.local?.activeTasks || [],
                  '当前宿主机本地没有活动任务。',
                  renderLocalTask
                );

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

                if (snapshot.local?.warnings?.length) {
                  localTasks.insertAdjacentHTML('beforeend', `<div class="notice">${snapshot.local.warnings.map(escapeHTML).join('<br>')}</div>`);
                }

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

              document.addEventListener('click', async (event) => {
                const button = event.target.closest('button[data-action]');
                if (!button) return;

                const action = button.dataset.action;
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

              localCreateForm.addEventListener('submit', async (event) => {
                event.preventDefault();
                if (!hasLocalControl) return;

                const prompt = createPromptInput.value.trim();
                const workspaceID = createWorkspaceSelect.value;
                const relativePath = normalizeRelativePath(createRelativePathInput.value);
                const title = (createTitleInput.value.trim() || defaultLocalTaskTitle(prompt)).trim();

                if (!workspaceID) {
                  stamp.textContent = '请先选择工作区。';
                  return;
                }
                if (!prompt) {
                  stamp.textContent = '请先输入任务说明。';
                  return;
                }

                const submitButton = document.getElementById('create-submit');
                const previousLabel = submitButton.textContent;
                submitButton.disabled = true;
                submitButton.textContent = '发起中...';

                try {
                  createTitleInput.value = title;
                  const payload = await postJSON('/api/local-managed-runs', {
                    title,
                    workspaceID,
                    relativePath: relativePath || null,
                    prompt
                  });
                  stamp.textContent = payload?.taskID
                    ? `已在宿主机发起任务 ${payload.taskID}`
                    : '已在宿主机发起任务';
                  createPromptInput.value = '';
                  await refreshSnapshot();
                } catch (error) {
                  stamp.textContent = `发起失败：${error.message || error}`;
                } finally {
                  submitButton.disabled = false;
                  submitButton.textContent = previousLabel;
                }
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

              refreshSnapshot();
              setInterval(refreshSnapshot, 4000);
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

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
