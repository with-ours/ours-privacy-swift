import Foundation
import XCTest
@testable import OursPrivacyKit

private final class SerialProbeLogger: OursPrivacyLogging {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0

    func addMessage(message: OursPrivacyLogMessage) {
        guard message.text.hasPrefix("serial-probe-") else { return }
        lock.lock()
        active += 1
        peak = max(peak, active)
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.01)
        lock.lock()
        active -= 1
        lock.unlock()
    }

    func peakConcurrency() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }
}

final class LoggerConcurrencyTests: XCTestCase {
    func testRegisteredLoggerReceivesMessagesSerially() {
        let logger = SerialProbeLogger()
        OursPrivacyLogger.addLogging(logger)
        OursPrivacyLogger.enableLevel(.info)
        DispatchQueue.concurrentPerform(iterations: 16) { index in
            OursPrivacyLogger.info(message: "serial-probe-\(index)")
        }
        XCTAssertEqual(logger.peakConcurrency(), 1)
    }
}
