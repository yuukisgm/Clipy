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
import RealmSwift
import RxCocoa
import RxSwift
import RxOptional

final class MenuManager: NSObject {
    fileprivate var snippetMenu: NSMenu?
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
    // Icon Cache
    fileprivate let folderIcon = Asset.Common.iconFolder.image
    fileprivate let snippetIcon = Asset.Common.iconText.image
    // Other
    fileprivate let disposeBag = DisposeBag()
    fileprivate let notificationCenter = NotificationCenter.default
    fileprivate let kMaxKeyEquivalents = 10
    // Realm
    fileprivate let realm = try! Realm()
    fileprivate var snippetToken: NotificationToken?

    // MARK: - Enum Values
    // raw values match the menu item tags in CPYGeneralPreferenceViewController.xib
    // (None=0, Black=1, White=2) so the popup binding (selectedTag) and the
    // setting storage agree.
    enum StatusType: Int {
        case none = 0
        case black = 1
        case white = 2
    }

    // MARK: - Initialize
    override init() {
        super.init()
        folderIcon.isTemplate = true
        folderIcon.size = NSSize(width: 15, height: 13)
        snippetIcon.isTemplate = true
        snippetIcon.size = NSSize(width: 12, height: 13)
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
        let pt = popUpLocation()

        switch type {
        case .history:
            let menu = FilterMenu(title: L10n.history)
            // Passing the first item as `positioning` makes NSMenu open with
            // that item under `pt` AND give it the initial highlight, so arrow
            // keys can start navigating immediately.
            menu.popUp(positioning: menu.items.first, at: pt, in: statusItem?.button)
        case .snippet:
            if let menu = snippetMenu {
                applyAppearance(statusItem?.button?.effectiveAppearance, to: menu)
            }
            snippetMenu?.popUp(positioning: snippetMenu?.items.first, at: pt, in: statusItem?.button)
        }
    }

    /// Returns the popup anchor in coordinates relative to the status item
    /// button's window — what NSMenu.popUp(positioning:at:in:) expects when the
    /// `in:` view is the status item button. Tries caret → mouse → button.
    fileprivate func popUpLocation() -> CGPoint {
        guard let buttonOrigin = statusItem?.button?.window?.frame.origin else { return .zero }
        let screenPoint = caretScreenPoint() ?? NSEvent.mouseLocation
        // Cocoa screen coordinates have y growing upward; the status button
        // window's local space has y growing downward from its origin.
        return NSPoint(x: screenPoint.x - buttonOrigin.x, y: buttonOrigin.y - screenPoint.y)
    }

    /// Asks AX for the focused text element of the frontmost app and returns
    /// the bottom-left of the caret (or element bounds) in Cocoa screen
    /// coordinates. Returns nil if anything fails or AX trust is not granted.
    fileprivate func caretScreenPoint() -> NSPoint? {
        guard AXIsProcessTrusted() else { return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedAny: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedAny) == .success,
              let focusedRef = focusedAny else { return nil }
        let focused = focusedRef as! AXUIElement

        guard let rect = caretRect(for: focused) ?? elementRect(for: focused) else { return nil }

        let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
        let primaryHeight = primary?.frame.height ?? 0
        let cocoaY = primaryHeight - rect.maxY - 4
        return NSPoint(x: rect.minX, y: cocoaY)
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

    fileprivate func applyAppearance(_ appearance: NSAppearance?, to menu: NSMenu) {
        menu.appearance = appearance
        menu.items.forEach { item in
            if let submenu = item.submenu {
                applyAppearance(appearance, to: submenu)
            }
        }
    }

    func popUpSnippetFolder(_ folder: CPYFolder) {
        let folderMenu = NSMenu(title: folder.title)
        let appearance = statusItem?.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        // Folder title
        let labelItem = NSMenuItem(title: folder.title, action: nil)
        labelItem.isEnabled = false
        folderMenu.addItem(labelItem)
        // Snippets
        var index = firstIndexOfMenuItems()
        folder.snippets
            .sorted(byKeyPath: #keyPath(CPYSnippet.index), ascending: true)
            .filter { $0.enable }
            .forEach { snippet in
                let subMenuItem = makeSnippetMenuItem(snippet, listNumber: index)
                folderMenu.addItem(subMenuItem)
                index += 1
            }
        applyAppearance(appearance, to: folderMenu)
        // 履歴メニューと同じ位置計算（キャレット → マウス → ステータスバー）。
        let pt = popUpLocation()
        folderMenu.popUp(positioning: folderMenu.items.first, at: pt, in: statusItem?.button)
    }
}

// MARK: - Binding
private extension MenuManager {
    func bind() {
        // NOTE: Do not observe CPYClip changes here — createClipMenu() rebuilds
        // only the snippet menu, which is independent of clip history. Watching
        // clips would force a rebuild on every copy and waste CPU.
        snippetToken = realm.objects(CPYFolder.self)
                        .observe { [weak self] _ in
                            DispatchQueue.main.async { [weak self] in
                                self?.createClipMenu()
                            }
                        }
        // Menu icon
        AppEnvironment.current.defaults.rx.observe(Int.self, Preferences.General.statusTypeItem, retainSelf: false)
            .filterNil()
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] key in
                self?.changeStatusItem(StatusType(rawValue: key) ?? .none)
            })
            .disposed(by: disposeBag)

