//
//  OursPrivacyType.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Yarden Eitan on 8/19/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//

import Foundation

/// Property keys must be String objects and the supported value types need to conform to OursPrivacyType.
/// OursPrivacyType can be either String, Int, UInt, Double, Float, Bool, [OursPrivacyType], [String: OursPrivacyType], Date, URL, or NSNull.
/// Numbers are not NaN or infinity
public protocol OursPrivacyType: Any {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     */
    func isValidNestedTypeAndValue() -> Bool
    
    func equals(rhs: OursPrivacyType) -> Bool
}

extension Optional: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     */
    public func isValidNestedTypeAndValue() -> Bool {
        guard let val = self else { return true } // nil is valid
        switch val {
        case let v as OursPrivacyType:
            return v.isValidNestedTypeAndValue()
        default:
            // non-nil but cannot be unwrapped to OursPrivacyType
            return false
        }
    }

    public func equals(rhs: OursPrivacyType) -> Bool {
        if let v = self as? String, rhs is String {
            return v == rhs as! String
        } else if let v = self as? NSString, rhs is NSString {
            return v == rhs as! NSString
        } else if let v = self as? NSNumber, rhs is NSNumber {
            return v.isEqual(to: rhs as! NSNumber)
        } else if let v = self as? Int, rhs is Int {
            return v == rhs as! Int
        } else if let v = self as? UInt, rhs is UInt {
            return v == rhs as! UInt
        } else if let v = self as? Double, rhs is Double {
            return v == rhs as! Double
        } else if let v = self as? Float, rhs is Float {
            return v == rhs as! Float
        } else if let v = self as? Bool, rhs is Bool {
            return v == rhs as! Bool
        } else if let v = self as? Date, rhs is Date {
            return v == rhs as! Date
        } else if let v = self as? URL, rhs is URL {
            return v == rhs as! URL
        } else if self is NSNull && rhs is NSNull {
            return true
        }
        return false
    }
}
extension String: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool { return true }
    
    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is String {
            return self == rhs as! String
        }
        return false
    }
}

extension NSString: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool { return true }

    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is NSString {
            return self == rhs as! NSString
        }
        return false
    }
}

extension NSNumber: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool {
        return !self.doubleValue.isInfinite && !self.doubleValue.isNaN
    }
    
    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is NSNumber {
            return self.isEqual(rhs)
        }
        return false
    }
}

extension Int: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool { return true }
    
    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is Int {
            return self == rhs as! Int
        }
        return false
    }
}

extension UInt: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool { return true }
    
    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is UInt {
            return self == rhs as! UInt
        }
        return false
    }
}
extension Double: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool {
        return !self.isInfinite && !self.isNaN
    }
    
    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is Double {
            return self == rhs as! Double
        }
        return false
    }
}
extension Float: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool {
        return !self.isInfinite && !self.isNaN
    }
    
    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is Float {
            return self == rhs as! Float
        }
        return false
    }
}
extension Bool: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool { return true }

    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is Bool {
            return self == rhs as! Bool
        }
        return false
    }
}

extension Date: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool { return true }

    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is Date {
            return self == rhs as! Date
        }
        return false
    }
}

extension URL: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool { return true }

    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is URL {
            return self == rhs as! URL
        }
        return false
    }
}

extension NSNull: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     Will always return true.
     */
    public func isValidNestedTypeAndValue() -> Bool { return true }

    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is NSNull {
            return true
        }
        return false
    }
}

extension Array: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     */
    public func isValidNestedTypeAndValue() -> Bool {
        for element in self {
            guard let _ = element as? OursPrivacyType else {
                return false
            }
        }
        return true
    }

    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is [OursPrivacyType] {
            let rhs = rhs as! [OursPrivacyType]
            
            if self.count != rhs.count {
                return false
            }

            if !isValidNestedTypeAndValue() {
                return false
            }
            
            let lhs = self as! [OursPrivacyType]
            for (i, val) in lhs.enumerated() {
                if !val.equals(rhs: rhs[i]) {
                    return false
                }
            }
            return true
        }
        return false
    }
}

extension NSArray: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     */
    public func isValidNestedTypeAndValue() -> Bool {
        for element in self {
            guard let _ = element as? OursPrivacyType else {
                return false
            }
        }
        return true
    }

    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is [OursPrivacyType] {
            let rhs = rhs as! [OursPrivacyType]
            
            if self.count != rhs.count {
                return false
            }

            if !isValidNestedTypeAndValue() {
                return false
            }
            
            let lhs = self as! [OursPrivacyType]
            for (i, val) in lhs.enumerated() {
                if !val.equals(rhs: rhs[i]) {
                    return false
                }
            }
            return true
        }
        return false
    }
}

extension Dictionary: OursPrivacyType {
    /**
     Checks if this object has nested object types that OursPrivacy supports.
     */
    public func isValidNestedTypeAndValue() -> Bool {
        for (key, value) in self {
            guard let _ = key as? String, let _ = value as? OursPrivacyType else {
                return false
            }
        }
        return true
    }
    
    public func equals(rhs: OursPrivacyType) -> Bool {
        if rhs is [String: OursPrivacyType] {
            let rhs = rhs as! [String: OursPrivacyType]
            
            if self.keys.count != rhs.keys.count {
                return false
            }
            
            if !isValidNestedTypeAndValue() {
                return false
            }
            
            for (key, val) in self as! [String: OursPrivacyType] {
                guard let rVal = rhs[key] else {
                    return false
                }

                if !val.equals(rhs: rVal) {
                    return false
                }
            }
            return true
        }
        return false
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
