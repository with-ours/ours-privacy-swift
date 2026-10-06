# Changelog

## 3.1.0

- Add opt-in iOS lifecycle and engagement events, explicit `trackScreen` events, and mobile session metadata; automatic lifecycle tracking remains off by default.
- Reserve `$mobile_*` event names for SDK facts; manual `track(event:)` calls with that prefix are ignored.
- Keep StoreKit `$ae_iap` collection separately opt-in through `trackAutomaticPurchases`, independent of lifecycle tracking and subject to full opt-out.
- Remove the raw deep-link URL from `$deep_link_opened` event properties; supported attribution fields remain in `defaultProperties`.

## 3.0.0

- Raise minimum versions to iOS 15, tvOS 15, macOS 12, and watchOS 8. Apps supporting older systems must stay on 2.x.
- Report the SDK release version in every event instead of the old Mixpanel fork version.
- Update to the Swift 6 toolchain while retaining Swift 5 language mode.
- Make `identify`, `reset`, and `flush` completion closures `@Sendable`; callers capturing mutable state may need actor isolation or synchronization.
- Add a local package demo and recorder backed simulator tests.

The SDK is distributed through Swift Package Manager. CocoaPods support ended with 2.x.
