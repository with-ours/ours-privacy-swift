import XCTest
@testable import OursPrivacyKit

extension OursPrivacyTests {
    func testTrackScreenDropsUnstableLabelsWithPrivateWarnings() async {
        let op = makeMobileInstance()
        await op.initialize()
        let logger = RecordingPrivacyLogger()
        OursPrivacyLogger.addLogging(logger)
        op.setLoggingEnabled(true)
        defer { op.setLoggingEnabled(false) }
        op.trackScreen("Home")
        op.trackingQueue.sync {}
        let before = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let invalid = ["", " Schedule", "Schedule ", "https://example.test/route",
                       "Schedule/Patient", "Patiént", "Schedule\n", "123",
                       String(repeating: "A", count: 81)]
        for label in invalid {
            op.trackScreen(label)
        }
        op.trackingQueue.sync {}
        XCTAssertEqual(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).count, before.count)
        let warnings = logger.capturedWarnings.filter { $0.contains("trackScreen") }
        XCTAssertEqual(warnings.count, invalid.count)
        for warning in warnings {
            XCTAssertTrue(warning.contains("invalid screen label"))
            XCTAssertFalse(warning.contains(op.name))
            for label in invalid where !label.isEmpty {
                XCTAssertFalse(warning.contains(label))
            }
        }

        op.setLoggingEnabled(false)
        op.trackScreen("Private/999")
        XCTAssertEqual(logger.capturedWarnings.filter { $0.contains("trackScreen") }.count, warnings.count)
        op.trackScreen("Home")
        op.trackScreen("A")
        op.trackScreen(String(repeating: "A", count: 80))
        op.trackingQueue.sync {}

        let screens = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            .filter { $0["event"] as? String == "$mobile_screen_view" }
        XCTAssertEqual(screens.compactMap {
            ($0["eventProperties"] as? [String: Any])?["screen_name"] as? String
        }, ["Home", "A", String(repeating: "A", count: 80)])
    }
}
