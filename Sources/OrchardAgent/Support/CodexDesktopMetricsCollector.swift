import Foundation
import OrchardCore

final class CodexDesktopMetricsCollector: @unchecked Sendable {
    private let scopeURL: URL
    private let freshnessWindow: TimeInterval

    init(
        scopeURL: URL = CodexDesktopMetricsCollector.defaultScopeURL(),
        freshnessWindow: TimeInterval = 120
    ) {
        self.scopeURL = scopeURL
        self.freshnessWindow = max(freshnessWindow, 30)
    }

    func snapshot(now: Date = Date()) -> CodexDesktopMetrics? {
        guard FileManager.default.fileExists(atPath: scopeURL.path) else {
            return nil
        }
        guard
            let data = try? Data(contentsOf: scopeURL),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let snapshot = latestSnapshot(in: payload)
        else {
            return nil
        }

        let snapshotAt = snapshot.timestamp ?? fileModificationDate(for: scopeURL)
        guard let snapshotAt else {
            return nil
        }

        if now.timeIntervalSince(snapshotAt) > freshnessWindow {
            return CodexDesktopMetrics(lastSnapshotAt: snapshotAt)
        }

        return CodexDesktopMetrics(
            activeThreadCount: intValue(snapshot.data["thread_count_active"]),
            inflightThreadCount: intValue(snapshot.data["thread_count_with_inflight_turn"]),
            inflightTurnCount: intValue(snapshot.data["inflight_turn_count"]),
            loadedThreadCount: intValue(snapshot.data["thread_count_loaded_recent"]),
            totalThreadCount: intValue(snapshot.data["thread_count_total"]),
            lastSnapshotAt: snapshotAt
        )
    }

    private func latestSnapshot(in payload: [String: Any]) -> AppStateSnapshot? {
        guard
            let scope = payload["scope"] as? [String: Any],
            let breadcrumbs = scope["breadcrumbs"] as? [[String: Any]]
        else {
            return nil
        }

        for breadcrumb in breadcrumbs.reversed() {
            guard
                (breadcrumb["category"] as? String) == "app_state",
                (breadcrumb["message"] as? String) == "app_state_snapshot",
                let data = breadcrumb["data"] as? [String: Any]
            else {
                continue
            }

            return AppStateSnapshot(
                timestamp: dateValue(breadcrumb["timestamp"]),
                data: data
            )
        }

        return nil
    }

    private func fileModificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private func dateValue(_ value: Any?) -> Date? {
        switch value {
        case let number as NSNumber:
            return Date(timeIntervalSince1970: number.doubleValue)
        case let string as String:
            if let unix = Double(string) {
                return Date(timeIntervalSince1970: unix)
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: string) {
                return parsed
            }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string)
        default:
            return nil
        }
    }

    private struct AppStateSnapshot {
        let timestamp: Date?
        let data: [String: Any]
    }

    private static func defaultScopeURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Codex/sentry/scope_v3.json", isDirectory: false)
    }
}
