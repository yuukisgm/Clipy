import Cocoa
import RealmSwift

// Borderless NSPanel that can become key (required for IME and text input).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// Floating search panel for clipboard history.
// Replaces the old NSMenu-based FilterMenu so IME (Japanese input) works correctly.
final class ClipSearchPanelController: NSObject {

    // MARK: - Singleton

    static let shared = ClipSearchPanelController()

    // MARK: - UI

    private lazy var panel: KeyablePanel = {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        // Hide title bar chrome while keeping .titled so the panel can become key (required for IME).
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.contentView = containerView
        return p
    }()

    private lazy var containerView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .menu
        v.blendingMode = .behindWindow
        v.state = .active
        v.wantsLayer = true
        v.layer?.cornerRadius = 10
        v.layer?.masksToBounds = true
        return v
    }()

    private lazy var searchField: NSTextField = {
        let f = NSTextField()
        f.placeholderString = "履歴を検索…"
        f.isBordered = false
        f.drawsBackground = false
        f.font = NSFont.systemFont(ofSize: 15)
        f.focusRingType = .none
        f.translatesAutoresizingMaskIntoConstraints = false
        f.delegate = self
        return f
    }()

    private lazy var separatorLine: NSBox = {
        let b = NSBox()
        b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private lazy var scrollView: NSScrollView = {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.drawsBackground = false
        s.translatesAutoresizingMaskIntoConstraints = false
        s.documentView = tableView
        return s
    }()

    private lazy var tableView: NSTableView = {
        let t = NSTableView()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        col.isEditable = false
        t.addTableColumn(col)
        t.headerView = nil
        t.rowHeight = 28
        t.backgroundColor = .clear
        t.intercellSpacing = NSSize(width: 0, height: 2)
        t.selectionHighlightStyle = .regular
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.doubleAction = #selector(tableViewDoubleClicked)
        return t
    }()

    // MARK: - State

    private var allClips: [CPYClip] = []
    private var filteredClips: [CPYClip] = []
    private var realm = try! Realm()
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    // Continuously tracked so we always know where to paste even if frontmostApplication
    // returns nil at the moment the hotkey fires.
    private var lastActiveApp: NSRunningApplication?
    private var workspaceObserver: Any?

    // MARK: - App Tracking

    func startTrackingFrontmostApp() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            self?.lastActiveApp = app
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveApp = front
        }
    }

    // MARK: - Layout

    private func setupLayout() {
        guard containerView.subviews.isEmpty else { return }

        containerView.addSubview(searchField)
        containerView.addSubview(separatorLine)
        containerView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 14),
            searchField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -14),
            searchField.heightAnchor.constraint(equalToConstant: 24),

            separatorLine.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            separatorLine.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            separatorLine.heightAnchor.constraint(equalToConstant: 1),

            scrollView.topAnchor.constraint(equalTo: separatorLine.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -4)
        ])
    }

    // MARK: - Show / Hide

    func show(at screenPoint: NSPoint) {
        setupLayout()
        loadClips()
        applyFilter("")

        resizePanel()
        positionPanel(near: screenPoint)

        // Activate Clipy so the panel can become key and IME works correctly.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)

        installEventMonitors()
    }

    func close(restoreFocus: Bool = true) {
        removeEventMonitors()
        panel.orderOut(nil)
        searchField.stringValue = ""
        if restoreFocus {
            lastActiveApp?.activate(options: [])
        }
    }

    // MARK: - Data

    private func loadClips() {
        let maxHistory = AppEnvironment.current.defaults.integer(forKey: Preferences.General.maxHistorySize)
        let ascending = !AppEnvironment.current.defaults.bool(forKey: Preferences.General.reorderClipsAfterPasting)
        let results = realm
            .objects(CPYClip.self)
            .sorted(byKeyPath: #keyPath(CPYClip.updateTime), ascending: ascending)
        let limit = maxHistory > 0 ? min(maxHistory, results.count) : results.count
        allClips = Array(results[0..<limit])
    }

    private func applyFilter(_ query: String) {
        if query.isEmpty {
            filteredClips = allClips
        } else {
            filteredClips = allClips.filter { $0.title.localizedStandardContains(query) }
        }
        tableView.reloadData()
        if !filteredClips.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        resizePanel()
    }

    // MARK: - Panel Geometry

    private func resizePanel() {
        let rowCount = min(filteredClips.count, 12)
        let listHeight = CGFloat(rowCount) * (tableView.rowHeight + tableView.intercellSpacing.height) + 8
        let totalHeight = 24 + 10 + 1 + 4 + listHeight + 4 + 12
        var frame = panel.frame
        frame.size.height = max(totalHeight, 80)
        frame.origin.y -= (frame.size.height - panel.frame.size.height)
        panel.setFrame(frame, display: true, animate: false)
    }

    private func positionPanel(near screenPoint: NSPoint) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) }) ?? NSScreen.main else { return }

        var origin = NSPoint(x: screenPoint.x, y: screenPoint.y - panel.frame.height)

        if origin.x + panel.frame.width > screen.visibleFrame.maxX {
            origin.x = screen.visibleFrame.maxX - panel.frame.width
        }
        if origin.x < screen.visibleFrame.minX {
            origin.x = screen.visibleFrame.minX
        }
        if origin.y < screen.visibleFrame.minY {
            origin.y = screenPoint.y
        }

        panel.setFrameOrigin(origin)
    }

    // MARK: - Selection

    private func selectCurrentItem() {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredClips.count else { return }
        let clip = filteredClips[row]
        let targetApp = lastActiveApp
        close(restoreFocus: false)
        pasteToApp(targetApp, clip: clip)
    }

    private func pasteToApp(_ targetApp: NSRunningApplication?, clip: CPYClip) {
        guard !clip.isInvalidated else { return }

        guard let targetApp = targetApp else {
            AppEnvironment.current.pasteService.paste(with: clip)
            return
        }

        var token: Any?
        var fired = false

        let paste = {
            guard !fired else { return }
            fired = true
            if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t); token = nil }
            AppEnvironment.current.pasteService.paste(with: clip)
        }

        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activated?.processIdentifier == targetApp.processIdentifier else { return }
            paste()
        }

        targetApp.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { paste() }
    }

    @objc private func tableViewDoubleClicked() {
        selectCurrentItem()
    }

    // MARK: - Event Monitors

    private func installEventMonitors() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func removeEventMonitors() {
        if let m = globalEventMonitor { NSEvent.removeMonitor(m); globalEventMonitor = nil }
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // Escape
            close()
            return nil
        case 36, 76: // Return, numpad Enter
            selectCurrentItem()
            return nil
        case 125: // Down arrow
            let next = min(tableView.selectedRow + 1, filteredClips.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView.scrollRowToVisible(next)
            return nil
        case 126: // Up arrow
            let prev = max(tableView.selectedRow - 1, 0)
            tableView.selectRowIndexes(IndexSet(integer: prev), byExtendingSelection: false)
            tableView.scrollRowToVisible(prev)
            return nil
        default:
            return event
        }
    }
}

// MARK: - NSTextFieldDelegate

extension ClipSearchPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        applyFilter(searchField.stringValue)
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension ClipSearchPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredClips.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ClipCell")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = id
            let tf = NSTextField()
            tf.isBordered = false
            tf.drawsBackground = false
            tf.isEditable = false
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }

        let clip = filteredClips[row]
        let query = searchField.stringValue

        if query.isEmpty {
            cell.textField?.attributedStringValue = NSAttributedString(string: clip.title)
        } else {
            cell.textField?.attributedStringValue = highlighted(clip.title, query: query)
        }

        return cell
    }

    private func highlighted(_ text: String, query: String) -> NSAttributedString {
        let att = NSMutableAttributedString(string: text)
        guard let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) else {
            return att
        }
        att.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(range, in: text))
        return att
    }
}
