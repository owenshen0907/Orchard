import Foundation
import OrchardCore

actor OrchardControlPlaneState {
    private var devices: [String: DeviceRecord] = [:]
    private var tasks: [String: TaskRecord] = [:]

    func snapshot() -> DashboardSnapshot {
        DashboardSnapshot(
            devices: listDevices(),
            tasks: listTasks()
        )
    }

    func listDevices() -> [DeviceRecord] {
        devices.values.sorted { lhs, rhs in
            lhs.lastSeenAt > rhs.lastSeenAt
        }
    }

    func listTasks() -> [TaskRecord] {
        tasks.values.sorted { lhs, rhs in
            lhs.updatedAt > rhs.updatedAt
        }
    }

    func registerDevice(_ registration: DeviceRegistration) -> DeviceRecord {
        let now = Date()
        let record = DeviceRecord(
            deviceID: registration.deviceID,
            name: registration.name,
            hostName: registration.hostName,
            platform: registration.platform,
            capabilities: registration.capabilities,
            workRoot: registration.workRoot,
            metrics: devices[registration.deviceID]?.metrics ?? DeviceMetrics(),
            registeredAt: devices[registration.deviceID]?.registeredAt ?? now,
            lastSeenAt: now
        )
        devices[registration.deviceID] = record
        return record
    }

    func heartbeat(deviceID: String, heartbeat: HeartbeatRequest) -> DeviceRecord? {
        guard var device = devices[deviceID] else {
            return nil
        }
        device.metrics = heartbeat.metrics
        device.lastSeenAt = Date()
        devices[deviceID] = device
        return device
    }

    func createTask(_ request: CreateTaskRequest) -> TaskRecord {
        let now = Date()
        let task = TaskRecord(
            id: UUID().uuidString.lowercased(),
            title: request.title,
            command: request.command,
            workDirectory: request.workDirectory,
            kind: request.kind,
            priority: request.priority,
            status: .queued,
            assignedDeviceID: request.preferredDeviceID,
            createdAt: now,
            updatedAt: now
        )
        tasks[task.id] = task
        return task
    }
}
