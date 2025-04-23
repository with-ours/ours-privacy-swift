//
//  OursPrivacyLogger.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Sam Green on 7/8/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//

import Foundation

/// This defines the various levels of logging that a message may be tagged with. This allows hiding and
/// showing different logging levels at run time depending on the environment
public enum OursPrivacyLogLevel: String {
    /// OursPrivacyLogging displays *all* logs and additional debug information that may be useful to a developer
    case debug

    /// OursPrivacyLogging displays *all* logs (**except** debug)
    case info

    /// OursPrivacyLogging displays *only* warnings and above
    case warning

    /// OursPrivacyLogging displays *only* errors and above
    case error
}

/// This holds all the data for each log message, since the formatting is up to each
/// logging object. It is a simple bag of data
public struct OursPrivacyLogMessage {
    /// The file where this log message was created
    public let file: String

    /// The function where this log message was created
    public let function: String

    /// The text of the log message
    public let text: String

    /// The level of the log message
    public let level: OursPrivacyLogLevel

    init(path: String, function: String, text: String, level: OursPrivacyLogLevel) {
        if let file = path.components(separatedBy: "/").last {
            self.file = file
        } else {
            self.file = path
        }
        self.function = function
        self.text = text
        self.level = level
    }
}

/// Any object that conforms to this protocol may log messages
public protocol OursPrivacyLogging {
    func addMessage(message: OursPrivacyLogMessage)
}

public class OursPrivacyLogger {
    private static var loggers = [OursPrivacyLogging]()
    private static var enabledLevels = Set<OursPrivacyLogLevel>()
    private static let readWriteLock: ReadWriteLock = ReadWriteLock(label: "loggerLock")

    /// Add a `OursPrivacyLogging` object to receive all log messages
    public class func addLogging(_ logging: OursPrivacyLogging) {
        readWriteLock.write {
            loggers.append(logging)
        }
    }

    /// Enable log messages of a specific `LogLevel` to be added to the log
    class func enableLevel(_ level: OursPrivacyLogLevel) {
        _ = readWriteLock.write {
            enabledLevels.insert(level)
        }
    }

    /// Disable log messages of a specific `LogLevel` to prevent them from being logged
    class func disableLevel(_ level: OursPrivacyLogLevel) {
        _ = readWriteLock.write {
            enabledLevels.remove(level)
        }
    }

    /// debug: Adds a debug message to the OursPrivacy log
    /// - Parameter message: The message to be added to the log
    class func debug(message: @autoclosure() -> Any, _ path: String = #file, _ function: String = #function) {
        var enabledLevels = Set<OursPrivacyLogLevel>()
        readWriteLock.read {
            enabledLevels = self.enabledLevels
        }
        guard enabledLevels.contains(.debug) else { return }
        forwardLogMessage(OursPrivacyLogMessage(path: path, function: function, text: "\(message())",
                                              level: .debug))
    }

    /// info: Adds an informational message to the OursPrivacy log
    /// - Parameter message: The message to be added to the log
    class func info(message: @autoclosure() -> Any, _ path: String = #file, _ function: String = #function) {
        var enabledLevels = Set<OursPrivacyLogLevel>()
        readWriteLock.read {
            enabledLevels = self.enabledLevels
        }
        guard enabledLevels.contains(.info) else { return }
        forwardLogMessage(OursPrivacyLogMessage(path: path, function: function, text: "\(message())",
                                              level: .info))
    }

    /// warn: Adds a warning message to the OursPrivacy log
    /// - Parameter message: The message to be added to the log
    class func warn(message: @autoclosure() -> Any, _ path: String = #file, _ function: String = #function) {
        var enabledLevels = Set<OursPrivacyLogLevel>()
        readWriteLock.read {
            enabledLevels = self.enabledLevels
        }
        guard enabledLevels.contains(.warning) else { return }
        forwardLogMessage(OursPrivacyLogMessage(path: path, function: function, text: "\(message())",
                                              level: .warning))
    }

    /// error: Adds an error message to the OursPrivacy log
    /// - Parameter message: The message to be added to the log
    class func error(message: @autoclosure() -> Any, _ path: String = #file, _ function: String = #function) {
        var enabledLevels = Set<OursPrivacyLogLevel>()
        readWriteLock.read {
            enabledLevels = self.enabledLevels
        }
        guard enabledLevels.contains(.error) else { return }
        forwardLogMessage(OursPrivacyLogMessage(path: path, function: function, text: "\(message())",
                                               level: .error))
    }

    /// This forwards a `OursPrivacyLogMessage` to each logger that has been added
    class private func forwardLogMessage(_ message: OursPrivacyLogMessage) {
        // Forward the log message to every registered OursPrivacyLogging instance
        var loggers = [OursPrivacyLogging]()
        readWriteLock.read {
            loggers = self.loggers
        }
        readWriteLock.write {
            loggers.forEach { $0.addMessage(message: message) }
        }
    }
}
