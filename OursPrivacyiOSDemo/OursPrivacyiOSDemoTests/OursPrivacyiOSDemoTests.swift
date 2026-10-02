import Testing
import UIKit
import OursPrivacyKit
@testable import OursPrivacyiOSDemo

struct OursPrivacyiOSDemoTests {
    @Test @MainActor
    func demoShowsSDKStateAndExposesEveryAction() throws {
        let delegate = AppDelegate.shared
        let previous = delegate.oursPrivacy
        defer { delegate.oursPrivacy = previous }

        let sdk = OursPrivacy(token: "demo-unit-test", trackAutomaticEvents: false)
        delegate.oursPrivacy = sdk

        let storyboard = UIStoryboard(name: "Main", bundle: .main)
        let controller = try #require(storyboard.instantiateInitialViewController() as? ViewController)
        controller.loadViewIfNeeded()

        #expect(controller.txtToken.text == "demo-unit-test")
        #expect(controller.txtResults.text.contains(sdk.getVisitorId() ?? "missing visitor"))
        for identifier in ["start", "sendYellow", "sendBlue", "sendRed", "sendGreen",
                           "sendDeepLink", "optOut", "optIn", "flush"] {
            #expect(findButton(identifier, in: controller.view) != nil)
        }
    }

    @MainActor
    private func findButton(_ identifier: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityIdentifier == identifier {
            return button
        }
        for child in view.subviews {
            if let button = findButton(identifier, in: child) {
                return button
            }
        }
        return nil
    }
}
