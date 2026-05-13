# Ours Privacy Swift SDK

[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)
[![Apache License](https://img.shields.io/github/license/with-ours/ours-privacy-swift)](https://oursprivacy.com)
[![Documentation](https://img.shields.io/badge/Documentation-blue)](https://docs.oursprivacy.com/docs/overview)

The official Ours Privacy SDK for iOS, tvOS, macOS, and watchOS, written in Swift.

## Table of contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [API reference](#api-reference)
- [Payload structure](#payload-structure)
- [Migration from 1.x](#migration-from-1x)
- [FAQ](#faq)
- [Development](#development)

## Installation

### Swift Package Manager

In Xcode: **File → Add Package Dependencies…** and enter `https://github.com/with-ours/ours-privacy-swift`. Pick the latest tagged release.

Or add the package as a dependency in `Package.swift`:

```swift
.package(url: "https://github.com/with-ours/ours-privacy-swift", from: "2.0.0"),
```

Then add `"OursPrivacyKit"` to your target's dependencies.

### Platform minimums

- iOS 13
- tvOS 13
- macOS 10.15
- watchOS 6

## Quick start

```swift
import OursPrivacyKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var oursPrivacy: OursPrivacy!

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        oursPrivacy = OursPrivacy(token: "YOUR_TOKEN", trackAutomaticEvents: true)
        Task { await oursPrivacy.initialize() }
        return true
    }
}
```

Once you know who the visitor is — typically after sign-in — call `identify`:

```swift
oursPrivacy.identify(
    OursPrivacyUserProperties(
        email: "user@example.com",
        externalId: "user-123",
        firstName: "Ada",
        lastName: "Lovelace"
    )
)
```

Then record events as the user moves through the app:

```swift
oursPrivacy.track(event: "Sign Up", properties: [
    "plan": "pro",
    "source": "landing-page",
])
```

The SDK batches events and flushes them every 60 seconds and on background. Call `flush()` to force a flush.

## API reference

### Constructing the instance

```swift
init(token: String, trackAutomaticEvents: Bool)
init(token: String, trackAutomaticEvents: Bool, proxyServerConfig: ProxyServerConfig)
```

Hold a single `OursPrivacy` instance for the lifetime of your app — typically on `AppDelegate`. `trackAutomaticEvents` controls whether the SDK records session and first-launch events automatically (ignored on watchOS / macOS where automatic events aren't supported).

```swift
func initialize(options: OursPrivacyInitOptions? = nil) async
```

Applies boot-time options and starts the flush timer. Call once, immediately after construction. Safe to skip if you have no options to set, but the flush timer won't start until you do.

```swift
public struct OursPrivacyInitOptions {
    public var serverURL: String?
    public var visitorId: String?
    public var initialURL: String?
    public var defaultEventProperties: [String: OursPrivacyType]?
    public var defaultUserCustomProperties: [String: OursPrivacyType]?
    public var defaultUserConsentProperties: [String: OursPrivacyType]?
    public var optedOutByDefault: Bool?
}
```

- `serverURL` — override the default ingest endpoint.
- `visitorId` — pin a host-supplied visitor ID at boot (equivalent to calling `setVisitorId(_:)`).
- `initialURL` — parse a URL for attribution at boot (equivalent to calling `trackDeepLink(_:)`).
- `defaultEventProperties`, `defaultUserCustomProperties`, `defaultUserConsentProperties` — seed the store-level default property bags.
- `optedOutByDefault` — opt the visitor out on first launch. Ignored if a prior opt-in / opt-out decision is already persisted.

```swift
await op.initialize(options: OursPrivacyInitOptions(optedOutByDefault: true))
// op.hasOptedOutTracking() == true on a fresh install; subsequent track() calls are dropped.
// Call op.optInTracking() once the user grants consent.
```

### Identity

```swift
func identify(_ userProperties: OursPrivacyUserProperties? = nil,
              completion: (() -> Void)? = nil)
```

Identify the current visitor. To stitch the visitor to an external system, set `externalId` on the `OursPrivacyUserProperties` struct — it serializes as `external_id` on the wire.

```swift
public struct OursPrivacyUserProperties {
    public var email: String?
    public var externalId: String?
    public var phoneNumber: String?
    public var firstName: String?
    public var lastName: String?
    public var gender: String?
    public var dateOfBirth: String?
    public var city: String?
    public var state: String?
    public var zip: String?
    public var country: String?
    public var companyName: String?
    public var jobTitle: String?
    public var ip: String?
    public var customProperties: [String: OursPrivacyType]?
    public var consent: [String: OursPrivacyType]?
}
```

Swift fields use camelCase; they're serialized to snake_case on the wire (`firstName` → `first_name`).

```swift
func getVisitorId() -> String?
func setVisitorId(_ visitorId: String)
```

`getVisitorId` returns the current visitor ID, or `nil` if the SDK hasn't booted one yet. `setVisitorId` overrides the visitor ID with a host-supplied value (e.g. one received from a web client via a deep link) and flips the envelope's `is_manually_set_id` flag.

```swift
func reset(completion: (() -> Void)? = nil)
```

Clear the visitor identity, the typed user bags, and the local event queue. The next event gets a fresh visitor ID.

### Tracking

```swift
func track(event: String?,
           properties: Properties? = nil,
           userProperties: OursPrivacyUserProperties? = nil)
```

Record an event. `properties` carries free-form event-specific data; the SDK merges the store-level `defaultEventProperties` on top of it. `userProperties` is per-call only — not sticky across subsequent tracks (the server stitches by `visitor_id`).

### Default property bags

```swift
func updateDefaultEventProperties(_ properties: [String: OursPrivacyType])
func updateDefaultUserCustomProperties(_ properties: [String: OursPrivacyType])
func updateDefaultUserConsentProperties(_ properties: [String: OursPrivacyType])
```

Merge keys into the SDK's default bags. Per-call values win on collision. Useful for properties you want on every event (e.g. an `app_section` or a CMP consent state).

### Deep links

```swift
func trackDeepLink(_ url: String)
```

Parse a deep-link URL for marketing attribution and record a `$deep_link_opened` event with the raw URL. UTM parameters and ad-network click IDs are extracted and stored as store-level attribution defaults — they're sent under `defaultProperties` on every subsequent event. Calling `trackDeepLink` again **replaces** the prior attribution rather than merging, so stale UTM keys don't leak into events triggered by a later link.

If the URL carries an `ours_visitor_id` query parameter, the SDK calls `setVisitorId(_:)` so cross-platform sessions (e.g. web → app) stitch to the same visitor.

```swift
public func parseAttributionFromURL(_ url: String) -> AttributionResult
```

The standalone parser is also exported if you want to inspect attribution without firing an event:

```swift
public struct AttributionResult: Equatable {
    public let utmParams: [String: String]?
    public let clickIds: [String: String]?
    public let oursVisitorId: String?
    public let rawURL: String
}
```

### Opt-out

```swift
func optOutTracking()
func optInTracking(userProperties: OursPrivacyUserProperties? = nil,
                   properties: Properties? = nil)
func hasOptedOutTracking() -> Bool
```

`optOutTracking()` stops all tracking, regenerates the visitor ID, and clears the local event queue. `optInTracking()` re-enables tracking and fires a `$opt_in` event; if `userProperties` are supplied it identifies the visitor in the same flow.

### Flush + logging

```swift
func flush(performFullFlush: Bool = false, completion: (() -> Void)? = nil)
var flushInterval: Double { get set }
var flushBatchSize: Int { get set }
func setLoggingEnabled(_ enabled: Bool)
```

The flush timer runs every `flushInterval` seconds (default 60). Set `flushInterval = 0` to disable it and call `flush()` manually. Batches are capped at 50 events per request server-side.

## Payload structure

Every event is sent to the `/ingest` endpoint inside a batch envelope:

```json
{
  "token": "<your-token>",
  "is_manually_set_id": false,
  "data": [
    {
      "event": "Sign Up",
      "visitor_id": "stable-per-install-uuid",
      "distinct_id": "per-event-uuid",
      "eventProperties": { "plan": "pro", "source": "landing-page" },
      "userProperties": null,
      "defaultProperties": {
        "device_vendor": "Apple",
        "device_model": "iPhone17,1",
        "os_name": "iOS",
        "os_version": "18.0",
        "version": "2.0.0"
      }
    }
  ]
}
```

- `event` — the event name. Identify events use `$identify`. Deep-link attribution uses `$deep_link_opened`.
- `visitor_id` — stable per-install UUID. The same value across every event from this device unless `reset()`, `optOutTracking()`, or `setVisitorId()` change it.
- `distinct_id` — per-event UUID. Callers can override by passing `$distinct_id` in `properties`; the override is removed from the wire `eventProperties` before send.
- `eventProperties` — free-form event-specific data (merged from `defaultEventProperties` + per-call `properties`, per-call wins). `null` when there's nothing to send.
- `userProperties` — visitor identity and consent. Carries `external_id`, `email`, `phone_number`, `first_name`, `last_name`, plus nested `custom_properties` and `consent` dicts. `null` when there's nothing to send.
- `defaultProperties` — device metadata + marketing attribution (UTM params, click IDs).

The SDK only sends `consent` when there's actual consent data on either the per-call argument or the store-level default — emitting `consent: {}` would race with a consent management platform's initialization signal.

## Migration from 1.x

The 2.0 surface is a hard break. The migration is small in practice:

| 1.x | 2.x |
| --- | --- |
| `OursPrivacy.initialize(token: ..., trackAutomaticEvents: ...)` | `OursPrivacy(token: ..., trackAutomaticEvents: ...)` then `await op.initialize()` |
| `OursPrivacy.mainInstance()` | Hold your own `OursPrivacy` reference (typically on `AppDelegate`) |
| `OursPrivacy.getInstance(name:)`, `setMainInstance(name:)`, `removeInstance(name:)` | Construct multiple `OursPrivacy(...)` instances if you need them |
| `identify(distinctId:, userProperties: [String: OursPrivacyType])` | `identify(OursPrivacyUserProperties(externalId: ..., ...))` |
| `track(event:, properties:, userProperties: [String: OursPrivacyType])` | `track(event:, properties:, userProperties: OursPrivacyUserProperties)` |
| `op.archive()` | Removed — the events queue is auto-persisted to `UserDefaults` |
| `op.loggingEnabled = true` | `op.setLoggingEnabled(true)` (property setter still works for source compatibility) |
| `Flush.useIPAddressForGeoLocation` | Removed |

Events queued under 1.x are not migrated to the new persistence layer; they're dropped on first launch under 2.x.

Platform minimums moved up: iOS 13 / tvOS 13 / macOS 10.15 / watchOS 6 (required for `async`/`await`).

## FAQ

**How do I opt a test user out of tracking?**

Call `optOutTracking()` on your instance. The opt-out flag is persisted to `UserDefaults`; the visitor stays opted out across launches until you call `optInTracking()`.

**Why aren't my events showing up?**

Events are batched. The default flush interval is 60 seconds; the SDK also flushes when the app backgrounds. Call `flush()` to force a send. If events still don't arrive, enable logging with `op.setLoggingEnabled(true)` to see the SDK's debug output, and check that `hasOptedOutTracking()` is `false`.

**Do I need ATT for this SDK?**

No. The SDK doesn't use IDFA and doesn't require user permission through `AppTrackingTransparency`.

**Can I run more than one instance in the same app?**

Yes — just construct multiple `OursPrivacy(...)` instances with different tokens. The SDK no longer has a singleton manager; you're responsible for holding the references.

**How does the deep-link parser decide what to extract?**

`trackDeepLink` extracts known UTM parameters (`utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term`, `utm_name`) and known ad-network click IDs (`gclid`, `fbclid`, `ttclid`, `msclkid`, and a couple dozen others). The ingest API has typed columns for each; unknown query parameters are ignored.

## Development

Local tests (no simulator needed):

```sh
swift test
```

Full iOS coverage (requires the iOS Simulator runtime):

```sh
xcodebuild test \
  -project OursPrivacy.xcodeproj \
  -scheme OursPrivacy \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Wire-shape parity check (boots a local HTTP recorder and runs the SDK against it):

```sh
rm -rf /tmp/op-captures && mkdir -p /tmp/op-captures
python3 tools/payload-recorder/server.py --port 8765 --out /tmp/op-captures &
swift run RecorderProbe http://127.0.0.1:8765
python3 tools/payload-recorder/assert_payload.py /tmp/op-captures/*_ingest.json tools/payload-recorder/fixtures/canonical_envelope.json
pkill -f "tools/payload-recorder/server.py"
```

The last command should print `match`. See `tools/payload-recorder/README.md` for details.

## Support

- Documentation: [docs.oursprivacy.com](https://docs.oursprivacy.com)
- Issues: [GitHub issues](https://github.com/with-ours/ours-privacy-swift/issues)
- Email: support@oursprivacy.com
