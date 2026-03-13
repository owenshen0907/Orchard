import Foundation
import OrchardCore
import Vapor

final class CodexSessionProxyService: @unchecked Sendable {
    private let store: OrchardControlPlaneStore
    private let registry: AgentConnectionRegistry
    private let broker: AgentCodexCommandBroker
    private let requestTimeout: TimeInterval

    init(
        store: OrchardControlPlaneStore,
        registry: AgentConnectionRegistry,
        broker: AgentCodexCommandBroker,
        requestTimeout: TimeInterval = 15
    ) {
        self.store = store
        self.registry = registry
        self.broker = broker
        self.requestTimeout = requestTimeout
    }

    func listSessions(deviceID: String? = nil, limit: Int = 20) async throws -> [CodexSessionSummary] {
        let sanitizedLimit = min(max(limit, 1), 50)

        if let deviceID, !deviceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let device = try await requireAvailableCodexDevice(deviceID: deviceID)
            return try await listSessions(on: device, limit: sanitizedLimit)
        }

        let devices = try await store.listDevices()
            .filter { $0.status == .online && $0.capabilities.contains(.codex) }

        guard !devices.isEmpty else {
            return []
        }

        return await withTaskGroup(of: [CodexSessionSummary].self) { group in
            for device in devices {
                group.addTask {
                    (try? await self.listSessions(on: device, limit: sanitizedLimit)) ?? []
                }
            }

            var merged: [CodexSessionSummary] = []
            for await sessions in group {
                merged.append(contentsOf: sessions)
            }

            return merged.sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    return lhs.state == .running
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id < rhs.id
            }
        }
    }

    func fetchSessionDetail(deviceID: String, sessionID: String) async throws -> CodexSessionDetail {
        let device = try await requireAvailableCodexDevice(deviceID: deviceID)
        let response = try await sendCommand(
            to: deviceID,
            action: .readSession,
            sessionID: sessionID,
            prompt: nil,
            limit: nil
        )

        if let errorMessage = response.errorMessage {
            throw Abort(.badGateway, reason: errorMessage)
        }
        guard let detail = response.detail else {
            throw Abort(.badGateway, reason: "Agent 未返回 Codex 会话详情。")
        }
        return enriched(detail, for: device)
    }

    func continueSession(deviceID: String, sessionID: String, prompt: String) async throws -> CodexSessionDetail {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw Abort(.badRequest, reason: "继续追问内容不能为空。")
        }
        let device = try await requireAvailableCodexDevice(deviceID: deviceID)
        let response = try await sendCommand(
            to: deviceID,
            action: .continueSession,
            sessionID: sessionID,
            prompt: trimmedPrompt,
            limit: nil
        )

        if let errorMessage = response.errorMessage {
            throw Abort(.badGateway, reason: errorMessage)
        }
        guard let detail = response.detail else {
            throw Abort(.badGateway, reason: "Agent 未返回更新后的 Codex 会话。")
        }
        return enriched(detail, for: device)
    }

    func interruptSession(deviceID: String, sessionID: String) async throws -> CodexSessionDetail {
        let device = try await requireAvailableCodexDevice(deviceID: deviceID)
        let response = try await sendCommand(
            to: deviceID,
            action: .interruptSession,
            sessionID: sessionID,
            prompt: nil,
            limit: nil
        )

        if let errorMessage = response.errorMessage {
            throw Abort(.badGateway, reason: errorMessage)
        }
        guard let detail = response.detail else {
            throw Abort(.badGateway, reason: "Agent 未返回中断后的 Codex 会话。")
        }
        return enriched(detail, for: device)
    }

    private func listSessions(on device: DeviceRecord, limit: Int) async throws -> [CodexSessionSummary] {
        let response = try await sendCommand(
            to: device.deviceID,
            action: .listSessions,
            sessionID: nil,
            prompt: nil,
            limit: limit
        )

        if let errorMessage = response.errorMessage {
            throw Abort(.badGateway, reason: errorMessage)
        }
        return (response.sessions ?? []).map { enriched($0, for: device) }
    }

    private func enriched(_ detail: CodexSessionDetail, for device: DeviceRecord) -> CodexSessionDetail {
        CodexSessionDetail(
            session: enriched(detail.session, for: device),
            turns: detail.turns,
            items: detail.items
        )
    }

    private func enriched(_ session: CodexSessionSummary, for device: DeviceRecord) -> CodexSessionSummary {
        guard session.workspaceID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
            return session
        }

        var session = session
        session.workspaceID = OrchardWorkspaceLocator.bestMatch(for: session.cwd, workspaces: device.workspaces)?.id
        return session
    }

    private func sendCommand(
        to deviceID: String,
        action: AgentCodexCommandAction,
        sessionID: String?,
        prompt: String?,
        limit: Int?
    ) async throws -> AgentCodexCommandResponse {
        let requestID = UUID().uuidString.lowercased()
        await broker.clear(requestID: requestID)

        let request = AgentCodexCommandRequest(
            requestID: requestID,
            action: action,
            sessionID: sessionID,
            prompt: prompt,
            limit: limit
        )

        guard await registry.send(.codexCommand(request), to: deviceID) else {
            throw Abort(.serviceUnavailable, reason: "目标设备当前未连接，无法代理 Codex 会话。")
        }

        let deadline = Date().addingTimeInterval(requestTimeout)
        while Date() < deadline {
            if let response = await broker.take(requestID: requestID) {
                return response
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw Abort(.gatewayTimeout, reason: "等待设备返回 Codex 会话结果超时。")
    }

    private func requireAvailableCodexDevice(deviceID: String) async throws -> DeviceRecord {
        let device = try await store.requireDevice(deviceID: deviceID)
        guard device.capabilities.contains(.codex) else {
            throw Abort(.badRequest, reason: "目标设备未声明 Codex 能力。")
        }
        guard device.status == .online else {
            throw Abort(.serviceUnavailable, reason: "目标设备当前离线。")
        }
        return device
    }
}
