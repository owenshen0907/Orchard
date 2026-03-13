import Foundation
import OrchardCore

struct CodexSessionRolloutStateInspector: Sendable {
    var recentActivityWindow: TimeInterval
    var stalledTurnWindow: TimeInterval
    var tailByteCount: Int

    init(
        recentActivityWindow: TimeInterval = 180,
        stalledTurnWindow: TimeInterval = 900,
        tailByteCount: Int = 256 * 1024
    ) {
        self.recentActivityWindow = max(recentActivityWindow, 30)
        self.stalledTurnWindow = max(stalledTurnWindow, recentActivityWindow)
        self.tailByteCount = max(tailByteCount, 16 * 1024)
    }

    func inferredState(for path: String?, now: Date = Date()) -> CodexSessionState? {
        guard let url = rolloutURL(for: path) else {
            return nil
        }

        guard let data = try? tailData(from: url) else {
            return nil
        }

        let lines = parseLines(in: data)
        let latestActivityAt = latestActivityDate(in: lines) ?? fileModificationDate(for: url)
        let latestControl = latestControlEvent(in: lines)

        switch latestControl?.payloadType {
        case "task_complete":
            return .completed
        case "turn_aborted":
            if latestControl?.payloadReason == "interrupted" {
                return .interrupted
            }
            return .failed
        case "task_started":
            guard let latestActivityAt else {
                return nil
            }
            return now.timeIntervalSince(latestActivityAt) <= stalledTurnWindow ? .running : nil
        default:
            guard let latestActivityAt else {
                return nil
            }
            return now.timeIntervalSince(latestActivityAt) <= recentActivityWindow ? .running : nil
        }
    }

    private func rolloutURL(for path: String?) -> URL? {
        guard let path else {
            return nil
        }

        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func tailData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let fileSize = try handle.seekToEnd()
        guard fileSize > 0 else {
            return Data()
        }

        let readLength = min(UInt64(tailByteCount), fileSize)
        try handle.seek(toOffset: fileSize - readLength)
        var data = handle.readDataToEndOfFile()

        if readLength < fileSize, let newlineIndex = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newlineIndex)...]
        }

        return data
    }

    private func parseLines(in data: Data) -> [RolloutLine] {
        data
            .split(separator: 0x0A)
            .compactMap { parseLine(Data($0)) }
    }

    private func parseLine(_ data: Data) -> RolloutLine? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        let timestamp = parseDate(object["timestamp"])
        let lineType = object["type"] as? String
        let payload = object["payload"] as? [String: Any]
        return RolloutLine(
            timestamp: timestamp,
            lineType: lineType,
            payloadType: payload?["type"] as? String,
            payloadReason: payload?["reason"] as? String
        )
    }

    private func latestActivityDate(in lines: [RolloutLine]) -> Date? {
        lines.reversed().compactMap(\.timestamp).first
    }

    private func latestControlEvent(in lines: [RolloutLine]) -> RolloutLine? {
        lines.reversed().first { line in
            switch line.payloadType {
            case "task_complete", "turn_aborted", "task_started":
                return true
            default:
                return false
            }
        }
    }

    private func fileModificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = fractionalFormatter.date(from: string) {
            return parsed
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private struct RolloutLine {
        let timestamp: Date?
        let lineType: String?
        let payloadType: String?
        let payloadReason: String?
    }
}
