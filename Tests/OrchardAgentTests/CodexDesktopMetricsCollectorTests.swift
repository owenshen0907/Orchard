import Foundation
import XCTest
@testable import OrchardAgent
import OrchardCore

final class CodexDesktopMetricsCollectorTests: XCTestCase {
    func testCollectorParsesFreshAppStateSnapshot() throws {
        let directory = try makeCollectorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scopeURL = directory.appendingPathComponent("scope_v3.json", isDirectory: false)
        let now = Date()
        try writeScopeFile(
            breadcrumbTimestamp: now.addingTimeInterval(-8),
            data: [
                "thread_count_active": 3,
                "thread_count_with_inflight_turn": 1,
                "inflight_turn_count": 2,
                "thread_count_loaded_recent": 9,
                "thread_count_total": 26,
            ],
            to: scopeURL
        )

        let collector = CodexDesktopMetricsCollector(scopeURL: scopeURL, freshnessWindow: 120)
        let snapshot = collector.snapshot(now: now)

        XCTAssertEqual(snapshot?.activeThreadCount, 3)
        XCTAssertEqual(snapshot?.inflightThreadCount, 1)
        XCTAssertEqual(snapshot?.inflightTurnCount, 2)
        XCTAssertEqual(snapshot?.loadedThreadCount, 9)
        XCTAssertEqual(snapshot?.totalThreadCount, 26)
        XCTAssertNotNil(snapshot?.lastSnapshotAt)
    }

    func testCollectorDropsCountsWhenSnapshotIsStale() throws {
        let directory = try makeCollectorTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let scopeURL = directory.appendingPathComponent("scope_v3.json", isDirectory: false)
        let now = Date()
        try writeScopeFile(
            breadcrumbTimestamp: now.addingTimeInterval(-500),
            data: [
                "thread_count_active": 5,
                "thread_count_with_inflight_turn": 2,
                "inflight_turn_count": 4,
            ],
            to: scopeURL
        )

        let collector = CodexDesktopMetricsCollector(scopeURL: scopeURL, freshnessWindow: 120)
        let snapshot = collector.snapshot(now: now)

        XCTAssertNotNil(snapshot?.lastSnapshotAt)
        XCTAssertNil(snapshot?.activeThreadCount)
        XCTAssertNil(snapshot?.inflightThreadCount)
        XCTAssertNil(snapshot?.inflightTurnCount)
        XCTAssertNil(snapshot?.loadedThreadCount)
        XCTAssertNil(snapshot?.totalThreadCount)
    }
}

private func writeScopeFile(
    breadcrumbTimestamp: Date,
    data: [String: Any],
    to url: URL
) throws {
    let payload: [String: Any] = [
        "scope": [
            "breadcrumbs": [
                [
                    "timestamp": breadcrumbTimestamp.timeIntervalSince1970,
                    "category": "app_state",
                    "level": "info",
                    "message": "app_state_snapshot",
                    "data": data,
                ],
            ],
        ],
        "event": [:],
    ]

    let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    try encoded.write(to: url)
}

private func makeCollectorTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("orchard-codex-desktop-metrics-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
