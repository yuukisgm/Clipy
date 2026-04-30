//
//  PasteService.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/11/23.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Foundation
import Cocoa
import Sauce

final class PasteService {

    // MARK: - Properties
    fileprivate let lock = NSRecursiveLock(name: "com.clipy-app.Clipy.Pastable")
    fileprivate var isPastePlainText: Bool {
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.Beta.pastePlainText) else { return false }

        let modifierSetting = AppEnvironment.current.defaults.integer(forKey: Preferences.Beta.pastePlainTextModifier)
        return isPressedModifier(modifierSetting)
    }
    fileprivate var isDeleteHistory: Bool {
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.Beta.deleteHistory) else { return false }

        let modifierSetting = AppEnvironment.current.defaults.integer(forKey: Preferences.Beta.deleteHistoryModifier)
        return isPressedModifier(modifierSetting)
    }
    fileprivate var isPasteAndDeleteHistory: Bool {
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.Beta.pasteAndDeleteHistory) else { return false }

        let modifierSetting = AppEnvironment.current.defaults.integer(forKey: Preferences.Beta.pasteAndDeleteHistoryModifier)
        return isPressedModifier(modifierSetting)
    }

    // MARK: - Modifiers
    private func isPressedModifier(_ flag: Int) -> Bool {
        let flags = NSEvent.modifierFlags
        if flag == 0 && flags.contains(.command) {
            return true
        } else if flag == 1 && flags.contains(.shift) {
            return true
        } else if flag == 2 && flags.contains(.control) {
            return true
        } else if flag == 3 && flags.contains(.option) {
            return true
        }
        return false
    }
}

// MARK: - Copy
extension PasteService {
    func paste(with clip: CPYClip) {
        guard !clip.isInvalidated else { return }

        do {
            let clipData = try decodeClipData(from: clip)

            // Handling modifier actions
            let isPastePlainText = self.isPastePlainText
            let isPasteAndDeleteHistory = self.isPasteAndDeleteHistory
            let isDeleteHistory = self.isDeleteHistory
            guard isPastePlainText || isPasteAndDeleteHistory || isDeleteHistory else {
                copyToPasteboard(with: clipData)
                paste()
                return
            }

            // Increment change count for don't copy paste item
            if isPasteAndDeleteHistory {
                AppEnvironment.current.clipService.incrementChangeCount()
            }
            // Paste history
            if isPastePlainText {
                copyToPasteboard(with: clipData.stringValue)
                paste()
            } else if isPasteAndDeleteHistory {
                copyToPasteboard(with: clipData)
                paste()
            }
            // Delete clip
            if isDeleteHistory || isPasteAndDeleteHistory {
                AppEnvironment.current.clipService.delete(with: clip)
            }
        } catch {
            lError(error)
        }
    }

    private func decodeClipData(from clip: CPYClip) throws -> CPYClipData {
        let data = try Data(contentsOf: .init(fileURLWithPath: clip.dataPath))
        return try JSONDecoder().decode(CPYClipData.self, from: data)
    }

    func copyToPasteboard(with string: String?) {
        guard let string = string else { return }
        lock.lock(); defer { lock.unlock() }

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(string, forType: .string)
    }

    func copyToPasteboard(with clip: CPYClip) {
        do {
            copyToPasteboard(with: try decodeClipData(from: clip))
        } catch {
            lError(error)
        }
    }

    private func copyToPasteboard(with clipData: CPYClipData) {
        lock.lock(); defer { lock.unlock() }

        let pasteboard = NSPasteboard.general
        let types = clipData.content.compactMap(\.toPasteboardType)
        pasteboard.declareTypes(types, owner: nil)
        clipData.content.forEach { type in
            type.recover(to: pasteboard)
        }
    }
}

// MARK: - Paste
extension PasteService {
    func paste() {
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.General.inputPasteCommand) else { return }
        // Check Accessibility Permission
        guard AppEnvironment.current.accessibilityService.isAccessibilityEnabled(isPrompt: false) else {
            AppEnvironment.current.accessibilityService.showAccessibilityAuthenticationAlert()
            return
        }

        let vKeyCode = Sauce.shared.keyCode(for: .v)
        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .combinedSessionState)
            // Disable local keyboard events while pasting
            source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
            // Simulate full Command+V sequence:
            // flagsChanged(Cmd↓) → keyDown(V,⌘) → keyUp(V,⌘) → flagsChanged(Cmd↑)
            // The final flagsChanged(Cmd↑) is required so virtualization apps
            // (e.g. Parallels) don't see Command as stuck after the paste.
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
            cmdDown?.type = .flagsChanged
            cmdDown?.flags = .maskCommand
            let keyVDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
            keyVDown?.flags = .maskCommand
            let keyVUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
            keyVUp?.flags = .maskCommand
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)
            cmdUp?.type = .flagsChanged
            cmdUp?.flags = []
            // Post Paste Command
            cmdDown?.post(tap: .cgAnnotatedSessionEventTap)
            keyVDown?.post(tap: .cgAnnotatedSessionEventTap)
            keyVUp?.post(tap: .cgAnnotatedSessionEventTap)
            cmdUp?.post(tap: .cgAnnotatedSessionEventTap)
        }
    }
}
