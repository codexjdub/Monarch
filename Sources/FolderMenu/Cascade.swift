import AppKit
import SwiftUI
import Combine
import PDFKit

// MARK: - Sort order (shared)

enum FileSortOrder: String, CaseIterable {
    case name         = "name"
    case dateModified = "modified"
    case dateCreated  = "created"
    case fileType     = "type"

    var label: String {
        switch self {
        case .name:         return "Name"
        case .dateModified: return "Date Modified"
        case .dateCreated:  return "Date Created"
        case .fileType:     return "File Type"
        }
    }
}

// MARK: - Peek window subclass

final class PeekNSWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Cascade Model
//
// The single source of truth for the whole cascade UI.
//
// A cascade is a horizontal chain of lists:
//   level 0 = the main popover, showing configured folder roots
//   level 1 = first peek window (to the right of level 0)
//   level 2 = peek to the right of level 1
//   ...
//
// Exactly one `(level, index)` pair is "focused" across the whole cascade.
// Hover and keyboard are just two input methods that write into `focus`.
// Every visual is a pure function of (levels, focus, pathIndices).

@MainActor
final class CascadeModel: ObservableObject {

    struct Focus: Equatable {
        var level: Int
        var index: Int   // -1 means no row focused in that window
    }

    /// A level renders one of two things: a folder's contents (list of rows),
    /// or a file preview (image / PDF / markdown / text).
    enum Content {
        case folder(items: [FileItem], rowFrames: [Int: NSRect])
        case preview(kind: PreviewKind, url: URL)
    }

    struct Level {
        /// Source URL for this level:
        ///   - nil for level 0 (the root list of configured folders)
        ///   - folder URL for .folder content
        ///   - file URL for .preview content
        let source: URL?
        var content: Content

        // Convenience accessors (return empty for preview levels).
        var items: [FileItem] {
            if case .folder(let items, _) = content { return items }
            return []
        }
        var rowFrames: [Int: NSRect] {
            if case .folder(_, let frames) = content { return frames }
            return [:]
        }
        /// For .folder levels, swap in a new items array without touching frames.
        mutating func setItems(_ newItems: [FileItem]) {
            if case .folder(_, let frames) = content {
                content = .folder(items: newItems, rowFrames: frames)
            }
        }
        /// For .folder levels, record a row's screen frame.
        mutating func setRowFrame(_ index: Int, _ frame: NSRect) {
            if case .folder(let items, var frames) = content {
                frames[index] = frame
                content = .folder(items: items, rowFrames: frames)
            }
        }
        var isPreview: Bool {
            if case .preview = content { return true }
            return false
        }
    }

    // Published state — views render from this.
    @Published private(set) var levels: [Level] = []
    @Published var focus: Focus = Focus(level: 0, index: -1)
    /// `pathIndices[L]` is the row at level L that currently has a child peek open
    /// at level L+1. Used for "on-path" highlighting and for restoring focus when
    /// backing out.
    @Published private(set) var pathIndices: [Int: Int] = [:]

    // Collaborators
    private let folderStore: FolderStore
    private var storeSub: AnyCancellable?
    let onDismiss: () -> Void

    // Peek window registry (levels 1+). Level 0 is the NSPopover, not owned here.
    private var peekWindows: [Int: PeekNSWindow] = [:]
    private let peekSize = NSSize(width: 320, height: 440)

    // Timing
    static let mouseOpenDelay:    TimeInterval = 0.12
    static let mouseReplaceDelay: TimeInterval = 0.06
    static let mouseCloseDelay:   TimeInterval = 0.30

    private var pendingOpen:  DispatchWorkItem?
    private var pendingClose: DispatchWorkItem?

    // MARK: - Init

