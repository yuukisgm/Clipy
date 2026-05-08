import Cocoa
import PINCache
import RealmSwift
import SwiftUI

// Borderless NSPanel that can become key (required for IME and text input).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// SwiftUI 製の透過背景。NSVisualEffectView を NSViewRepresentable で埋め、
// clipShape(.continuous) で角丸を当て、上から枠線を overlay する。
// AppKit の layer.cornerRadius / maskImage では NSVisualEffectView の vibrancy
// クリップが甘く四角い角が残るため、SwiftUI レンダラの合成段クリップに任せる。
private struct VisualEffectBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = false
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private struct PanelBackdropView: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        VisualEffectBackdrop()
            .clipShape(shape)
            .overlay(shape.strokeBorder(SwiftUI.Color.white.opacity(0.16), lineWidth: 1))
    }
}

// 検索パネルの container ビュー。
// 自身は素の NSView。subview を以下の順で持つ:
//   1. NSHostingView<PanelBackdropView>  ← 透過 + 角丸 + 枠線（SwiftUI clipShape）
//   2. searchField / separatorLine / scrollView ← 既存 AppKit ツリーがそのまま乗る
// 自身の layer に cornerRadius=12 + masksToBounds=true をかけて、
// AppKit 側の subview もウィンドウ角に従ってクリップされるようにする。
// （SwiftUI clipShape は背景の vibrancy をクリップする役目、
//   layer.cornerRadius は AppKit subview をクリップする役目で二重 / 同形状）
private final class MenuBackgroundView: NSView {
    static let cornerRadius: CGFloat = 12

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = Self.cornerRadius
        if #available(macOS 11.0, *) {
            layer?.cornerCurve = .continuous
        }
        layer?.masksToBounds = true

        let host = NSHostingView(rootView: PanelBackdropView(cornerRadius: Self.cornerRadius))
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
}

private final class MenuTooltipBackgroundView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .menu
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func textColor() -> NSColor {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.86, alpha: 1)
            : NSColor(calibratedWhite: 0.24, alpha: 1)
    }
}

private final class MenuSeparatorView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        applyAppearance()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        layer?.backgroundColor = (dark
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.10)).cgColor
    }
}

private final class MenuTableView: NSTableView {
    private var hoverTrackingArea: NSTrackingArea?
    var hoverSelectionHandler: ((MenuTableView) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea = hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseMoved]
        hoverTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(hoverTrackingArea!)
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, row < numberOfRows else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollRowToVisible(row)
        if let action = action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, row < numberOfRows else { return }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        scrollRowToVisible(row)
        hoverSelectionHandler?(self)
    }
}

