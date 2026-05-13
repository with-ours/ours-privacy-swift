# ``OursPrivacyKit``

The Ours Privacy SDK for iOS, tvOS, macOS, and watchOS.

## Overview

`OursPrivacyKit` records events from your app and ships them to the Ours Privacy ingest API. Hold a single ``OursPrivacy`` instance for the lifetime of the host process; identify the current visitor when you know who they are; record events as they move through your product.

```swift
import OursPrivacyKit

let op = OursPrivacy(token: "YOUR_TOKEN", trackAutomaticEvents: true)
await op.initialize()

op.identify(distinctId: "user-123",
            userProperties: OursPrivacyUserProperties(email: "ada@example.com"))

op.track(event: "Sign Up", properties: ["plan": "pro"])
```

The full README — including the payload structure, migration notes from 1.x, and a development guide — lives at the repository root.

## Topics

### Constructing the SDK

- ``OursPrivacy``
- ``OursPrivacyInitOptions``
- ``ProxyServerConfig``

### Identity

- ``OursPrivacy/identify(distinctId:userProperties:completion:)``
- ``OursPrivacy/getVisitorId()``
- ``OursPrivacy/setVisitorId(_:)``
- ``OursPrivacy/reset(completion:)``
- ``OursPrivacyUserProperties``

### Tracking events

- ``OursPrivacy/track(event:properties:userProperties:)``
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
- ``OursPrivacy/optInTracking(distinctId:properties:)``
- ``OursPrivacy/hasOptedOutTracking()``

### Logging and delegates

- ``OursPrivacy/setLoggingEnabled(_:)``
- ``OursPrivacy/loggingEnabled``
- ``OursPrivacyDelegate``
- ``OursPrivacyProxyServerDelegate``

### Property values

- ``OursPrivacyType``
- ``Properties``
