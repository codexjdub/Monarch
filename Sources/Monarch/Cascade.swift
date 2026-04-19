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

// MARK: - Peek Window Manager
//
// Owns the window registry and all AppKit window-creation/animation logic.
// CascadeModel calls through here; it retains ownership of level state,
// watchers, focus, and search state.

@MainActor
final class PeekWindowManager {

    let defaultSize = NSSize(width: 320, height: 440)
    private let peekAnimationDuration: TimeInterval = 0.20
    private var windows: [Int: PeekNSWindow] = [:]

    // MARK: Window lifecycle

    func present(atLevel level: Int, anchor: NSRect, size: NSSize, content: AnyView) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor.origin) })
                        ?? NSScreen.main
                        ?? NSScreen.screens.first else { return }

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
        win.appearance = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: UDKey.appearanceMode) ?? ""
        )?.nsAppearance

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 10
        visualEffect.layer?.masksToBounds = true
        visualEffect.layer?.borderWidth = 0.5
        visualEffect.layer?.borderColor = NSColor.separatorColor.cgColor

        let hc = NSHostingController(rootView: content)
        hc.view.translatesAutoresizingMaskIntoConstraints = false
        hc.view.wantsLayer = true
        hc.view.layer?.backgroundColor = NSColor.clear.cgColor
        visualEffect.addSubview(hc.view)
        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: visualEffect.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: visualEffect.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: visualEffect.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: visualEffect.bottomAnchor),
        ])
        win.contentView = visualEffect

        // Animate in: slide up 6pt + fade from 0 → 1 over 120ms.
        let finalFrame = NSRect(origin: origin, size: size)
        let startFrame = NSRect(x: origin.x, y: origin.y - 6,
                                width: size.width, height: size.height)
        win.setFrame(startFrame, display: false)
        win.alphaValue = 0
        win.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = peekAnimationDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            win.animator().alphaValue = 1
            win.animator().setFrame(finalFrame, display: true)
        }
        windows[level] = win
    }

    func close(level: Int) {
        windows[level]?.close()
        windows[level] = nil
    }

    /// All level keys strictly above `minLevel`, unsorted.
    func levels(greaterThan minLevel: Int) -> [Int] {
        windows.keys.filter { $0 > minLevel }
    }

    // MARK: Preview sizing

    /// Compute a sensible window size for a file preview based on its content.
    static func previewSize(for url: URL, kind: PreviewKind) -> NSSize {
        let minW: CGFloat = 280, maxW: CGFloat = 800
        let minH: CGFloat = 200, maxH: CGFloat = 700
        let chromeH: CGFloat = 34  // header bar height

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
            return NSSize(width: 640, height: 780)
        case .video:
            return NSSize(width: 720, height: 480)
        case .audio:
            return NSSize(width: 480, height: 140)
        }
    }

    private static func fit(aspect: NSSize, minW: CGFloat, maxW: CGFloat,
                             minH: CGFloat, maxH: CGFloat) -> NSSize {
        let ratio = aspect.width / aspect.height
        var w = maxW; var h = w / ratio
        if h > maxH { h = maxH; w = h * ratio }
        if w < minW { w = minW; h = w / ratio }
        if h < minH { h = minH; w = h * ratio }
        return NSSize(width: min(max(w, minW), maxW), height: min(max(h, minH), maxH))
    }
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
        case folder(items: [FileItem], sections: [Section], rowFrames: [Int: NSRect])
        case preview(kind: PreviewKind, url: URL)
    }

    /// A named section in a folder level. Indices refer to the flat `items` array.
    struct Section: Hashable {
        let title: String
        let range: Range<Int>
    }

    struct Level {
        /// Source URL for this level:
        ///   - nil for level 0 (the root list of configured folders)
        ///   - folder URL for .folder content
        ///   - file URL for .preview content
        let source: URL?
        var content: Content
        /// Sum of direct-child file sizes (bytes). 0 for level 0 and preview levels.
        var totalSize: Int64

        init(source: URL?, content: Content, totalSize: Int64 = 0) {
            self.source = source
            self.content = content
            self.totalSize = totalSize
        }

        // Convenience accessors (return empty for preview levels).
        var items: [FileItem] {
            if case .folder(let items, _, _) = content { return items }
            return []
        }
        var sections: [Section] {
            if case .folder(_, let secs, _) = content { return secs }
            return []
        }
        var rowFrames: [Int: NSRect] {
            if case .folder(_, _, let frames) = content { return frames }
            return [:]
        }
        /// For .folder levels, swap in new items + sections without touching frames.
        mutating func setContents(_ newItems: [FileItem], _ newSections: [Section], totalSize: Int64? = nil) {
            if case .folder(_, _, let frames) = content {
                content = .folder(items: newItems, sections: newSections, rowFrames: frames)
            }
            if let totalSize { self.totalSize = totalSize }
        }
        /// For .folder levels, record a row's screen frame.
        mutating func setRowFrame(_ index: Int, _ frame: NSRect) {
            if case .folder(let items, let secs, var frames) = content {
                frames[index] = frame
                content = .folder(items: items, sections: secs, rowFrames: frames)
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

    // Search state
    @Published var filterText: [Int: String] = [:]
    @Published var searchVisible: [Int: Bool] = [:]
    @Published var focusSearchLevel: Int? = nil

    // Collaborators
    private let shortcutStore: ShortcutStore
    private var storeSub: AnyCancellable?
    let onDismiss: () -> Void

    /// Called when "Remove from Monarch" is triggered on a root row.
    /// Wired by StatusItemController to call store.remove(_:).
    var onRemoveRoot: ((URL) -> Void)?

    // Peek window manager (levels 1+). Level 0 is the NSPopover, not owned here.
    private let peekManager = PeekWindowManager()

    // FSEvents watchers, one per .folder level (including level 0 roots).
    private var watchers: [Int: [FolderWatcher]] = [:]

    // Timing
    static let mouseOpenDelay:    TimeInterval = 0.12
    static let mouseReplaceDelay: TimeInterval = 0.06
    static let mouseCloseDelay:   TimeInterval = 0.30

    private var pendingOpen:  DispatchWorkItem?
    private var pendingClose: DispatchWorkItem?

    /// `true` while a cross-app drag is in flight. Suppresses tracking-area
    /// exits so peek windows stay open until the drag lands or is cancelled.
    var externalDragActive = false

    // MARK: - Search

    func showSearch(forLevel level: Int) {
        searchVisible[level] = true
        focusSearchLevel = level
    }

    func hideSearch(forLevel level: Int) {
        searchVisible.removeValue(forKey: level)
        filterText.removeValue(forKey: level)
        if focusSearchLevel == level { focusSearchLevel = nil }
    }

    func setFilter(_ text: String, forLevel level: Int) {
        if text.isEmpty {
            filterText.removeValue(forKey: level)
        } else {
            filterText[level] = text
        }
    }

    // MARK: - Init

    init(folderStore: ShortcutStore, onDismiss: @escaping () -> Void) {
        self.shortcutStore = folderStore
        self.onDismiss = onDismiss
        rebuildLevel0()
        storeSub = shortcutStore.$shortcuts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildLevel0() }
        PinStore.shared.onPinsChanged = { [weak self] folder in
            Task { @MainActor in self?.pinsChanged(folder: folder) }
        }
    }

    private func pinsChanged(folder: URL) {
        for i in 1..<levels.count {
            guard case .folder = levels[i].content, levels[i].source == folder else { continue }
            reloadLevelPreservingFocus(i)
        }
    }

    private func rebuildLevel0() {
        let items = shortcutStore.shortcuts.map { FileItem(url: $0) }
        if levels.isEmpty {
            levels = [Level(source: nil, content: .folder(items: items, sections: [], rowFrames: [:]))]
        } else {
            levels[0].setContents(items, [])
        }
        // Watch directory shortcuts so drilling in reflects live changes.
        // File shortcuts don't need watching (no folder listing to refresh).
        installWatchersForLevel0()
    }

    private func installWatchersForLevel0() {
        var ws: [FolderWatcher] = []
        for shortcut in shortcutStore.shortcuts where shortcut.hasDirectoryPath {
            ws.append(FolderWatcher(url: shortcut) { [weak self] in
                self?.folderDidChange(url: shortcut)
            })
        }
        watchers[0] = ws
    }

    private func installWatcher(forLevel level: Int, url: URL) {
        watchers[level] = [
            FolderWatcher(url: url) { [weak self] in
                self?.folderDidChange(url: url)
            }
        ]
    }

    private func removeWatchers(forLevel level: Int) {
        watchers[level] = nil
    }

    /// FSEvents fired for `url`. Reload any .folder levels whose source
    /// matches, preserving focus and path by URL (not index).
    private func folderDidChange(url: URL) {
        // Snapshot matching indices BEFORE the loop. reloadLevelPreservingFocus
        // can call closeDeeperThan → closePeeks → levels.removeLast(), which
        // shrinks the array and would cause an index-out-of-bounds crash if we
        // iterated live. Bounds-check again before each reload for safety.
        let matchingIndices = (1..<levels.count).filter { i in
            guard case .folder = levels[i].content else { return false }
            return levels[i].source == url
        }
        for i in matchingIndices {
            guard levels.indices.contains(i) else { continue }
            reloadLevelPreservingFocus(i)
        }
    }

    private func reloadLevelPreservingFocus(_ level: Int) {
        guard levels.indices.contains(level),
              case .folder = levels[level].content,
              let src = levels[level].source else { return }

        // Snapshot URLs we want to keep focused / on-path.
        let focusedURL: URL? = {
            if focus.level == level, levels[level].items.indices.contains(focus.index) {
                return levels[level].items[focus.index].url
            }
            return nil
        }()
        let pathURL: URL? = {
            if let idx = pathIndices[level], levels[level].items.indices.contains(idx) {
                return levels[level].items[idx].url
            }
            return nil
        }()

        // Reload.
        let result = CascadeModel.loadFolder(src)
        let newItems = result.items
        levels[level].setContents(result.items, result.sections, totalSize: result.totalSize)

        // Restore focus.
        if let focusedURL, let newIdx = newItems.firstIndex(where: { $0.url == focusedURL }) {
            focus = Focus(level: level, index: newIdx)
        } else if focus.level == level {
            focus = Focus(level: level, index: min(focus.index, max(newItems.count - 1, -1)))
        }

        // Restore path index — if the on-path child URL is gone, close its peek.
        if let pathURL {
            if let newIdx = newItems.firstIndex(where: { $0.url == pathURL }) {
                pathIndices[level] = newIdx
            } else {
                pathIndices[level] = nil
                closeDeeperThan(level)
            }
        }
    }

    func reloadAll() {
        rebuildLevel0()
        for i in 1..<levels.count {
            guard case .folder = levels[i].content, let f = levels[i].source else { continue }
            let result = CascadeModel.loadFolder(f)
            levels[i].setContents(result.items, result.sections, totalSize: result.totalSize)
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
        guard !externalDragActive else { return }
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
        pendingOpen?.cancel(); pendingOpen = nil
        pendingClose?.cancel(); pendingClose = nil
        // No focus yet → ↑ jumps to last item; otherwise move up, clamped at 0.
        let next = focus.index < 0 ? n - 1 : max(0, focus.index - 1)
        focus = Focus(level: l, index: next)
    }

    func keyDown() {
        let l = focus.level
        guard levels.indices.contains(l) else { return }
        let n = levels[l].items.count
        guard n > 0 else { return }
        pendingOpen?.cancel(); pendingOpen = nil
        pendingClose?.cancel(); pendingClose = nil
        // No focus yet → ↓ jumps to first item; otherwise move down, clamped at end.
        let next = focus.index < 0 ? 0 : min(n - 1, focus.index + 1)
        focus = Focus(level: l, index: next)
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
        pendingOpen?.cancel(); pendingOpen = nil
        let l = focus.level
        if l == 0 { onDismiss(); return }
        // If a preview is open one level deeper, ← closes just the preview
        // and leaves focus on the current folder listing. If the deeper level
        // is a folder peek (or nothing), ← collapses back to the parent.
        let deeperIsPreview = levels.indices.contains(l + 1) && levels[l + 1].isPreview
        closeDeeperThan(deeperIsPreview ? l : l - 1)
    }

    // MARK: - Spring-loaded folders (drag hover opens peek)

    /// Called when a drag hovers a folder row long enough. Opens the peek
    /// immediately (no open delay — the spring-load delay already fired).
    func springLoadFolder(level: Int, index: Int) {
        guard levels.indices.contains(level),
              levels[level].items.indices.contains(index) else { return }
        let item = levels[level].items[index]
        guard item.isDirectory else { return }
        pendingOpen?.cancel(); pendingOpen = nil
        openFolderPeek(atLevel: level + 1, folder: item.url, parentIndex: index)
        pathIndices[level] = index
    }

    // MARK: - Click (from row onTap)

    func clickRow(level: Int, index: Int) {
        guard levels.indices.contains(level),
              levels[level].items.indices.contains(index) else { return }
        let item = levels[level].items[index]
        // Everything opens in the default app on click — folders open in
        // Finder, files in their associated app. Hover handles peeks.
        NSWorkspace.shared.open(item.url)
        onDismiss()
    }

    // MARK: - Peek open / close

    private func openFolderPeek(atLevel level: Int, folder: URL, parentIndex: Int) {
        closePeeks(atLevelsGreaterThan: level - 1)
        let result = CascadeModel.loadFolder(folder)
        let state = Level(source: folder, content: .folder(items: result.items, sections: result.sections, rowFrames: [:]), totalSize: result.totalSize)
        guard installLevel(state, atLevel: level, parentIndex: parentIndex) else { return }
        installWatcher(forLevel: level, url: folder)
        let content = AnyView(LevelListView(level: level, model: self))
        presentPeek(atLevel: level, parentIndex: parentIndex, size: peekManager.defaultSize, content: content)
    }

    private func openPreviewPeek(atLevel level: Int, url: URL, kind: PreviewKind, parentIndex: Int) {
        closePeeks(atLevelsGreaterThan: level - 1)
        let state = Level(source: url, content: .preview(kind: kind, url: url))
        guard installLevel(state, atLevel: level, parentIndex: parentIndex) else { return }
        let content = AnyView(PreviewLevelView(level: level, url: url, kind: kind, model: self))
        presentPeek(atLevel: level, parentIndex: parentIndex, size: PeekWindowManager.previewSize(for: url, kind: kind), content: content)
    }

    /// Inserts or replaces `state` at `level`, trims any deeper levels, and
    /// records the parent path index. Returns false if the level index is out
    /// of range (caller should bail out).
    @discardableResult
    private func installLevel(_ state: Level, atLevel level: Int, parentIndex: Int) -> Bool {
        if levels.count == level {
            levels.append(state)
        } else if levels.count > level {
            levels[level] = state
            if levels.count > level + 1 {
                levels.removeLast(levels.count - level - 1)
            }
        } else {
            return false
        }
        pathIndices[level - 1] = parentIndex
        return true
    }

    private func presentPeek(atLevel level: Int, parentIndex: Int, size: NSSize, content: AnyView) {
        let anchor = levels[level - 1].rowFrames[parentIndex] ?? .zero
        peekManager.present(atLevel: level, anchor: anchor, size: size, content: content)
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
        for l in peekManager.levels(greaterThan: minLevel).sorted(by: >) {
            peekManager.close(level: l)
            removeWatchers(forLevel: l)
        }
        // Trim model levels beyond minLevel (keep levels[0...minLevel]).
        if levels.count > minLevel + 1 {
            levels.removeLast(levels.count - minLevel - 1)
        }
        // Keep pathIndices[minLevel] — it records which row at the surviving
        // level opened the now-closed peek, needed for focus restoration.
        for k in pathIndices.keys where k > minLevel {
            pathIndices[k] = nil
        }
        // Clear search state for closed levels.
        for k in filterText.keys where k > minLevel { filterText.removeValue(forKey: k) }
        for k in searchVisible.keys where k > minLevel { searchVisible.removeValue(forKey: k) }
    }

    /// Click on a breadcrumb segment: collapse the cascade to that level
    /// and focus the parent's on-path row (so the user sees where they are).
    func jumpToBreadcrumb(level: Int) {
        closeDeeperThan(level)
        if let idx = pathIndices[level] {
            focus = Focus(level: level, index: idx)
        } else {
            focus = Focus(level: level, index: 0)
        }
    }

    func closeAll() {
        pendingOpen?.cancel(); pendingOpen = nil
        pendingClose?.cancel(); pendingClose = nil
        closePeeks(atLevelsGreaterThan: 0)
        focus = Focus(level: 0, index: -1)
    }

    // Convenience: the URL of the focused level-0 shortcut, if any.
    var focusedRootShortcut: URL? {
        guard focus.level == 0,
              levels.indices.contains(0),
              levels[0].items.indices.contains(focus.index) else { return nil }
        return levels[0].items[focus.index].url
    }

    func moveRoot(from: Int, to: Int) {
        shortcutStore.move(from: from, to: to)
    }

    func addToRoot(_ url: URL) {
        shortcutStore.add(url)
    }

    func isInRoot(_ url: URL) -> Bool {
        shortcutStore.shortcuts.contains(url)
    }

    // MARK: - Folder loading

    struct FolderContents {
        let items: [FileItem]
        let sections: [Section]
        let totalSize: Int64
    }

    static func loadFolder(_ folder: URL) -> FolderContents {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey]
        let contents = (try? fm.contentsOfDirectory(at: folder,
                                                    includingPropertiesForKeys: keys,
                                                    options: [])) ?? []
        let sortOrder  = FileSortOrder(rawValue: UserDefaults.standard.string(forKey: UDKey.sortOrder) ?? "") ?? .name
        let showHidden = UserDefaults.standard.bool(forKey: UDKey.showHiddenFiles)
        let defaultDescending: Bool = (sortOrder == .dateModified || sortOrder == .dateCreated)
        let descending = UserDefaults.standard.object(forKey: UDKey.sortDescending) as? Bool ?? defaultDescending

        // Pre-fetch all file attributes in one pass so that sort comparators
        // and the totalSize reduce can do plain dictionary lookups instead of
        // calling resourceValues() O(N log N) times.
        struct Attrs {
            var modDate: Date
            var createDate: Date
            var fileSize: Int
        }
        var attrs = [URL: Attrs](minimumCapacity: contents.count)
        for url in contents {
            let r = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                      .creationDateKey, .fileSizeKey])
            attrs[url] = Attrs(
                modDate:    r?.contentModificationDate ?? .distantPast,
                createDate: r?.creationDate            ?? .distantPast,
                fileSize:   r?.fileSize                ?? 0
            )
        }

        let totalSize: Int64 = contents.reduce(0) { $0 + Int64(attrs[$1]?.fileSize ?? 0) }

        let allSorted = contents
            .map { FileItem(url: $0) }
            .filter { showHidden || !$0.isHidden }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                let ascending: Bool
                switch sortOrder {
                case .name:
                    ascending = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                case .dateModified:
                    ascending = (attrs[a.url]?.modDate ?? .distantPast) < (attrs[b.url]?.modDate ?? .distantPast)
                case .dateCreated:
                    ascending = (attrs[a.url]?.createDate ?? .distantPast) < (attrs[b.url]?.createDate ?? .distantPast)
                case .fileType:
                    ascending = a.url.pathExtension.localizedCaseInsensitiveCompare(b.url.pathExtension) == .orderedAscending
                }
                return descending ? !ascending : ascending
            }

        // Build sections: Pinned, Recent, All.
        let pinnedURLs = PinStore.shared.pinned(in: folder)
        let pinnedSet = Set(pinnedURLs.map(\.path))
        let pinnedItems = pinnedURLs.compactMap { url in
            allSorted.first(where: { $0.url == url })
        }

        // Recent: top 5 non-pinned files by modification date (skip dirs).
        let recentCount = 5
        let recentCandidates = allSorted
            .filter { !$0.isDirectory && !pinnedSet.contains($0.url.path) }
            .sorted { a, b in
                (attrs[a.url]?.modDate ?? .distantPast) > (attrs[b.url]?.modDate ?? .distantPast)
            }
        let recentItems: [FileItem]
        // Show Recent only when the folder has enough items to make it useful.
        if allSorted.count >= 10, recentCandidates.count >= 3 {
            recentItems = Array(recentCandidates.prefix(recentCount))
        } else {
            recentItems = []
        }
        let recentSet = Set(recentItems.map(\.url.path))

        // All — minus pinned and recent (they already appear above).
        let remainingItems = allSorted.filter {
            !pinnedSet.contains($0.url.path) && !recentSet.contains($0.url.path)
        }

        // No sections needed if there are no pins and no recent.
        if pinnedItems.isEmpty && recentItems.isEmpty {
            return FolderContents(items: allSorted, sections: [], totalSize: totalSize)
        }

        // Compose flat item list and build section descriptors.
        var items: [FileItem] = []
        var sections: [Section] = []

        if !pinnedItems.isEmpty {
            let start = items.count
            items.append(contentsOf: pinnedItems)
            sections.append(Section(title: "Pinned", range: start..<items.count))
        }
        if !recentItems.isEmpty {
            let start = items.count
            items.append(contentsOf: recentItems)
            sections.append(Section(title: "Recent", range: start..<items.count))
        }
        let start = items.count
        items.append(contentsOf: remainingItems)
        sections.append(Section(title: "All", range: start..<items.count))

        return FolderContents(items: items, sections: sections, totalSize: totalSize)
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
        if window == nil {
            // View is leaving its window — remove all observers immediately,
            // even if observedClip's weak ref has already gone nil.
            NotificationCenter.default.removeObserver(self)
            observedClip = nil
        }
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
