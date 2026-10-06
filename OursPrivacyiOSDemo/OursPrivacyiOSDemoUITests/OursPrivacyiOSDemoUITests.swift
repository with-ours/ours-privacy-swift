import XCTest

final class OursPrivacyiOSDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoActionsSendCanonicalPayloads() throws {
        let recorderURL = ProcessInfo.processInfo.environment["RECORDER_URL"] ?? "http://127.0.0.1:8765"
        let token = "swift-e2e-\(UUID().uuidString)"
        let app = XCUIApplication()
        app.launchEnvironment["OURSPRIVACY_TOKEN"] = token
        app.launchEnvironment["OURSPRIVACY_SERVER_URL"] = recorderURL
        app.launch()

        let start = app.buttons["start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)
        wait(for: [ready], timeout: 15)
        let userId = app.textFields["userId"]
        userId.tap()
        userId.typeText("demo-e2e-user")
        start.tap()

        let identify = try waitForEvent("$identify", token: token, recorderURL: recorderURL)
        XCTAssertEqual((identify["userProperties"] as? [String: Any])?["external_id"] as? String,
                       "demo-e2e-user")
        let started = try waitForEvent("Started", token: token, recorderURL: recorderURL)
        XCTAssertEqual((started["eventProperties"] as? [String: Any])?["app_section"] as? String, "demo")

        for (button, event) in [("sendYellow", "Yellow"), ("sendBlue", "Blue"),
                                ("sendRed", "Red"), ("sendGreen", "Green")] {
            app.buttons[button].tap()
            app.buttons["flush"].tap()
            let payload = try waitForEvent(event, token: token, recorderURL: recorderURL)
            if event == "Green" {
                let properties = try XCTUnwrap(payload["eventProperties"] as? [String: Any])
                XCTAssertEqual(properties["test"] as? String, "data")
                XCTAssertEqual(properties["testInt"] as? Int, 42)
                XCTAssertEqual(properties["boolean"] as? Bool, true)
            }
        }

        app.buttons["sendDeepLink"].tap()
        app.buttons["flush"].tap()
        let deepLink = try waitForEvent("$deep_link_opened", token: token, recorderURL: recorderURL)
        XCTAssertNil((deepLink["eventProperties"] as? [String: Any])?["url"])
        XCTAssertEqual((deepLink["eventProperties"] as? [String: Any])?["app_section"] as? String, "demo")
        XCTAssertFalse(String(describing: deepLink).contains("https://example.com"))
        XCTAssertEqual((deepLink["defaultProperties"] as? [String: Any])?["utm_source"] as? String, "demo")
        XCTAssertEqual((deepLink["defaultProperties"] as? [String: Any])?["fbclid"] as? String, "abc123")

        let beforeOptOut = try events(token: token, recorderURL: recorderURL).count
        app.buttons["optOut"].tap()
        app.buttons["sendRed"].tap()
        app.buttons["flush"].tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(try events(token: token, recorderURL: recorderURL).count, beforeOptOut)

        app.buttons["optIn"].tap()
        app.buttons["sendBlue"].tap()
        app.buttons["flush"].tap()
        _ = try waitForEvent("$opt_in", token: token, recorderURL: recorderURL, flushing: app)
        let afterOptIn = try events(token: token, recorderURL: recorderURL)
        XCTAssertGreaterThan(afterOptIn.filter { $0["event"] as? String == "Blue" }.count, 1)

        for envelope in try envelopes(recorderURL: recorderURL)
            where envelope["token"] as? String == token {
            XCTAssertNotNil(envelope["is_manually_set_id"] as? Bool)
            for event in envelope["data"] as? [[String: Any]] ?? [] {
                XCTAssertNotNil(event["event"] as? String)
                XCTAssertNotNil(event["visitor_id"] as? String)
                XCTAssertNotNil(event["distinct_id"] as? String)
                let defaults = try XCTUnwrap(event["defaultProperties"] as? [String: Any])
                XCTAssertEqual(defaults["version"] as? String, "swift@3.0.0")
                XCTAssertEqual(defaults["device_vendor"] as? String, "Apple")
            }
        }
    }

    @MainActor
    private func waitForEvent(_ name: String, token: String, recorderURL: String,
                              flushing app: XCUIApplication? = nil) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let event = try events(token: token, recorderURL: recorderURL)
                .first(where: { $0["event"] as? String == name }) {
                return event
            }
            app?.buttons["flush"].tap()
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("No \(name) event reached the recorder")
        return [:]
    }

    private func events(token: String, recorderURL: String) throws -> [[String: Any]] {
        try envelopes(recorderURL: recorderURL)
            .filter { $0["token"] as? String == token }
            .flatMap { $0["data"] as? [[String: Any]] ?? [] }
    }

    private func envelopes(recorderURL: String) throws -> [[String: Any]] {
        let url = try XCTUnwrap(URL(string: recorderURL + "/captures"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }
}
