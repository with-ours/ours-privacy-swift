//
//  ViewController.swift
//  OPTestApp
//
//  Created by Steve Krenek on 4/11/25.
//

import UIKit
import OursPrivacy

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        OursPrivacy.initialize(token: "e93676a05e4c1dbed98cd2cd3fc03b206c289921af313192296d9dbbf0bfff00", trackAutomaticEvents: true, serverURL: "https://dev-api.oursprivacy.com/api/v1")
        OursPrivacy.mainInstance().loggingEnabled = true // Enable logging
        OursPrivacy.mainInstance().flushInterval = 10.0 // Set auto-flush interval to 10 seconds.  (Defaults to 60 seconds)
    }

    @IBAction func track(_ sender: Any) {

    }
}
