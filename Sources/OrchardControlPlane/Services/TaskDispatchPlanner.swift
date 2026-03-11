import Foundation
import OrchardCore

struct TaskDispatchPlanner {
    static func orderedQueuedTasks(_ tasks: [TaskRecord]) -> [TaskRecord] {
        tasks.sorted { lhs, rhs in
            let leftPriority = priorityRank(lhs.priority)
            let rightPriority = priorityRank(rhs.priority)
            if leftPriority != rightPriority {
                return leftPriority > rightPriority
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    static func selectDevice(
        for task: TaskRecord,
        from devices: [DeviceRecord],
        connectedDeviceIDs: Set<String>
    ) -> DeviceRecord? {
        devices
            .filter { device in
                connectedDeviceIDs.contains(device.deviceID) &&
                    device.status == .online &&
                    device.capabilities.contains(task.kind.requiredCapability) &&
                    device.workspaces.contains(where: { $0.id == task.workspaceID }) &&
                    device.runningTaskCount < device.maxParallelTasks &&
                    (task.preferredDeviceID == nil || task.preferredDeviceID == device.deviceID)
            }
            .sorted { lhs, rhs in
                if lhs.runningTaskCount != rhs.runningTaskCount {
                    return lhs.runningTaskCount < rhs.runningTaskCount
                }
                if lhs.lastSeenAt != rhs.lastSeenAt {
                    return lhs.lastSeenAt > rhs.lastSeenAt
                }
                return lhs.deviceID < rhs.deviceID
            }
            .first
    }

    private static func priorityRank(_ priority: TaskPriority) -> Int {
        switch priority {
        case .high:
            return 2
        case .normal:
            return 1
        case .low:
            return 0
        }
    }
}
