//
//  CPYTypePreferenceViewController.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/03/17.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Cocoa

class CPYTypePreferenceViewController: NSViewController {

    // MARK: - Properties
    @objc var storeTypes: NSMutableDictionary!

    // MARK: - Initialize
    override func loadView() {
        if let dictionary = AppEnvironment.current.defaults.object(forKey: Constants.UserDefaults.storeTypes) as? [String: Any] {
            storeTypes = NSMutableDictionary(dictionary: dictionary)
        } else {
            storeTypes = NSMutableDictionary()
        }
        super.loadView()
        // The checkboxes are bound to the dictionary; apply a change right away instead of on window close.
        CPYClipData.availableTypesString.forEach {
            storeTypes.addObserver(self, forKeyPath: $0, options: [], context: nil)
        }
    }

    // swiftlint:disable:next block_based_kvo
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard object as AnyObject? === storeTypes else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            return
        }
        AppEnvironment.current.defaults.set(storeTypes, forKey: Constants.UserDefaults.storeTypes)
    }

}
