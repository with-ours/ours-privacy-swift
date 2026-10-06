import XCTest

final class OursPrivacyiOSDemoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoActionsSendCanonicalPayloads() throws {
        let recorderURL = ProcessInfo.processInfo.environment["RECORDER_URL"] ?? "http://127.0.0.1:8765"
        let token = "swift-e2e-\(UUID().uuidString)"
        let visitorId = "swift-visitor-\(UUID().uuidString)"
        let initialURL = "https://example.com/schedule?utm_source=ios_demo&ours_visitor_id=\(visitorId)" +
            "&patient_email=private-demo-value&idfa=private-ad-value"
        let app = XCUIApplication()
        app.launchEnvironment["OURSPRIVACY_TOKEN"] = token
        app.launchEnvironment["OURSPRIVACY_SERVER_URL"] = recorderURL
        app.launchEnvironment["OURSPRIVACY_INITIAL_URL"] = initialURL
        app.launch()

        let start = app.buttons["start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)
        wait(for: [ready], timeout: 15)
        app.buttons["flush"].tap()
        let firstOpen = try waitForEvent("$mobile_first_open", token: token, recorderURL: recorderURL, flushing: app)
        let sessionStart = try waitForEvent("$mobile_session_start", token: token, recorderURL: recorderURL, flushing: app)
        let initialDeepLink = try waitForEvent("$deep_link_opened", token: token, recorderURL: recorderURL,
                                               utmSource: "ios_demo")
        XCTAssertEqual(initialDeepLink["visitor_id"] as? String, visitorId)
        XCTAssertNil((initialDeepLink["eventProperties"] as? [String: Any])?["url"])
        XCTAssertEqual(firstOpen["visitor_id"] as? String, visitorId)
        XCTAssertEqual(sessionStart["visitor_id"] as? String, visitorId)
        let sid = try XCTUnwrap((sessionStart["defaultProperties"] as? [String: Any])?["sid"] as? String)
        XCTAssertFalse(sid.isEmpty)
        XCTAssertEqual((firstOpen["defaultProperties"] as? [String: Any])?["sid"] as? String, sid)

        app.buttons["openSchedule"].tap()
        app.buttons["flush"].tap()
        let screen = try waitForEvent("$mobile_screen_view", token: token, recorderURL: recorderURL, flushing: app)
        XCTAssertEqual((screen["eventProperties"] as? [String: Any])?["screen_name"] as? String, "Schedule")
        XCTAssertEqual(screen["visitor_id"] as? String, visitorId)
        XCTAssertEqual((screen["defaultProperties"] as? [String: Any])?["sid"] as? String, sid)

        app.buttons["bookAppointment"].tap()
        app.buttons["flush"].tap()
        let booking = try waitForEvent("appointment_booked", token: token, recorderURL: recorderURL, flushing: app)
        XCTAssertEqual((booking["eventProperties"] as? [String: Any])?["appointment_id"] as? String,
                       "synthetic-ios-appointment")
        XCTAssertEqual(booking["visitor_id"] as? String, visitorId)
        XCTAssertEqual((booking["defaultProperties"] as? [String: Any])?["sid"] as? String, sid)

        Thread.sleep(forTimeInterval: 1)
        XCUIDevice.shared.press(.home)
        let engagement = try waitForEvent("$mobile_session_engagement", token: token,
                                          recorderURL: recorderURL, screenName: "Schedule")
        let duration = try XCTUnwrap((engagement["eventProperties"] as? [String: Any])?["engagement_duration_ms"] as? Int)
        XCTAssertGreaterThan(duration, 0)
        XCTAssertEqual(engagement["visitor_id"] as? String, visitorId)
        XCTAssertEqual((engagement["defaultProperties"] as? [String: Any])?["sid"] as? String, sid)
        let beforeResume = try events(token: token, recorderURL: recorderURL)
        XCTAssertEqual(beforeResume.filter { $0["event"] as? String == "$mobile_app_open" }.count, 1)
        app.activate()
        XCTAssertTrue(start.waitForExistence(timeout: 10))

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
        let deepLink = try waitForEvent("$deep_link_opened", token: token, recorderURL: recorderURL,
                                        utmSource: "demo")
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

        let captured = try events(token: token, recorderURL: recorderURL)
        XCTAssertEqual(captured.filter { $0["event"] as? String == "$mobile_first_open" }.count, 1)
        let appOpens = captured.enumerated().filter { $0.element["event"] as? String == "$mobile_app_open" }
        XCTAssertEqual(appOpens.count, 2)
        let coldOpen = try XCTUnwrap(appOpens.first)
        let warmOpen = try XCTUnwrap(appOpens.last)
        for appOpen in [coldOpen.element, warmOpen.element] {
            XCTAssertEqual(appOpen["visitor_id"] as? String, visitorId)
            XCTAssertEqual((appOpen["defaultProperties"] as? [String: Any])?["sid"] as? String, sid)
        }
        XCTAssertEqual(captured.filter { $0["event"] as? String == "$mobile_session_start" }.count, 1)
        let automatic = captured.filter {
            let name = $0["event"] as? String
            return name?.hasPrefix("$mobile_") == true || name?.hasPrefix("$ae_") == true
        }
        XCTAssertFalse(automatic.isEmpty)
        XCTAssertFalse(captured.contains { $0["event"] as? String == "$ae_iap" })
        let firstOpenIndex = try XCTUnwrap(captured.firstIndex { $0["event"] as? String == "$mobile_first_open" })
        let sessionStartIndex = try XCTUnwrap(captured.firstIndex { $0["event"] as? String == "$mobile_session_start" })
        let screenIndex = try XCTUnwrap(captured.firstIndex { $0["event"] as? String == "$mobile_screen_view" })
        let bookingIndex = try XCTUnwrap(captured.firstIndex { $0["event"] as? String == "appointment_booked" })
        let engagementIndex = try XCTUnwrap(captured.firstIndex {
            $0["event"] as? String == "$mobile_session_engagement" &&
                ($0["eventProperties"] as? [String: Any])?["screen_name"] as? String == "Schedule"
        })
        XCTAssertLessThan(firstOpenIndex, sessionStartIndex)
        XCTAssertLessThan(firstOpenIndex, coldOpen.offset)
        XCTAssertLessThan(coldOpen.offset, sessionStartIndex)
        XCTAssertLessThan(sessionStartIndex, screenIndex)
        XCTAssertLessThan(screenIndex, bookingIndex)
        XCTAssertLessThan(bookingIndex, engagementIndex)
        XCTAssertLessThan(engagementIndex, warmOpen.offset)
        for event in [firstOpen, sessionStart, screen, booking, engagement] {
            let defaults = try XCTUnwrap(event["defaultProperties"] as? [String: Any])
            XCTAssertEqual(defaults["mobile_platform"] as? String, "ios")
            XCTAssertEqual(defaults["mobile_contract_version"] as? Int, 1)
            XCTAssertEqual(defaults["app_version"] as? String, "1.0")
            XCTAssertEqual(defaults["app_build"] as? String, "1")
            let startedAt = try XCTUnwrap(defaults["mobile_session_started_at"] as? String)
            let occurredAt = try XCTUnwrap(defaults["mobile_occurred_at"] as? String)
            XCTAssertTrue(isUTCMillisecondTimestamp(startedAt), startedAt)
            XCTAssertTrue(isUTCMillisecondTimestamp(occurredAt), occurredAt)
            XCTAssertEqual(startedAt, (sessionStart["defaultProperties"] as? [String: Any])?["mobile_session_started_at"] as? String)
            XCTAssertNil(event["time"])
        }
        let automaticJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: automatic),
                                                 encoding: .utf8)).lowercased()
        for forbidden in [initialURL.lowercased(), "private-demo-value", "private-ad-value",
                          "patient", "advertising_id", "idfa", "gaid", "idfv", "app_set_id",
                          "https://", "http://"] {
            XCTAssertFalse(automaticJSON.contains(forbidden), forbidden)
        }
        let capturedJSON = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: captured),
                                                encoding: .utf8)).lowercased()
        for forbidden in [initialURL.lowercased(), "private-demo-value", "private-ad-value"] {
            XCTAssertFalse(capturedJSON.contains(forbidden), forbidden)
        }

        for envelope in try envelopes(recorderURL: recorderURL)
            where envelope["token"] as? String == token {
            XCTAssertNotNil(envelope["is_manually_set_id"] as? Bool)
            for event in envelope["data"] as? [[String: Any]] ?? [] {
                XCTAssertNotNil(event["event"] as? String)
                XCTAssertNotNil(event["visitor_id"] as? String)
                XCTAssertNotNil(event["distinct_id"] as? String)
                XCTAssertNil(event["time"])
                let defaults = try XCTUnwrap(event["defaultProperties"] as? [String: Any])
                XCTAssertEqual(defaults["version"] as? String, "swift@3.0.0")
                XCTAssertEqual(defaults["device_vendor"] as? String, "Apple")
            }
        }
    }

    @MainActor
    private func waitForEvent(_ name: String, token: String, recorderURL: String,
                              screenName: String? = nil,
                              utmSource: String? = nil,
                              flushing app: XCUIApplication? = nil) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let event = try events(token: token, recorderURL: recorderURL)
                .first(where: {
                    $0["event"] as? String == name &&
                        (screenName == nil ||
                            ($0["eventProperties"] as? [String: Any])?["screen_name"] as? String == screenName) &&
                        (utmSource == nil ||
                            ($0["defaultProperties"] as? [String: Any])?["utm_source"] as? String == utmSource)
                }) {
                return event
            }
            app?.buttons["flush"].tap()
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("No \(name) event reached the recorder")
        return [:]
    }

    private func isUTCMillisecondTimestamp(_ value: String) -> Bool {
        value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
                    options: .regularExpression) != nil
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
