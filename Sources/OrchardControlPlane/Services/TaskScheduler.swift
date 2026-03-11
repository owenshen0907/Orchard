import Foundation
import OrchardCore
import Vapor

actor TaskScheduler {
    private let store: OrchardControlPlaneStore
    private let registry: AgentConnectionRegistry
    private var isRunning = false
    private var needsRerun = false

    init(store: OrchardControlPlaneStore, registry: AgentConnectionRegistry) {
        self.store = store
        self.registry = registry
    }

    func trigger() async {
        if isRunning {
            needsRerun = true
            return
        }

        isRunning = true
        defer { isRunning = false }

        repeat {
            needsRerun = false
            do {
                try await dispatchQueuedTasks()
            } catch {
                if let abort = error as? AbortError, abort.status == .serviceUnavailable {
                    return
                }
                print("[OrchardControlPlane] scheduler error: \(error)")
            }
        } while needsRerun
    }

    private func dispatchQueuedTasks() async throws {
        var devices = try await store.listDevices()
        let connected = registry.connectedDeviceIDs()
        let queuedTasks = try await store.listQueuedTasks()

        for task in queuedTasks {
            guard let chosen = TaskDispatchPlanner.selectDevice(for: task, from: devices, connectedDeviceIDs: connected) else {
                continue
            }

            let assigned = try await store.assignTask(taskID: task.id, to: chosen.deviceID)
            if registry.send(.taskAssigned(assigned), to: chosen.deviceID) {
                if let index = devices.firstIndex(where: { $0.deviceID == chosen.deviceID }) {
                    devices[index].runningTaskCount += 1
                }
            } else {
                try await store.revertAssignment(taskID: task.id)
            }
        }
    }
}
