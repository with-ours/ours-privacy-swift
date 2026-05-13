//
//  ViewController.swift
//  OursPrivacyiOSDemo
//

import UIKit
import OursPrivacyKit

class ViewController: UIViewController {

    @IBOutlet weak var txtToken: UITextField!
    @IBOutlet weak var txtId: UITextField!
    @IBOutlet weak var txtResults: UITextView!
    @IBOutlet weak var btnYellow: UIButton!
    @IBOutlet weak var btnBlue: UIButton!
    @IBOutlet weak var btnRed: UIButton!
    @IBOutlet weak var btnGreen: UIButton!

    private var op: OursPrivacy? { AppDelegate.shared.oursPrivacy }

    override func viewDidLoad() {
        super.viewDidLoad()
        txtToken.text = op?.apiToken ?? ""
        appendResult("Demo loaded. Visitor: \(op?.getVisitorId() ?? "nil")")
        appendResult("Opted out: \(op?.hasOptedOutTracking() == true)")
    }

    // MARK: - Identify + default properties

    @IBAction func start(_ sender: Any) {
        guard let op = op else { return }
        let externalId = txtId.text?.isEmpty == false ? txtId.text! : "demo_user"

        op.updateDefaultEventProperties(["app_section": "demo"])
        op.updateDefaultUserCustomProperties(["tier": "demo"])

        op.identify(OursPrivacyUserProperties(email: "someone@example.com",
                                              externalId: externalId,
                                              firstName: "Demo",
                                              lastName: "User"))
        op.track(event: "Started")
        op.flush()

        btnYellow.isEnabled = true
        btnBlue.isEnabled = true
        btnRed.isEnabled = true
        btnGreen.isEnabled = true
        txtId.endEditing(true)
        txtToken.endEditing(true)
        appendResult("identify(\(externalId)) + Started")
    }

    // MARK: - Per-button track

    @IBAction func btnClicked(_ sender: Any) {
        guard let op = op, let btn = sender as? UIButton else { return }
        let event = btn.titleLabel?.text?.replacingOccurrences(of: "Send ", with: "") ?? "Event"
        if event == "Green" {
            let props: Properties = [
                "test": "data",
                "testInt": 42,
                "boolean": true,
                "double": 42.42,
            ]
            op.track(event: event, properties: props)
        } else {
            op.track(event: event)
        }
        appendResult("track(\(event))")
    }

    // MARK: - Deep link

    @IBAction func sendDeepLink(_ sender: Any) {
        guard let op = op else { return }
        op.trackDeepLink("https://example.com/?utm_source=demo&utm_medium=button&fbclid=abc123")
        appendResult("trackDeepLink(demo url)")
    }

    // MARK: - Opt-in / opt-out

    @IBAction func optOut(_ sender: Any) {
        op?.optOutTracking()
        appendResult("optOutTracking()")
    }

    @IBAction func optIn(_ sender: Any) {
        op?.optInTracking()
        appendResult("optInTracking()")
    }

    @IBAction func flush(_ sender: Any) {
        op?.flush()
        appendResult("flush()")
    }

    private func appendResult(_ line: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let prefix = txtResults.text.isEmpty ? "" : "\n"
        txtResults.text = (txtResults.text ?? "") + "\(prefix)[\(ts)] \(line)"
    }
}
