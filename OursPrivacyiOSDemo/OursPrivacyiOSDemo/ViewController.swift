//
//  ViewController.swift
//  OursPrivacyiOSDemo
//
//  Created by Steve Krenek on 4/9/25.
//

import UIKit
import OursPrivacy

class ViewController: UIViewController {
    
    @IBOutlet weak var txtToken: UITextField!
    @IBOutlet weak var txtId: UITextField!
    @IBOutlet weak var txtResults: UITextView!
    @IBOutlet weak var btnYellow: UIButton!
    @IBOutlet weak var btnBlue: UIButton!
    @IBOutlet weak var btnRed: UIButton!
    @IBOutlet weak var btnGreen: UIButton!

    override func viewDidLoad() {
        super.viewDidLoad()
        txtToken.text = OursPrivacy.mainInstance().apiToken
    }
    
    @IBAction func start(_ sender: Any) {
        OursPrivacy.mainInstance().userId = txtId.text ?? "demo_user"
        OursPrivacy.mainInstance().identify(distinctId: OursPrivacy.mainInstance().userId!, userProperties: ["email": "someone@example.com"])
        OursPrivacy.mainInstance().track(event: "Started")
        OursPrivacy.mainInstance().flush()
        btnYellow.isEnabled = true
        btnBlue.isEnabled = true
        btnRed.isEnabled = true
        btnGreen.isEnabled = true
        txtId.endEditing(true)
        txtToken.endEditing(true)
    }

    @IBAction func btnClicked(_ sender: Any) {
        if let btn = sender as? UIButton {
            let event = btn.titleLabel?.text?.replacingOccurrences(of: "Send ", with: "")
            if event == "Green" {
                let props: Properties = [
                    "test": "data",
                    "testInt": 42,
                    "boolean": true,
                    "double": 42.42
                ]
                OursPrivacy.mainInstance().track(event: event, properties: props)
            } else {
                OursPrivacy.mainInstance().track(event: event)
            }
        }
    }
}
