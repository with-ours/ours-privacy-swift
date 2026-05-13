//
//  OursPrivacyiOSTests.swift
//  OursPrivacyiOSTests
//
//  Created by Zeytech on 4/11/25.
//  Copyright © 2025 Ours Wellness Inc. All rights reserved.
//

import Foundation
import Testing
@testable import OursPrivacyKit

struct OursPrivacyiOSTests {

    @Test func maxBatchSizeIsClampedAt50() async throws {
        #expect(APIConstants.maxBatchSize == 50)
    }

    @Test func optedOutByDefaultBlocksTrackingOnFreshInstance() async throws {
        let op = OursPrivacy(token: "ios-test-\(UUID().uuidString)", trackAutomaticEvents: false)
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        #expect(op.hasOptedOutTracking() == true)

        op.track(event: "should-be-dropped")
        op.trackingQueue.sync {}
        #expect(op.oursprivacyPersistence.loadEntitiesInBatch(type: .events).isEmpty)
    }

    @Test func optedOutByDefaultRespectsPersistedOptIn() async throws {
        let op = OursPrivacy(token: "ios-test-\(UUID().uuidString)", trackAutomaticEvents: false)
        op.optInTracking()
        op.trackingQueue.sync {}
        await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
        #expect(op.hasOptedOutTracking() == false)
    }

}
