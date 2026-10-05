# Swift SDK Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release a Swift 6 toolchain compatible SDK with correct event versions and a locally runnable, CI backed demo.

**Architecture:** Keep the public SDK and UIKit demo. Use a single SDK version constant for event payloads and validate it against the framework plist and release title. Run recorder backed XCUITests through one repository command.

**Tech Stack:** SwiftPM, Xcode 26.5, SwiftLint, SwiftFormat, XCTest, Python recorder, GitHub Actions.

**Spec:** The SDK quality ticket and Tyler's September 28 decisions in this conversation.

## Global Constraints

- Swift tools version 6.0 in Swift 5 language mode, with complete concurrency checking and zero warnings.
- iOS 15, tvOS 15, macOS 12, watchOS 8.
- CocoaPods remains dropped; UIKit remains the demo UI.
- One local E2E command runs the same recorder backed tests in CI without external services.
- A major version is required.
- Open a release PR against `main` after verification; merging still requires review.

---

### Task 1: Version and platform contract

**Files:** `Package.swift`, `OursPrivacy/Utilities/AutomaticProperties.swift`, `Info.plist`, `OursPrivacy.xcodeproj/project.pbxproj`, `OursPrivacyiOSDemo/OursPrivacyiOSDemo.xcodeproj/project.pbxproj`, `Tests/OursPrivacyTests/OursPrivacyTests.swift`, `README.md`

**Interfaces:** `AutomaticProperties.libVersion()` returns the release version. Event payloads use `swift@<version>`.

- [ ] Make the existing default property test assert `swift@3.0.0` and run it to observe the stale value.
- [ ] Set the SDK version in one Swift declaration and use it in automatic properties.
- [ ] Align package, framework, demo, plist, and README minimums and version.
- [ ] Run `swift test` and Xcode platform builds.

### Task 2: Strict concurrency

**Files:** SDK sources, `Package.swift`, `OursPrivacy.xcodeproj/project.pbxproj`, `tools/recorder-probe/main.swift`

**Interfaces:** Public methods retain their current behavior and signatures except callback sendability where required by queue transfer.

- [ ] Capture baseline diagnostics with `swift test -Xswiftc -strict-concurrency=complete`.
- [ ] Protect shared mutable state and mark only synchronization backed types as `@unchecked Sendable`.
- [ ] Make transferred values and callbacks Sendable, or keep them confined to their queues.
- [ ] Repeat complete concurrency tests and platform builds until no warnings remain.

### Task 3: Local demo and recorder tests

**Files:** demo project, demo app, demo tests, `tools/payload-recorder`, `README.md`

**Interfaces:** `tools/payload-recorder/run-ios-e2e.sh` runs the recorder and `xcodebuild test`; UI tests pass their server URL to the demo.

- [ ] Replace the remote package pin with a local package reference.
- [ ] Add static tests for demo behavior and XCUITests for every demo action and payload shape.
- [ ] Add deterministic accessibility identifiers and recorder URL configuration.
- [ ] Run the one command on an available iOS simulator and inspect captured payloads.

### Task 4: CI and release

**Files:** `.github/workflows`, `.github/dependabot.yml`, `.swiftlint.yml`, SwiftFormat config, release notes

**Interfaces:** CI and local E2E call the same script; publish and release title checks validate the SDK constant and plist.

- [ ] Pin macOS 26 and Xcode 26.5; add package, simulator, tvOS, and watchOS checks.
- [ ] Enable SwiftLint, SwiftFormat, and Dependabot Swift updates; remove stale lint exclusions.
- [ ] Run the local equivalents of all CI checks and leave the branch ready for review.
- [ ] Open a release PR for review; after its approved merge, verify the tag, SPM version, and demo telemetry.
