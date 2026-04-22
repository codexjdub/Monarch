import AppKit
import SwiftUI
import Combine

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
//
// Nested data types (Focus, Content, Section, Level, FolderContents) and
// the static loadFolder(_:) helper live in CascadeLevel.swift.

@MainActor
final class CascadeModel: ObservableObject {

    // Published state — views render from this.
    @Published private(set) var levels: [Level] = []
    @Published var focus: Focus = Focus(level: 0, index: Focus.noFocus)
    /// Incremented only by keyboard navigation. `scrollView` observes this to
    /// scroll the focused row into view — mouse hover updates `focus` too but
    /// must never trigger an auto-scroll.
    @Published private(set) var keyboardFocusVersion: Int = 0
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

    /// Monotonic token per level. Incremented whenever we kick off an async
    /// load; the async completion only applies if its token still matches.
    /// Prevents stale results from a fast-then-slow hover sequence (A then B)
    /// stomping the current level.
    private var loadTokens: [Int: Int] = [:]

    private func beginLoad(atLevel level: Int) -> Int {
        let token = (loadTokens[level] ?? 0) + 1
        loadTokens[level] = token
        return token
    }

    private func isTokenValid(_ token: Int, atLevel level: Int) -> Bool {
        loadTokens[level] == token
    }

    /// Main-actor entry point for folder loads. Gathers UserDefaults/PinStore
    /// inputs on main, then runs the actual filesystem work in a detached task.
    private func loadFolderAsync(_ folder: URL) async -> FolderContents {
        let pinnedURLs = PinStore.shared.pinned(in: folder)
        let sortOrder  = FileSortOrder(rawValue: UserDefaults.standard.string(forKey: UDKey.sortOrder) ?? "") ?? .name
        let showHidden = UserDefaults.standard.bool(forKey: UDKey.showHiddenFiles)
        let defaultDescending: Bool = (sortOrder == .dateModified || sortOrder == .dateCreated)
        let descending = UserDefaults.standard.object(forKey: UDKey.sortDescending) as? Bool ?? defaultDescending
        return await Task.detached(priority: .userInitiated) {
            CascadeModel.loadFolder(folder,
                                    pinnedURLs: pinnedURLs,
                                    sortOrder: sortOrder,
                                    showHidden: showHidden,
                                    descending: descending)
        }.value
    }

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
            Task { [weak self] in await self?.reloadLevelPreservingFocus(i) }
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
            Task { [weak self] in await self?.reloadLevelPreservingFocus(i) }
        }
    }

    private func reloadLevelPreservingFocus(_ level: Int) async {
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

        // Reload (async). Keep the old contents visible until the new ones arrive.
        let token = beginLoad(atLevel: level)
        let result = await loadFolderAsync(src)
        // Abandon if the level was closed, replaced, or superseded by a newer load.
        guard isTokenValid(token, atLevel: level),
              levels.indices.contains(level),
              case .folder = levels[level].content,
              levels[level].source == src else { return }
        let newItems = result.items
        levels[level].setContents(result.items, result.sections, totalSize: result.totalSize, readError: result.readError)

        // Restore focus.
        if let focusedURL, let newIdx = newItems.firstIndex(where: { $0.url == focusedURL }) {
            focus = Focus(level: level, index: newIdx)
        } else if focus.level == level {
            focus = Focus(level: level, index: min(focus.index, max(newItems.count - 1, Focus.noFocus)))
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
        // Kick off async reloads for every open peek level. Each one is
        // token-guarded, so concurrent applies can't collide.
        for i in 1..<levels.count {
            guard case .folder = levels[i].content else { continue }
            Task { [weak self] in await self?.reloadLevelPreservingFocus(i) }
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

        // Broken root shortcut → no peek, just trim any deeper stale window.
        if level == 0, !item.exists {
            closeDeeperThan(level)
            return
        }

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
            focus = Focus(level: 0, index: Focus.noFocus)
        }
        // Close this level (and deeper) if it's a peek level. Level 0 is the
        // popover itself and must never be removed by close logic.
        scheduleClose(deeperThan: max(level - 1, 0))
    }

    // MARK: - Keyboard inputs

    /// Set focus and mark it as keyboard-driven so the scroll view reacts.
    private func setKeyboardFocus(_ f: Focus) {
        focus = f
        keyboardFocusVersion &+= 1
    }

    func keyUp() {
        let l = focus.level
        guard levels.indices.contains(l) else { return }
        let n = levels[l].items.count
        guard n > 0 else { return }
        pendingOpen?.cancel(); pendingOpen = nil
        pendingClose?.cancel(); pendingClose = nil
        // No focus yet → ↑ jumps to last item; otherwise move up, clamped at 0.
        let next = focus.index < 0 ? n - 1 : max(0, focus.index - 1)
        setKeyboardFocus(Focus(level: l, index: next))
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
        setKeyboardFocus(Focus(level: l, index: next))
    }

    func keyRight() { keyboardDrillIn() }
    func keyLeft()  { keyboardDrillOut() }

    func keyReturn() {
        let l = focus.level
        guard levels.indices.contains(l),
              levels[l].items.indices.contains(focus.index) else { return }
        let item = levels[l].items[focus.index]
        if l == 0, !item.exists {
            handleMissingShortcut(url: item.url)
            return
        }
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
            setKeyboardFocus(Focus(level: l + 1, index: 0))
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
        // Broken root shortcut — offer Remove / Locate instead of silently
        // failing (NSWorkspace.open on a nonexistent URL does nothing visible).
        if level == 0, !item.exists {
            handleMissingShortcut(url: item.url)
            return
        }
        // Everything opens in the default app on click — folders open in
        // Finder, files in their associated app. Hover handles peeks.
        NSWorkspace.shared.open(item.url)
        onDismiss()
    }

    /// Present a "shortcut is missing" alert with Remove / Locate… / Cancel.
    /// Locate… opens NSOpenPanel; the chosen URL replaces the old one in the
    /// store (position preserved).
    private func handleMissingShortcut(url: URL) {
        let alert = NSAlert()
        alert.messageText = "\"\(url.lastPathComponent)\" can't be found"
        alert.informativeText = "The item has been moved or deleted. You can remove it from Monarch or locate it in its new place."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Locate…")
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Locate \"\(url.lastPathComponent)\""
            panel.prompt = "Choose"
            if panel.runModal() == .OK, let newURL = panel.url {
                shortcutStore.replace(oldURL: url, newURL: newURL)
            }
        case .alertSecondButtonReturn:
            onRemoveRoot?(url)
        default:
            break
        }
    }

    // MARK: - Peek open / close

    private func openFolderPeek(atLevel level: Int, folder: URL, parentIndex: Int) {
        closePeeks(atLevelsGreaterThan: level - 1)
        // Install a placeholder level with empty contents; present the peek
        // immediately so hover feels instant. The async load fills it in.
        let placeholder = Level(source: folder, content: .folder(items: [], sections: [], rowFrames: [:]), isLoading: true)
        guard installLevel(placeholder, atLevel: level, parentIndex: parentIndex) else { return }
        installWatcher(forLevel: level, url: folder)
        let content = AnyView(LevelListView(level: level, model: self))
        presentPeek(atLevel: level, parentIndex: parentIndex, size: peekManager.defaultSize, content: content)

        let token = beginLoad(atLevel: level)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.loadFolderAsync(folder)
            // Only apply if this level still exists, still points at `folder`,
            // and no newer load has superseded this one.
            guard self.isTokenValid(token, atLevel: level),
                  self.levels.indices.contains(level),
                  case .folder = self.levels[level].content,
                  self.levels[level].source == folder else { return }
            self.levels[level].setContents(result.items, result.sections,
                                           totalSize: result.totalSize,
                                           readError: result.readError)
        }
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
            let idx = pathIndices[clamped] ?? Focus.noFocus
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
}
