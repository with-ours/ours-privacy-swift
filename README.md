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
  - [Default Properties](#default-properties)
  - [Configuration](#configuration)
  - [Identity](#identity)
  - [Deep Link Attribution](#deep-link-attribution)
  - [Privacy Controls](#privacy-controls)
- [Payload Structure](#payload-structure)
- [FAQ](#faq)
- [Support](#support)

---

## Quick Start

### 1. Install

In Xcode: **File → Add Package Dependencies…** and enter `https://github.com/with-ours/ours-privacy-swift`. Or add to `Package.swift`:

```swift
.package(url: "https://github.com/with-ours/ours-privacy-swift", from: "2.0.0"),
```

Then add `"OursPrivacyKit"` to your target's dependencies.

**Platform minimums:** iOS 13, tvOS 13, macOS 10.15, watchOS 6.

> **Migrating from CocoaPods?** Past versions of `OursPrivacy-swift` remain installable from CocoaPods trunk but receive no further updates. New releases ship via Swift Package Manager.

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

#### `OursPrivacy(token:trackAutomaticEvents:)`

Construct an instance. Hold a single `OursPrivacy` for the lifetime of your app.

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `token` | `String` | Yes | Your project token |
| `trackAutomaticEvents` | `Bool` | Yes | Record session and first-launch events automatically (ignored on watchOS / macOS) |

```swift
let op = OursPrivacy(token: "YOUR_API_TOKEN", trackAutomaticEvents: true)
```

There is also an overload that accepts a `ProxyServerConfig` if you route ingest through a proxy.

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

Parse a deep link URL for marketing attribution data and fire a `$deep_link_opened` event. Extracts UTM parameters, ad network click IDs, and `ours_visitor_id` for cross-platform identity stitching.

Parsed attribution params are merged into `defaultProperties`, so they appear on all subsequent `track()` calls. Calling `trackDeepLink` again **replaces** the prior attribution rather than merging, so stale UTM keys don't leak into events triggered by a later link.

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

Stop all tracking immediately. Any queued events that have not been flushed will be discarded. Call `flush()` first if you want to preserve queued events.

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
        "version": "2.0.0"
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

## FAQ

**Do I need to request permission through AppTrackingTransparency?**

No. Ours Privacy does not use IDFA, so no ATT permission is required.

**Why aren't my events showing up?**

Events are batched and sent every 10 seconds by default. Call `flush()` to send immediately. Enable debug logging with `setLoggingEnabled(true)` to see what's happening. Also check that `hasOptedOutTracking()` is `false`.

**Can I run more than one instance in the same app?**

Yes — construct multiple `OursPrivacy(...)` instances with different tokens. You are responsible for holding the references.

**What platforms are supported?**

- iOS 13+
- tvOS 13+
- macOS 10.15+
- watchOS 6+

---

## Support

- [Documentation](https://docs.oursprivacy.com/docs/ios-sdk)
- [GitHub Issues](https://github.com/with-ours/ours-privacy-swift/issues)
- Email: support@oursprivacy.com
