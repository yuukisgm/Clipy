//
//  CPYBetaPreferenceViewController.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/06/28.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Cocoa

final class CPYBetaPreferenceViewController: NSViewController {
    @IBOutlet private weak var versionTF: NSTextField!
    @IBOutlet private weak var pastePlainTextByDefaultSwitch: NSSwitch!
    @IBOutlet private weak var pastePlainTextButton: NSButton!

    override func loadView() {
        super.loadView()

        versionTF.stringValue = Bundle.main.appVersion.map { str in
            return "Version: \(str)"
        } ?? ""
        pastePlainTextByDefaultSwitch.state = isPastePlainTextByDefault ? .on : .off
        updatePastePlainTextTitle()
    }

    private var isPastePlainTextByDefault: Bool {
        AppEnvironment.current.defaults.bool(forKey: Preferences.Beta.pastePlainTextByDefault)
    }

    @IBAction private func togglePastePlainTextByDefault(_ sender: NSSwitch) {
        AppEnvironment.current.defaults.set(sender.state == .on, forKey: Preferences.Beta.pastePlainTextByDefault)
        updatePastePlainTextTitle()
    }

    // The modifier pastes in the opposite format of the default.
    private func updatePastePlainTextTitle() {
        pastePlainTextButton.title = isPastePlainTextByDefault
            ? NSLocalizedString("Paste as Rich Text", comment: "")
            : NSLocalizedString("Paste as Plain Text", comment: "")
    }
}
