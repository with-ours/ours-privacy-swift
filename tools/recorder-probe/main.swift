// Quick load-fire-inspect probe. Boots the SDK, points it at a local
// payload recorder, fires a few events, flushes, and exits. Used to
// eyeball the wire shape during parity work.
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

let op = OursPrivacy(token: token, trackAutomaticEvents: false)

let semaphore = DispatchSemaphore(value: 0)
Task {
    await op.initialize(options: OursPrivacyInitOptions(serverURL: serverURL))
    op.setLoggingEnabled(true)
    op.flushInterval = 0

    op.identify(distinctId: "probe-user",
                userProperties: OursPrivacyUserProperties(email: "probe@example.com",
                                                         firstName: "Probe"))

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

    op.track(event: "Probe Event With User Props",
             properties: ["source": "probe"],
             userProperties: OursPrivacyUserProperties(email: "probe-track@example.com",
                                                      customProperties: ["tier": "gold"]))

    print("[probe] flushing...")
    op.flush(performFullFlush: true) {
        print("[probe] flush completed")
        semaphore.signal()
    }
}

// Hold the run loop open long enough for sendRequest's semaphore to drain.
_ = semaphore.wait(timeout: .now() + 10)
print("[probe] done")
