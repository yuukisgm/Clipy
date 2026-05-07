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

    // MARK: - Modifiers
    private func isPressedModifier(_ flag: Int, flags: NSEvent.ModifierFlags) -> Bool {
        switch flag {
        case 0: return flags.contains(.command)
        case 1: return flags.contains(.shift)
        case 2: return flags.contains(.control)
        case 3: return flags.contains(.option)
        default: return false
        }
    }

    private func isPastePlainText(flags: NSEvent.ModifierFlags) -> Bool {
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.Beta.pastePlainText) else { return false }
        return isPressedModifier(AppEnvironment.current.defaults.integer(forKey: Preferences.Beta.pastePlainTextModifier), flags: flags)
    }

    private func isDeleteHistory(flags: NSEvent.ModifierFlags) -> Bool {
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.Beta.deleteHistory) else { return false }
        return isPressedModifier(AppEnvironment.current.defaults.integer(forKey: Preferences.Beta.deleteHistoryModifier), flags: flags)
    }

    private func isPasteAndDeleteHistory(flags: NSEvent.ModifierFlags) -> Bool {
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.Beta.pasteAndDeleteHistory) else { return false }
        return isPressedModifier(AppEnvironment.current.defaults.integer(forKey: Preferences.Beta.pasteAndDeleteHistoryModifier), flags: flags)
    }

    func isDeleteOnlyAction(flags: NSEvent.ModifierFlags) -> Bool {
        isDeleteHistory(flags: flags) && !isPasteAndDeleteHistory(flags: flags) && !isPastePlainText(flags: flags)
    }
}

// MARK: - Copy
extension PasteService {
    func paste(with clip: CPYClip, capturedFlags: NSEvent.ModifierFlags? = nil) {
        guard !clip.isInvalidated else { return }

        do {
            let clipData = try decodeClipData(from: clip)
            // Use caller-captured flags when available (async paste fires with stale currentEvent).
            let flags = capturedFlags ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags

            // Handling modifier actions
            let isPastePlainText = self.isPastePlainText(flags: flags)
            let isPasteAndDeleteHistory = self.isPasteAndDeleteHistory(flags: flags)
            let isDeleteHistory = self.isDeleteHistory(flags: flags)
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
                let plainText: String?
                if let raw = clipData.stringValue,
                   let url = URL(string: raw), url.scheme == "file" {
                    plainText = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
                } else {
                    plainText = clipData.stringValue
                }
                copyToPasteboard(with: plainText)
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
