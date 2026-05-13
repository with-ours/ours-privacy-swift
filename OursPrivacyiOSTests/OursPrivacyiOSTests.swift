//
//  OursPrivacyiOSTests.swift
//  OursPrivacyiOSTests
//
//  Created by Zeytech on 4/11/25.
//  Copyright © 2025 Ours Wellness Inc. All rights reserved.
//

import Testing
@testable import OursPrivacy

struct OursPrivacyiOSTests {

    @Test func maxBatchSizeIsClampedAt50() async throws {
        #expect(APIConstants.maxBatchSize == 50)
    }

}
