import XCTest
@testable import OursPrivacy

final class OursPrivacyTests: XCTestCase {
    func testMaxBatchSizeIsClampedAt50() {
        XCTAssertEqual(APIConstants.maxBatchSize, 50)
    }
}