    init(folderStore: FolderStore, onDismiss: @escaping () -> Void) {
        self.folderStore = folderStore
        self.onDismiss = onDismiss
        rebuildLevel0()
        storeSub = folderStore.$folders
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildLevel0() }
    }

    private func rebuildLevel0() {
        let items = folderStore.folders.map { FileItem(url: $0) }
        if levels.isEmpty {
            levels = [Level(source: nil, content: .folder(items: items, rowFrames: [:]))]
        } else {
            levels[0].setItems(items)
        }
    }

    func reloadAll() {
        rebuildLevel0()
        for i in 1..<levels.count {
            guard case .folder = levels[i].content, let f = levels[i].source else { continue }
            levels[i].setItems(CascadeModel.loadFolder(f))
        }
    }

    // MARK: - Row frame reporting (from RowFrameReporter)

    func setRowFrame(level: Int, index: Int, frame: NSRect) {
        guard levels.indices.contains(level) else { return }
        levels[level].setRowFrame(index, frame)
    }

    func hitTestRow(level: Int, at screenPoint: NSPoint) -> Int {
        guard levels.indices.contains(level) else { return -1 }
        for (idx, rect) in levels[level].rowFrames where rect.contains(screenPoint) {
            return idx
        }
        return -1
    }

    // MARK: - Mouse inputs (from WindowMouseTracker)

    /// Mouse moved onto a row.
    func mouseHover(level: Int, index: Int) {
        guard levels.indices.contains(level),
              levels[level].items.indices.contains(index) else { return }

        pendingClose?.cancel(); pendingClose = nil
        focus = Focus(level: level, index: index)

        let item = levels[level].items[index]
        pendingOpen?.cancel(); pendingOpen = nil

        // Folder row → schedule folder peek.
        if item.isDirectory {
            // Same folder already peeked? Just refresh path linkage.
            if levels.count > level + 1,
               case .folder = levels[level + 1].content,
               levels[level + 1].source == item.url {
                pathIndices[level] = index
                return
            }
            let delay: TimeInterval = (levels.count > level + 1)
                ? CascadeModel.mouseReplaceDelay
                : CascadeModel.mouseOpenDelay
            let url = item.url
            let task = DispatchWorkItem { [weak self] in
                self?.openFolderPeek(atLevel: level + 1, folder: url, parentIndex: index)
            }
            pendingOpen = task
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
            return
        }

        // Previewable file → schedule preview peek.
        if let kind = item.previewKind {
            // Same preview already open? No-op.
            if levels.count > level + 1,
               case .preview(let existingKind, let existingURL) = levels[level + 1].content,
               existingKind == kind, existingURL == item.url {
                pathIndices[level] = index
                return
            }
            let delay: TimeInterval = (levels.count > level + 1)
                ? CascadeModel.mouseReplaceDelay
                : CascadeModel.mouseOpenDelay
            let url = item.url
            let task = DispatchWorkItem { [weak self] in
                self?.openPreviewPeek(atLevel: level + 1, url: url, kind: kind, parentIndex: index)
            }
            pendingOpen = task
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
            return
        }

        // Non-previewable file: trim any child peek.
        closeDeeperThan(level)
    }

    /// Cursor entered a window (any level). Cancels a scheduled close.
    func mouseEnteredWindow(level: Int) {
        pendingClose?.cancel(); pendingClose = nil
    }

    /// Cursor left the window at `level` entirely (exited its bounds).
    /// Behavior: focus snaps to the parent's on-path row; a close of this level
    /// (and deeper) is scheduled. Re-entering parent within the grace period
    /// cancels the close.
    func mouseLeftWindow(level: Int) {
        pendingOpen?.cancel(); pendingOpen = nil
        if level > 0, let parentIdx = pathIndices[level - 1] {
            focus = Focus(level: level - 1, index: parentIdx)
        } else if level == 0 {
            focus = Focus(level: 0, index: -1)
        }
        // Close this level (and deeper) if it's a peek level. Level 0 is the
        // popover itself and must never be removed by close logic.
        scheduleClose(deeperThan: max(level - 1, 0))
    }

    // MARK: - Keyboard inputs

    func keyUp() {
        let l = focus.level
        guard levels.indices.contains(l) else { return }
        let n = levels[l].items.count
        guard n > 0 else { return }
        focus = Focus(level: l, index: max(0, focus.index <= 0 ? 0 : focus.index - 1))
    }

    func keyDown() {
        let l = focus.level
        guard levels.indices.contains(l) else { return }
        let n = levels[l].items.count
        guard n > 0 else { return }
        focus = Focus(level: l, index: min(n - 1, focus.index < 0 ? 0 : focus.index + 1))
    }

    func keyRight() { keyboardDrillIn() }
    func keyLeft()  { keyboardDrillOut() }

    func keyReturn() {
        let l = focus.level
        guard levels.indices.contains(l),
              levels[l].items.indices.contains(focus.index) else { return }
        let item = levels[l].items[focus.index]
        if item.isDirectory {
            keyboardDrillIn()
        } else {
            NSWorkspace.shared.open(item.url)
            onDismiss()
        }
    }

    func keyEscape() {
        if levels.count > 1 {
            let newLevel = levels.count - 2
            closeDeeperThan(newLevel)
        } else {
            onDismiss()
        }
    }

    private func keyboardDrillIn() {
        let l = focus.level
        guard levels.indices.contains(l),
              levels[l].items.indices.contains(focus.index) else { return }
        let item = levels[l].items[focus.index]
        pendingOpen?.cancel(); pendingOpen = nil
        if item.isDirectory {
            openFolderPeek(atLevel: l + 1, folder: item.url, parentIndex: focus.index)
            // Keyboard → on folder jumps focus into the new peek (spec B).
            focus = Focus(level: l + 1, index: 0)
        } else if let kind = item.previewKind {
            openPreviewPeek(atLevel: l + 1, url: item.url, kind: kind, parentIndex: focus.index)
            // Preview has no rows; focus stays on the parent row.
        }
    }

    private func keyboardDrillOut() {
        let l = focus.level
        if l == 0 { return }
        let newLevel = l - 1
        closeDeeperThan(newLevel)
    }

    // MARK: - Click (from row onTap)

    func clickRow(level: Int, index: Int) {
        guard levels.indices.contains(level),
              levels[level].items.indices.contains(index) else { return }
        let item = levels[level].items[index]
        if item.isDirectory {
            pendingOpen?.cancel(); pendingOpen = nil
            openFolderPeek(atLevel: level + 1, folder: item.url, parentIndex: index)
            // Mouse click → focus stays on parent (spec A).
            focus = Focus(level: level, index: index)
        } else {
            // Any file (previewable or not) opens in default app on click.
            NSWorkspace.shared.open(item.url)
            onDismiss()
        }
    }

    // MARK: - Peek open / close

    private func openFolderPeek(atLevel level: Int, folder: URL, parentIndex: Int) {
        // Close any existing peek at this level and deeper; we're replacing.
        closePeeks(atLevelsGreaterThan: level - 1)

        let items = CascadeModel.loadFolder(folder)
        let state = Level(source: folder, content: .folder(items: items, rowFrames: [:]))
        if levels.count == level {
            levels.append(state)
        } else if levels.count > level {
            levels[level] = state
            if levels.count > level + 1 {
                levels.removeLast(levels.count - level - 1)
            }
        } else {
            return
        }
        pathIndices[level - 1] = parentIndex

        let content = AnyView(LevelListView(level: level, model: self))
        presentPeek(atLevel: level, parentIndex: parentIndex, size: peekSize, content: content)
    }

    private func openPreviewPeek(atLevel level: Int, url: URL, kind: PreviewKind, parentIndex: Int) {
        closePeeks(atLevelsGreaterThan: level - 1)

        let size = CascadeModel.previewSize(for: url, kind: kind)
        let state = Level(source: url, content: .preview(kind: kind, url: url))
        if levels.count == level {
            levels.append(state)
        } else if levels.count > level {
            levels[level] = state
            if levels.count > level + 1 {
                levels.removeLast(levels.count - level - 1)
            }
        } else {
            return
        }
        pathIndices[level - 1] = parentIndex

        let content = AnyView(PreviewLevelView(level: level, url: url, kind: kind, model: self))
        presentPeek(atLevel: level, parentIndex: parentIndex, size: size, content: content)
    }

    private func presentPeek(atLevel level: Int, parentIndex: Int, size: NSSize, content: AnyView) {
        // Position the new peek window from the parent row's screen frame.
        let anchor = levels[level - 1].rowFrames[parentIndex] ?? .zero
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
                  ?? NSScreen.main
                  ?? NSScreen.screens.first!

        var origin = NSPoint(x: anchor.maxX + 2, y: anchor.maxY - size.height)
        if origin.x + size.width > screen.visibleFrame.maxX {
            origin.x = anchor.minX - size.width - 2
        }
        if origin.y < screen.visibleFrame.minY + 8 {
            origin.y = screen.visibleFrame.minY + 8
        }
        if origin.y + size.height > screen.visibleFrame.maxY {
            origin.y = screen.visibleFrame.maxY - size.height
        }

        let win = PeekNSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .popUpMenu
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.transient, .ignoresCycle]

        let hc = NSHostingController(rootView: content)
        hc.view.wantsLayer = true
        hc.view.layer?.cornerRadius = 10
        hc.view.layer?.masksToBounds = true
        hc.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        hc.view.layer?.borderWidth = 0.5
        hc.view.layer?.borderColor = NSColor.separatorColor.cgColor

        win.contentView = hc.view
        win.setFrame(NSRect(origin: origin, size: size), display: true)
        win.orderFront(nil)
        peekWindows[level] = win
    }

    /// Aspect-sized preview window sizing.
    /// - Images: load NSImage and fit into a 280...800 × 200...700 bounding box.
    /// - PDFs: first page bounds, same clamp.
    /// - Text/Markdown: fixed 520 × 600.
    static func previewSize(for url: URL, kind: PreviewKind) -> NSSize {
        let minW: CGFloat = 280, maxW: CGFloat = 800
        let minH: CGFloat = 200, maxH: CGFloat = 700
        let chromeH: CGFloat = 34  // header

        switch kind {
        case .image:
            if let img = NSImage(contentsOf: url), img.size.width > 0, img.size.height > 0 {
                let size = fit(aspect: img.size, minW: minW, maxW: maxW, minH: minH, maxH: maxH - chromeH)
                return NSSize(width: size.width, height: size.height + chromeH)
            }
            return NSSize(width: 520, height: 400)
        case .pdf:
            if let doc = PDFDocument(url: url), let page = doc.page(at: 0) {
                let bounds = page.bounds(for: .mediaBox)
                let size = fit(aspect: bounds.size, minW: minW, maxW: maxW, minH: minH, maxH: maxH - chromeH)
                return NSSize(width: size.width, height: size.height + chromeH)
            }
            return NSSize(width: 520, height: 600)
        case .markdown, .text:
            return NSSize(width: 520, height: 600)
        case .quicklook:
            // Roughly letter-paper aspect — fits docx/pages/epub nicely.
            return NSSize(width: 640, height: 780)
        case .video:
            return NSSize(width: 720, height: 480)
        case .audio:
            return NSSize(width: 480, height: 140)
        }
    }

    private static func fit(aspect: NSSize, minW: CGFloat, maxW: CGFloat, minH: CGFloat, maxH: CGFloat) -> NSSize {
        let ratio = aspect.width / aspect.height
        // Start at maxW, derive height.
        var w = maxW
        var h = w / ratio
        if h > maxH { h = maxH; w = h * ratio }
        if w < minW { w = minW; h = w / ratio }
        if h < minH { h = minH; w = h * ratio }
        w = min(max(w, minW), maxW)
        h = min(max(h, minH), maxH)
        return NSSize(width: w, height: h)
    }

    private func scheduleClose(deeperThan level: Int) {
        pendingClose?.cancel()
        let task = DispatchWorkItem { [weak self] in
            self?.closeDeeperThan(level)
        }
        pendingClose = task
        DispatchQueue.main.asyncAfter(deadline: .now() + CascadeModel.mouseCloseDelay, execute: task)
    }

    func closeDeeperThan(_ level: Int) {
        // Level 0 is the popover; we can only close peek levels (>= 1).
        let clamped = max(level, 0)
        closePeeks(atLevelsGreaterThan: clamped)
        if focus.level > clamped {
            let idx = pathIndices[clamped] ?? -1
            focus = Focus(level: clamped, index: idx)
        }
    }

    private func closePeeks(atLevelsGreaterThan level: Int) {
        // Defensive clamp: never touch level 0.
        let minLevel = max(level, 0)
        let ls = peekWindows.keys.filter { $0 > minLevel }.sorted(by: >)
        for l in ls {
            peekWindows[l]?.close()
            peekWindows[l] = nil
        }
        // Trim model levels beyond minLevel (keep levels[0...minLevel]).
        if levels.count > minLevel + 1 {
            levels.removeLast(levels.count - minLevel - 1)
        }
        for k in pathIndices.keys where k >= minLevel {
            pathIndices[k] = nil
        }
    }

    func closeAll() {
        pendingOpen?.cancel(); pendingOpen = nil
        pendingClose?.cancel(); pendingClose = nil
        closePeeks(atLevelsGreaterThan: 0)
        focus = Focus(level: 0, index: -1)
    }

    // Convenience: the URL of the focused root (level 0), if any.
    var focusedRootFolder: URL? {
        guard focus.level == 0,
              levels.indices.contains(0),
              levels[0].items.indices.contains(focus.index) else { return nil }
        return levels[0].items[focus.index].url
    }

    // MARK: - Folder loading

    static func loadFolder(_ folder: URL) -> [FileItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey]
        let contents = (try? fm.contentsOfDirectory(at: folder,
                                                    includingPropertiesForKeys: keys,
                                                    options: [])) ?? []
        let sortOrder  = FileSortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .name
        let showHidden = UserDefaults.standard.bool(forKey: "showHiddenFiles")
        return contents
            .map { FileItem(url: $0) }
            .filter { showHidden || !$0.isHidden }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                switch sortOrder {
                case .name:
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                case .dateModified:
                    let ad = (try? a.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    let bd = (try? b.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                    return ad > bd
                case .dateCreated:
                    let ad = (try? a.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    let bd = (try? b.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                    return ad > bd
                case .fileType:
                    let ae = a.url.pathExtension.lowercased()
                    let be = b.url.pathExtension.lowercased()
                    return ae.localizedCaseInsensitiveCompare(be) == .orderedAscending
                }
            }
    }
}

// MARK: - Row Frame Reporter
//
// Attached to each row; reports the row's screen frame to the model so that
// the window mouse tracker (and keyboard drill-in) can position peeks and
// hit-test the cursor against rows. Stateless — just geometry.

struct RowFrameReporter: NSViewRepresentable {
    let level: Int
    let index: Int
    let model: CascadeModel

    func makeNSView(context: Context) -> RowFrameReporterNSView {
        let v = RowFrameReporterNSView()
        v.configure(level: level, index: index, model: model)
        return v
    }
    func updateNSView(_ nsView: RowFrameReporterNSView, context: Context) {
        nsView.configure(level: level, index: index, model: model)
        nsView.reportIfReady()
    }
}

final class RowFrameReporterNSView: NSView {
    private var level: Int = 0
    private var index: Int = 0
    private weak var model: CascadeModel?
    private weak var observedClip: NSClipView?

    func configure(level: Int, index: Int, model: CascadeModel) {
        self.level = level
        self.index = index
        self.model = model
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attachScrollObserverIfNeeded()
        reportIfReady()
    }
    override func layout() { super.layout(); reportIfReady() }
    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize); reportIfReady()
    }

    /// Find the enclosing NSClipView (inside NSScrollView) and listen for
    /// bounds-changed notifications so the reported row frame stays fresh
    /// as the list scrolls.
    private func attachScrollObserverIfNeeded() {
        // Tear down any previous observer (in case we moved window).
        if let clip = observedClip {
            NotificationCenter.default.removeObserver(
                self, name: NSView.boundsDidChangeNotification, object: clip
            )
            observedClip = nil
        }
        guard window != nil else { return }

        var v: NSView? = self.superview
        while let s = v {
            if let clip = s as? NSClipView {
                clip.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(scrollDidChange),
                    name: NSView.boundsDidChangeNotification,
                    object: clip
                )
                observedClip = clip
                return
            }
            v = s.superview
        }
    }

    @objc private func scrollDidChange() { reportIfReady() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func reportIfReady() {
        guard let window, window.isVisible else { return }
        let inWin = convert(bounds, to: nil)
        let inScreen = window.convertToScreen(inWin)
        model?.setRowFrame(level: level, index: index, frame: inScreen)
    }
}