        // Edit snippets
        notificationCenter.rx.notification(Notification.Name(rawValue: Constants.Notification.closeSnippetEditor))
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] _ in
                self?.createClipMenu()
            })
            .disposed(by: disposeBag)
        // Observe change preference settings
        let defaults = AppEnvironment.current.defaults
        Observable.merge(
            defaults.rx.observe(Int.self, Preferences.General.reorderClipsAfterPasting, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Int.self, Preferences.General.maxShowHistorySize, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Int.self, Preferences.General.maxHistorySize, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Int.self, Preferences.General.maxWidthOfMenuItem, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Int.self, Preferences.General.menuFontSize, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Bool.self, Preferences.Menu.showIconInTheMenu, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Int.self, Preferences.Menu.numberOfItemsPlaceInline, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Int.self, Preferences.Menu.numberOfItemsPlaceInsideFolder, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Bool.self, Preferences.Menu.menuItemsAreMarkedWithNumbers, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Bool.self, Preferences.Menu.showToolTipOnMenuItem, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Bool.self, Preferences.Menu.showImageInTheMenu, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Bool.self, Preferences.Menu.addNumericKeyEquivalents, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Int.self, Preferences.Menu.maxLengthOfToolTip, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged(),
            defaults.rx.observe(Bool.self, Preferences.Menu.showColorPreviewInTheMenu, options: [.new], retainSelf: false).filterNil().mapVoidDistinctUntilChanged())
            .skip(1)
            .throttle(.seconds(1), scheduler: MainScheduler.instance)
            .asDriver(onErrorDriveWith: .empty())
            .drive(onNext: { [weak self] in
                self?.createClipMenu()
            })
            .disposed(by: disposeBag)
    }
}

// MARK: - Menus
private extension MenuManager {
     func createClipMenu() {
        snippetMenu = NSMenu(title: Constants.Menu.snippet)

        addSnippetItems(snippetMenu!, separateMenu: false)
    }

    func makeSubmenuItem(_ count: Int, start: Int, end: Int, numberOfItems: Int) -> NSMenuItem {
        var count = count
        if start == 0 {
            count -= 1
        }
        var lastNumber = count + numberOfItems
        if end < lastNumber {
            lastNumber = end
        }
        let menuItemTitle = "\(count + 1) - \(lastNumber)"
        return makeSubmenuItem(menuItemTitle)
    }

    func makeSubmenuItem(_ title: String) -> NSMenuItem {
        let subMenu = NSMenu(title: "")
        let subMenuItem = NSMenuItem(title: title, action: nil)
        subMenuItem.submenu = subMenu
        subMenuItem.image = (AppEnvironment.current.defaults.bool(forKey: Preferences.Menu.showIconInTheMenu)) ? folderIcon : nil
        return subMenuItem
    }

}

// MARK: - Snippets
private extension MenuManager {
    func addSnippetItems(_ menu: NSMenu, separateMenu: Bool) {
        let folderResults = realm.objects(CPYFolder.self).sorted(byKeyPath: #keyPath(CPYFolder.index), ascending: true)
        guard !folderResults.isEmpty else { return }
        if separateMenu {
            menu.addItem(NSMenuItem.separator())
        }

        // Snippet title
        let labelItem = NSMenuItem(title: L10n.snippet, action: nil)
        labelItem.isEnabled = false
        menu.addItem(labelItem)

        var subMenuIndex = menu.numberOfItems - 1
        let firstIndex = firstIndexOfMenuItems()

        folderResults
            .filter { $0.enable }
            .forEach { folder in
                let folderTitle = folder.title
                let subMenuItem = makeSubmenuItem(folderTitle)
                menu.addItem(subMenuItem)
                subMenuIndex += 1

                var i = firstIndex
                folder.snippets
                    .sorted(byKeyPath: #keyPath(CPYSnippet.index), ascending: true)
                    .filter { $0.enable }
                    .forEach { snippet in
                        let subMenuItem = makeSnippetMenuItem(snippet, listNumber: i)
                        if let subMenu = menu.item(at: subMenuIndex)?.submenu {
                            subMenu.addItem(subMenuItem)
                            i += 1
                        }
                    }
            }
    }

    func makeSnippetMenuItem(_ snippet: CPYSnippet, listNumber: Int) -> NSMenuItem {
        let defaults = AppEnvironment.current.defaults
        let isMarkWithNumber = defaults.bool(forKey: Preferences.Menu.menuItemsAreMarkedWithNumbers)
        let isShowIcon = defaults.bool(forKey: Preferences.Menu.showIconInTheMenu)
        let maxWidth = CGFloat(defaults.float(forKey: Preferences.General.maxWidthOfMenuItem))
        let fontSize = CGFloat(defaults.float(forKey: Preferences.General.menuFontSize))

        let prefix = isMarkWithNumber ? "\(listNumber). " : ""
        let attributedTitle = snippet.title.trimForMenuItem(with: prefix, maxWidth: maxWidth, fontSize: fontSize)

        let menuItem = NSMenuItem(title: attributedTitle.string, action: #selector(AppDelegate.selectSnippetMenuItem(_:)), keyEquivalent: "")
        menuItem.attributedTitle = attributedTitle
        menuItem.representedObject = snippet.identifier
        menuItem.toolTip = snippet.content
        menuItem.image = isShowIcon ? snippetIcon : nil

        return menuItem
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
            alert.messageText = "メニューバーアイコンを非表示にしました"
            alert.informativeText = """
            この設定では Clipy の設定画面を画面上から開く手段がなくなります。
            再表示するには、ターミナルで次のコマンドを実行してください：

            defaults write com.clipy-project.Clipy kCPYPrefStatusTypeItemKey -int 1 && killall Clipy && open -a Clipy
            """
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "今後表示しない"
            alert.addButton(withTitle: "OK")
            alert.runModal()
            if alert.suppressionButton?.state == .on {
                defaults.set(true, forKey: Self.hideAlertSuppressKey)
            }
        }
    }
}

// MARK: - Settings
private extension MenuManager {
    func firstIndexOfMenuItems() -> NSInteger {
        return  1
    }
}
