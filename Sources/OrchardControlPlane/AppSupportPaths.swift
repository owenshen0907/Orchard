import Foundation

enum OrchardControlPlanePaths {
    static func supportDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let explicit = environment["ORCHARD_DATA_DIR"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            return url
        }

        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let url = base.appendingPathComponent("Orchard", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        return url
    }

    static func databaseURL() throws -> URL {
        try supportDirectory().appendingPathComponent("control-plane.sqlite", isDirectory: false)
    }
}
