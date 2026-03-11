import Darwin
import Foundation
import OrchardCore

struct OrchardAgentConfig {
    var serverURL: URL
    var deviceID: String
    var deviceName: String
    var workRoot: String

    static func load() -> OrchardAgentConfig {
        let environment = ProcessInfo.processInfo.environment
        let hostName = ProcessInfo.processInfo.hostName
        let server = environment["ORCHARD_SERVER_URL"] ?? "http://127.0.0.1:8080/"
        let workRoot = environment["ORCHARD_WORK_ROOT"] ?? NSString(string: "~/Orchard/workspaces").expandingTildeInPath
        let deviceName = environment["ORCHARD_DEVICE_NAME"] ?? hostName
        let deviceID = environment["ORCHARD_DEVICE_ID"] ?? sanitize(hostName)

        return OrchardAgentConfig(
            serverURL: URL(string: server) ?? URL(string: "http://127.0.0.1:8080/")!,
            deviceID: deviceID,
            deviceName: deviceName,
            workRoot: workRoot
        )
    }

    private static func sanitize(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

@main
enum OrchardAgentMain {
    static func main() async throws {
        let config = OrchardAgentConfig.load()
        let client = OrchardAPIClient(baseURL: config.serverURL)
        let registration = DeviceRegistration(
            deviceID: config.deviceID,
            name: config.deviceName,
            hostName: ProcessInfo.processInfo.hostName,
            platform: .macOS,
            capabilities: [.shell, .filesystem, .git, .codex],
            workRoot: config.workRoot
        )

        let registered = try await client.registerDevice(registration)
        print("[OrchardAgent] registered device \(registered.deviceID) -> \(config.serverURL.absoluteString)")

        while true {
            let metrics = DeviceMetrics(
                cpuPercentApprox: approximateCPUPercent(),
                memoryPercent: nil,
                loadAverage: loadAverage(),
                runningTasks: 0
            )
            let heartbeat = try await client.sendHeartbeat(deviceID: config.deviceID, metrics: metrics)
            print("[OrchardAgent] heartbeat \(heartbeat.name) load=\(heartbeat.metrics.loadAverage ?? 0)")
            try await Task.sleep(for: .seconds(10))
        }
    }

    private static func loadAverage() -> Double? {
        var values = [Double](repeating: 0, count: 3)
        let result = getloadavg(&values, 3)
        guard result > 0 else {
            return nil
        }
        return values[0]
    }

    private static func approximateCPUPercent() -> Double? {
        guard let currentLoad = loadAverage() else {
            return nil
        }
        let processorCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
        return min(100, (currentLoad / Double(processorCount)) * 100)
    }
}
