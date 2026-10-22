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
    @IBOutlet weak var btnStart: UIButton!

    private var actionButtons: [UIButton] = []

    private var op: OursPrivacy? { AppDelegate.shared.oursPrivacy }

    override func viewDidLoad() {
        super.viewDidLoad()
        txtToken.text = op?.apiToken ?? ""
        txtId.accessibilityIdentifier = "userId"
        txtResults.accessibilityIdentifier = "results"
        btnStart.accessibilityIdentifier = "start"
        btnStart.isEnabled = AppDelegate.shared.sdkReady
        btnYellow.accessibilityIdentifier = "sendYellow"
        btnBlue.accessibilityIdentifier = "sendBlue"
        btnRed.accessibilityIdentifier = "sendRed"
        btnGreen.accessibilityIdentifier = "sendGreen"
        configureActionButtons()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(sdkDidBecomeReady),
                                               name: AppDelegate.sdkReadyNotification,
                                               object: nil)
        if AppDelegate.shared.sdkReady {
            sdkDidBecomeReady()
        }
        appendResult("Demo loaded. Visitor: \(op?.getVisitorId() ?? "nil")")
        appendResult("Opted out: \(op?.hasOptedOutTracking() == true)")
    }

    @objc private func sdkDidBecomeReady() {
        btnStart.isEnabled = true
        actionButtons.forEach { $0.isEnabled = true }
        appendResult("SDK ready")
    }

    private func configureActionButtons() {
        let deepLink = makeActionButton("Deep Link", identifier: "sendDeepLink", action: #selector(sendDeepLink(_:)))
        let optOut = makeActionButton("Opt Out", identifier: "optOut", action: #selector(optOut(_:)))
        let optIn = makeActionButton("Opt In", identifier: "optIn", action: #selector(optIn(_:)))
        let flush = makeActionButton("Flush", identifier: "flush", action: #selector(flush(_:)))
        let schedule = makeActionButton("Schedule", identifier: "openSchedule", action: #selector(openSchedule(_:)))
        let book = makeActionButton("Book Appointment", identifier: "bookAppointment", action: #selector(bookAppointment(_:)))
        actionButtons = [deepLink, optOut, optIn, flush, schedule, book]

        let topRow = UIStackView(arrangedSubviews: [deepLink, optOut])
        let middleRow = UIStackView(arrangedSubviews: [optIn, flush])
        let bottomRow = UIStackView(arrangedSubviews: [schedule, book])
        for row in [topRow, middleRow, bottomRow] {
            row.distribution = .fillEqually
            row.spacing = 10
        }
        let stack = UIStackView(arrangedSubviews: [topRow, middleRow, bottomRow])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        view.constraints
            .filter { ($0.firstItem as? UIView) === txtResults && $0.firstAttribute == .top }
            .forEach { $0.isActive = false }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: txtResults.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: txtResults.trailingAnchor),
            stack.topAnchor.constraint(equalTo: btnRed.bottomAnchor, constant: 10),
            topRow.heightAnchor.constraint(equalToConstant: 35),
            middleRow.heightAnchor.constraint(equalToConstant: 35),
            bottomRow.heightAnchor.constraint(equalToConstant: 35),
            txtResults.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 10)
        ])
    }

    private func makeActionButton(_ title: String, identifier: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = identifier
        button.isEnabled = AppDelegate.shared.sdkReady
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    // MARK: - Identify + default properties

    @IBAction func start(_ sender: Any) {
        guard AppDelegate.shared.sdkReady, let op = op else { return }
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
                "double": 42.42
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

    @IBAction func openSchedule(_ sender: Any) {
        op?.trackScreen("Schedule")
        appendResult("trackScreen(Schedule)")
    }

    @IBAction func bookAppointment(_ sender: Any) {
        op?.track(event: "appointment_booked", properties: ["appointment_id": "synthetic-ios-appointment"])
        appendResult("track(appointment_booked)")
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
