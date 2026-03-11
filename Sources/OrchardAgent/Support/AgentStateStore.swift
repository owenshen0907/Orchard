import Foundation
import OrchardCore

private struct PersistedAgentState: Codable, Sendable {
    var activeTaskIDs: [String]
    var pendingTaskUpdates: [String: AgentTaskUpdatePayload]
}

actor AgentStateStore {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func bootstrap() throws -> [AgentTaskUpdatePayload] {
        var state = try loadState()
        for taskID in state.activeTaskIDs {
            state.pendingTaskUpdates[taskID] = AgentTaskUpdatePayload(
                taskID: taskID,
                status: .failed,
                summary: "agent restarted"
            )
        }
        state.activeTaskIDs = []
        try saveState(state)
        return state.pendingTaskUpdates.values.sorted { lhs, rhs in
            lhs.taskID < rhs.taskID
        }
    }

    func markTaskStarted(_ taskID: String) throws {
        var state = try loadState()
        if !state.activeTaskIDs.contains(taskID) {
            state.activeTaskIDs.append(taskID)
            state.activeTaskIDs.sort()
        }
        try saveState(state)
    }

    func stageTaskUpdate(_ payload: AgentTaskUpdatePayload) throws {
        var state = try loadState()
        state.activeTaskIDs.removeAll { $0 == payload.taskID }
        state.pendingTaskUpdates[payload.taskID] = payload
        try saveState(state)
    }

    func markTaskUpdateDelivered(_ taskID: String) throws {
        var state = try loadState()
        state.activeTaskIDs.removeAll { $0 == taskID }
        state.pendingTaskUpdates.removeValue(forKey: taskID)
        try saveState(state)
    }

    private func loadState() throws -> PersistedAgentState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return PersistedAgentState(activeTaskIDs: [], pendingTaskUpdates: [:])
        }
        return try OrchardJSON.decoder.decode(PersistedAgentState.self, from: Data(contentsOf: url))
    }

    private func saveState(_ state: PersistedAgentState) throws {
        let data = try OrchardJSON.encoder.encode(state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: nil)
        try data.write(to: url, options: .atomic)
    }
}