// MARK: - Window Mouse Tracker
//
// ONE tracker per window (popover or peek). On every mouse-move it asks the
// model "which row is the cursor on?" and reports hover events.
//
// Crucially: exits are driven ONLY by real `mouseExited` events. This view
// never synthesizes exits from polling — that's what caused the previous
// attempts to cascade-close the cascade during layout churn.

struct WindowMouseTracker: NSViewRepresentable {
    let level: Int
    let model: CascadeModel

    func makeNSView(context: Context) -> WindowMouseTrackerNSView {
        let v = WindowMouseTrackerNSView()
        v.configure(level: level, model: model)
        return v
    }
    func updateNSView(_ nsView: WindowMouseTrackerNSView, context: Context) {
        nsView.configure(level: level, model: model)
    }
}

final class WindowMouseTrackerNSView: NSView {
    private var level: Int = 0
    private weak var model: CascadeModel?
    private var area: NSTrackingArea?
    private var lastIndex: Int = -2  // sentinel distinct from -1 (=no row)

    func configure(level: Int, model: CascadeModel) {
        self.level = level
        self.model = model
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let a = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(a)
        area = a
        // Prime: if the cursor is already inside (window just appeared under
        // the cursor), emulate an entry event — additive only.
        syncIfInside()
    }

    override func mouseEntered(with event: NSEvent) {
        model?.mouseEnteredWindow(level: level)
        syncIfInside()
    }
    override func mouseMoved(with event: NSEvent) { syncIfInside() }
    override func mouseExited(with event: NSEvent) {
        lastIndex = -2
        model?.mouseLeftWindow(level: level)
    }

    /// If the cursor is currently inside our bounds, update the focused row.
    /// No-op if outside (does NOT send leave events — those come from mouseExited).
    private func syncIfInside() {
        guard let window, window.isVisible, let model else { return }
        let mouseInWin = window.mouseLocationOutsideOfEventStream
        let localPoint = convert(mouseInWin, from: nil)
        guard bounds.contains(localPoint) else { return }

        model.mouseEnteredWindow(level: level)
        let mouseScreen = window.convertPoint(toScreen: mouseInWin)
        let idx = model.hitTestRow(level: level, at: mouseScreen)
        if idx == lastIndex { return }
        lastIndex = idx
        if idx >= 0 {
            model.mouseHover(level: level, index: idx)
        }
        // If idx == -1 (between rows), leave current focus alone — keeps last
        // hovered row highlighted while the cursor is in the gap. A genuine
        // exit fires only when the cursor leaves the window entirely.
    }
}
