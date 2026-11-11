//
//  MenuManager.swift
//
//  Clipy
//  GitHub: https://github.com/clipy
//  HP: https://clipy-app.com
//
//  Created by Econa77 on 2016/03/08.
//
//  Copyright © 2015-2018 Clipy Project.
//

import Cocoa
import ApplicationServices
import RxCocoa
import RxSwift
import RxOptional

final class MenuManager: NSObject {
    fileprivate lazy var configMenu: NSMenu = {
        let v = NSMenu(title: Constants.Menu.config)
        v.addItem(.init(title: L10n.clearHistory, action: #selector(AppDelegate.clearAllHistory)))
        v.addItem(.init(title: L10n.preferences, action: #selector(AppDelegate.showPreferenceWindow)))
        v.addItem(.init(title: L10n.snippets, action: #selector(AppDelegate.showSnippetEditorWindow)))
        v.addItem(.separator())
        v.addItem(.init(title: L10n.restartClipy, action: #selector(AppDelegate.restart)))
        v.addItem(.init(title: L10n.quitClipy, action: #selector(AppDelegate.terminate)))
        return v
    }()

    // StatusMenu
    fileprivate var statusItem: NSStatusItem?
    // Other
    fileprivate let disposeBag = DisposeBag()

    // MARK: - Enum Values
    // raw values match the menu item tags in CPYGeneralPreferenceViewController.xib
    // (None=0, Black=1, White=2) so the popup binding (selectedTag) and the
    // setting storage agree.
    enum StatusType: Int {
        case none = 0
        case black = 1
        case white = 2
    }

    func setup() {
        bind()
    }

}

// MARK: - Popup Menu
extension MenuManager {
    func popUpMenu(_ type: MenuType) {
        // Prefer the focused text caret of the frontmost app; fall back to the
        // mouse cursor; finally the status bar button. Caret-relative is the
        // closest to where the user is actually looking.
        switch type {
        case .history:
            let screenPt = caretScreenPoint() ?? NSEvent.mouseLocation
            ClipSearchPanelController.shared.show(at: screenPt)
        case .snippet:
            let screenPt = caretScreenPoint() ?? NSEvent.mouseLocation
            ClipSearchPanelController.shared.showSnippets(at: screenPt)
        }
    }

    /// Asks AX for the focused text element of the frontmost app and returns
    /// the bottom-left of the caret (or element bounds) in Cocoa screen
    /// coordinates. Returns nil if anything fails or AX trust is not granted.
    private static let caretQueryTimeout: Float = 0.5

    fileprivate func caretScreenPoint() -> NSPoint? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        // The default timeout is several seconds; an unresponsive app must not hold up the panel.
        AXUIElementSetMessagingTimeout(appElement, Self.caretQueryTimeout)

        var focusedAny: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedAny) == .success,
              let focusedRef = focusedAny else { return nil }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, Self.caretQueryTimeout)

        guard let rect = caretRect(for: focused) ?? elementRect(for: focused) else { return nil }

        // Reject obviously bogus AX results so we don't drop the menu in the
        // bottom-left of the screen. The text caret we want is always a small
        // rect actually located on a real screen.
        if rect.origin == .zero { return nil }
        if rect.width <= 0 && rect.height <= 0 { return nil }
        // A "text caret" rect should not be enormous; reject anything that
        // covers more than ~70% of any screen height (likely a window frame).
        let screen = NSScreen.screens.first { $0.frame.intersects(axRectToCocoa(rect)) }
        guard let onScreen = screen else { return nil }
        if rect.height > onScreen.frame.height * 0.7 { return nil }

        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let primaryHeight = primary?.frame.height ?? 0
        let cocoaY = primaryHeight - rect.maxY - 4
        let candidate = NSPoint(x: rect.minX, y: cocoaY)
        // Final sanity check: the resulting Cocoa point must land on a screen.
        guard NSScreen.screens.contains(where: { $0.frame.contains(candidate) }) else { return nil }
        return candidate
    }

    /// Helper: convert an AX rect (y from top of the primary screen, growing
    /// down) to a Cocoa rect (y from bottom of the primary screen, growing up)
    /// purely for screen-membership tests.
    private func axRectToCocoa(_ axRect: CGRect) -> CGRect {
        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let primaryHeight = primary?.frame.height ?? 0
        return CGRect(x: axRect.minX,
                      y: primaryHeight - axRect.maxY,
                      width: axRect.width,
                      height: axRect.height)
    }

    private func caretRect(for element: AXUIElement) -> CGRect? {
        var rangeAny: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeAny) == .success,
              let rangeRef = rangeAny, CFGetTypeID(rangeRef) == AXValueGetTypeID() else { return nil }
        let rangeValue = rangeRef as! AXValue
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }

        guard let param = AXValueCreate(.cfRange, &range) else { return nil }
        var boundsAny: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &boundsAny) == .success,
              let boundsRef = boundsAny, CFGetTypeID(boundsRef) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) else { return nil }
        // Some apps return zero-size rects when there is no caret; reject those.
        return rect.width > 0 || rect.height > 0 ? rect : nil
    }

    private func elementRect(for element: AXUIElement) -> CGRect? {
        var posAny: AnyObject?
        var sizeAny: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posAny) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeAny) == .success,
              let posRef = posAny, let sizeRef = sizeAny,
              CFGetTypeID(posRef) == AXValueGetTypeID(), CFGetTypeID(sizeRef) == AXValueGetTypeID() else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: pos, size: size)
    }

