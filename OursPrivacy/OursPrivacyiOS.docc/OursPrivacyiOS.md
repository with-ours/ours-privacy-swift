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

Map routes to constant labels. Syntax validation cannot distinguish an alphanumeric patient name from a constant label. Never pass patient names, titles, route parameters, or raw URLs; the SDK does not inspect screen content. Manual screens and `track(event:properties:userProperties:)` work with `trackAutomaticEvents: false` and carry iOS `defaultProperties.sid`, `mobile_session_started_at`, `mobile_occurred_at`, `mobile_platform`, `mobile_contract_version`, and app version/build when available. With automatic lifecycle tracking on, the SDK also emits `$mobile_first_open`, `$mobile_app_open`, `$mobile_session_start`, `$mobile_session_engagement`, `$mobile_session_end` when observed, and `$mobile_app_update` when a later app build changes.

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
