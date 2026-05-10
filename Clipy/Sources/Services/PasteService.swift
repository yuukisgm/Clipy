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
    func paste(with clip: CPYClip, capturedFlags: NSEvent.ModifierFlags? = nil, targetBundleIdentifier: String? = nil) {
        do {
            let clipData = try SQLiteClipStore.shared.decodedClipData(for: clip)
            // Use caller-captured flags when available (async paste fires with stale currentEvent).
            let flags = capturedFlags ?? NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags

            // Handling modifier actions
            let isPastePlainText = self.isPastePlainText(flags: flags)
            let isPasteAndDeleteHistory = self.isPasteAndDeleteHistory(flags: flags)
            let isDeleteHistory = self.isDeleteHistory(flags: flags)
            guard isPastePlainText || isPasteAndDeleteHistory || isDeleteHistory else {
                copyToPasteboard(with: clipData)
                AppEnvironment.current.clipService.reorderAfterPasting(clip)
                paste(targetBundleIdentifier: targetBundleIdentifier)
                return
            }

            // Increment change count for don't copy paste item
            if isPasteAndDeleteHistory {
                AppEnvironment.current.clipService.incrementChangeCount()
            }
            // Paste history
            if isPastePlainText {
                copyToPasteboard(with: plainText(from: clipData))
                AppEnvironment.current.clipService.reorderAfterPasting(clip)
                paste(targetBundleIdentifier: targetBundleIdentifier)
            } else if isPasteAndDeleteHistory {
                copyToPasteboard(with: clipData)
                paste(targetBundleIdentifier: targetBundleIdentifier)
            }
            // Delete clip
            if isDeleteHistory || isPasteAndDeleteHistory {
                AppEnvironment.current.clipService.delete(with: clip)
            }
        } catch {
            lError(error)
        }
    }

    func copyToPasteboard(with string: String?) {
        guard let string = string else { return }
        lock.lock(); defer { lock.unlock() }

        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(string, forType: .string)
        AppEnvironment.current.clipService.ignoreCurrentPasteboardChange()
    }

    func copyToPasteboard(with clip: CPYClip) {
        do {
            copyToPasteboard(with: try SQLiteClipStore.shared.decodedClipData(for: clip))
        } catch {
            lError(error)
        }
    }

    private func copyToPasteboard(with clipData: CPYClipData) {
        lock.lock(); defer { lock.unlock() }

        let pasteboard = NSPasteboard.general
        var types = clipData.content.compactMap(\.toPasteboardType)
        let plainText = plainText(from: clipData)
        let tableTextTypes = Self.tableTextPasteboardTypes
        if plainText != nil {
            tableTextTypes.forEach {
                if !types.contains($0) {
                    types.append($0)
                }
            }
        }
        pasteboard.declareTypes(types, owner: nil)
        clipData.content.forEach { type in
            type.recover(to: pasteboard)
        }
        if let plainText = plainText {
            tableTextTypes.forEach {
                pasteboard.setString(plainText, forType: $0)
            }
        }
        AppEnvironment.current.clipService.ignoreCurrentPasteboardChange()
    }

    private func plainText(from clipData: CPYClipData) -> String? {
        guard let raw = clipData.stringValue else { return nil }
        if let url = URL(string: raw), url.scheme == "file" {
            return url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        }
        return raw
    }

    private static let tableTextPasteboardTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(rawValue: "NSStringPboardType"),
        NSPasteboard.PasteboardType(rawValue: "NeXT plain ascii pasteboard type"),
        NSPasteboard.PasteboardType(rawValue: "NSTabularTextPboardType"),
        NSPasteboard.PasteboardType(rawValue: "public.utf8-tab-separated-values-text"),
        NSPasteboard.PasteboardType(rawValue: "public.tab-separated-values-text"),
        NSPasteboard.PasteboardType(rawValue: "public.comma-separated-values-text")
    ]
}

// MARK: - Paste
extension PasteService {
    func paste(targetBundleIdentifier: String? = nil) {
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.General.inputPasteCommand) else { return }
        // Check Accessibility Permission
        guard AppEnvironment.current.accessibilityService.isAccessibilityEnabled(isPrompt: false) else {
            AppEnvironment.current.accessibilityService.showAccessibilityAuthenticationAlert()
            return
        }

        let vKeyCode = Sauce.shared.keyCode(for: .v)
        let bundleIdentifier = targetBundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .combinedSessionState)
            // Disable local keyboard events while pasting
            source?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
            if Self.requiresClearingInternalClipboard(bundleIdentifier: bundleIdentifier) {
                Self.postEscape(source: source)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    Self.postPasteCommand(source: source, vKeyCode: vKeyCode)
                }
                return
            }
            Self.postPasteCommand(source: source, vKeyCode: vKeyCode)
        }
    }

    private static func requiresClearingInternalClipboard(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.microsoft.Excel"
    }

    private static func postEscape(source: CGEventSource?) {
        let escapeKeyCode: CGKeyCode = 0x35
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: escapeKeyCode, keyDown: false)
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func postPasteCommand(source: CGEventSource?, vKeyCode: CGKeyCode) {
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