    func popUpSnippetFolder(_ folder: CPYFolder) {
        let screenPt = caretScreenPoint() ?? NSEvent.mouseLocation
        ClipSearchPanelController.shared.showSnippetFolder(folder, at: screenPt)
    }
}

// MARK: - Binding
private extension MenuManager {
    func bind() {
        // Menu icon
        AppEnvironment.current.defaults.rx.observe(Int.self, Preferences.General.statusTypeItem, retainSelf: false)
            .filterNil()
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] key in
                self?.changeStatusItem(StatusType(rawValue: key) ?? .none)
            })
            .disposed(by: disposeBag)

    }
}

// MARK: - Status Item
private extension MenuManager {
    func changeStatusItem(_ type: StatusType) {
        removeStatusItem()

        let image: NSImage?
        switch type {
        case .none:
            // The user opted to hide the menu bar icon entirely.
            warnAboutHiddenStatusItemIfNeeded()
            return
        case .black:
            image = Asset.StatusIcon.menuBlack.image
        case .white:
            image = Asset.StatusIcon.menuWhite.image
        }
        image?.isTemplate = true

        statusItem = NSStatusBar.system.statusItem(withLength: -1)
        statusItem?.button?.image = image
        let cell = statusItem?.button?.cell as? NSButtonCell
        cell?.highlightsBy = [.contentsCellMask, .changeBackgroundCellMask]
        statusItem?.button?.toolTip = "\(Constants.Application.name) \(Bundle.main.appVersion ?? "")"
        statusItem?.menu = configMenu
    }

    func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    private static let hideAlertSuppressKey = "kCPYSuppressAlertForHideStatusIcon"

    private func warnAboutHiddenStatusItemIfNeeded() {
        let defaults = AppEnvironment.current.defaults
        if defaults.bool(forKey: Self.hideAlertSuppressKey) { return }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = NSLocalizedString("Menu bar icon is now hidden", comment: "")
            alert.informativeText = NSLocalizedString("To show the icon again, relaunch Clipy.app from the Applications folder in Finder.", comment: "")
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = NSLocalizedString("Do not show again", comment: "")
            alert.addButton(withTitle: "OK")
            alert.runModal()
            if alert.suppressionButton?.state == .on {
                defaults.set(true, forKey: Self.hideAlertSuppressKey)
            }
        }
    }
}
