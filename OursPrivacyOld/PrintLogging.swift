//
//  PrintLogging.swift
//  MPLogger
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Sam Green on 7/8/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//

import Foundation

/// Simply formats and prints the object by calling `print`
class PrintLogging: OursPrivacyLogging {
    func addMessage(message: OursPrivacyLogMessage) {
        print("[OursPrivacy - \(message.file) - func \(message.function)] (\(message.level.rawValue)) - \(message.text)")
    }
}

/// Simply formats and prints the object by calling `debugPrint`, this makes things a bit easier if you
/// need to print data that may be quoted for instance.
class PrintDebugLogging: OursPrivacyLogging {
    func addMessage(message: OursPrivacyLogMessage) {
        debugPrint("[OursPrivacy - \(message.file) - func \(message.function)] (\(message.level.rawValue)) - \(message.text)")
    }
}
