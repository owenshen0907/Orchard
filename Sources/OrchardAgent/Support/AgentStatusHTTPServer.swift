import Foundation
import Network
import OrchardCore

final class AgentStatusHTTPServer: @unchecked Sendable {
    private let options: AgentStatusOptions
    private let statusService: AgentStatusService
    private let queue = DispatchQueue(label: "orchard.agent.status-http")
    private var listener: NWListener?

    init(
        options: AgentStatusOptions,
        statusService: AgentStatusService = AgentStatusService()
    ) {
        self.options = options
        self.statusService = statusService
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
            return .html(AgentStatusPageRenderer.render(options: options))
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
            if components.count == 4,
               components[0] == "api",
               components[1] == "local-tasks",
               components[3] == "stop" {
                let taskID = components[2]
                _ = try await makeRemoteClient().stopTask(
                    taskID: taskID,
                    reason: "宿主本地状态页请求停止"
                )
                return .jsonMessage("已发送停止指令")
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
    static func render(options: AgentStatusOptions) -> String {
        let checked = options.includeRemote ? "checked" : ""
        let remoteActionStatus = options.accessKey?.nilIfEmpty == nil ? "未启用" : "已启用"
        let remoteActionHint = options.accessKey?.nilIfEmpty == nil
            ? "当前未配置访问密钥，本地页只能查看，不能继续/中断/停止远程任务。"
            : "当前已配置访问密钥，本地页可以直接对控制面里的任务发继续 / 中断 / 停止指令。"
        return """
        <!doctype html>
        <html lang="zh-CN">
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>OrchardAgent 本地状态页</title>
            <style>
              :root {
                --bg: #f4efe6;
                --panel: rgba(255, 250, 242, 0.9);
                --panel-strong: #fffaf2;
                --ink: #1e1a17;
                --muted: #6f645d;
                --line: rgba(58, 44, 35, 0.12);
                --accent: #117a65;
                --accent-strong: #0a594b;
                --warn: #b35c00;
                --danger: #9d2d2d;
                --shadow: 0 18px 50px rgba(71, 45, 28, 0.10);
              }

              * { box-sizing: border-box; }

              body {
                margin: 0;
                min-height: 100vh;
                font-family: "PingFang SC", "Noto Sans SC", sans-serif;
                color: var(--ink);
                background:
                  radial-gradient(circle at top left, rgba(17, 122, 101, 0.16), transparent 32%),
                  radial-gradient(circle at right 20%, rgba(179, 92, 0, 0.10), transparent 24%),
                  linear-gradient(180deg, #f6f0e5 0%, #efe6d9 100%);
              }

              .shell {
                width: min(1240px, calc(100vw - 24px));
                margin: 20px auto 32px;
              }

              .hero {
                background: linear-gradient(135deg, rgba(15, 91, 78, 0.96), rgba(23, 52, 46, 0.92));
                color: #f7f5ef;
                padding: 22px 24px;
                border-radius: 26px;
                box-shadow: var(--shadow);
              }

              .hero-top {
                display: flex;
                justify-content: space-between;
                gap: 16px;
                align-items: flex-start;
              }

              .eyebrow {
                font-size: 12px;
                letter-spacing: 0.16em;
                text-transform: uppercase;
                opacity: 0.72;
                margin-bottom: 8px;
              }

              h1 {
                margin: 0;
                font-size: clamp(28px, 4vw, 42px);
                line-height: 1.02;
              }

              .hero p {
                margin: 10px 0 0;
                max-width: 780px;
                line-height: 1.6;
                color: rgba(247, 245, 239, 0.84);
              }

              .hero-side {
                display: grid;
                gap: 6px;
                text-align: right;
                font-size: 13px;
                color: rgba(247, 245, 239, 0.78);
              }

              .toolbar {
                display: flex;
                flex-wrap: wrap;
                gap: 12px;
                align-items: center;
                justify-content: space-between;
                margin: 18px 0 16px;
                padding: 14px 16px;
                border-radius: 20px;
                background: var(--panel);
                box-shadow: var(--shadow);
                border: 1px solid var(--line);
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
                font-size: 14px;
                color: var(--muted);
              }

              .toggle input {
                width: 18px;
                height: 18px;
                accent-color: var(--accent);
              }

              button {
                border: 0;
                border-radius: 999px;
                padding: 11px 16px;
                background: var(--accent);
                color: #fff;
                font: inherit;
                cursor: pointer;
              }

              button.secondary {
                background: rgba(17, 122, 101, 0.12);
                color: var(--accent-strong);
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
                margin-bottom: 10px;
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

              .panel h2 {
                margin: 0 0 10px;
                font-size: 20px;
              }

              .panel-subtitle {
                color: var(--muted);
                margin-bottom: 14px;
                line-height: 1.5;
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
                gap: 10px;
                align-items: flex-start;
                justify-content: space-between;
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
                background: rgba(17, 122, 101, 0.12);
                color: var(--accent-strong);
              }

              .badge.warn {
                background: rgba(179, 92, 0, 0.12);
                color: var(--warn);
              }

              .badge.danger {
                background: rgba(157, 45, 45, 0.12);
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
                line-height: 1.55;
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
                font-size: 13px;
                font-weight: 700;
                cursor: pointer;
                background: rgba(17, 122, 101, 0.12);
                color: var(--accent-strong);
              }

              .action-button.secondary {
                background: rgba(17, 122, 101, 0.08);
                color: var(--muted);
              }

              .action-button.danger {
                background: rgba(157, 45, 45, 0.12);
                color: var(--danger);
              }

              .action-button[disabled] {
                opacity: 0.45;
                cursor: not-allowed;
              }

              .empty {
                padding: 16px;
                border-radius: 16px;
                background: rgba(17, 122, 101, 0.06);
                color: var(--muted);
                line-height: 1.6;
              }

              .notice {
                margin-top: 14px;
                padding: 12px 14px;
                border-radius: 16px;
                background: rgba(179, 92, 0, 0.10);
                color: #7c470d;
                line-height: 1.55;
              }

              .notice.error {
                background: rgba(157, 45, 45, 0.10);
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
                .hero-top {
                  flex-direction: column;
                }

                .hero-side {
                  text-align: left;
                }

                .toolbar {
                  align-items: flex-start;
                }
              }
            </style>
          </head>
          <body>
            <div class="shell">
              <section class="hero">
                <div class="hero-top">
                  <div>
                    <div class="eyebrow">Local Host Console</div>
                    <h1>OrchardAgent 本地状态页</h1>
                    <p>这里直接看宿主机本地执行中的任务、待回传更新、Codex 桌面活跃线程，以及控制面里指向本机的托管 run / 会话。</p>
                  </div>
                  <div class="hero-side">
                    <div>监听地址：http://\(escapeHTML(options.bindHost)):\(options.port)</div>
                    <div>刷新方式：页面自动轮询</div>
                    <div>接口：`/api/status`</div>
                    <div>远程动作：\(remoteActionStatus)</div>
                  </div>
                </div>
                <div class="notice\(options.accessKey?.nilIfEmpty == nil ? "" : "")" style="margin-top: 14px; background: rgba(255,255,255,0.08); color: rgba(247,245,239,0.88);">
                  \(escapeHTML(remoteActionHint))
                </div>
              </section>

              <section class="toolbar">
                <div class="toolbar-controls">
                  <label class="toggle">
                    <input type="checkbox" id="remote-toggle" \(checked)>
                    <span>包含控制面视角</span>
                  </label>
                  <label class="toggle">
                    <span>列表上限</span>
                    <select id="limit-select">
                      <option value="5">5</option>
                      <option value="8" selected>8</option>
                      <option value="12">12</option>
                      <option value="20">20</option>
                    </select>
                  </label>
                  <button id="refresh-button">立即刷新</button>
                  <button id="copy-button" class="secondary">复制 JSON</button>
                </div>
                <div class="stamp" id="stamp">等待首次刷新…</div>
              </section>

              <section class="metrics" id="metrics"></section>

              <section class="grid">
                <article class="panel">
                  <h2>本地活动任务</h2>
                  <div class="panel-subtitle">直接来自宿主机运行目录与 `agent-state.json`，不依赖控制面是否显示正常。</div>
                  <div id="local-tasks"></div>
                </article>

                <article class="panel">
                  <h2>待回传更新</h2>
                  <div class="panel-subtitle">如果 WebSocket 或上报链路抖动，这里会显示尚未同步到控制面的状态更新。</div>
                  <div id="pending-updates"></div>
                </article>

                <article class="panel">
                  <h2>远程托管运行</h2>
                  <div class="panel-subtitle">控制面里已经分配给本机，或已指定本机但尚未接手的托管 run。</div>
                  <div id="remote-managed-runs"></div>
                </article>

                <article class="panel">
                  <h2>远程 Codex 会话</h2>
                  <div class="panel-subtitle">控制面从本机同步出来的 Codex 会话列表，可用来和本地桌面快照对照。</div>
                  <div id="remote-codex-sessions"></div>
                </article>
              </section>

              <section class="panel" style="margin-top: 14px;">
                <h2>原始 JSON</h2>
                <div class="panel-subtitle">排查字段映射问题时，直接看原始返回最稳。</div>
                <pre id="raw-json">等待首次刷新…</pre>
              </section>
            </div>

            <script>
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
              const hasRemoteActions = \(options.accessKey?.nilIfEmpty == nil ? "false" : "true");

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
                const danger = ['失败', '已取消'];
                const warn = ['停止中', '中断中', '等待输入', '排队中'];
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

              function actionButton(label, action, attrs = {}, tone = '') {
                const attributes = Object.entries(attrs)
                  .map(([key, value]) => `data-${key}="${escapeHTML(value)}"`)
                  .join(' ');
                const toneClass = tone ? ` ${tone}` : '';
                const disabled = hasRemoteActions ? '' : ' disabled';
                return `<button class="action-button${toneClass}" data-action="${escapeHTML(action)}" ${attributes}${disabled}>${escapeHTML(label)}</button>`;
              }

              function renderLocalTask(task) {
                const status = task.managedRunStatus ? statusTitleForManagedRun(task.managedRunStatus) : statusTitleForTask(task.task?.status);
                const actions = [];
                if (canStopLocalTask(task)) {
                  actions.push(actionButton('停止', 'stop-local-task', { taskId: task.task?.id || '' }, 'danger'));
                }
                return `
                  <article class="item">
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(task.task?.title || task.task?.id || '未命名任务')}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      <span>${escapeHTML(task.task?.kind === 'codex' ? 'Codex' : 'Shell')}</span>
                      <span>${escapeHTML(task.task?.workspaceID || '—')}</span>
                      ${task.pid ? `<span>PID ${escapeHTML(task.pid)}</span>` : ''}
                      ${task.codexThreadID ? `<span>线程 ${escapeHTML(task.codexThreadID)}</span>` : ''}
                      ${task.task?.relativePath ? `<span>${escapeHTML(task.task.relativePath)}</span>` : '<span>工作区根目录</span>'}
                    </div>
                    <p>${escapeHTML(task.lastAssistantPreview || task.lastUserPrompt || task.cwd || task.runtimeWarning || '当前没有额外摘要。')}</p>
                    ${actions.length ? `<div class="item-actions">${actions.join('')}</div>` : ''}
                  </article>
                `;
              }

              function renderPendingUpdate(update) {
                const status = statusTitleForTask(update.status);
                return `
                  <article class="item">
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(update.taskID)}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      ${update.exitCode !== null && update.exitCode !== undefined ? `<span>exit ${escapeHTML(update.exitCode)}</span>` : ''}
                      ${update.codexSessionID ? `<span>会话 ${escapeHTML(update.codexSessionID)}</span>` : ''}
                    </div>
                    <p>${escapeHTML(update.summary || '没有摘要')}</p>
                  </article>
                `;
              }

              function renderManagedRun(run) {
                const status = statusTitleForManagedRun(run.status);
                const actions = [];
                if (canContinueManagedRun(run)) {
                  actions.push(actionButton('继续', 'continue-managed-run', { runId: run.id }));
                }
                if (canInterruptManagedRun(run)) {
                  actions.push(actionButton('中断', 'interrupt-managed-run', { runId: run.id }, 'secondary'));
                }
                if (canStopManagedRun(run)) {
                  actions.push(actionButton('停止', 'stop-managed-run', { runId: run.id }, 'danger'));
                }
                return `
                  <article class="item">
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(run.title)}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      <span>${escapeHTML(run.workspaceID)}</span>
                      <span>${escapeHTML(run.relativePath || '工作区根目录')}</span>
                      <span>${escapeHTML(run.deviceID || `待分配 -> ${run.preferredDeviceID || '未指定'}`)}</span>
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
                  actions.push(actionButton('继续', 'continue-codex-session', { deviceId: session.deviceID, sessionId: session.id }));
                }
                if (canInterruptSession(session)) {
                  actions.push(actionButton('中断', 'interrupt-codex-session', { deviceId: session.deviceID, sessionId: session.id }, 'secondary'));
                }
                return `
                  <article class="item">
                    <div class="item-head">
                      <div class="item-title">${escapeHTML(session.name || session.preview || session.id)}</div>
                      <span class="${badgeClass(status)}">${escapeHTML(status)}</span>
                    </div>
                    <div class="meta">
                      <span>${escapeHTML(session.workspaceID || '未映射工作区')}</span>
                      <span>${escapeHTML(session.cwd)}</span>
                    </div>
                    <p>${escapeHTML(session.lastAssistantMessage || session.lastUserMessage || session.preview || '当前没有额外摘要。')}</p>
                    ${actions.length ? `<div class="item-actions">${actions.join('')}</div>` : ''}
                  </article>
                `;
              }

              function canStopLocalTask(task) {
                if (!hasRemoteActions) return false;
                const status = task?.task?.status;
                return Boolean(task?.task?.id) && status && !['succeeded', 'failed', 'cancelled', 'stopRequested'].includes(status);
              }

              function canContinueManagedRun(run) {
                return hasRemoteActions && run?.status === 'waitingInput' && Boolean(run?.codexSessionID);
              }

              function canInterruptManagedRun(run) {
                return hasRemoteActions && ['running', 'waitingInput'].includes(run?.status) && Boolean(run?.codexSessionID);
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
                if (session.lastTurnStatus === 'inProgress' || session.state === 'running') return '推理中';
                switch (session.state) {
                  case 'idle': return '待命';
                  case 'completed': return '已完成';
                  case 'failed': return '失败';
                  case 'interrupted': return '已中断';
                  default: return session.state || '未知';
                }
              }

              function renderMetrics(snapshot) {
                const codexDesktop = snapshot.local?.metrics?.codexDesktop || {};
                metrics.innerHTML = [
                  metricCard('本地活动任务', snapshot.local?.activeTasks?.length || 0, '直接来自宿主机运行目录'),
                  metricCard('待回传更新', snapshot.local?.pendingUpdates?.length || 0, '链路抖动时这里先可见'),
                  metricCard('桌面活跃线程', codexDesktop.activeThreadCount ?? 0, '来自 Codex sentry 快照'),
                  metricCard('进行中轮次', codexDesktop.inflightTurnCount ?? 0, '即使控制面未刷新也能看到'),
                  metricCard('远程总运行中', snapshot.remote?.totalRunningCount ?? 0, snapshot.remote ? '托管 + 独立任务 + Codex 推理' : '未启用远程'),
                  metricCard('远程托管运行', snapshot.remote?.runningManagedRunCount ?? 0, snapshot.remote ? '当前占槽 run' : '未启用远程'),
                  metricCard('远程独立任务', snapshot.remote?.unmanagedRunningTaskCount ?? 0, snapshot.remote ? '直接走 /api/tasks' : '未启用远程'),
                  metricCard('远程 Codex 推理', snapshot.remote?.observedRunningCodexCount ?? 0, snapshot.remote ? '会话 running + inflight 兜底' : '未启用远程')
                ].join('');
              }

              function renderSnapshot(snapshot) {
                lastPayload = snapshot;
                stamp.textContent = `${snapshot.deviceName} · ${snapshot.deviceID} · 最近刷新 ${formatDate(snapshot.generatedAt)}`;
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
                  remoteManagedRuns.insertAdjacentHTML('beforeend', `<div class="notice">${escapeHTML(snapshot.remote.fetchError)}</div>`);
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
                  button.disabled = !hasRemoteActions;
                  button.textContent = previousLabel;
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
