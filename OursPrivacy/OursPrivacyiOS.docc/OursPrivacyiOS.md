# ``OursPrivacyKit``

The Ours Privacy SDK for iOS, tvOS, macOS, and watchOS.

## Overview

`OursPrivacyKit` records events from your app and ships them to the Ours Privacy ingest API. Hold a single ``OursPrivacy`` instance for the lifetime of the host process; identify the current visitor when you know who they are; record events as they move through your product.

```swift
import OursPrivacyKit

let op = OursPrivacy(token: "YOUR_TOKEN", trackAutomaticEvents: true)
await op.initialize()

op.identify(OursPrivacyUserProperties(email: "ada@example.com",
                                      externalId: "user-123"))

op.track(event: "Sign Up", properties: ["plan": "pro"])
```

The full README — including the payload structure, migration notes from 1.x, and a development guide — lives at the repository root.

## Mobile screens and StoreKit

Call ``OursPrivacy/trackScreen(_:)`` from each custom UIKit or SwiftUI navigation transition:

```swift
op.trackScreen("Schedule")
```

The public method accepts a fixed, developer-chosen 1–80-character ASCII label matching `^[A-Za-z][A-Za-z0-9 _-]{0,79}$`, with no leading or trailing whitespace. It ignores empty, URL-like, and non-ASCII labels and suppresses a repeated active screen. In the iOS app runtime it emits `$mobile_screen_view` with `eventProperties.screen_name`; a change checkpoints prior-screen `$mobile_session_engagement` with `engagement_duration_ms` and the prior `screen_name` when automatic lifecycle tracking is enabled. On macOS, tvOS, visionOS, watchOS, and iOS apps running on Mac it emits no canonical screen event; ordinary `track(event:)` remains available. Custom navigation requires explicit calls; there is no complete automatic screen tracker.

Map routes to constant labels. Syntax validation cannot distinguish an alphanumeric patient name from a constant label. Never pass patient names, titles, route parameters, or raw URLs; the SDK does not inspect screen content. Manual screens and `track(event:properties:userProperties:)` work with `trackAutomaticEvents: false`. The option defaults to `false` and enables automatic lifecycle, engagement, and update facts when set to `true`. `$mobile_*` names are reserved: manual `track(event:)` calls with that prefix are ignored, including unknown names. Legacy `$ae_*` handling is unchanged.

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

StoreKit collection requires a separate explicit choice, independent of automatic lifecycle tracking:

```swift
let op = OursPrivacy(token: "YOUR_TOKEN",
                     trackAutomaticEvents: true,
                     trackAutomaticPurchases: true)
await op.initialize()
```

`trackAutomaticPurchases` defaults to `false` and can also be overridden at boot with `OursPrivacyInitOptions(trackAutomaticPurchases: true)`. A purchased transaction retains the legacy `$ae_iap` event and `eventProperties.$ae_iap_price` (string), `$ae_iap_quantity` (integer), and `$ae_iap_name` (product identifier). Apps migrating from the shared automatic flag must opt in explicitly to keep these product details. ``OursPrivacy/optOutTracking()`` suppresses and clears pending screens, lifecycle events, and purchases.

## Topics

### Constructing the SDK

- ``OursPrivacy``
- ``OursPrivacyInitOptions``
- ``ProxyServerConfig``

### Identity

- ``OursPrivacy/identify(_:completion:)``
- ``OursPrivacy/getVisitorId()``
- ``OursPrivacy/setVisitorId(_:)``
- ``OursPrivacy/reset(completion:)``
- ``OursPrivacyUserProperties``

### Tracking events

- ``OursPrivacy/track(event:properties:userProperties:)``
- ``OursPrivacy/trackScreen(_:)``
- ``OursPrivacy/updateDefaultEventProperties(_:)``
- ``OursPrivacy/updateDefaultUserCustomProperties(_:)``
- ``OursPrivacy/updateDefaultUserConsentProperties(_:)``

### Deep links and attribution

- ``OursPrivacy/trackDeepLink(_:)``
- ``parseAttributionFromURL(_:)``
- ``AttributionResult``

### Flushing and lifecycle

- ``OursPrivacy/flush(performFullFlush:completion:)``
- ``OursPrivacy/flushInterval``
- ``OursPrivacy/flushBatchSize``
- ``OursPrivacy/flushOnBackground``

### Opt-out

- ``OursPrivacy/optOutTracking()``
- ``OursPrivacy/optInTracking(userProperties:properties:)``
- ``OursPrivacy/hasOptedOutTracking()``

### Logging and delegates

- ``OursPrivacy/setLoggingEnabled(_:)``
- ``OursPrivacy/loggingEnabled``
- ``OursPrivacyDelegate``
- ``OursPrivacyProxyServerDelegate``

### Property values

- ``OursPrivacyType``
- ``Properties``
