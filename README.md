# Ours Privacy Swift SDK

[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)
[![Apache License](https://img.shields.io/github/license/with-ours/ours-privacy-swift)](https://oursprivacy.com)
[![Documentation](https://img.shields.io/badge/Documentation-blue)](https://docs.oursprivacy.com/docs/ios-sdk)

Privacy-first analytics for iOS, tvOS, macOS, and watchOS, written in Swift.

- [Swift Package Manager](https://github.com/with-ours/ours-privacy-swift) — `https://github.com/with-ours/ours-privacy-swift`
- [GitHub](https://github.com/with-ours/ours-privacy-swift)
- [Docs](https://docs.oursprivacy.com/docs/ios-sdk)

---

## Table of Contents

- [Quick Start](#quick-start)
- [Complete Example](#complete-example)
- [API Reference](#api-reference)
  - [Initialization](#initialization)
  - [Core Tracking](#core-tracking)
  - [Mobile Screens and Purchases](#mobile-screens-and-purchases)
  - [Default Properties](#default-properties)
  - [Configuration](#configuration)
  - [Identity](#identity)
  - [Deep Link Attribution](#deep-link-attribution)
  - [Privacy Controls](#privacy-controls)
- [Payload Structure](#payload-structure)
- [Local Demo Tests](#local-demo-tests)
- [FAQ](#faq)
- [Support](#support)

---

## Quick Start

### 1. Install

In Xcode: **File → Add Package Dependencies…** and enter `https://github.com/with-ours/ours-privacy-swift`. Or add to `Package.swift`:

```swift
.package(url: "https://github.com/with-ours/ours-privacy-swift", from: "3.1.0"),
```

Then add `"OursPrivacyKit"` to your target's dependencies.

**Platform minimums:** iOS 15, tvOS 15, macOS 12, watchOS 8.

> **Migrating from CocoaPods?** Past versions of `OursPrivacy-swift` remain installable from CocoaPods trunk but receive no further updates. New releases ship via Swift Package Manager.

### Upgrading to 3.0

Version 3.0 requires Xcode with Swift 6 support and raises the deployment targets to iOS 15, tvOS 15, macOS 12, and watchOS 8. Apps with lower deployment targets should remain on 2.x. The package uses Swift 5 language mode with complete concurrency checking.

The `identify`, `reset`, and `flush` completion closures are now `@Sendable`. If a completion captures mutable or main-actor state, move that work onto the appropriate actor or capture a thread-safe value. Event payloads now report `defaultProperties.version` as `swift@3.0.0`; update any code that compares the old value. CocoaPods consumers must move to Swift Package Manager for 3.0.

**Mobile instrumentation migration:** `trackAutomaticEvents: true` continues to enable lifecycle events, but no longer observes StoreKit or emits `$ae_iap` by itself. Apps that intentionally use the legacy purchase event must set `trackAutomaticPurchases: true` at construction or boot. Review product identifiers and prices before enabling collection. Add explicit `trackScreen` calls for app screens; the SDK does not infer every UIKit or SwiftUI navigation transition.

**Deep-link migration:** `$deep_link_opened` keeps its event name but the SDK no longer adds `eventProperties.url`. Replace reports or integrations that read the full URL with the supported UTM and click-ID fields in `defaultProperties`. Do not copy the URL into custom properties. Use PHI-free event and screen names, attribution values, and visitor IDs; screen names should be fixed labels without route parameters or patient details.

### 2. Initialize

```swift
import OursPrivacyKit

let op = OursPrivacy(token: "YOUR_API_TOKEN", trackAutomaticEvents: true)
Task { await op.initialize() }
```

That's it. The SDK connects to `https://cdn.oursprivacy.com` by default — no endpoint configuration needed.

Hold a single instance for the lifetime of your app — typically on `AppDelegate` or in a singleton you control.

### 3. Track Events

```swift
op.track(event: "Button Pressed")
op.track(event: "Purchase", properties: ["value": 49.99, "currency": "USD"])
```

### 4. Identify Users

After login, link events to a user:

```swift
op.identify(
    OursPrivacyUserProperties(
        externalId: "user-123",
        email: "user@example.com",
        firstName: "Jane"
    )
)
```

### 5. Flush

Events are batched and sent every 60 seconds by default. To send immediately:

```swift
op.flush()
```

---

## Complete Example

```swift
import UIKit
import OursPrivacyKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var op: OursPrivacy!

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        op = OursPrivacy(token: "YOUR_API_TOKEN", trackAutomaticEvents: true)
        Task {
            await op.initialize(options: OursPrivacyInitOptions(
                defaultEventProperties: ["app_version": "2.0.0"]
            ))
        }
        return true
    }

    func trackPurchase() {
        op.track(event: "Purchase", properties: ["value": 49.99, "currency": "USD"])
    }
}
```

---

## API Reference

### Initialization

#### `OursPrivacy(token:trackAutomaticEvents:trackAutomaticPurchases:)`

Construct an instance. Hold a single `OursPrivacy` for the lifetime of your app.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `token` | `String` | Yes | Your project token |
| `trackAutomaticEvents` | `Bool` | No | Record iOS lifecycle, engagement, and update events automatically; defaults to `false` (ignored on watchOS / macOS) |
| `trackAutomaticPurchases` | `Bool` | No | Observe StoreKit purchases and emit legacy `$ae_iap`; defaults to `false`, independent of lifecycle tracking |

```swift
let op = OursPrivacy(token: "YOUR_API_TOKEN", trackAutomaticEvents: true)
```

There is also an overload that accepts a `ProxyServerConfig` if you route ingest through a proxy.
Both overloads leave automatic lifecycle tracking off when `trackAutomaticEvents` is omitted.

---

#### `op.initialize(options:)`

Apply boot-time options and start the flush timer. Call once, immediately after construction.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `options` | `OursPrivacyInitOptions?` | No | Initialization options (see below) |

**`OursPrivacyInitOptions` shape (all camelCase):**

| Field | Type | Description |
|-------|------|-------------|
| `optedOutByDefault` | `Bool` | If `true`, tracking starts opted out (default: `false`) |
| `trackAutomaticPurchases` | `Bool?` | Override the constructor's purchase choice at boot; omitted keeps it unchanged (default: `false`) |
| `onIngestRejected` | `(@Sendable (String, String) -> Void)?` | Called with an event's `distinct_id` and rejection code after the rejected batch leaves the durable queue |
| `visitorId` | `String` | Pre-set the visitor ID; sets `is_manually_set_id: true` on all events |
| `defaultEventProperties` | `[String: OursPrivacyType]` | Properties merged into `eventProperties` on every `track()` call |
| `defaultUserCustomProperties` | `[String: OursPrivacyType]` | Properties merged into `userProperties.custom_properties` on every event |
| `defaultUserConsentProperties` | `[String: OursPrivacyType]` | Properties merged into `userProperties.consent` on every event |
| `serverURL` | `String` | Override the base URL used for requests, for example a local QA capture server |
| `initialURL` | `String` | Deep link URL to parse on init — extracts UTM params, click IDs, and `ours_visitor_id` (see [Deep Link Attribution](#deep-link-attribution)) |

**Returns:** `Void` (async)

```swift
// Minimal init
await op.initialize()

// With options
await op.initialize(options: OursPrivacyInitOptions(
    serverURL: nil,
    visitorId: "pre-known-id",
    defaultEventProperties: ["platform": "ios", "app_version": "2.0.0"],
    defaultUserCustomProperties: ["tier": "pro"],
    defaultUserConsentProperties: ["marketing": true]
))
```

---

### Core Tracking

#### `op.track(event:properties:userProperties:)`

Track an event with optional properties.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `event` | `String?` | Yes | Name of the event |
| `properties` | `[String: OursPrivacyType]?` | No | Key/value pairs to attach to the event |
| `userProperties` | `OursPrivacyUserProperties?` | No | Per-call user properties (not sticky — use `identify()` for sticky identity) |

**Returns:** `Void`

```swift
op.track(event: "Page View", properties: ["page": "/home", "referrer": "google"])
```

---

### Mobile Screens and Purchases

#### `op.trackScreen(_:)`

Call on each actual iOS app screen transition, including custom UIKit navigation and SwiftUI routes. The API emits one `$mobile_screen_view` with `eventProperties.screen_name` for a new label; repeated calls with the active label are suppressed. A screen switch first emits any measured `$mobile_session_engagement` for the previous screen, with `engagement_duration_ms` and that previous `screen_name` (when automatic lifecycle tracking is on). Automatic screen discovery is not complete for custom navigation, so connect your own navigation callback. On macOS, tvOS, visionOS, watchOS, and iOS apps running on Mac, `trackScreen` emits no canonical screen event; use ordinary `track(event:)` for supported manual events.

```swift
func didShowRoute(_ route: AppRoute) {
    switch route {
    case .schedule:
        op.trackScreen("Schedule")
    case .booking:
        op.trackScreen("Booking")
    }
}
```

Use fixed developer-chosen labels of 1–80 ASCII characters matching `^[A-Za-z][A-Za-z0-9 _-]{0,79}$`, without leading or trailing whitespace. Empty, URL-like, and non-ASCII strings are ignored. Validation cannot tell a patient name such as `Jane Smith` from a fixed label, so **never** pass patient data, visible titles, route parameters, or raw URLs. Map each route to a fixed label as above. The SDK does not inspect screen content.

`trackScreen` and manual `track()` work with `trackAutomaticEvents: false`. On iOS, each carries the mobile session metadata below. `trackAutomaticEvents` defaults to `false` and enables automatic lifecycle, engagement, and update facts when set to `true`. `$mobile_*` names are reserved for SDK facts: manual `track(event:)` calls with that prefix are ignored, including unknown names. Legacy `$ae_*` handling is unchanged.

| Canonical event | When emitted on iOS | `eventProperties` |
| --- | --- | --- |
| `$mobile_first_open` | First eligible tracked foreground open for this installation and token, once | `null` |
| `$mobile_app_open` | Each foreground entry, including cold and warm opens | `null` |
| `$mobile_session_start` | First tracked foreground entry in a new session, once per `sid` | `null` |
| `$mobile_session_engagement` | A positive measured foreground-time delta at a checkpoint, screen change, or pause/background | Required positive integer `engagement_duration_ms` in milliseconds; `screen_name` when a tracked screen is active |
| `$mobile_session_end` | Best effort when an expired session is observed on a later foreground entry; it can be absent | `null` |
| `$mobile_app_update` | A later tracked open after the observed app version or build changes, never the first observed open | `previous_app_version` and `previous_app_build` when previously known |
| `$mobile_screen_view` | A valid explicit `trackScreen` transition; repeated active labels are suppressed | Required `screen_name`; no `screen_class` is collected by the explicit Swift API |

Every iOS mobile event, including manual `track()` and `trackScreen()`, has SDK-owned `defaultProperties.sid` (a session ID), `mobile_session_started_at`, `mobile_occurred_at`, `mobile_platform: "ios"`, and `mobile_contract_version: 1`, plus `app_version` and `app_build` when the host bundle supplies them. Canonical facts also have `device_vendor` and `version`, plus `device_model`, `device_type`, `os_name`, `os_version`, `screen_width`, and `screen_height` when available. `version` is the SDK version, not the app version. Timestamps are ISO-8601 UTC with exactly three fractional digits and `Z`; `mobile_occurred_at` is captured when the event is queued and is no earlier than its session start. The SDK does not set top-level `time`. Foregrounding at or after 30 minutes of inactivity starts a new `sid`; a warm open under 30 minutes keeps it. Engagement uses nonoverlapping, positive integer millisecond deltas from a monotonic clock; 10 seconds accumulated within a session meets the engaged threshold. Reset, visitor-ID change, and opt-out discard the session; opt-out clears queued events and suppresses manual screens, lifecycle facts, and purchases.

Canonical facts carry only SDK lifecycle metadata and stable screen labels. They have `userProperties: null`, never merge caller default or per-call event/user properties, and collect no patient fields, advertising IDs, or raw URL. Screen labels and manual event properties are developer-controlled, so keep them free of patient data and route parameters. The mobile contract applies to iOS app runtime; on macOS, tvOS, visionOS, watchOS, and iOS apps running on Mac, `trackScreen` emits no canonical fact and ordinary manual events continue without mobile session metadata.

#### StoreKit purchase collection

StoreKit observation is separately disabled by default, even if `trackAutomaticEvents` is `true`. Set `trackAutomaticPurchases: true` at construction or use `OursPrivacyInitOptions(trackAutomaticPurchases: true)` during `initialize()` to keep legacy `$ae_iap` telemetry. You may enable purchases while automatic lifecycle tracking is off.

```swift
let op = OursPrivacy(token: "YOUR_API_TOKEN",
                     trackAutomaticEvents: true,
                     trackAutomaticPurchases: true)
await op.initialize()
```

When enabled, a purchased StoreKit transaction emits `$ae_iap` with `eventProperties.$ae_iap_price` (string), `$ae_iap_quantity` (integer), and `$ae_iap_name` (product identifier). The purchase option controls both observation and queued `$ae_iap` delivery. Full opt-out suppresses it.

---

#### `op.identify(_:completion:)`

Associate all future `track()` calls with the given user identity. Call this after a user logs in.

Pass identifying fields inside the `userProperties` bag — most commonly `externalId` (your system's user ID). Any default custom or consent properties registered via `updateDefault*` are merged in automatically.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `userProperties` | `OursPrivacyUserProperties?` | No | User properties to attach to this identity |
| `completion` | `(() -> Void)?` | No | Called after the identify event is queued |

**`OursPrivacyUserProperties` shape (all camelCase):**

| Field | Type | Description |
|-------|------|-------------|
| `email` | `String` | User's email address |
| `externalId` | `String` | ID from your own system |
| `phoneNumber` | `String` | User's phone number |
| `firstName` | `String` | First name |
| `lastName` | `String` | Last name |
| `gender` | `String` | Gender |
| `dateOfBirth` | `String` | Date of birth (ISO 8601, e.g. `1990-04-12`) |
| `city` | `String` | City |
| `state` | `String` | State / region |
| `zip` | `String` | Postal / ZIP code |
| `country` | `String` | Country (ISO 3166-1 alpha-2 preferred) |
| `companyName` | `String` | Company name |
| `jobTitle` | `String` | Job title |
| `ip` | `String` | Client IP (only set this if you have a reliable source — the server will infer otherwise) |
| `customProperties` | `[String: OursPrivacyType]` | Arbitrary custom user attributes |
| `consent` | `[String: OursPrivacyType]` | Consent flags (e.g. `["marketing": true]`) |

The SDK converts these camelCase fields to the snake_case wire format (`externalId` → `external_id`, `dateOfBirth` → `date_of_birth`, etc.) before sending.

**Returns:** `Void`

```swift
op.identify(
    OursPrivacyUserProperties(
        email: "jane@example.com",
        externalId: "db-user-456",
        firstName: "Jane",
        customProperties: ["tier": "pro"],
        consent: ["marketing": true]
    )
)
```

---

#### `op.flush(performFullFlush:completion:)`

Push all queued events to the server immediately. Useful before app close or logout.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `performFullFlush` | `Bool` | No | Ignore the batch size cap and send everything in one request (default: `false`) |
| `completion` | `(() -> Void)?` | No | Called after the flush completes |

**Returns:** `Void`

```swift
op.flush()
```

An indexed `/ingest` response acknowledges accepted and rejected items together. Set
`onIngestRejected` in `OursPrivacyInitOptions` or on the instance to handle rejected events:

```swift
await op.initialize(options: OursPrivacyInitOptions(
    onIngestRejected: { _, code in
        print("Ingest rejected: \(code)")
    }
))
```

The callback runs on the SDK network queue after queue removal succeeds. It receives
`distinct_id` and the rejection code, without event properties. A caller can supply
`$distinct_id`, so the ID may contain patient data; log only the code. Keep callback
work brief or dispatch it to your app's queue. Transport
failures and malformed or stale responses retain queued events without invoking it.
Legacy no-index responses can acknowledge batches until this source token has received
an indexed response; indexed mode persists across app restarts.

---

#### `op.reset(completion:)`

Clear the current user identity and all default properties. Generates a new random visitor ID. Call this when a user logs out.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `completion` | `(() -> Void)?` | No | Called after the reset completes |

**Returns:** `Void`

```swift
op.reset()
```

---

### Default Properties

Default properties are automatically merged into every event the SDK sends. They are the primary way to attach persistent, per-user or per-session context without repeating it on every `track()` call.

These methods can be called at init time via `options`, or at any point afterwards.

---

#### `op.updateDefaultEventProperties(_:)`

Merge properties into `eventProperties` on every future `track()` call. Properties are merged shallowly — later calls overwrite earlier ones for the same key.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `properties` | `[String: OursPrivacyType]` | Yes | Key/value pairs to merge into default event properties |

**Returns:** `Void`

```swift
// At init time:
await op.initialize(options: OursPrivacyInitOptions(
    defaultEventProperties: ["app_version": "2.0.0", "environment": "production"]
))

// Or post-init (e.g. after fetching user data):
op.updateDefaultEventProperties(["experiment_group": "variant_b"])

// Every subsequent track() will include these automatically.
op.track(event: "Button Pressed")
```

---

#### `op.updateDefaultUserCustomProperties(_:)`

Merge properties into `userProperties.custom_properties` on every future event. Useful for attaching user attributes that should travel with every event.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `properties` | `[String: OursPrivacyType]` | Yes | Key/value pairs to merge into default user custom properties |

**Returns:** `Void`

```swift
op.updateDefaultUserCustomProperties(["tier": "enterprise", "seats": 50])
```

---

#### `op.updateDefaultUserConsentProperties(_:)`

Merge properties into `userProperties.consent` on every future event. Use this to send the user's consent state alongside all analytics events.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `properties` | `[String: OursPrivacyType]` | Yes | Key/value pairs to merge into default user consent properties |

**Returns:** `Void`

```swift
op.updateDefaultUserConsentProperties(["marketing": true])
```

---

### Configuration

#### `op.flushInterval`

The flush timer runs every `flushInterval` seconds (default 10). Set `flushInterval = 0` to disable it and call `flush()` manually.

```swift
op.flushInterval = 30
```

---

#### `op.flushBatchSize`

Maximum number of events sent in a single network request. Capped at 50 server-side; values above 50 are clamped.

```swift
op.flushBatchSize = 25
```

---

#### `op.setLoggingEnabled(_:)`

Enable or disable debug logging. All logging is disabled by default.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `enabled` | `Bool` | Yes | Whether to enable SDK logging |

**Returns:** `Void`

```swift
op.setLoggingEnabled(true)
```

---

### Identity

#### `op.getVisitorId()`

Returns the stable visitor UUID for this install, or `nil` if the SDK hasn't booted one yet.

**Returns:** `String?`

```swift
let visitorId = op.getVisitorId()
```

---

#### `op.setVisitorId(_:)`

Update the visitor ID after initialization. Use this for web-to-app identity stitching when the visitor ID arrives outside of a deep link (e.g. via a native bridge or async lookup).

Sets `is_manually_set_id: true` on all subsequent events.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `visitorId` | `String` | Yes | The Ours Privacy visitor ID to adopt |

**Returns:** `Void`

```swift
op.setVisitorId("550e8400-e29b-41d4-a716-446655440000")
```

---

### Deep Link Attribution

#### `op.trackDeepLink(_:)`

Parse a deep link URL for marketing attribution data and fire a `$deep_link_opened` event. The SDK does not add the raw URL to event properties or its own diagnostics. It extracts only supported UTM parameters, ad network click IDs, and `ours_visitor_id` for cross-platform identity stitching; other query parameters are ignored.

Parsed attribution params are merged into `defaultProperties`, so they appear on all subsequent `track()` calls. Calling `trackDeepLink` again **replaces** the prior attribution rather than merging, so stale UTM keys don't leak into events triggered by a later link.

Keep attribution values and `ours_visitor_id` free of PHI. The SDK forwards supported values as supplied by the app, so avoid patient details in campaign names, click IDs, and other attribution values.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `url` | `String` | Yes | The deep link or initial URL to parse |

**Returns:** `Void`

```swift
// In SceneDelegate / AppDelegate
func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
    if let url = userActivity.webpageURL?.absoluteString {
        op.trackDeepLink(url)
    }
}
```

Alternatively, pass the URL at init time:

```swift
await op.initialize(options: OursPrivacyInitOptions(
    initialURL: launchURL
))
```

**Supported parameters:**

| Category | Parameters |
|----------|-----------|
| UTM | `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term` |
| Google | `gclid`, `gad_source`, `dclid`, `gbraid`, `wbraid` |
| Meta | `fbclid`, `fbc`, `fbp` |
| Microsoft | `msclkid` |
| TikTok | `ttclid` |
| Twitter/X | `twclid` |
| LinkedIn | `li_fat_id` |
| Reddit | `rdt_cid` |
| Snapchat | `sccid` |
| Pinterest | `epik` |
| Quora | `qclid` |
| AppLovin | `aleid`, `alart`, `axwrt` |
| Other | `clickid`, `clid`, `ndclid`, `irclickid`, `im_ref`, `sacid`, `basis_cid` |
| Identity | `ours_visitor_id` — cross-platform visitor stitching |

**AppLovin example:**

When a user clicks an AppLovin ad, the deep link will contain `aleid` (click ID) and `alart` (app user ID):

```swift
// Deep link: myapp://open?aleid=click_abc&alart=user_xyz&utm_source=applovin
op.trackDeepLink("myapp://open?aleid=click_abc&alart=user_xyz&utm_source=applovin")

// All subsequent events will include aleid, alart, and utm_source in defaultProperties.
```

> **Note:** `esi` (Event Source Indicator) is configured in the AppLovin destination mapping in the Ours Privacy dashboard, not in the SDK. Set it to `"app"` for mobile events in your destination settings.

---

### Privacy Controls

#### `op.optOutTracking()`

Stop all tracking immediately. Any queued events that have not been flushed will be discarded. Call `flush()` first if you want to preserve queued events. Opt-out rotates `visitor_id` and clears the current mobile session. A later opt-in starts a new session under the new visitor ID, so reports do not automatically link activity before and after opt-out.

**Returns:** `Void`

```swift
op.flush()
op.optOutTracking()
```

---

#### `op.optInTracking(userProperties:properties:)`

Resume tracking after a previous call to `optOutTracking()`. This also sends an `$opt_in` event to the server. If `userProperties` are supplied it identifies the visitor in the same flow.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `userProperties` | `OursPrivacyUserProperties?` | No | User identity to attach on opt-in |
| `properties` | `[String: OursPrivacyType]?` | No | Event properties to attach to the `$opt_in` event |

**Returns:** `Void`

```swift
op.optInTracking()
```

---

#### `op.hasOptedOutTracking()`

Check whether the current user has opted out of tracking.

**Returns:** `Bool`

```swift
if op.hasOptedOutTracking() {
    print("User has opted out")
}
```

---

## Payload Structure

The SDK sends a JSON body to `POST /ingest` on the configured `serverURL`. Understanding this structure is useful if you are building a proxy, using the local QA capture server, or verifying your data in the Ours Privacy dashboard.

```json
{
  "token": "your-project-token",
  "is_manually_set_id": false,
  "data": [
    {
      "event": "Purchase",
      "visitor_id": "550e8400-e29b-41d4-a716-446655440000",
      "distinct_id": "ecff9f0e-d4f8-4d9e-b2f8-8d9b2fcdf7b2",
      "eventProperties": {
        "price": 99
      },
      "userProperties": {
        "custom_properties": {
          "tier": "pro"
        },
        "consent": {
          "marketing": true
        }
      },
      "defaultProperties": {
        "device_type": "mobile",
        "os_name": "iOS",
        "os_version": "18.0",
        "device_vendor": "Apple",
        "device_model": "iPhone17,1",
        "version": "swift@3.1.0"
      }
    }
  ]
}
```

**Key fields:**

| Field | Description |
|-------|-------------|
| `token` | Your project token |
| `is_manually_set_id` | `true` when visitor ID was set via `initialize()` options, `setVisitorId()`, or `ours_visitor_id` in a deep link |
| `data` | Array of event objects in this batch |
| `event` | Event name. Identify events use `$identify`; deep-link attribution uses `$deep_link_opened`. |
| `visitor_id` | Stable visitor UUID for this install (no prefix) |
| `distinct_id` | Per-event UUID generated for this event occurrence |
| `eventProperties` | Properties from `track()` merged with default event properties |
| `userProperties.custom_properties` | From `identify()` and `updateDefaultUserCustomProperties()` |
| `userProperties.consent` | From `identify()` and `updateDefaultUserConsentProperties()` |
| `defaultProperties` | Automatically collected device/SDK metadata + marketing attribution |

---

## Local Demo Tests

Install Xcode 26.5 with the iOS 26.5 simulator runtime. From the repository root, run:

```sh
./tools/payload-recorder/run-ios-e2e.sh
```

The command starts the included recorder, runs the UIKit demo on an iPhone 17 Pro simulator, and checks the payloads sent by each demo action. It needs no Ours Privacy account or external service. Each run saves captures in its own directory under `tools/payload-recorder/captures/`; the command prints the path. CI uses this same command.

The demo Xcode project resolves the SDK from this checkout. Set `OURSPRIVACY_TOKEN` and `OURSPRIVACY_SERVER_URL` in the demo scheme to try it manually against your own source.

---

## FAQ

**Do I need to request permission through AppTrackingTransparency?**

No. Ours Privacy does not use IDFA, so no ATT permission is required.

**Why aren't my events showing up?**

Events are batched and sent every 10 seconds by default. Call `flush()` to send immediately. Enable debug logging with `setLoggingEnabled(true)` to see what's happening. Also check that `hasOptedOutTracking()` is `false`.

**Can I run more than one instance in the same app?**

Yes — construct multiple `OursPrivacy(...)` instances with different tokens. You are responsible for holding the references.

**What platforms are supported?**

- iOS 15+
- tvOS 15+
- macOS 12+
- watchOS 8+

---

## Support

- [Documentation](https://docs.oursprivacy.com/docs/ios-sdk)
- [GitHub Issues](https://github.com/with-ours/ours-privacy-swift/issues)
- Email: support@oursprivacy.com
