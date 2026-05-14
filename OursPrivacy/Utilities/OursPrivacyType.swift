//
//  OursPrivacyType.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//

import Foundation

/// Property keys must be String objects and the supported value types need to conform to OursPrivacyType.
/// OursPrivacyType can be either String, Int, UInt, Double, Float, Bool, [OursPrivacyType], [String: OursPrivacyType], Date, URL, or NSNull.
/// Numbers are not NaN or infinity
public protocol OursPrivacyType: Any {
    func isValidNestedTypeAndValue() -> Bool
}

extension Optional: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool {
        guard let val = self else { return true }
        switch val {
        case let v as OursPrivacyType:
            return v.isValidNestedTypeAndValue()
        default:
            return false
        }
    }
}
extension String: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool { return true }
}

extension NSString: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool { return true }
}

extension NSNumber: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool {
        return !self.doubleValue.isInfinite && !self.doubleValue.isNaN
    }
}

extension Int: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool { return true }
}

extension UInt: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool { return true }
}

extension Double: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool {
        return !self.isInfinite && !self.isNaN
    }
}

extension Float: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool {
        return !self.isInfinite && !self.isNaN
    }
}

extension Bool: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool { return true }
}

extension Date: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool { return true }
}

extension URL: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool { return true }
}

extension NSNull: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool { return true }
}

extension Array: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool {
        for element in self {
            guard let _ = element as? OursPrivacyType else {
                return false
            }
        }
        return true
    }
}

extension NSArray: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool {
        for element in self {
            guard let _ = element as? OursPrivacyType else {
                return false
            }
        }
        return true
    }
}

extension Dictionary: OursPrivacyType {
    public func isValidNestedTypeAndValue() -> Bool {
        for (key, value) in self {
            guard let _ = key as? String, let _ = value as? OursPrivacyType else {
                return false
            }
        }
        return true
    }
}

func assertPropertyTypes(_ properties: Properties?) {
    if let properties = properties {
        for (_, v) in properties {
            MPAssert(v.isValidNestedTypeAndValue(),
                "Property values must be of valid type (OursPrivacyType) and valid value. Got \(type(of: v)) and Value \(v)")
        }
    }
}

extension Dictionary {
    func get<T>(key: Key, defaultValue: T) -> T {
        if let value = self[key] as? T {
            return value
        }

        return defaultValue
    }
}