private final class MenuSearchFieldCell: NSTextFieldCell {
    private let horizontalInset: CGFloat = 4

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(super.drawingRect(forBounds: rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centeredRect(super.titleRect(forBounds: rect))
    }

    override func edit(withFrame rect: NSRect,
                       in controlView: NSView,
                       editor textObj: NSText,
                       delegate: Any?,
                       event: NSEvent?) {
        super.edit(withFrame: centeredRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect,
                         in controlView: NSView,
                         editor textObj: NSText,
                         delegate: Any?,
                         start selStart: Int,
                         length selLength: Int) {
        super.select(withFrame: centeredRect(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }

    private func centeredRect(_ rect: NSRect) -> NSRect {
        let textHeight = cellSize.height
        let y = rect.origin.y + floor((rect.height - textHeight) / 2)
        return NSRect(x: rect.origin.x + horizontalInset,
                      y: y,
                      width: max(0, rect.width - horizontalInset * 2),
                      height: textHeight)
    }
}

private final class MenuItemTextFieldCell: NSTextFieldCell {
    private static let verticalOpticalOffset: CGFloat = 1

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(super.drawingRect(forBounds: rect), forBounds: rect)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        verticallyCenteredRect(super.titleRect(forBounds: rect), forBounds: rect)
    }

    private func verticallyCenteredRect(_ baseRect: NSRect, forBounds rect: NSRect) -> NSRect {
        var drawingRect = baseRect
        let textSize = cellSize(forBounds: rect)
        let heightDelta = drawingRect.height - textSize.height
        guard heightDelta > 0 else { return drawingRect }
        drawingRect.origin.y += floor(heightDelta / 2) + Self.verticalOpticalOffset
        drawingRect.size.height -= heightDelta
        return drawingRect
    }
}

private final class MenuSearchField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    func applyAppearance() {
        textColor = .labelColor
    }
}

// Always shows accent-colored selection regardless of focus state — matches NSMenu behavior.
private final class ClipRowView: NSTableRowView {
    override var isEmphasized: Bool { get { true } set {} }
}

// Floating search panel for clipboard history.
// Replaces the old NSMenu-based FilterMenu so IME (Japanese input) works correctly.
final class ClipSearchPanelController: NSObject {
    private static let mainTableIdentifier = NSUserInterfaceItemIdentifier("main")
    private static let folderTableIdentifier = NSUserInterfaceItemIdentifier("folder")
    private static let folderTopInset: CGFloat = 2
    private static let folderBottomInset: CGFloat = 2
    private static let folderVerticalPadding: CGFloat = folderTopInset + folderBottomInset
    private static let snippetTopInset: CGFloat = 2
    private static let snippetBottomInset: CGFloat = 2
    private static let snippetVerticalInset: CGFloat = snippetTopInset + snippetBottomInset
    private static let snippetListBottomPadding: CGFloat = 0
    private static let submenuListBottomPadding: CGFloat = 0
    // history モード時の chrome 高さ内訳:
    // searchTop(10) + searchHeight(22) + separatorTop(6) + separatorH(1) + scrollTopFromSep(2) + scrollBottom(2)
    private static let historyChromeHeight: CGFloat = 10 + 22 + 6 + 1 + 2 + 2


    // MARK: - Singleton

    static let shared = ClipSearchPanelController()

    // MARK: - UI

    private lazy var panel: KeyablePanel = {
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        p.contentView = containerView
        return p
    }()

    private lazy var containerView: MenuBackgroundView = {
        return MenuBackgroundView()
    }()

    private lazy var searchField: NSTextField = {
        let f = MenuSearchField()
        let cell = MenuSearchFieldCell(textCell: "")
        cell.isEditable = true
        cell.isSelectable = true
        cell.isScrollable = true
        cell.usesSingleLineMode = true
        cell.lineBreakMode = .byTruncatingTail
        f.cell = cell
        f.placeholderString = NSLocalizedString("Search History…", comment: "")
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.isEditable = true
        f.isSelectable = true
        f.font = NSFont.systemFont(ofSize: 15)
        f.focusRingType = .none
        f.translatesAutoresizingMaskIntoConstraints = false
        f.delegate = self
        f.applyAppearance()
        return f
    }()

    private lazy var separatorLine: MenuSeparatorView = {
        let v = MenuSeparatorView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private lazy var scrollView: NSScrollView = {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.drawsBackground = false
        s.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        s.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.documentView = tableView
        return s
    }()

    private lazy var tableView: NSTableView = {
        let t = MenuTableView()
        t.identifier = Self.mainTableIdentifier
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        col.isEditable = false
        t.addTableColumn(col)
        t.headerView = nil
        t.rowHeight = menuRowHeight()
        t.backgroundColor = .clear
        t.intercellSpacing = menuIntercellSpacing()
        t.selectionHighlightStyle = .regular
        mainTableViewRef = t
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.action = #selector(tableViewClicked)
        t.doubleAction = #selector(tableViewDoubleClicked)
        t.hoverSelectionHandler = { [weak self] tableView in
            self?.suppressInitialTooltip = false
            self?.showFolderIfNeeded(at: tableView.selectedRow)
        }
        return t
    }()

    private lazy var folderPanel: NSPanel = {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.hasShadow = true
        p.contentView = folderContainerView
        return p
    }()

    private lazy var folderContainerView: MenuBackgroundView = {
        return MenuBackgroundView()
    }()

    private lazy var tooltipPanel: NSPanel = {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 22),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hidesOnDeactivate = false
        p.ignoresMouseEvents = true
        p.hasShadow = true
        p.contentView = tooltipContainerView
        return p
    }()

    private lazy var tooltipContainerView: MenuTooltipBackgroundView = {
        return MenuTooltipBackgroundView()
    }()

    private lazy var tooltipLabel: NSTextField = {
        let f = NSTextField(labelWithString: "")
        f.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 6
        f.font = NSFont.systemFont(ofSize: 13)
        f.textColor = tooltipContainerView.textColor()
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return f
    }()

    private lazy var tooltipColorSwatch: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 2
        v.layer?.borderWidth = 0.5
        v.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 14),
            v.heightAnchor.constraint(equalToConstant: 14)
        ])
        return v
    }()

    private lazy var tooltipImageView: NSImageView = {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.translatesAutoresizingMaskIntoConstraints = false
        let w = v.widthAnchor.constraint(equalToConstant: 80)
        let h = v.heightAnchor.constraint(equalToConstant: 80)
        NSLayoutConstraint.activate([w, h])
        tooltipImageWidthConstraint = w
        tooltipImageHeightConstraint = h
        return v
    }()

    private var tooltipImageWidthConstraint: NSLayoutConstraint?
    private var tooltipImageHeightConstraint: NSLayoutConstraint?

    private lazy var tooltipContentStack: NSStackView = {
        let labelRow = NSStackView(views: [tooltipColorSwatch, tooltipLabel])
        labelRow.orientation = .horizontal
        labelRow.spacing = 6
        labelRow.alignment = .centerY
        labelRow.distribution = .fill

        let s = NSStackView(views: [tooltipImageView, labelRow])
        s.orientation = .vertical
        s.spacing = 4
        s.alignment = .leading
        s.translatesAutoresizingMaskIntoConstraints = false
        tooltipContainerView.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: tooltipContainerView.leadingAnchor, constant: 8),
            s.trailingAnchor.constraint(equalTo: tooltipContainerView.trailingAnchor, constant: -8),
            s.topAnchor.constraint(equalTo: tooltipContainerView.topAnchor, constant: 4),
            s.bottomAnchor.constraint(equalTo: tooltipContainerView.bottomAnchor, constant: -4)
        ])
        return s
    }()

    private lazy var folderScrollView: NSScrollView = {
        let s = NSScrollView()
        s.hasVerticalScroller = true
        s.autohidesScrollers = true
        s.drawsBackground = false
        s.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        s.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.documentView = folderTableView
        return s
    }()

    private lazy var folderTableView: NSTableView = {
        let t = MenuTableView()
        t.identifier = Self.folderTableIdentifier
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        col.isEditable = false
        t.addTableColumn(col)
        t.headerView = nil
        t.rowHeight = menuRowHeight()
        t.backgroundColor = .clear
        t.intercellSpacing = menuIntercellSpacing()
        t.selectionHighlightStyle = .regular
        folderTableViewRef = t
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.action = #selector(folderTableViewClicked)
        t.doubleAction = #selector(folderTableViewDoubleClicked)
        t.hoverSelectionHandler = { [weak self] tableView in
            self?.suppressInitialTooltip = false
            self?.showSelectionTooltip(for: tableView)
        }
        return t
    }()

    // MARK: - State

    private enum SearchRow {
        case folder(String, Range<Int>)
        case clip(CPYClip, listNumber: Int?)
        case snippetFolder(CPYFolder, [CPYSnippet])
        case snippet(CPYSnippet, listNumber: Int?)
    }

    private enum ActiveList {
        case main
        case folder
    }

    private enum PanelMode {
        case history
        case snippet
    }

    private enum FolderPanelSide {
        case left
        case right
    }

    private var allClips: [CPYClip] = []
    private var visibleClips: [CPYClip] = []
    private var filteredRows: [SearchRow] = []
    private var folderClips: [CPYClip] = []
    private var folderSnippets: [CPYSnippet] = []
    private var activeList: ActiveList = .main
    private var panelMode: PanelMode = .history
    private var folderPanelSide: FolderPanelSide = .right
    private weak var mainTableViewRef: NSTableView?
    private weak var folderTableViewRef: NSTableView?
    private var suppressSelectionSideEffects = false
    private var suppressInitialTooltip = false
    private var realm = try! Realm()
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var resignKeyObserver: Any?
    private var searchObserver: Any?
    private var searchDebounceWorkItem: DispatchWorkItem?
    // Continuously tracked so we always know where to paste even if frontmostApplication
    // returns nil at the moment the hotkey fires.
    private var lastActiveApp: NSRunningApplication?
    private var workspaceObserver: Any?
    private var scrollTopToSeparatorConstraint: NSLayoutConstraint?
    private var scrollTopToContainerConstraint: NSLayoutConstraint?
    private var scrollBottomConstraint: NSLayoutConstraint?
    private var searchTopConstraint: NSLayoutConstraint?
    private var searchHeightConstraint: NSLayoutConstraint?
    private var separatorTopConstraint: NSLayoutConstraint?
    private var separatorHeightConstraint: NSLayoutConstraint?
    private var folderTopConstraint: NSLayoutConstraint?
    private var folderBottomConstraint: NSLayoutConstraint?
    private var didSetupMainLayout = false
    private var didSetupFolderLayout = false

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
        guard !didSetupMainLayout else { return }
        didSetupMainLayout = true

        containerView.addSubview(searchField)
        containerView.addSubview(separatorLine)
        containerView.addSubview(scrollView)

        scrollTopToSeparatorConstraint = scrollView.topAnchor.constraint(equalTo: separatorLine.bottomAnchor, constant: 2)
        scrollTopToContainerConstraint = scrollView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 2)
        scrollBottomConstraint = scrollView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -2)
        searchTopConstraint = searchField.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10)
        searchHeightConstraint = searchField.heightAnchor.constraint(equalToConstant: 22)
        separatorTopConstraint = separatorLine.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6)
        separatorHeightConstraint = separatorLine.heightAnchor.constraint(equalToConstant: 1)

        NSLayoutConstraint.activate([
            searchTopConstraint!,
            searchField.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -10),
            searchHeightConstraint!,

            separatorTopConstraint!,
            separatorLine.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            separatorLine.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            separatorHeightConstraint!,

            scrollTopToSeparatorConstraint!,
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            scrollBottomConstraint!
        ])
    }

    private func setupFolderLayout() {
        guard !didSetupFolderLayout else { return }
        didSetupFolderLayout = true

        folderContainerView.addSubview(folderScrollView)
        folderTopConstraint = folderScrollView.topAnchor.constraint(equalTo: folderContainerView.topAnchor, constant: Self.folderTopInset)
        folderBottomConstraint = folderScrollView.bottomAnchor.constraint(equalTo: folderContainerView.bottomAnchor, constant: -Self.folderBottomInset)

        NSLayoutConstraint.activate([
            folderTopConstraint!,
            folderScrollView.leadingAnchor.constraint(equalTo: folderContainerView.leadingAnchor),
            folderScrollView.trailingAnchor.constraint(equalTo: folderContainerView.trailingAnchor),
            folderBottomConstraint!
        ])
    }

    // MARK: - Show / Hide

    func show(at screenPoint: NSPoint) {
        rememberFrontmostApp()
        CPYUtilities.registerUserDefaultKeys()
        panelMode = .history
        setupLayout()
        setupFolderLayout()
        applyPanelModeLayout()
        updateTableMetrics()
        loadClips()
        suppressInitialTooltip = true
        applyFilter("")

        resizePanel()
        positionPanel(near: screenPoint)

        // Activate Clipy so the panel can become key and IME works correctly.
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(searchField)
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.panel.isVisible else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.orderFrontRegardless()
            self.panel.makeKeyAndOrderFront(nil)
            self.panel.makeFirstResponder(self.searchField)
        }

        removeEventMonitors()
        removeSearchObserver()
        installEventMonitors()
        installSearchObserver()
    }

    func showSnippets(at screenPoint: NSPoint) {
        rememberFrontmostApp()
        CPYUtilities.registerUserDefaultKeys()
        panelMode = .snippet
        setupLayout()
        setupFolderLayout()
        applyPanelModeLayout()
        updateTableMetrics()
        suppressInitialTooltip = true
        loadSnippetRows()

        resizePanel()
        positionPanel(near: screenPoint)

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tableView)
        showFolderIfNeeded(at: tableView.selectedRow)

        removeEventMonitors()
        removeSearchObserver()
        installEventMonitors()
    }

    func showSnippetFolder(_ folder: CPYFolder, at screenPoint: NSPoint) {
        rememberFrontmostApp()
        CPYUtilities.registerUserDefaultKeys()
        panelMode = .snippet
        setupLayout()
        setupFolderLayout()
        applyPanelModeLayout()
        updateTableMetrics()
        suppressInitialTooltip = true
        filteredRows = enabledSnippets(in: folder).enumerated().map { .snippet($0.element, listNumber: $0.offset + 1) }
        folderPanel.orderOut(nil)
        tableView.reloadData()
        invalidateRowHeights(tableView)
        if !filteredRows.isEmpty {
            select(row: 0, showTooltip: false)
        }

        resizePanel()
        positionPanel(near: screenPoint)

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(tableView)

        removeEventMonitors()
        removeSearchObserver()
        installEventMonitors()
    }

    func close(restoreFocus: Bool = true) {
        removeEventMonitors()
        removeSearchObserver()
        hideSelectionTooltip()
        folderPanel.orderOut(nil)
        panel.orderOut(nil)
        searchField.stringValue = ""
        if restoreFocus {
            lastActiveApp?.activate(options: [])
        }
    }

    private func applyPanelModeLayout() {
        let isHistory = panelMode == .history
        searchField.isHidden = !isHistory
        separatorLine.isHidden = !isHistory
        searchTopConstraint?.constant = isHistory ? 10 : 0
        searchHeightConstraint?.constant = isHistory ? 22 : 0
        separatorTopConstraint?.constant = isHistory ? 6 : 0
        separatorHeightConstraint?.constant = isHistory ? 1 : 0
        scrollTopToContainerConstraint?.constant = isHistory ? 2 : Self.snippetTopInset
        scrollBottomConstraint?.constant = isHistory ? -2 : -Self.snippetBottomInset
        scrollTopToSeparatorConstraint?.constant = isHistory ? 2 : 0
        scrollTopToSeparatorConstraint?.isActive = false
        scrollTopToContainerConstraint?.isActive = false
        scrollTopToSeparatorConstraint?.isActive = isHistory
        scrollTopToContainerConstraint?.isActive = !isHistory
        containerView.layoutSubtreeIfNeeded()
    }

    // MARK: - Data

    private func loadClips() {
        realm.refresh()
        let maxHistory = integerPreference(Preferences.General.maxHistorySize, fallback: 100)
        let ascending = !AppEnvironment.current.defaults.bool(forKey: Preferences.General.reorderClipsAfterPasting)
        let results = realm
            .objects(CPYClip.self)
            .sorted(byKeyPath: #keyPath(CPYClip.updateTime), ascending: ascending)
        let limit = maxHistory > 0 ? min(maxHistory, results.count) : results.count
        allClips = Array(results[0..<limit])
    }

    private func applyFilter(_ query: String) {
        rebuildMainTable(query: query, closeFolderPanel: true)
    }

    private func rebuildMainTable(query: String, closeFolderPanel: Bool) {
        let maxShowHistory = integerPreference(Preferences.General.maxShowHistorySize, fallback: 25)
        let limit = maxShowHistory > 0 ? maxShowHistory : allClips.count
        let matches = query.isEmpty ? allClips : allClips.filter {
            $0.title.localizedStandardContains(query) ||
            clipListTitle($0).localizedStandardContains(query)
        }
        let clips = Array(matches.prefix(limit))
        visibleClips = clips
        if closeFolderPanel {
            folderPanel.orderOut(nil)
            activeList = .main
        }
        filteredRows = query.isEmpty ? menuRows(from: visibleClips) : visibleClips.map { .clip($0, listNumber: nil) }
        if !closeFolderPanel { suppressSelectionSideEffects = true }
        tableView.reloadData()
        invalidateRowHeights(tableView)
        if let firstRow = nextSelectableRow(from: -1) {
            select(row: firstRow, showTooltip: false)
        }
        if !closeFolderPanel { suppressSelectionSideEffects = false }
        resizePanel()
    }

    private func menuRows(from clips: [CPYClip]) -> [SearchRow] {
        let inlineCount = max(integerPreference(Preferences.Menu.numberOfItemsPlaceInline, fallback: 10), 0)
        let folderCount = max(integerPreference(Preferences.Menu.numberOfItemsPlaceInsideFolder, fallback: 15), 1)
        let firstFolderIndex = min(inlineCount, clips.count)
        var rows: [SearchRow] = clips[0..<firstFolderIndex].enumerated().map { obj in
            .clip(obj.element, listNumber: obj.offset + 1)
        }

        var begin = firstFolderIndex
        while begin < clips.count {
            let end = min(begin + folderCount, clips.count)
            rows.append(.folder("\(begin + 1) - \(end)", begin..<end))
            begin = end
        }
        return rows
    }

    private func loadSnippetRows() {
        realm.refresh()
        let folders = realm.objects(CPYFolder.self).sorted(byKeyPath: #keyPath(CPYFolder.index), ascending: true)
        filteredRows = folders
            .filter { $0.enable }
            .map { folder in .snippetFolder(folder, enabledSnippets(in: folder)) }
        folderPanel.orderOut(nil)
        suppressSelectionSideEffects = true
        activeList = .main
        tableView.reloadData()
        invalidateRowHeights(tableView)
        if !filteredRows.isEmpty {
            select(row: 0, showTooltip: false)
        }
        suppressSelectionSideEffects = false
    }

    private func enabledSnippets(in folder: CPYFolder) -> [CPYSnippet] {
        Array(folder.snippets
            .sorted(byKeyPath: #keyPath(CPYSnippet.index), ascending: true)
            .filter { $0.enable })
    }

    private func showFolder(_ range: Range<Int>, from row: Int, activate: Bool = false) {
        guard range.lowerBound >= 0, range.upperBound <= visibleClips.count else { return }
        folderClips = Array(visibleClips[range])
        folderSnippets = []
        showFolderPanel(from: row, activate: activate)
    }

    private func showSnippetFolder(_ snippets: [CPYSnippet], from row: Int, activate: Bool = false) {
        folderClips = []
        folderSnippets = snippets
        showFolderPanel(from: row, activate: activate)
    }

    private func showFolderPanel(from row: Int, activate: Bool) {
        folderTableView.reloadData()
        invalidateRowHeights(folderTableView)
        if activate, folderTableView.numberOfRows > 0 {
            folderTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            folderTableView.scrollRowToVisible(0)
        } else {
            folderTableView.deselectAll(nil)
        }
        resizeFolderPanel(anchorRow: row)
        layoutTableDocumentView(folderTableView)
        folderPanel.orderFront(nil)
        folderPanel.invalidateShadow()
        if activate {
            activeList = .folder
        }
    }

    // MARK: - Panel Geometry

    private func panelWidth() -> CGFloat {
        let itemWidth = CGFloat(integerPreference(Preferences.General.maxWidthOfMenuItem, fallback: 260))
        return max(260, itemWidth) + 48  // text area + scrollbar + side padding
    }

    private func menuFontSize() -> CGFloat {
        let fontSize = CGFloat(AppEnvironment.current.defaults.float(forKey: Preferences.General.menuFontSize))
        return fontSize > 0 ? fontSize : 14
    }

    private func menuRowHeight() -> CGFloat {
        let fontSize = menuFontSize()
        let regularFont = NSFont.systemFont(ofSize: fontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: fontSize)
        let textHeight = max(
            regularFont.boundingRectForFont.height,
            boldFont.boundingRectForFont.height,
            regularFont.ascender - regularFont.descender + regularFont.leading,
            boldFont.ascender - boldFont.descender + boldFont.leading
        )
        return max(24, ceil(textHeight) + 8)
    }

    private func menuIntercellSpacing() -> NSSize {
        NSSize(width: 0, height: 0)
    }

    private func updateTableMetrics() {
        let rowHeight = menuRowHeight()
        let spacing = menuIntercellSpacing()
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = spacing
        folderTableView.rowHeight = rowHeight
        folderTableView.intercellSpacing = spacing
        invalidateRowHeights(tableView)
        invalidateRowHeights(folderTableView)
    }

    private func integerPreference(_ key: String, fallback: Int) -> Int {
        let defaults = AppEnvironment.current.defaults
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.integer(forKey: key)
    }

    private func menuDisplayTitle(_ title: String) -> String {
        title.replace(pattern: "\\s+", withTemplate: " ").trim
    }

    private func clipListTitle(_ clip: CPYClip) -> String {
        if clip.title.isEmpty && !clip.thumbnailPath.isEmpty { return NSLocalizedString("(Image)", comment: "") }
        if let url = URL(string: clip.title), url.scheme == "file" {
            return "📋" + url.lastPathComponent
        }
        return clip.title
    }

    private func resizePanel() {
        let maxHeight = maxMenuHeight(for: panel)
        let rowCount = min(filteredRows.count, maxMainRowCount(for: maxHeight))
        let listHeight = rowsHeightForRows(rowCount, tableView: tableView) + listBottomPadding(for: tableView)
        let chromeHeight: CGFloat = panelMode == .history
            ? Self.historyChromeHeight
            : Self.snippetVerticalInset
        let totalHeight = chromeHeight + listHeight
        let minHeight: CGFloat = panelMode == .history
            ? 60
            : chromeHeight + minimumRowHeight(tableView) + listBottomPadding(for: tableView)
        var frame = panel.frame
        let oldHeight = frame.size.height
        frame.size.width = panelWidth()
        frame.size.height = min(max(totalHeight, minHeight), maxHeight)
        frame.origin.y -= (frame.size.height - oldHeight)
        panel.setFrame(frame, display: true, animate: false)
        panel.invalidateShadow()
        layoutTableDocumentView(tableView)
    }

    private func resizeFolderPanel(anchorRow row: Int) {
        let maxHeight = maxMenuHeight(for: folderPanel)
        let rowCount = min(folderTableView.numberOfRows, maxFolderRowCount(for: maxHeight))
        let verticalInset = folderSnippets.isEmpty ? Self.folderVerticalPadding : Self.snippetVerticalInset
        let topInset = folderSnippets.isEmpty ? Self.folderTopInset : Self.snippetTopInset
        folderTopConstraint?.constant = folderSnippets.isEmpty ? Self.folderTopInset : Self.snippetTopInset
        folderBottomConstraint?.constant = folderSnippets.isEmpty ? -Self.folderBottomInset : -Self.snippetBottomInset
        folderContainerView.layoutSubtreeIfNeeded()
        folderTableView.layoutSubtreeIfNeeded()
        let rowsHeight = rowCount > 0
            ? rowsHeightForRows(rowCount, tableView: folderTableView)
            : minimumRowHeight(folderTableView)
        let listHeight = rowsHeight + verticalInset + listBottomPadding(for: folderTableView)
        var frame = folderPanel.frame
        frame.size.width = panelWidth()
        frame.size.height = min(max(listHeight, rowPitch(folderTableView) + verticalInset + listBottomPadding(for: folderTableView)), maxHeight)

        let rowRect = tableView.rect(ofRow: row)
        let rowWindowRect = tableView.convert(rowRect, to: nil)
        let rowScreenRect = panel.convertToScreen(rowWindowRect)

        frame.origin = NSPoint(
            x: panel.frame.maxX + 2,
            y: rowScreenRect.maxY + topInset - frame.height + 10
        )

        if let screen = panel.screen ?? NSScreen.main {
            if frame.maxX > screen.visibleFrame.maxX {
                frame.origin.x = panel.frame.minX - frame.width - 2
                folderPanelSide = .left
            } else {
                folderPanelSide = .right
            }
            if frame.minY < screen.visibleFrame.minY {
                frame.origin.y = screen.visibleFrame.minY
            }
            if frame.maxY > screen.visibleFrame.maxY {
                frame.origin.y = screen.visibleFrame.maxY - frame.height
            }
        }

        folderPanel.setFrame(frame, display: true, animate: false)
        folderPanel.invalidateShadow()
        if !folderSnippets.isEmpty {
            layoutTableDocumentView(folderTableView)
        }
    }

    private func layoutTableDocumentView(_ tableView: NSTableView) {
        guard let clipView = tableView.enclosingScrollView?.contentView else { return }
        tableView.enclosingScrollView?.superview?.layoutSubtreeIfNeeded()
        tableView.enclosingScrollView?.layoutSubtreeIfNeeded()
        clipView.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        var frame = tableView.frame
        frame.size.width = clipView.bounds.width
        frame.size.height = rowsHeightForRows(tableView.numberOfRows, tableView: tableView) + listBottomPadding(for: tableView)
        frame.origin = .zero
        tableView.frame = frame
        clipView.scroll(to: .zero)
        tableView.enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    private func maxMenuHeight(for window: NSWindow) -> CGFloat {
        let visibleHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 600
        return max(60, visibleHeight - 16)
    }

    private func maxMainRowCount(for maxHeight: CGFloat) -> Int {
        let nonRowHeight: CGFloat = panelMode == .history
            ? Self.historyChromeHeight
            : Self.snippetVerticalInset + Self.snippetListBottomPadding
        return max(1, Int((maxHeight - nonRowHeight) / rowPitch(tableView)))
    }

    private func maxFolderRowCount(for maxHeight: CGFloat) -> Int {
        let verticalInset = folderSnippets.isEmpty ? Self.folderVerticalPadding : Self.snippetVerticalInset
        let nonRowHeight = verticalInset + listBottomPadding(for: folderTableView)
        return max(1, Int((maxHeight - nonRowHeight) / rowPitch(folderTableView)))
    }

    private func listBottomPadding(for tableView: NSTableView) -> CGFloat {
        if tableView.identifier == Self.mainTableIdentifier, panelMode == .snippet {
            return Self.snippetListBottomPadding
        }
        if tableView.identifier == Self.folderTableIdentifier {
            return Self.submenuListBottomPadding
        }
        return 0
    }

    private func invalidateRowHeights(_ tableView: NSTableView) {
        guard tableView.numberOfRows > 0 else { return }
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<tableView.numberOfRows))
    }

    private func rowsHeightForRows(_ rowCount: Int, tableView: NSTableView) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        let lastRow = min(rowCount, tableView.numberOfRows) - 1
        guard lastRow >= 0 else { return 0 }
        tableView.layoutSubtreeIfNeeded()
        let lastRowRect = tableView.rect(ofRow: lastRow)
        // 先頭行の上端マージン (rect(ofRow: 0).minY) を下端にも足して、上下対称の余白を確保。
        let symmetricBottomPadding = tableView.rect(ofRow: 0).minY
        return ceilToBackingPixel(lastRowRect.maxY + symmetricBottomPadding, in: tableView)
    }

    private func rowPitch(_ tableView: NSTableView) -> CGFloat {
        tableView.rowHeight + tableView.intercellSpacing.height
    }

    private func minimumRowHeight(_ tableView: NSTableView) -> CGFloat {
        ceilToBackingPixel(rowPitch(tableView), in: tableView)
    }

    private func ceilToBackingPixel(_ value: CGFloat, in view: NSView) -> CGFloat {
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        return ceil(value * scale) / scale
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
        guard row >= 0, row < filteredRows.count else { return }

        switch filteredRows[row] {
        case let .folder(_, range):
            showFolder(range, from: row, activate: true)
        case let .clip(clip, _):
            let capturedFlags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            if AppEnvironment.current.pasteService.isDeleteOnlyAction(flags: capturedFlags) {
                guard !clip.isInvalidated else { return }
                AppEnvironment.current.clipService.delete(with: clip)
                loadClips()
                applyFilter(searchField.stringValue)
            } else {
                let targetApp = lastActiveApp
                close(restoreFocus: false)
                pasteToApp(targetApp, clip: clip)
            }
        case let .snippetFolder(_, snippets):
            showSnippetFolder(snippets, from: row, activate: true)
        case let .snippet(snippet, _):
            let targetApp = lastActiveApp
            close(restoreFocus: false)
            pasteSnippetToApp(targetApp, snippet: snippet)
        }
    }

    private func clip(at row: Int) -> CPYClip? {
        guard row >= 0, row < filteredRows.count else { return nil }
        guard case let .clip(clip, _) = filteredRows[row] else { return nil }
        return clip
    }

    private func snippet(at row: Int) -> CPYSnippet? {
        guard row >= 0, row < filteredRows.count else { return nil }
        guard case let .snippet(snippet, _) = filteredRows[row] else { return nil }
        return snippet
    }

    private func pasteToApp(_ targetApp: NSRunningApplication?, clip: CPYClip) {
        guard !clip.isInvalidated else { return }
        // Capture modifier flags synchronously here; NSApp.currentEvent becomes stale
        // after the target app activates (activation event overwrites currentEvent).
        let capturedFlags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags

        guard let targetApp = targetApp else {
            AppEnvironment.current.pasteService.paste(with: clip, capturedFlags: capturedFlags)
            return
        }

        var token: Any?
        var fired = false

        let paste = {
            guard !fired else { return }
            fired = true
            if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t); token = nil }
            AppEnvironment.current.pasteService.paste(with: clip, capturedFlags: capturedFlags)
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

    private func pasteSnippetToApp(_ targetApp: NSRunningApplication?, snippet: CPYSnippet) {
        guard !snippet.isInvalidated else { return }

        let paste = {
            AppEnvironment.current.pasteService.copyToPasteboard(with: snippet.content)
            AppEnvironment.current.pasteService.paste()
        }

        guard let targetApp = targetApp else {
            paste()
            return
        }

        var token: Any?
        var fired = false
        let pasteOnce = {
            guard !fired else { return }
            fired = true
            if let t = token { NSWorkspace.shared.notificationCenter.removeObserver(t); token = nil }
            paste()
        }

        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard activated?.processIdentifier == targetApp.processIdentifier else { return }
            pasteOnce()
        }

        targetApp.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { pasteOnce() }
    }

    @objc private func tableViewClicked() {
        selectClickedRow(in: tableView)
        selectCurrentItem()
    }

    @objc private func tableViewDoubleClicked() {
        selectClickedRow(in: tableView)
        selectCurrentItem()
    }

    @objc private func folderTableViewClicked() {
        selectClickedRow(in: folderTableView)
        selectCurrentFolderItem()
    }

    @objc private func folderTableViewDoubleClicked() {
        selectClickedRow(in: folderTableView)
        selectCurrentFolderItem()
    }

    // MARK: - Event Monitors

    private func installEventMonitors() {
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            let mouseLocation = NSEvent.mouseLocation
            guard !self.panel.frame.contains(mouseLocation),
                  !self.folderPanel.frame.contains(mouseLocation) else { return }
            let frontmostApp = NSWorkspace.shared.frontmostApplication
            let isClipyFrontmost = frontmostApp?.bundleIdentifier == Bundle.main.bundleIdentifier
            self.close(restoreFocus: !isClipyFrontmost)
        }
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyDown(event)
        }
        // Fallback: close when the panel loses key status (e.g. Dock click, system UI, or
        // any case the global mouse monitor misses).
        resignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.close()
        }
    }

    private func removeEventMonitors() {
        if let m = globalEventMonitor { NSEvent.removeMonitor(m); globalEventMonitor = nil }
        if let m = localEventMonitor { NSEvent.removeMonitor(m); localEventMonitor = nil }
        if let o = resignKeyObserver { NotificationCenter.default.removeObserver(o); resignKeyObserver = nil }
    }

    private func installSearchObserver() {
        searchObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidChangeNotification,
            object: searchField,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            // 高速タイプ中は textDidChange が連続発火する。毎打鍵で applyFilter →
            // tableView.reloadData() を回すと体感が重くなるので 120ms debounce で間引く。
            self.searchDebounceWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.applyFilter(self.searchField.stringValue)
            }
            self.searchDebounceWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
        }
    }

    private func removeSearchObserver() {
        searchDebounceWorkItem?.cancel()
        searchDebounceWorkItem = nil
        if let o = searchObserver { NotificationCenter.default.removeObserver(o); searchObserver = nil }
    }

    private func selectClickedRow(in tableView: NSTableView) {
        guard let window = tableView.window else { return }
        let windowPoint = window.mouseLocationOutsideOfEventStream
        let tablePoint = tableView.convert(windowPoint, from: nil)
        let row = tableView.row(at: tablePoint)
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    private func rememberFrontmostApp() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastActiveApp = front
    }

    private func hasMarkedText() -> Bool {
        guard panelMode == .history else { return false }
        guard let editor = searchField.currentEditor() as? NSTextView else { return false }
        return editor.markedRange().length > 0
    }

    private var isEditingSearchText: Bool {
        searchField.currentEditor() != nil
    }

    private func select(row: Int, showTooltip: Bool = true) {
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        if showTooltip {
            showSelectionTooltip(for: tableView)
        }
    }

    private func nextSelectableRow(from row: Int) -> Int? {
        let next = row + 1
        return next < filteredRows.count ? next : nil
    }

    private func previousSelectableRow(from row: Int) -> Int? {
        let prev = row - 1
        return prev >= 0 ? prev : nil
    }

    private func selectFolder(row: Int) {
        folderTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        folderTableView.scrollRowToVisible(row)
        showSelectionTooltip(for: folderTableView)
    }

    private func nextFolderRow(from row: Int) -> Int? {
        let next = row + 1
        return next < folderTableView.numberOfRows ? next : nil
    }

    private func previousFolderRow(from row: Int) -> Int? {
        let prev = row - 1
        return prev >= 0 && folderTableView.numberOfRows > 0 ? prev : nil
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        switch event.keyCode {
        case 53: // Escape
            close()
            return nil
        case 36, 76: // Return, numpad Enter
            guard !hasMarkedText() else { return event }
            if activeList == .folder, folderPanel.isVisible {
                selectCurrentFolderItem()
            } else {
                selectCurrentItem()
            }
            return nil
        case 123: // Left arrow
            if activeList == .folder, folderPanelSide == .right {
                activeList = .main
                folderPanel.orderOut(nil)
                hideSelectionTooltip()
                return nil
            }
            if activeList == .main, folderPanelSide == .left {
                return activateSelectedFolder() ? nil : event
            }
            return event
        case 124: // Right arrow
            guard !hasMarkedText() else { return event }
            if activeList == .folder, folderPanelSide == .left {
                activeList = .main
                folderPanel.orderOut(nil)
                hideSelectionTooltip()
                return nil
            }
            if activeList == .main, folderPanelSide == .right {
                return activateSelectedFolder() ? nil : event
            }
            return event
        case 125: // Down arrow — pass through while IME candidate list is active
            if hasMarkedText() { return event }
            suppressInitialTooltip = false
            if activeList == .folder, folderPanel.isVisible {
                guard let next = nextFolderRow(from: folderTableView.selectedRow) else { return nil }
                selectFolder(row: next)
                return nil
            }
            guard let next = nextSelectableRow(from: tableView.selectedRow) else { return nil }
            activeList = .main
            select(row: next)
            showFolderIfNeeded(at: next)
            return nil
        case 126: // Up arrow — pass through while IME candidate list is active
            if hasMarkedText() { return event }
            suppressInitialTooltip = false
            if activeList == .folder, folderPanel.isVisible {
                guard let prev = previousFolderRow(from: folderTableView.selectedRow) else { return nil }
                selectFolder(row: prev)
                return nil
            }
            guard let prev = previousSelectableRow(from: tableView.selectedRow) else { return nil }
            activeList = .main
            select(row: prev)
            showFolderIfNeeded(at: prev)
            return nil
        default:
            // Number key quick-select: only when search is empty and IME is idle
            guard panelMode == .history,
                  searchField.stringValue.isEmpty,
                  !hasMarkedText(),
                  AppEnvironment.current.defaults.bool(forKey: Preferences.Menu.addNumericKeyEquivalents),
                  let chars = event.characters, chars.count == 1,
                  let digit = chars.first, digit.isNumber else { return event }
            let listNumber = digit == "0" ? 10 : Int(String(digit))!
            guard let row = filteredRows.firstIndex(where: {
                guard case let .clip(_, number) = $0 else { return false }
                return number == listNumber
            }) else { return event }
            select(row: row)
            selectCurrentItem()
            return nil
        }
    }

    private func showFolderIfNeeded(at row: Int) {
        guard row >= 0, row < filteredRows.count else { return }
        switch filteredRows[row] {
        case let .folder(_, range):
            hideSelectionTooltip()
            showFolder(range, from: row)
        case let .snippetFolder(_, snippets):
            hideSelectionTooltip()
            showSnippetFolder(snippets, from: row)
        default:
            folderPanel.orderOut(nil)
            activeList = .main
            showSelectionTooltip(for: tableView)
        }
    }

    private func activateSelectedFolder() -> Bool {
        guard tableView.selectedRow >= 0,
              tableView.selectedRow < filteredRows.count else { return false }
        switch filteredRows[tableView.selectedRow] {
        case let .folder(_, range):
            showFolder(range, from: tableView.selectedRow, activate: true)
            return true
        case let .snippetFolder(_, snippets):
            showSnippetFolder(snippets, from: tableView.selectedRow, activate: true)
            return true
        default:
            return false
        }
    }

    private func selectCurrentFolderItem() {
        let row = folderTableView.selectedRow
        let targetApp = lastActiveApp
        if row >= 0, row < folderClips.count {
            let clip = folderClips[row]
            let capturedFlags = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
            if AppEnvironment.current.pasteService.isDeleteOnlyAction(flags: capturedFlags) {
                guard !clip.isInvalidated else { return }
                AppEnvironment.current.clipService.delete(with: clip)
                folderClips.remove(at: row)
                if folderClips.isEmpty {
                    folderPanel.orderOut(nil)
                    activeList = .main
                    loadClips()
                    applyFilter(searchField.stringValue)
                } else {
                    let anchorMainRow = tableView.selectedRow
                    loadClips()
                    rebuildMainTable(query: searchField.stringValue, closeFolderPanel: false)
                    // Refresh folderClips from the updated visibleClips for the same group
                    if anchorMainRow >= 0, anchorMainRow < filteredRows.count,
                       case let .folder(_, newRange) = filteredRows[anchorMainRow],
                       newRange.upperBound <= visibleClips.count {
                        suppressSelectionSideEffects = true
                        tableView.selectRowIndexes(IndexSet(integer: anchorMainRow), byExtendingSelection: false)
                        suppressSelectionSideEffects = false
                        folderClips = Array(visibleClips[newRange])
                    }
                    folderTableView.reloadData()
                    invalidateRowHeights(folderTableView)
                    resizeFolderPanel(anchorRow: anchorMainRow)
                    layoutTableDocumentView(folderTableView)
                    let nextRow = min(row, folderClips.count - 1)
                    if nextRow >= 0 {
                        folderTableView.selectRowIndexes(IndexSet(integer: nextRow), byExtendingSelection: false)
                    }
                }
            } else {
                close(restoreFocus: false)
                pasteToApp(targetApp, clip: clip)
            }
        } else if row >= 0, row < folderSnippets.count {
            let snippet = folderSnippets[row]
            close(restoreFocus: false)
            pasteSnippetToApp(targetApp, snippet: snippet)
        }
    }

    private func hideSelectionTooltip() {
        tooltipPanel.orderOut(nil)
    }

    private func tooltipTitle(for tableView: NSTableView, row: Int) -> String? {
        if tableView.identifier == Self.folderTableIdentifier {
            if row >= 0, row < folderClips.count {
                let clip = folderClips[row]
                if clip.title.isEmpty && !clip.thumbnailPath.isEmpty { return NSLocalizedString("(Image)", comment: "") }
                return tooltipDisplayTitle(clipListTitle(clip))
            }
            guard row >= 0, row < folderSnippets.count else { return nil }
            return tooltipDisplayTitle(folderSnippets[row].content)
        }

        guard row >= 0, row < filteredRows.count else { return nil }
        switch filteredRows[row] {
        case let .clip(clip, _):
            if clip.title.isEmpty && !clip.thumbnailPath.isEmpty { return NSLocalizedString("(Image)", comment: "") }
            return tooltipDisplayTitle(clipListTitle(clip))
        case let .snippet(snippet, _):
            return tooltipDisplayTitle(snippet.content)
        default:
            return nil
        }
    }

    private func tooltipDisplayTitle(_ title: String) -> String {
        title
            .replace(pattern: "\\r\\n?", withTemplate: "\n")
            .replace(pattern: "[\\t ]+", withTemplate: " ")
            .trim
    }

    private func showSelectionTooltip(for tableView: NSTableView) {
        let row = tableView.selectedRow
        if suppressInitialTooltip {
            hideSelectionTooltip()
            return
        }
        guard AppEnvironment.current.defaults.bool(forKey: Preferences.Menu.showToolTipOnMenuItem) else {
            hideSelectionTooltip()
            return
        }
        _ = tooltipContentStack

        let clip = tooltipClip(for: tableView, row: row)
        let defaults = AppEnvironment.current.defaults
        let isColor = clip?.isColorCode == true &&
                      defaults.bool(forKey: Preferences.Menu.showColorPreviewInTheMenu)
        let isFileURL = clip?.primaryType == NSPasteboard.PasteboardType.fileURL.rawValue
        let hasImage = !isFileURL &&
                       clip?.isColorCode == false &&
                       clip?.thumbnailPath.isNotEmpty == true &&
                       defaults.bool(forKey: Preferences.Menu.showImageInTheMenu)

        tooltipImageView.isHidden = !hasImage
        tooltipColorSwatch.isHidden = !isColor
        tooltipLabel.isHidden = hasImage

        prepareTooltipAnchor(in: tableView, row: row)

        if hasImage, let thumbnailPath = clip?.thumbnailPath {
            if let cached = PINCache.shared.memoryCache.object(forKey: thumbnailPath) as? NSImage {
                tooltipImageView.image = cached
                let maxDim: CGFloat = 200
                let natural = cached.size
                let scale = min(maxDim / natural.width, maxDim / natural.height, 1.0)
                let displayW = max(ceil(natural.width * scale), 40)
                let displayH = max(ceil(natural.height * scale), 40)
                tooltipImageWidthConstraint?.constant = displayW
                tooltipImageHeightConstraint?.constant = displayH
                positionAndShowTooltip(tableView: tableView, row: row,
                                       size: NSSize(width: displayW + 16, height: displayH + 8))
                return
            }
            // Not in memory cache yet — kick off async load and fall through to text fallback.
            // Next hover will show the image once cached.
            loadTooltipImage(thumbnailPath: thumbnailPath)
            tooltipImageView.isHidden = true
        }

        if isColor, let title = clip?.title,
           let hex = title.firstMatch(pattern: "^(?:0x|#)?([0-9a-fA-F]{6,8})$"),
           let color = NSColor(hexString: hex) {
            tooltipColorSwatch.layer?.backgroundColor = color.cgColor
        }

        guard let title = tooltipTitle(for: tableView, row: row), !title.isEmpty else {
            hideSelectionTooltip()
            return
        }
        let maxLength = integerPreference(Preferences.Menu.maxLengthOfToolTip, fallback: 100)
        let titleNSString = title as NSString
        let clippedTitle = titleNSString.substring(to: min(titleNSString.length, maxLength))
        tooltipLabel.stringValue = clippedTitle
        tooltipLabel.font = NSFont.systemFont(ofSize: 13)
        tooltipLabel.textColor = tooltipContainerView.textColor()

        let font = tooltipLabel.font ?? NSFont.systemFont(ofSize: 13)
        let swatchExtra: CGFloat = isColor ? (14 + 6) : 0
        let textRect = (clippedTitle as NSString).boundingRect(
            with: NSSize(width: 406 - swatchExtra, height: 120),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let width = min(max(ceil(textRect.width) + swatchExtra + 16, 32), 422)
        let height = min(max(ceil(textRect.height) + 8, 22), 128)
        positionAndShowTooltip(tableView: tableView, row: row, size: NSSize(width: width, height: height))
    }

    private func positionAndShowTooltip(tableView: NSTableView, row: Int, size: NSSize) {
        var frame = tooltipPanel.frame
        frame.size = size
        let rowRect = tableView.rect(ofRow: row)
        let rowWindowRect = tableView.convert(rowRect, to: nil)
        let rowScreenRect = tableView.window?.convertToScreen(rowWindowRect) ?? .zero
        frame.origin = NSPoint(x: rowScreenRect.maxX + 6,
                               y: rowScreenRect.maxY - frame.height - 1)
        if let screen = tableView.window?.screen ?? NSScreen.main {
            if frame.maxX > screen.visibleFrame.maxX { frame.origin.x = rowScreenRect.minX - frame.width - 6 }
            if frame.minY < screen.visibleFrame.minY { frame.origin.y = screen.visibleFrame.minY }
            if frame.maxY > screen.visibleFrame.maxY { frame.origin.y = screen.visibleFrame.maxY - frame.height }
        }
        tooltipPanel.setFrame(frame, display: true, animate: false)
        tooltipPanel.orderFrontRegardless()
    }

    private func tooltipClip(for tableView: NSTableView, row: Int) -> CPYClip? {
        if tableView === folderTableView {
            guard row >= 0, row < folderClips.count else { return nil }
            return folderClips[row]
        }
        guard row >= 0, row < filteredRows.count else { return nil }
        guard case let .clip(clip, _) = filteredRows[row] else { return nil }
        return clip
    }

    private func loadTooltipImage(thumbnailPath: String) {
        tooltipImageView.image = nil
        if let cached = PINCache.shared.memoryCache.object(forKey: thumbnailPath) as? NSImage {
            tooltipImageView.image = cached
            return
        }
        PINCache.shared.object(forKeyAsync: thumbnailPath) { [weak self] _, _, object in
            guard let self, let image = object as? NSImage else { return }
            DispatchQueue.main.async {
                guard self.tooltipPanel.isVisible else { return }
                self.tooltipImageView.image = image
            }
        }
    }

    private func prepareTooltipAnchor(in tableView: NSTableView, row: Int) {
        guard row >= 0, row < tableView.numberOfRows else { return }
        tableView.scrollRowToVisible(row)
        tableView.enclosingScrollView?.superview?.layoutSubtreeIfNeeded()
        tableView.enclosingScrollView?.layoutSubtreeIfNeeded()
        tableView.enclosingScrollView?.contentView.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()
        tableView.window?.layoutIfNeeded()
    }
}

