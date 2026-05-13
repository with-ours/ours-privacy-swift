// Quick load-fire-inspect probe. Boots the SDK, points it at a local
// payload recorder, fires a few events, flushes, and exits. Used to eyeball
// the wire shape against the canonical RN payload during parity work.
//
// Usage:
//   python3 tools/payload-recorder/server.py --port 8765 --out /tmp/captures &
//   swift run RecorderProbe http://127.0.0.1:8765
//   ls /tmp/captures && cat /tmp/captures/*.json

import Foundation
import OursPrivacyKit

let serverURL = CommandLine.arguments.dropFirst().first ?? "http://127.0.0.1:8765"
let token = ProcessInfo.processInfo.environment["OURSPRIVACY_TOKEN"] ?? "probe-token"

print("[probe] serverURL=\(serverURL) token=\(token)")

#if os(iOS) || os(tvOS) || os(watchOS)
OursPrivacy.initialize(token: token, trackAutomaticEvents: false, serverURL: serverURL)
#else
OursPrivacy.initialize(token: token, serverURL: serverURL)
#endif
let op = OursPrivacy.mainInstance()
op.loggingEnabled = true
op.flushInterval = 0  // disable auto-flush; we'll flush explicitly

op.identify(distinctId: "probe-user", userProperties: [
    "email": "probe@example.com",
    "first_name": "Probe",
])

op.track(event: "Probe Event", properties: [
    "value": 42,
    "platform": "swift",
    "is_probe": true,
])

op.track(event: "Probe Event With Many Props", properties: [
    "string_prop": "hello",
    "int_prop": 7,
    "double_prop": 3.14,
    "bool_prop": false,
])

// Exercise the per-call userProperties parameter — pinned by `formatUserProperties`
// in martech/apps/web-cdp/src/lib/format-track.ts.
op.track(event: "Probe Event With User Props", properties: ["source": "probe"], userProperties: [
    "email": "probe-track@example.com",
    "custom_properties": ["tier": "gold"],
])

print("[probe] flushing...")
let flushed = expectation()
op.flush(performFullFlush: true) {
    print("[probe] flush completed")
    flushed.fulfill()
}
// Hold the run loop open long enough for sendRequest's semaphore to drain.
RunLoop.current.run(until: Date().addingTimeInterval(5))
print("[probe] done")

// Tiny expectation shim so this stays a single-file probe with no XCTest.
final class Expectation {
    var fulfilled = false
    func fulfill() { fulfilled = true }
}
func expectation() -> Expectation { Expectation() }
