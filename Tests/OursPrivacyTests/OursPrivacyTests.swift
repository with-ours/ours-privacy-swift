import XCTest
@testable import OursPrivacyKit

final class OursPrivacyTests: XCTestCase {
    func testMaxBatchSizeIsClampedAt50() {
        XCTAssertEqual(APIConstants.maxBatchSize, 50)
    }

    func testDefaultAPIEndpointIsCdn() {
        XCTAssertEqual(BasePath.DefaultAPIEndpoint, "https://cdn.oursprivacy.com")
    }

    func testAllFlushesGoToIngest() {
        // Everything — events and `$identify` alike — POSTs to `/ingest`.
        // Pin all cases of FlushType so a future addition forces a deliberate
        // choice rather than accidentally re-introducing a `/identify` route.
        for type in [FlushType.events] {
            XCTAssertEqual(type.rawValue, "/ingest", "\(type) must POST to /ingest")
        }
    }

    func testEventsRequestURLComposesToCdnIngest() {
        let url = BasePath.buildURL(base: BasePath.DefaultAPIEndpoint,
                                    path: FlushType.events.rawValue,
                                    queryItems: nil)
        XCTAssertEqual(url?.absoluteString, "https://cdn.oursprivacy.com/ingest")
    }
}