// MARK: - NSSearchFieldDelegate

extension ClipSearchPanelController: NSSearchFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            guard !hasMarkedText() else { return false }
            if activeList == .folder, folderPanel.isVisible {
                selectCurrentFolderItem()
            } else {
                selectCurrentItem()
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }
}

// MARK: - ClipCellView

// Properly handles text color inversion on selection (Dark Mode / Light Mode compatible).
// NSTableView calls backgroundStyle automatically when selection changes.
private class ClipCellView: NSTableCellView {
    var plainTitle: String = ""
    var query: String = ""
    var listNumber: Int?
    var isGroupHeader = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyDisplay() }
    }

    func applyDisplay() {
        guard let tf = textField else { return }
        if isGroupHeader {
            tf.font = NSFont.boldSystemFont(ofSize: tf.font?.pointSize ?? NSFont.systemFontSize)
            tf.textColor = backgroundStyle == .emphasized ? .selectedMenuItemTextColor : .secondaryLabelColor
            tf.stringValue = plainTitle
            return
        }

        let prefix = numberPrefix()
        let display = prefix + plainTitle
        if backgroundStyle == .emphasized {
            tf.textColor = .selectedMenuItemTextColor
            tf.stringValue = display
        } else {
            tf.textColor = .labelColor
            if query.isEmpty {
                tf.stringValue = display
            } else {
                tf.attributedStringValue = highlighted(display, query: query, prefixLength: prefix.count)
            }
        }
    }

    private func numberPrefix() -> String {
        let defaults = AppEnvironment.current.defaults
        guard let listNumber = listNumber else { return "" }
        guard defaults.bool(forKey: Preferences.Menu.menuItemsAreMarkedWithNumbers),
              defaults.bool(forKey: Preferences.Menu.addNumericKeyEquivalents),
              listNumber <= 10 else { return "" }
        return listNumber == 10 ? "0. " : "\(listNumber). "
    }

    private func highlighted(_ text: String, query: String, prefixLength: Int) -> NSAttributedString {
        let font = textField?.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let base: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.labelColor, .font: font]
        let att = NSMutableAttributedString(string: text, attributes: base)
        // Only highlight within the title portion (skip prefix)
        let titlePart = String(text.dropFirst(prefixLength))
        guard let range = titlePart.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) else {
            return att
        }
        let offset = text.distance(from: text.startIndex, to: text.index(text.startIndex, offsetBy: prefixLength))
        let nsRange = NSRange(range, in: titlePart)
        att.addAttribute(.foregroundColor, value: NSColor.red,
                         range: NSRange(location: nsRange.location + offset, length: nsRange.length))
        return att
    }
}

