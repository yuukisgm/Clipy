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
            // The plain-text modifier inverts the default paste format.
            let defaultsToPlainText = AppEnvironment.current.defaults.bool(forKey: Preferences.Beta.pastePlainTextByDefault)
            // The plain-text default doesn't apply to files, or Finder would receive a text clipping.
            let pastesPlainText = (defaultsToPlainText && clipData.containsFiles) ? false : defaultsToPlainText != isPastePlainText
            guard isPastePlainText || isPasteAndDeleteHistory || isDeleteHistory else {
                copyToPasteboard(with: clipData, asPlainText: pastesPlainText)
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
                copyToPasteboard(with: clipData, asPlainText: pastesPlainText)
                AppEnvironment.current.clipService.reorderAfterPasting(clip)
                paste(targetBundleIdentifier: targetBundleIdentifier)
            } else if isPasteAndDeleteHistory {
                copyToPasteboard(with: clipData, asPlainText: pastesPlainText)
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

        AppEnvironment.current.clipService.writeToPasteboardWithoutRecording {
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(string, forType: .string)
        }
    }

    func copyToPasteboard(with clip: CPYClip) {
        do {
            copyToPasteboard(with: try SQLiteClipStore.shared.decodedClipData(for: clip))
        } catch {
            lError(error)
        }
    }

    private func copyToPasteboard(with clipData: CPYClipData, asPlainText: Bool) {
        // Clips without text (e.g. images) keep their original data.
        if asPlainText, let text = plainText(from: clipData) {
            copyToPasteboard(with: text)
        } else {
            copyToPasteboard(with: clipData)
        }
    }

    private func copyToPasteboard(with clipData: CPYClipData) {
        lock.lock(); defer { lock.unlock() }

        clipData.requestFileAccess()
        let pasteboard = NSPasteboard.general
        var types = clipData.content.compactMap(\.toPasteboardType)
        // Spreadsheet text types are meaningless for files and could compete with them in the target app.
        let plainText = clipData.containsFiles ? nil : self.plainText(from: clipData)
        let tableTextTypes = Self.tableTextPasteboardTypes
        if plainText != nil {
            tableTextTypes.forEach {
                if !types.contains($0) {
                    types.append($0)
                }
            }
        }
        AppEnvironment.current.clipService.writeToPasteboardWithoutRecording {
            pasteboard.declareTypes(types, owner: nil)
            clipData.content.forEach { type in
                type.recover(to: pasteboard)
            }
            if let plainText = plainText {
                tableTextTypes.forEach {
                    pasteboard.setString(plainText, forType: $0)
                }
            }
        }
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
        if let app = Self.virtualMachineApp(bundleIdentifier: bundleIdentifier) {
            // Parallels 27 forwards a synthesized Cmd+V to the guest as raw keys and drops
            // Command about half the time ("v" is typed). Its own Edit > Paste menu item syncs
            // the clipboard first and fails far less often (Parallels-side bug, ~1 in 8).
            Self.pressPasteMenuItem(of: app, attempt: 1, fallbackKeyCode: vKeyCode)
            return
        }
        Self.whenReadyForKeys(bundleIdentifier: targetBundleIdentifier, attempt: 1) {
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

    // MARK: - Target Readiness
    private static let readyForKeysPollInterval: TimeInterval = 0.02
    private static let readyForKeysQueryTimeout: Float = 0.05
    private static let readyForKeysMaxAttempts = 8

    /// The workspace reports the target as activated before the target itself has handled the
    /// activation. A Cmd+V arriving in that gap finds no key window and is dropped (the clip is
    /// on the pasteboard but nothing is pasted; seen with Electron apps). Wait until the target
    /// says it is frontmost, then post. Gives up after ~0.5s and posts anyway, as before.
    private static func whenReadyForKeys(bundleIdentifier: String?, attempt: Int, _ post: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 1 ? 0 : readyForKeysPollInterval)) {
            guard attempt < readyForKeysMaxAttempts,
                  let bundleIdentifier = bundleIdentifier,
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
                  !app.isActive || isHandlingKeys(app) == false else {
                post()
                return
            }
            whenReadyForKeys(bundleIdentifier: bundleIdentifier, attempt: attempt + 1, post)
        }
    }

    /// nil when the app can't tell (no Accessibility support); callers then don't wait.
    private static func isHandlingKeys(_ app: NSRunningApplication) -> Bool? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, readyForKeysQueryTimeout)
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(appElement, kAXFrontmostAttribute as CFString, &ref) {
        case .success: return ref as? Bool
        case .cannotComplete: return false // Busy: still starting to handle the activation.
        default: return nil
        }
    }

    private static func requiresClearingInternalClipboard(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier = bundleIdentifier, bundleIdentifier == "com.microsoft.Excel" else { return false }
        // Escape would discard the text being edited in a cell or close an open dialog.
        return !isEditingTextOrInDialog(bundleIdentifier: bundleIdentifier)
    }

    private static func isEditingTextOrInDialog(bundleIdentifier: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return false }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let focused = axElement(appElement, kAXFocusedUIElementAttribute),
           let role = axString(focused, kAXRoleAttribute),
           [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) {
            return true
        }
        if let window = axElement(appElement, kAXFocusedWindowAttribute),
           let subrole = axString(window, kAXSubroleAttribute),
           [kAXDialogSubrole, kAXSystemDialogSubrole].contains(subrole) {
            return true
        }
        return false
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    // MARK: - Virtual Machine
    private static let virtualMachinePasteDelay: TimeInterval = 0.1
    private static let virtualMachinePasteMaxAttempts = 10
    private static let pasteMenuItemTitles: Set<String> = ["Paste", "貼り付け", "ペースト"]

    private static func pressPasteMenuItem(of app: NSRunningApplication, attempt: Int, fallbackKeyCode: CGKeyCode) {
        DispatchQueue.main.asyncAfter(deadline: .now() + virtualMachinePasteDelay) {
            let pressed = pressPasteMenuItem(of: app)
            guard !pressed else { return }
            guard attempt >= virtualMachinePasteMaxAttempts else {
                pressPasteMenuItem(of: app, attempt: attempt + 1, fallbackKeyCode: fallbackKeyCode)
                return
            }
            postPasteCommand(source: CGEventSource(stateID: .combinedSessionState), vKeyCode: fallbackKeyCode)
        }
    }

    private static func virtualMachineApp(bundleIdentifier: String?) -> NSRunningApplication? {
        // Parallels VM windows and Coherence apps are "com.parallels.winapp.<VM UUID>.*"
        guard let bundleIdentifier = bundleIdentifier, bundleIdentifier.hasPrefix("com.parallels.winapp.") else { return nil }
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == bundleIdentifier {
            return front
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    private static func pressPasteMenuItem(of app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let menuBar = axElement(appElement, kAXMenuBarAttribute) else { return false }
        for menuBarItem in axChildren(menuBar) {
            for menu in axChildren(menuBarItem) {
                for item in axChildren(menu) {
                    var titleRef: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef) == .success,
                          let title = titleRef as? String,
                          pasteMenuItemTitles.contains(title) else { continue }
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private static func axElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement) // swiftlint:disable:this force_cast
    }

    private static func axChildren(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
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
