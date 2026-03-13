import Foundation
import OrchardCore
import Vapor

final class ProjectContextProxyService: @unchecked Sendable {
    private let store: OrchardControlPlaneStore
    private let registry: AgentConnectionRegistry
    private let broker: AgentProjectContextCommandBroker
    private let requestTimeout: TimeInterval

    init(
        store: OrchardControlPlaneStore,
        registry: AgentConnectionRegistry,
        broker: AgentProjectContextCommandBroker,
        requestTimeout: TimeInterval = 15
    ) {
        self.store = store
        self.registry = registry
        self.broker = broker
        self.requestTimeout = requestTimeout
    }

    func fetchSummary(deviceID: String, workspaceID: String) async throws -> AgentProjectContextCommandResponse {
        _ = try await requireAvailableWorkspace(deviceID: deviceID, workspaceID: workspaceID)
        return try await sendCommand(
            to: deviceID,
            workspaceID: workspaceID,
            action: .summary,
            subject: nil,
            selector: nil
        )
    }

    func lookup(
        deviceID: String,
        workspaceID: String,
        subject: ProjectContextRemoteSubject,
        selector: String?
    ) async throws -> AgentProjectContextCommandResponse {
        _ = try await requireAvailableWorkspace(deviceID: deviceID, workspaceID: workspaceID)
        return try await sendCommand(
            to: deviceID,
            workspaceID: workspaceID,
            action: .lookup,
            subject: subject,
            selector: normalizeSelector(selector)
        )
    }

    private func sendCommand(
        to deviceID: String,
        workspaceID: String,
        action: AgentProjectContextCommandAction,
        subject: ProjectContextRemoteSubject?,
        selector: String?
    ) async throws -> AgentProjectContextCommandResponse {
        let requestID = UUID().uuidString.lowercased()
        await broker.clear(requestID: requestID)

        let request = AgentProjectContextCommandRequest(
            requestID: requestID,
            action: action,
            workspaceID: workspaceID,
            subject: subject,
            selector: selector
        )

        guard await registry.send(.projectContextCommand(request), to: deviceID) else {
            throw Abort(.serviceUnavailable, reason: "目标设备当前未连接，无法代理项目上下文查询。")
        }

        let deadline = Date().addingTimeInterval(requestTimeout)
        while Date() < deadline {
            if let response = await broker.take(requestID: requestID) {
                return response
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw Abort(.gatewayTimeout, reason: "等待设备返回项目上下文结果超时。")
    }

    private func requireAvailableWorkspace(deviceID: String, workspaceID: String) async throws -> DeviceRecord {
        let device = try await store.requireDevice(deviceID: deviceID)
        guard device.status == .online else {
            throw Abort(.serviceUnavailable, reason: "目标设备当前离线。")
        }
        guard device.workspaces.contains(where: { $0.id == workspaceID }) else {
            throw Abort(.badRequest, reason: "目标设备未声明工作区 \(workspaceID)。")
        }
        return device
    }

    private func normalizeSelector(_ selector: String?) -> String? {
        guard let selector else { return nil }
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
