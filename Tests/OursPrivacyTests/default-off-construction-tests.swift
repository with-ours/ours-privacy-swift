import XCTest
@testable import OursPrivacyKit

final class OursPrivacyTestsDefaultOff: XCTestCase {
    func testConvenienceInitializersDefaultToNoAutomaticFacts() async {
        let token = "default-off-\(UUID().uuidString)"
        guard let proxy = ProxyServerConfig(serverUrl: "https://example.test") else {
            XCTFail("Expected a valid proxy configuration")
            return
        }
        let instances = [
            OursPrivacy(token: token),
            OursPrivacy(token: "\(token)-proxy", proxyServerConfig: proxy)
        ]

        for op in instances {
            XCTAssertFalse(op.trackAutomaticEventsEnabled)
            op.mobileSession = MobileSession(instanceName: op.name)
            op.mobileRuntimeEnabled = true
            await op.initialize()
            op.mobileForeground(at: MobileTimePoint.capture())
            op.trackingQueue.sync {}
            let queued = op.oursprivacyPersistence.loadEntitiesInBatch(type: .events)
            XCTAssertTrue(queued.isEmpty)
        }
    }
}
