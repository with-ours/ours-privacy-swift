# Changelog

## 3.1.0

- Add opt-in iOS lifecycle and engagement events, explicit `trackScreen` events, and mobile session metadata; automatic lifecycle tracking remains off by default.
- Reserve `$mobile_*` event names for SDK facts; manual `track(event:)` calls with that prefix are ignored.
- Keep StoreKit `$ae_iap` collection separately opt-in through `trackAutomaticPurchases`, independent of lifecycle tracking and subject to full opt-out.
- Remove the raw deep-link URL from `$deep_link_opened` event properties; supported attribution fields remain in `defaultProperties`.
- Preserve queued events through reset and retry failed local writes; visitor changes process asynchronously in tracking order.
- Recognize legacy installations even with automatic tracking off; preserve session ID uniqueness during rapid identity changes and continue foreground engagement after clock rollback.
- Let manual events and screen activity renew session inactivity in the background without adding engagement time.
- Accept empty or JSON-object non-indexed 2xx upload responses; bound malformed acknowledgments, retain offline data on 403, and remove invalid visitor rows after durable rejection.
- Cancel uploads that exceed the local wait; stop tracking and cancel active uploads immediately on opt-out, including while earlier tracking work is still queued.
- Keep legacy lifecycle events for compatibility; count only the `$mobile_*` stream for Mobile Analytics.

## 3.0.0

- Raise minimum versions to iOS 15, tvOS 15, macOS 12, and watchOS 8. Apps supporting older systems must stay on 2.x.
- Report the SDK release version in every event instead of the old Mixpanel fork version.
- Update to the Swift 6 toolchain while retaining Swift 5 language mode.
- Make `identify`, `reset`, and `flush` completion closures `@Sendable`; callers capturing mutable state may need actor isolation or synchronization.
- Add a local package demo and recorder backed simulator tests.

The SDK is distributed through Swift Package Manager. CocoaPods support ended with 2.x.