// MARK: - NSTableViewDataSource / NSTableViewDelegate

extension ClipSearchPanelController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView.identifier == Self.folderTableIdentifier {
            return folderClips.isEmpty ? folderSnippets.count : folderClips.count
        }
        return filteredRows.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ClipRowView()
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("ClipCell")
        let cell: ClipCellView
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? ClipCellView {
            cell = reused
        } else {
            cell = ClipCellView()
            cell.identifier = id
            let tf = NSTextField()
            tf.cell = MenuItemTextFieldCell(textCell: "")
            tf.isBordered = false
            tf.drawsBackground = false
            tf.isEditable = false
            tf.lineBreakMode = .byTruncatingTail
            tf.cell?.usesSingleLineMode = true
            tf.cell?.wraps = false
            tf.cell?.isScrollable = true
            tf.maximumNumberOfLines = 1
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                tf.topAnchor.constraint(equalTo: cell.topAnchor),
                tf.bottomAnchor.constraint(equalTo: cell.bottomAnchor)
            ])
        }

        cell.textField?.font = NSFont.systemFont(ofSize: menuFontSize())

        if tableView.identifier == Self.folderTableIdentifier {
            let title: String
            if row < folderClips.count {
                let clip = folderClips[row]
                title = menuDisplayTitle(clipListTitle(clip))
            } else {
                title = menuDisplayTitle(folderSnippets[row].title)
            }
            cell.plainTitle = title
            cell.query = ""
            cell.listNumber = nil
            cell.isGroupHeader = false
            cell.toolTip = nil
            cell.textField?.toolTip = nil
            cell.applyDisplay()
            return cell
        }

        switch filteredRows[row] {
        case let .folder(title, _):
            cell.plainTitle = title
            cell.query = ""
            cell.listNumber = nil
            cell.isGroupHeader = true
            cell.toolTip = nil
            cell.textField?.toolTip = nil
        case let .snippetFolder(folder, _):
            cell.plainTitle = menuDisplayTitle(folder.title)
            cell.query = ""
            cell.listNumber = nil
            cell.isGroupHeader = true
            cell.toolTip = nil
            cell.textField?.toolTip = nil
        case let .clip(clip, listNumber):
            let title = menuDisplayTitle(clipListTitle(clip))
            cell.plainTitle = title
            cell.query = clip.title.isEmpty ? "" : searchField.stringValue
            cell.listNumber = listNumber
            cell.isGroupHeader = false
            cell.toolTip = nil
            cell.textField?.toolTip = nil
        case let .snippet(snippet, listNumber):
            let title = menuDisplayTitle(snippet.title)
            cell.plainTitle = title
            cell.query = ""
            cell.listNumber = listNumber
            cell.isGroupHeader = false
            cell.toolTip = nil
            cell.textField?.toolTip = nil
        }
        cell.applyDisplay()

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionSideEffects else { return }
        guard let changedTableView = notification.object as? NSTableView else { return }
        if changedTableView.identifier == Self.mainTableIdentifier {
            showFolderIfNeeded(at: changedTableView.selectedRow)
        } else if changedTableView.identifier == Self.folderTableIdentifier {
            showSelectionTooltip(for: changedTableView)
        }
    }

    func tableView(_ tableView: NSTableView,
                   toolTipFor cell: NSCell,
                   rect: NSRectPointer,
                   tableColumn: NSTableColumn?,
                   row: Int,
                   mouseLocation: NSPoint) -> String {
        ""
    }
}
