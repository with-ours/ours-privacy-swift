[![Swift Package Manager compatible](https://img.shields.io/badge/Swift%20Package%20Manager-compatible-brightgreen.svg)](https://github.com/apple/swift-package-manager)
[![Apache License](https://img.shields.io/github/license/with-ours/ours-privacy-swift)](https://oursprivacy.com)
[![Documentation](https://img.shields.io/badge/Documentation-blue)](https://docs.oursprivacy.com/docs/overview)
# Table of Contents

<!-- MarkdownTOC -->

- [Overview](#overview)
- [Quick Start Guide](#quick-start-guide)
    - [Install Ours Privacy](#1-install-ours-privacy)
    - [Initialize Ours Privacy](#2-initialize-oursprivacy)
    - [Send Data](#3-send-data)
    - [Check for Success](#4-check-for-success)
    - [Complete Code Example](#complete-code-example)
- [FAQ](#faq)

<!-- /MarkdownTOC -->


<a name="introduction"></a>
# Overview

Welcome to the official Ours Privacy Swift Library

The Ours Privacy Swift library for iOS is an open-source project based on the Mixpanel Swift library and aims to be compatible with it.

# Quick Start Guide
Our master branch and our releases are on Swift 5.

## 1. Install Ours Privacy
You will need an API token  for an Ours Privacy source for initializing your library. You can get your API token by creating a "Server to Server" source in the Ours Privacy portal.

### Installation: Swift Package Manager (v2.8.0+)
The easiest way to get Ours Privacy into your iOS project is to use Swift Package Manager.
1. In Xcode, select File > Add Packages...
2. Enter the package URL for this repository [Ours Privacy Swift library](https://github.com/with-ours/ours-privacy-swift).


## 2. Initialize Ours Privacy
Import `OursPrivacy` into AppDelegate.swift, and initialize OursPrivacy within application:didFinishLaunchingWithOptions:
```swift
import OursPrivacy

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [NSObject: AnyObject]?) -> Bool {
    ...
    OursPrivacy.initialize(token: "API_TOKEN", trackAutomaticEvents: true)
    // Optionally: OursPrivacy.initialize(token: "API_TOKEN", trackAutomaticEvents: true, serverURL: "https://dev-api.oursprivacy.com/api/v1")
    ...
}
```

## 3. Identify the User
Once you know which user you're working with (i.e. after login), you can link the user's id to future tracking by calling identify with your user's id.
```swift
let userId = "some-uuid-or-unique-id" // Note the data type of string
OursPrivacy.mainInstance().identify(distinctId: userId, userProperties: ["email": "someone@example.com"])
```

## 3. Send Data
Let's get started by sending event data. You can send an event from anywhere in your application. Better understand user behavior by storing details that are specific to the event (properties).   Also, OursPrivacy automatically tracks some properties by default.
```swift
OursPrivacy.mainInstance().track(event: "Sign Up", properties: [
   "source": "Tyler's affiliate site",
   "Opted out of email": true
])
```

## 4. Check for Success
[Open up Recent Events](https://app.oursprivacy.com/recent-events) (under Reporting) in the Ours Privacy portal to view incoming events.

## Complete Code Example
Here's a runnable code example that covers everything in this quickstart guide.
```swift
import OursPrivacy

func application(_ application: UIApplication,
                 didFinishLaunchingWithOptions launchOptions: [NSObject: AnyObject]?) -> Bool {
    ...
    OursPrivacy.initialize(token: "API_TOKEN", trackAutomaticEvents: false)
    OursPrivacy.mainInstance().track(event: "Sign Up", properties: [
       "source": "Tyler's affiliate site",
       "Opted out of email": true
    ])
    ...
}
```

## Contributing

We welcome contributions! If you'd like to contribute to this SDK, please see our [publishing documentation](PUBLISHING.md) for development and publishing guidelines.

## Support

For help with this SDK, please:

- Check the [documentation](https://docs.oursprivacy.com)
- Open an issue on [GitHub](https://github.com/with-ours/ours-privacy-swift/issues)
- Contact us at support@oursprivacy.com

## FAQ
**I have a test user I would like to opt out of tracking. How do I do that?**

OursPrivacy's client-side tracking library contains the `optOutTracking()` method, which will set the user’s local opt-out state to “true” and will prevent data from being sent from a user’s device.

**Why aren't my events showing up?**

First, make sure your test device has internet access. To preserve battery life and customer bandwidth, the OursPrivacy library doesn't send the events you record immediately. Instead, it sends batches to the Ours Privacy servers every 60 seconds while your application is running, as well as when the application transitions to the background. You can call `flush()` manually if you want to force a flush at a particular moment.
```swift
OursPrivacy.mainInstance().flush()
```
If your events are still not showing up after 60 seconds, check if you have opted out of tracking. You can also enable OursPrivacy debugging and logging, it allows you to see the debug output from the OursPrivacy library. To enable it, set `loggingEnabled` to true.
```swift
OursPrivacy.mainInstance().loggingEnabled = true
```
**Starting with iOS 14.5, do I need to request the user’s permission through the AppTrackingTransparency framework to use OursPrivacy?**

No, OursPrivacy does not use IDFA so it does not require user permission through the AppTrackingTransparency(ATT) framework.
