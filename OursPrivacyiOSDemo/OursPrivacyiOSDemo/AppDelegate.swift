//
//  AppDelegate.swift
//  OursPrivacyiOSDemo
//

import UIKit
import OursPrivacyKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    static var shared: AppDelegate {
        UIApplication.shared.delegate as! AppDelegate
    }

    /// The single SDK instance the demo holds for the app's lifetime.
    /// Constructed in `didFinishLaunching`; ``initialize(optOutTrackingDefault:options:)``
    /// is awaited from a `Task` so the app delegate can stay sync.
    var oursPrivacy: OursPrivacy?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let token = ProcessInfo.processInfo.environment["OURSPRIVACY_TOKEN"] ?? ""
        let serverURL = ProcessInfo.processInfo.environment["OURSPRIVACY_SERVER_URL"]

        let op = OursPrivacy(token: token, trackAutomaticEvents: true)
        oursPrivacy = op

        Task {
            await op.initialize(options: OursPrivacyInitOptions(serverURL: serverURL))
            op.setLoggingEnabled(true)
            op.flushInterval = 10.0
        }
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {}
}
