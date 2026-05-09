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
    // mouseMoved で行をまたいだ瞬間に同期で呼ばれる通知。
    // controller 側で「他テーブルのキーボード予約 (keyboardTooltipWorkItem)」をキャンセルする等、
    // ホバー操作に切り替わった瞬間に他経路の予約を即時無効化するために使う。
    var onHoverImmediate: ((MenuTableView) -> Void)?
    // mouseExited で同期発火。ホバー対象（テーブル）から離れた瞬間にツールチップを即消すために使う。
    var onMouseExited: ((MenuTableView) -> Void)?
    // 直前にホバーした行を覚え、同じ行への mouseMoved は完全スキップする。
    // mouseMoved は秒 60 回飛んでくるが、ツールチップ更新が要るのは「行をまたいだ時だけ」。
    private var lastHoverRow: Int = -1
    // 行をまたいだ後、マウスが止まって dwell ミリ秒経ったら handler を呼ぶ（ツールチップ表示）。
    // スクロール中・速い移動中はキャンセルされ続けるので、ツールチップ表示が走らない。
    private var hoverDwellWorkItem: DispatchWorkItem?
    static let initialHoverDwellMillis: Int = 1500
    // 一度ツールチップを表示した後は、パネルが閉じられるまで即時表示にしたい。
    // controller 側でこの値を 0 に書き換える。close/show 時に 1500 に戻す。
    var hoverDwellMillis: Int = MenuTableView.initialHoverDwellMillis
    // ホバー由来の selectRowIndexes か矢印キー由来かを区別するフラグ。
    // selectionDidChange 通知は同期発火なので、selectRowIndexes 前後で短時間 true にすれば良い。
    // controller 側の tableViewSelectionDidChange でこのフラグを読み、ホバー時はツールチップを抑制する。
    private(set) var isSelectionFromHover: Bool = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea = hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        // mouseExited も拾って、マウスがテーブルを離れた瞬間に hover dwell を取り消す。
        // folder パネルからメインに戻る等、外部から panel を閉じる前にマウスが離れる
        // 経路で「ぴょこっとツールチップ」が出るのを防ぐ。
        let options: NSTrackingArea.Options = [.activeAlways, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited]
        hoverTrackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(hoverTrackingArea!)
    }

    override func mouseExited(with event: NSEvent) {
        cancelHoverDwell()
        onMouseExited?(self)
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
        if row == lastHoverRow { return }
        lastHoverRow = row
        // ホバーに切り替わった瞬間 — controller 側で他テーブルや keyboard 経路の予約をキャンセル。
        onHoverImmediate?(self)
        // 青枠ハイライトはユーザー反応性のため即時。selectionDidChange は同期発火するので、
        // フラグを true にしてから selectRowIndexes、戻り次第 false に戻す。
        // controller 側の tableViewSelectionDidChange はこのフラグを見てホバー由来ならツールチップ表示をスキップする。
        isSelectionFromHover = true
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        isSelectionFromHover = false
        // dwell: マウスが止まったまま 250ms 経過したら handler を呼んでツールチップ表示。
        // スクロール・速い移動ではキャンセルされ続けるので発火しない。
        hoverDwellWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverSelectionHandler?(self)
        }
        hoverDwellWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(hoverDwellMillis), execute: work)
    }

    override func reloadData() {
        // 行構成が変わったら直前ホバー行は無効。次の mouseMoved で必ず handler が走るようリセット。
        lastHoverRow = -1
        hoverDwellWorkItem?.cancel()
        hoverDwellWorkItem = nil
        super.reloadData()
    }

    func cancelHoverDwell() {
        lastHoverRow = -1
        hoverDwellWorkItem?.cancel()
        hoverDwellWorkItem = nil
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

// 右クリックメニュー (NSMenu) と同じ選択ハイライト処理。
// NSVisualEffectView の `.selection` material は NSMenu が内部で使っているのと同じ処理で、
// アクセントカラーをアクセシビリティ設定・ライト/ダーク・透過設定に追従させて描画する。
private final class ClipRowView: NSTableRowView {
    private let selectionEffectView: NSVisualEffectView = {
        let v = NSVisualEffectView()
        v.material = .selection
        v.blendingMode = .behindWindow
        v.state = .active
        v.isEmphasized = true
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.cornerCurve = .continuous
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
        return v
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSelectionLayer()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSelectionLayer()
    }

    private func setupSelectionLayer() {
        addSubview(selectionEffectView, positioned: .below, relativeTo: nil)
        let inset: CGFloat = 8
        NSLayoutConstraint.activate([
            selectionEffectView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            selectionEffectView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            selectionEffectView.topAnchor.constraint(equalTo: topAnchor),
            selectionEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var isSelected: Bool {
        didSet { selectionEffectView.isHidden = !isSelected }
    }
    override var isEmphasized: Bool { get { true } set {} }
    // 既存の不透明塗りを潰して、vibrancy オーバーレイにハイライト描画を委ねる。
    override func drawSelection(in dirtyRect: NSRect) {}
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
            // フォルダ展開は tableViewSelectionDidChange 経路で既に済んでいる。dwell 後にやるのは
            // ツールチップ表示だけ。folder 行のときは showSelectionTooltip 内で title=nil 判定により
            // hideSelectionTooltip に分岐するので問題ない。
            self?.suppressInitialTooltip = false
            self?.showSelectionTooltip(for: tableView)
        }
        t.onHoverImmediate = { [weak self] _ in
            // main にホバーが移った瞬間 — 全 tooltip 経路 (keyboard 予約 / folder hover dwell /
            // 表示中の tooltip) を即時クリア。フォーカス変化即消しの原則。
            self?.keyboardTooltipWorkItem?.cancel()
            self?.keyboardTooltipWorkItem = nil
            (self?.folderTableView as? MenuTableView)?.cancelHoverDwell()
            self?.hideSelectionTooltip()
        }
        t.onMouseExited = { [weak self] _ in
            // main テーブルからマウスが離れた瞬間も即消し。
            self?.hideSelectionTooltip()
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
        // RTF の段落属性により text rect が cell より大きく出ると、デフォルト cell では
        // テキストが上寄せに描かれて下に空白ができる。縦中央寄せ cell に差し替えて常に中央表示にする。
        let centeredCell = MenuItemTextFieldCell(textCell: "")
        centeredCell.isBordered = false
        centeredCell.drawsBackground = false
        centeredCell.lineBreakMode = .byTruncatingTail
        centeredCell.usesSingleLineMode = false
        centeredCell.wraps = true
        centeredCell.isEditable = false
        centeredCell.isSelectable = false
        f.cell = centeredCell
        f.maximumNumberOfLines = 6
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
        t.onHoverImmediate = { [weak self] _ in
            // folder にホバーが移った瞬間も同様に全クリア。
            self?.keyboardTooltipWorkItem?.cancel()
            self?.keyboardTooltipWorkItem = nil
            (self?.tableView as? MenuTableView)?.cancelHoverDwell()
            self?.hideSelectionTooltip()
        }
        t.onMouseExited = { [weak self] _ in
            self?.hideSelectionTooltip()
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
    // 直前検索の結果を superset として再利用するためのキャッシュ。
    // クエリが前回の延長 (hasPrefix) なら全件 allClips でなく前回絞り込み済みから走査して O(n) を縮める。
    // 早期打ち切り (limit 到達) で truncate された場合は nil にして無効化する。
    private var lastSearchQuery: String = ""
    private var lastSearchFullMatches: [CPYClip]? = nil
    // 矢印キー / 番号キー連打時のツールチップを debounce する。連打中はキャンセルされ続けるので、
    // 止まってから 1 回だけ表示が走る。連打中の重い tooltip 描画を抑える狙い。
    private var keyboardTooltipWorkItem: DispatchWorkItem?
    private static let initialKeyboardTooltipDwellMillis: Int = 1500
    // パネル表示中に一度でもツールチップが出たら、以降は閉じられるまで即時表示する。
    // showSelectionTooltip が成功したタイミングで true にし、両テーブルの hoverDwellMillis も 0 に揃える。
    // close()/show* で false に戻し、1500 に戻す。
    private var tooltipShownOnceThisSession: Bool = false
    private func currentKeyboardTooltipDwellMillis() -> Int {
        tooltipShownOnceThisSession ? 0 : Self.initialKeyboardTooltipDwellMillis
    }
    private func setTooltipImmediateModeIfNeeded() {
        guard !tooltipShownOnceThisSession else { return }
        tooltipShownOnceThisSession = true
        (tableView as? MenuTableView)?.hoverDwellMillis = 0
        (folderTableView as? MenuTableView)?.hoverDwellMillis = 0
    }
    private func resetTooltipDwellMode() {
        tooltipShownOnceThisSession = false
        (tableView as? MenuTableView)?.hoverDwellMillis = MenuTableView.initialHoverDwellMillis
        (folderTableView as? MenuTableView)?.hoverDwellMillis = MenuTableView.initialHoverDwellMillis
    }
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
        resetTooltipDwellMode()
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
        resetTooltipDwellMode()
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
        resetTooltipDwellMode()
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
        // 予約中の dwell タイマーを全部キャンセル。閉じた後に発火して tooltip が再表示される事故を防ぐ。
        keyboardTooltipWorkItem?.cancel()
        keyboardTooltipWorkItem = nil
        (tableView as? MenuTableView)?.cancelHoverDwell()
        (folderTableView as? MenuTableView)?.cancelHoverDwell()
        hideSelectionTooltip()
        resetTooltipDwellMode()
        folderPanel.orderOut(nil)
        panel.orderOut(nil)
        searchField.stringValue = ""
        if restoreFocus {
            lastActiveApp?.activate(options: [])
        }
    }

    private var lastAppliedPanelMode: PanelMode? = nil

    private func applyPanelModeLayout() {
        // panelMode が前回と同じなら制約再設定 + layoutSubtreeIfNeeded を回さない。
        // history → history の連続 show で毎回走らせるのは無駄。
        if lastAppliedPanelMode == panelMode { return }
        lastAppliedPanelMode = panelMode
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
        // allClips が更新されたので superset キャッシュは古い参照を抱えている。無効化する。
        lastSearchQuery = ""
        lastSearchFullMatches = nil
    }

    private func applyFilter(_ query: String) {
        rebuildMainTable(query: query, closeFolderPanel: true)
    }

    private func rebuildMainTable(query: String, closeFolderPanel: Bool) {
        // 検索打鍵やデータ更新で行構成が変わるなら、現在表示中の tooltip も全予約も即無効。
        flushTooltipForFocusChange()
        let maxShowHistory = integerPreference(Preferences.General.maxShowHistorySize, fallback: 25)
        let limit = maxShowHistory > 0 ? maxShowHistory : allClips.count
        let clips: [CPYClip]
        if query.isEmpty {
            clips = Array(allClips.prefix(limit))
            lastSearchQuery = ""
            lastSearchFullMatches = nil
        } else {
            // superset 再利用: 直前クエリの延長なら前回絞り込み済み配列をベースに走査する。
            let baseClips: [CPYClip]
            if !lastSearchQuery.isEmpty,
               query.hasPrefix(lastSearchQuery),
               let cached = lastSearchFullMatches {
                baseClips = cached
            } else {
                baseClips = allClips
            }
            // limit 件埋まったら走査打ち切り。打ち切った場合は完全結果が手に入らないので superset キャッシュ無効化。
            var matched: [CPYClip] = []
            matched.reserveCapacity(limit)
            var truncated = false
            for clip in baseClips {
                if clip.title.localizedStandardContains(query) ||
                   clipListTitle(clip).localizedStandardContains(query) {
                    matched.append(clip)
                    if matched.count >= limit {
                        truncated = true
                        break
                    }
                }
            }
            clips = matched
            lastSearchQuery = query
            lastSearchFullMatches = truncated ? nil : matched
        }
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
        flushTooltipForFocusChange()
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
        flushTooltipForFocusChange()
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

    private var lastAppliedRowHeight: CGFloat = -1

    private func updateTableMetrics() {
        // フォントサイズ等のユーザー設定が変わっていない時は再代入をスキップ。
        // show() のたびに走らせていたが、rowHeight 不変ならコストの無駄。
        let rowHeight = menuRowHeight()
        if rowHeight == lastAppliedRowHeight { return }
        lastAppliedRowHeight = rowHeight
        let spacing = menuIntercellSpacing()
        tableView.rowHeight = rowHeight
        tableView.intercellSpacing = spacing
        folderTableView.rowHeight = rowHeight
        folderTableView.intercellSpacing = spacing
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
        // showTooltip フラグに関係なく、選択が動くなら旧 tooltip は無効。先に flush する。
        flushTooltipForFocusChange()
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
        if showTooltip {
            scheduleKeyboardTooltip(for: tableView)
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
        flushTooltipForFocusChange()
        folderTableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        folderTableView.scrollRowToVisible(row)
        scheduleKeyboardTooltip(for: folderTableView)
    }

    private func scheduleKeyboardTooltip(for tableView: NSTableView) {
        flushTooltipForFocusChange()
        let work = DispatchWorkItem { [weak self, weak tableView] in
            guard let self, let tableView else { return }
            self.showSelectionTooltip(for: tableView)
        }
        keyboardTooltipWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(currentKeyboardTooltipDwellMillis()), execute: work)
    }

    /// 選択行・テーブル・パネルなど「フォーカス対象が変わる」全経路で呼ぶ統一クリア処理。
    /// 表示中の tooltip + キーボード予約 + 両テーブルの hover dwell 予約を即時無効化する。
    /// この関数を経由しないと「漏れ」になるので、新規にフォーカス遷移を増やす場合は必ず呼ぶこと。
    private func flushTooltipForFocusChange() {
        keyboardTooltipWorkItem?.cancel()
        keyboardTooltipWorkItem = nil
        (tableView as? MenuTableView)?.cancelHoverDwell()
        (folderTableView as? MenuTableView)?.cancelHoverDwell()
        hideSelectionTooltip()
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
            // folder パネルが開いている時、戻る方向のキーで main に戻す。
            // マウスホバーで folder を開いた場合 activeList は .main のままだが、
            // ユーザーから見れば「サブメニューが見えている」状態なので戻れて当然。
            // folderPanel.isVisible で統一判定する。
            if folderPanel.isVisible, folderPanelSide == .right {
                if activeList == .folder { activeList = .main }
                folderPanel.orderOut(nil)
                (folderTableView as? MenuTableView)?.cancelHoverDwell()
                hideSelectionTooltip()
                scheduleKeyboardTooltip(for: tableView)
                return nil
            }
            if activeList == .main, folderPanelSide == .left {
                return activateSelectedFolder() ? nil : event
            }
            return event
        case 124: // Right arrow
            guard !hasMarkedText() else { return event }
            if folderPanel.isVisible, folderPanelSide == .left {
                if activeList == .folder { activeList = .main }
                folderPanel.orderOut(nil)
                (folderTableView as? MenuTableView)?.cancelHoverDwell()
                hideSelectionTooltip()
                scheduleKeyboardTooltip(for: tableView)
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
            // showFolderIfNeeded は select() 内の selectRowIndexes が tableViewSelectionDidChange を
            // 同期発火するので既に実行済み。ここで再度 default(showTooltip:true) で呼ぶと keyboard
            // dwell をバイパスしてツールチップが即時表示されるため呼び出さない。
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
            // 同上。selectionDidChange 経路でフォルダ展開は済むので showFolderIfNeeded は呼ばない。
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

    private func showFolderIfNeeded(at row: Int, showTooltip: Bool = true) {
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
            if showTooltip {
                showSelectionTooltip(for: tableView)
            }
        }
    }

    private func activateSelectedFolder() -> Bool {
        guard tableView.selectedRow >= 0,
              tableView.selectedRow < filteredRows.count else { return false }
        switch filteredRows[tableView.selectedRow] {
        case let .folder(_, range):
            showFolder(range, from: tableView.selectedRow, activate: true)
            // フォルダ進入直後の最初の項目のツールチップを dwell 経由で予約。
            scheduleKeyboardTooltip(for: folderTableView)
            return true
        case let .snippetFolder(_, snippets):
            showSnippetFolder(snippets, from: tableView.selectedRow, activate: true)
            scheduleKeyboardTooltip(for: folderTableView)
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

    // dataHash → 整形済み NSAttributedString のキャッシュ。クリップが消されない限り再利用できる。
    // 件数キャップ 64 で枯らさない（パネル 1 セッションでさわるクリップ数を超えない想定）。
    private var richTooltipCache: [String: NSAttributedString] = [:]
    private static let richTooltipCacheLimit = 64
    // 「RTF を持っていない」と確定したクリップを次回 IO せずにスキップするためのネガティブキャッシュ。
    private var richTooltipMissCache: Set<String> = []

    private func richTooltipAttributedString(for clip: CPYClip,
                                             maxLength: Int,
                                             baseFont: NSFont,
                                             baseColor: NSColor) -> NSAttributedString? {
        let dataHash = clip.dataHash
        if let cached = richTooltipCache[dataHash] {
            return normalizeRichAttributed(cached, baseFont: baseFont, baseColor: baseColor, maxLength: maxLength)
        }
        if richTooltipMissCache.contains(dataHash) { return nil }
        let path = clip.dataPath
        guard !path.isEmpty else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let clipData = try? JSONDecoder().decode(CPYClipData.self, from: data) else {
            richTooltipMissCache.insert(dataHash)
            return nil
        }
        var rtfData: Data?
        var docType: NSAttributedString.DocumentType = .rtf
        for token in clipData.content {
            switch token {
            case .rtfd(let d): rtfData = d; docType = .rtfd
            case .rtf(let d): if rtfData == nil { rtfData = d; docType = .rtf }
            default: break
            }
            if docType == .rtfd { break }
        }
        guard let rtfData,
              let parsed = try? NSAttributedString(data: rtfData,
                                                   options: [.documentType: docType],
                                                   documentAttributes: nil),
              parsed.length > 0 else {
            richTooltipMissCache.insert(dataHash)
            return nil
        }
        if richTooltipCache.count >= Self.richTooltipCacheLimit {
            richTooltipCache.removeAll(keepingCapacity: true)
        }
        richTooltipCache[dataHash] = parsed
        return normalizeRichAttributed(parsed, baseFont: baseFont, baseColor: baseColor, maxLength: maxLength)
    }

    // 元の attributedString をツールチップ用に最小加工してプレビュー的に出す:
    // - 文字数を maxLength にクリップ
    // - フォントサイズだけ 18pt 上限でクランプ（家族名・bold/italic 等のトレイトは保持）
    // - 前景色・背景色は元のまま保持（コピー元の見た目を尊重）
    private static let richTooltipMaxFontSize: CGFloat = 20
    private func normalizeRichAttributed(_ source: NSAttributedString,
                                         baseFont: NSFont,
                                         baseColor: NSColor,
                                         maxLength: Int) -> NSAttributedString {
        let length = source.length
        let clipLen = min(length, maxLength)
        let mutable = NSMutableAttributedString(attributedString: source.attributedSubstring(from: NSRange(location: 0, length: clipLen)))
        // 末尾の空白・改行を物理的に削除。残っていると boundingRect が空段落ぶんの高さを返す。
        let ws = CharacterSet.whitespacesAndNewlines
        while mutable.length > 0 {
            let last = (mutable.string as NSString).character(at: mutable.length - 1)
            guard let scalar = UnicodeScalar(last), ws.contains(scalar) else { break }
            mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
        }
        guard mutable.length > 0 else { return mutable }
        let full = NSRange(location: 0, length: mutable.length)
        let cap = Self.richTooltipMaxFontSize
        mutable.enumerateAttribute(.font, in: full, options: []) { value, range, _ in
            let original = (value as? NSFont) ?? baseFont
            guard original.pointSize > cap else { return }
            let resized = NSFont(descriptor: original.fontDescriptor, size: cap) ?? baseFont
            mutable.addAttribute(.font, value: resized, range: range)
        }
        // Word / TextEdit からの RTF は段落の前後に paragraphSpacing が付くことが多く、
        // そのまま boundingRect に通すと「テキストは 1 行ぶんなのに高さは段落余白込み」になり、
        // ツールチップ内でテキストが上寄りに見える。段落スペーシングをゼロに正規化して解消する。
        // 行間 (lineSpacing) と minimum/maximum line height は保持して見た目はなるべく崩さない。
        mutable.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, range, _ in
            let original = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
            let copy = original.mutableCopy() as! NSMutableParagraphStyle
            copy.paragraphSpacing = 0
            copy.paragraphSpacingBefore = 0
            copy.lineSpacing = 0
            copy.minimumLineHeight = 0
            copy.maximumLineHeight = 0
            copy.lineHeightMultiple = 0
            mutable.addAttribute(.paragraphStyle, value: copy, range: range)
        }
        return mutable
    }

    private func showSelectionTooltip(for tableView: NSTableView) {
        let row = tableView.selectedRow
        // 検索パネル本体が閉じている時は出さない。dwell タイマーのキャンセル漏れに対する保険。
        guard panel.isVisible else {
            hideSelectionTooltip()
            return
        }
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

        let maxLength = integerPreference(Preferences.Menu.maxLengthOfToolTip, fallback: 100)
        let baseFont = NSFont.systemFont(ofSize: 13)
        let baseTextColor = tooltipContainerView.textColor()
        let swatchExtra: CGFloat = isColor ? (14 + 6) : 0
        let availableWidth: CGFloat = 406 - swatchExtra

        // RTF/RTFD があればリッチテキストのまま表示。色とサイズはツールチップ用に正規化、
        // 太字・イタリック等のフォントトレイトは元のまま保持する。
        // 画像・カラー優先表示中はここを使わずプレーン表示にフォールバック。
        let attributed: NSAttributedString?
        if !isColor, !hasImage, let clip {
            attributed = richTooltipAttributedString(for: clip,
                                                    maxLength: maxLength,
                                                    baseFont: baseFont,
                                                    baseColor: baseTextColor)
        } else {
            attributed = nil
        }

        let displaySize: NSSize
        if let attributed {
            tooltipLabel.attributedStringValue = attributed
            tooltipLabel.font = baseFont
            // attributed.boundingRect は RTF の段落属性の影響で空高さを返しやすい。
            // tooltipLabel の cell 自身に「この幅で何 pt 必要か」を計算させてその高さに揃える。
            tooltipLabel.preferredMaxLayoutWidth = availableWidth
            tooltipLabel.invalidateIntrinsicContentSize()
            let intrinsic = tooltipLabel.intrinsicContentSize
            let widthFit = min(ceil(intrinsic.width), availableWidth)
            displaySize = NSSize(width: widthFit, height: ceil(intrinsic.height))
        } else {
            guard let title = tooltipTitle(for: tableView, row: row), !title.isEmpty else {
                hideSelectionTooltip()
                return
            }
            let titleNSString = title as NSString
            let clippedTitle = titleNSString.substring(to: min(titleNSString.length, maxLength))
            tooltipLabel.stringValue = clippedTitle
            tooltipLabel.font = baseFont
            tooltipLabel.textColor = baseTextColor
            displaySize = (clippedTitle as NSString).boundingRect(
                with: NSSize(width: availableWidth, height: 120),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: baseFont]
            ).size
        }

        let width = min(max(ceil(displaySize.width) + swatchExtra + 16, 32), 422)
        let height = min(max(ceil(displaySize.height) + 8, 22), 128)
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
        setTooltipImmediateModeIfNeeded()
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
        // 対象行が既に可視範囲なら scrollRowToVisible は不要。ホバー経路では常に可視で、
        // ここをスキップすると layoutSubtreeIfNeeded × 5 連発も避けられる（行位置が動かないので再計算不要）。
        let rowRect = tableView.rect(ofRow: row)
        let visibleRect = tableView.visibleRect
        let isFullyVisible = visibleRect.minY <= rowRect.minY && rowRect.maxY <= visibleRect.maxY
        if isFullyVisible { return }
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
        // ツールチップ表示はこの経路では一切行わない（即発火を避けるため）。表示は呼び出し側に集約:
        //   ・矢印キー / 番号キー / 初期化  → select(row:) → scheduleKeyboardTooltip
        //   ・ホバー                        → MenuTableView.mouseMoved → dwell タイマー → hoverSelectionHandler
        //   ・クリック                      → mouseDown → 即 sendAction、ツールチップ不要
        if changedTableView.identifier == Self.mainTableIdentifier {
            showFolderIfNeeded(at: changedTableView.selectedRow, showTooltip: false)
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
