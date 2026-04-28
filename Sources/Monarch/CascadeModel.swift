import AppKit
import SwiftUI
import Combine

// MARK: - Cascade Model
//
// The single source of truth for the whole cascade UI.
//
// A cascade is a horizontal chain of lists:
//   level 0 = the main popover, showing configured folder roots
//   level 1 = first peek window beside level 0
//   level 2 = next peek window in the chain
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
    @Published private(set) var filterHighlightIndex: [Int: Int] = [:]
    @Published private(set) var clearSelectionVersion: Int = 0
    private var selectedURLsByLevel: [Int: Set<URL>] = [:]

    // Collaborators
    private let shortcutStore: ShortcutStore
    private let frequentStore = FrequentStore.shared
    private var storeSub: AnyCancellable?
    private var frequentSectionObserver: NSKeyValueObservation?
    private var frequentDisplayLimitObserver: NSKeyValueObservation?
    let onDismiss: () -> Void

    /// Called when "Remove from Monarch" is triggered on a root row.
    /// Wired by StatusItemController to call store.remove(_:).
    var onRemoveRoot: ((URL) -> Void)?

    // Peek window manager (levels 1+). Level 0 is the NSPopover, not owned here.
    private let peekManager = PeekWindowManager()

    // FSEvents watchers, one per .folder level (including level 0 roots).
    private var watchers: [Int: [FolderWatcher]] = [:]
    private var level0WatcherPaths: [String] = []

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
        let sortOrder  = UserDefaults.standard.sortOrder(for: folder)
        let descending = UserDefaults.standard.sortDescending(for: folder)
        let showHidden = UserDefaults.standard.bool(forKey: UDKey.showHiddenFiles)
        return await Task.detached(priority: .userInitiated) {
            CascadeModel.loadFolder(folder,
                                    pinnedURLs: pinnedURLs,
                                    sortOrder: sortOrder,
                                    showHidden: showHidden,
                                    descending: descending)
        }.value
    }

    /// Change sort order for the folder shown at `level` and reload.
    func setSort(order: FileSortOrder, descending: Bool, forLevel level: Int) {
        guard levels.indices.contains(level),
              let folder = levels[level].source else { return }
        UserDefaults.standard.setSortOrder(order, descending: descending, for: folder)
        Task { await reloadLevelPreservingFocus(level) }
    }

    /// Current sort state for the folder at `level`.
    func sortState(forLevel level: Int) -> (order: FileSortOrder, descending: Bool) {
        guard levels.indices.contains(level), let folder = levels[level].source else {
            return (.name, false)
        }
        return (UserDefaults.standard.sortOrder(for: folder),
                UserDefaults.standard.sortDescending(for: folder))
    }

    // Timing
    static let mouseOpenDelay:    TimeInterval = 0.12
    static let mouseReplaceDelay: TimeInterval = 0.06
    static let mouseCloseDelay:   TimeInterval = 0.30

    private struct PendingHoverTarget: Equatable {
        let level: Int
        let index: Int
        let url: URL
    }

    private var pendingOpen:  DispatchWorkItem?
    private var pendingClose: DispatchWorkItem?
    private var pendingHoverTarget: PendingHoverTarget?

    private func cancelPendingOpen() {
        pendingOpen?.cancel()
        pendingOpen = nil
        pendingHoverTarget = nil
    }

    /// `true` while a cross-app drag is in flight. Suppresses tracking-area
    /// exits so peek windows stay open until the drag lands or is cancelled.
    var externalDragActive = false

    // MARK: - Search

    enum KeyIntent {
        case moveUp
        case moveDown
        case moveLeft
        case moveRight
        case openFocused
        case quickLookFocused
        case escape
        case showSearch
        case insertSearchText(String)
        case deleteSearchBackward
    }

    enum KeyIntentResult {
        case handled
        case unhandled
        case quickLook(URL)
    }

    func showSearch(forLevel level: Int) {
        searchVisible[level] = true
        focusSearchLevel = level
    }

    func hideSearch(forLevel level: Int) {
        searchVisible.removeValue(forKey: level)
        filterText.removeValue(forKey: level)
        filterHighlightIndex.removeValue(forKey: level)
        if focusSearchLevel == level { focusSearchLevel = nil }
    }

    func setFilter(_ text: String, forLevel level: Int, deferFocus: Bool = false) {
        if text.isEmpty {
            filterText.removeValue(forKey: level)
            filterHighlightIndex.removeValue(forKey: level)
        } else {
            filterText[level] = text
            updateFilterHighlight(forLevel: level)
        }
        if deferFocus {
            DispatchQueue.main.async { [weak self] in
                self?.focusFirstVisibleResult(forLevel: level)
            }
            return
        }
        focusFirstVisibleResult(forLevel: level)
    }

    func visibleIndices(forLevel level: Int) -> [Int] {
        guard levels.indices.contains(level) else { return [] }
        let items = levels[level].items
        let filter = filterText[level]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !filter.isEmpty else { return Array(items.indices) }
        return items.indices.filter { index in
            itemMatchesFilter(items[index], filter: filter)
        }
    }

    func isIndexVisible(_ index: Int, forLevel level: Int) -> Bool {
        visibleIndices(forLevel: level).contains(index)
    }

    private func itemMatchesFilter(_ item: FileItem, filter: String) -> Bool {
        item.displayName.localizedCaseInsensitiveContains(filter)
            || item.name.localizedCaseInsensitiveContains(filter)
    }

    private func updateFilterHighlight(forLevel level: Int) {
        guard filterText[level]?.isEmpty == false else {
            filterHighlightIndex.removeValue(forKey: level)
            return
        }
        filterHighlightIndex[level] = visibleIndices(forLevel: level).first ?? Focus.noFocus
    }

    private func focusFirstVisibleResult(forLevel level: Int) {
        guard filterText[level]?.isEmpty == false else { return }
        guard levels.indices.contains(level) else { return }
        let visible = visibleIndices(forLevel: level)
        if let first = visible.first {
            setKeyboardFocus(Focus(level: level, index: first))
        } else {
            setKeyboardFocus(Focus(level: level, index: Focus.noFocus))
        }
    }

    @discardableResult
    func handleKeyIntent(_ intent: KeyIntent) -> KeyIntentResult {
        switch intent {
        case .moveUp:
            keyUp()
            return .handled
        case .moveDown:
            keyDown()
            return .handled
        case .moveLeft:
            keyLeft()
            return .handled
        case .moveRight:
            keyRight()
            return .handled
        case .openFocused:
            keyReturn()
            return .handled
        case .quickLookFocused:
            guard let item = focusedVisibleItem(), !item.isDirectory else { return .handled }
            return .quickLook(item.url)
        case .escape:
            if hasSelection {
                clearSelections()
                return .handled
            }
            let level = focus.level
            if searchVisible[level] == true {
                hideSearch(forLevel: level)
            } else {
                keyEscape()
            }
            return .handled
        case .showSearch:
            showSearch(forLevel: focus.level)
            return .handled
        case .insertSearchText(let text):
            guard searchVisible[focus.level] == true else { return .unhandled }
            setFilter((filterText[focus.level] ?? "") + text, forLevel: focus.level)
            return .handled
        case .deleteSearchBackward:
            guard searchVisible[focus.level] == true else { return .unhandled }
            setFilter(String((filterText[focus.level] ?? "").dropLast()), forLevel: focus.level)
            return .handled
        }
    }

    func focusedVisibleItem() -> FileItem? {
        let f = focus
        guard levels.indices.contains(f.level),
              levels[f.level].items.indices.contains(f.index),
              isIndexVisible(f.index, forLevel: f.level) else { return nil }
        return levels[f.level].items[f.index]
    }

    func setSelectedURLs(_ urls: Set<URL>, forLevel level: Int) {
        if urls.isEmpty {
            selectedURLsByLevel.removeValue(forKey: level)
        } else {
            selectedURLsByLevel[level] = urls
        }
    }

    private var hasSelection: Bool {
        selectedURLsByLevel.values.contains { !$0.isEmpty }
    }

    private func clearSelections() {
        guard hasSelection else { return }
        selectedURLsByLevel.removeAll()
        clearSelectionVersion &+= 1
    }

    // MARK: - Init

    init(folderStore: ShortcutStore, onDismiss: @escaping () -> Void) {
        self.shortcutStore = folderStore
        self.onDismiss = onDismiss
        rebuildLevel0()
        storeSub = shortcutStore.$shortcuts
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildLevel0() }
        frequentStore.onChanged = { [weak self] in
            self?.rebuildLevel0()
        }
        frequentSectionObserver = UserDefaults.standard.observe(
            \.showFrequentSection, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.rebuildLevel0() }
        }
        frequentDisplayLimitObserver = UserDefaults.standard.observe(
            \.frequentDisplayLimit, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.rebuildLevel0() }
        }
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

    private func makeRootItem(_ shortcut: RootShortcut) -> FileItem {
        FileItem(
            url: shortcut.url,
            role: .rootShortcut,
            displayNameOverride: shortcut.alias,
            subtitleOverride: shortcut.hasAlias
                ? NSString(string: shortcut.url.path).abbreviatingWithTildeInPath
                : nil
        )
    }

    private func makeFrequentItem(_ url: URL) -> FileItem {
        FileItem(
            url: url,
            role: .frequent,
            subtitleOverride: FrequentStore.subtitle(for: url)
        )
    }

    private func rebuildLevel0() {
        let focusedURL: URL? = {
            if focus.level == 0, levels.indices.contains(0), levels[0].items.indices.contains(focus.index) {
                return levels[0].items[focus.index].url
            }
            return nil
        }()
        let pathURL: URL? = {
            if levels.indices.contains(0),
               let idx = pathIndices[0],
               levels[0].items.indices.contains(idx) {
                return levels[0].items[idx].url
            }
            return nil
        }()

        let rootItems = shortcutStore.shortcuts.map(makeRootItem)
        let rootURLs = shortcutStore.shortcuts.map(\.url)
        let rootPaths = Set(rootURLs.map(\.path))
        let frequentItems: [FileItem]
        if UserDefaults.standard.showFrequentSection {
            frequentItems = frequentStore
                .topItems(within: rootURLs, excluding: rootPaths, limit: UserDefaults.standard.frequentDisplayLimit)
                .map(makeFrequentItem)
        } else {
            frequentItems = []
        }

        let items: [FileItem]
        let sections: [Section]
        if frequentItems.isEmpty {
            items = rootItems
            sections = []
        } else {
            items = frequentItems + rootItems
            var builtSections: [Section] = [
                Section(title: "Frequent", range: 0..<frequentItems.count)
            ]
            if !rootItems.isEmpty {
                builtSections.append(Section(title: "Shortcuts", range: frequentItems.count..<items.count))
            }
            sections = builtSections
        }

        if levels.isEmpty {
            levels = [Level(source: nil, content: .folder(items: items, sections: sections, rowFrames: [:]))]
        } else {
            levels[0].setContents(items, sections)
        }

        if let focusedURL, let newIdx = items.firstIndex(where: { $0.url == focusedURL }) {
            focus = Focus(level: 0, index: newIdx)
        } else if focus.level == 0 {
            focus = Focus(level: 0, index: min(focus.index, max(items.count - 1, Focus.noFocus)))
        }

        if let pathURL {
            if let newIdx = items.firstIndex(where: { $0.url == pathURL }) {
                pathIndices[0] = newIdx
            } else {
                pathIndices[0] = nil
                closeDeeperThan(0)
            }
        }
        // Watch directory shortcuts so drilling in reflects live changes.
        // File shortcuts don't need watching (no folder listing to refresh).
        updateFilterHighlight(forLevel: 0)
        installWatchersForLevel0()
    }

    private func installWatchersForLevel0() {
        let folderShortcuts = shortcutStore.shortcuts.filter { $0.url.hasDirectoryPath }
        let paths = folderShortcuts.map { $0.url.standardizedFileURL.path }
        guard paths != level0WatcherPaths else { return }

        var ws: [FolderWatcher] = []
        for shortcut in folderShortcuts {
            ws.append(FolderWatcher(url: shortcut.url) { [weak self] in
                self?.folderDidChange(url: shortcut.url)
            })
        }
        watchers[0] = ws
        level0WatcherPaths = paths
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
        if level == 0 { level0WatcherPaths = [] }
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
        levels[level].setContents(result.items,
                                  result.sections,
                                  totalSize: result.totalSize,
                                  sourceModifiedAt: result.sourceModifiedAt,
                                  readError: result.readError)
        updateFilterHighlight(forLevel: level)

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
        let item = levels[level].items[index]
        let target = PendingHoverTarget(level: level, index: index, url: item.url)

        if pendingOpen != nil,
           pendingHoverTarget == target,
           focus.level == level,
           focus.index == index {
            return
        }

        focus = Focus(level: level, index: index)
        cancelPendingOpen()

        // Broken root shortcut → no peek, just trim any deeper stale window.
        if level == 0, item.role == .rootShortcut, !item.exists {
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
                guard let self else { return }
                self.pendingOpen = nil
                self.pendingHoverTarget = nil
                self.openFolderPeek(atLevel: level + 1, folder: url, parentIndex: index)
            }
            pendingHoverTarget = target
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
                guard let self else { return }
                self.pendingOpen = nil
                self.pendingHoverTarget = nil
                self.openPreviewPeek(atLevel: level + 1, url: url, kind: kind, parentIndex: index)
            }
            pendingHoverTarget = target
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
        cancelPendingOpen()
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
        let visible = visibleIndices(forLevel: l)
        cancelPendingOpen()
        pendingClose?.cancel(); pendingClose = nil
        guard !visible.isEmpty else {
            setKeyboardFocus(Focus(level: l, index: Focus.noFocus))
            return
        }
        // No visible focus yet -> up jumps to the last visible item.
        let next: Int
        if let position = visible.firstIndex(of: focus.index) {
            next = visible[max(0, position - 1)]
        } else {
            next = visible.last ?? Focus.noFocus
        }
        setKeyboardFocus(Focus(level: l, index: next))
    }

    func keyDown() {
        let l = focus.level
        guard levels.indices.contains(l) else { return }
        let visible = visibleIndices(forLevel: l)
        cancelPendingOpen()
        pendingClose?.cancel(); pendingClose = nil
        guard !visible.isEmpty else {
            setKeyboardFocus(Focus(level: l, index: Focus.noFocus))
            return
        }
        // No visible focus yet -> down jumps to the first visible item.
        let next: Int
        if let position = visible.firstIndex(of: focus.index) {
            next = visible[min(visible.count - 1, position + 1)]
        } else {
            next = visible.first ?? Focus.noFocus
        }
        setKeyboardFocus(Focus(level: l, index: next))
    }

    func keyRight() { keyboardDrillIn() }
    func keyLeft()  { keyboardDrillOut() }

    func hasPreviewChild(ofLevel level: Int) -> Bool {
        levels.indices.contains(level + 1) && levels[level + 1].isPreview
    }

    func keyReturn() {
        let l = focus.level
        guard levels.indices.contains(l),
              levels[l].items.indices.contains(focus.index),
              isIndexVisible(focus.index, forLevel: l) else { return }
        let item = levels[l].items[focus.index]
        if l == 0, item.role == .rootShortcut, !item.exists {
            handleMissingShortcut(url: item.url)
            return
        }
        if item.isDirectory {
            keyboardDrillIn()
        } else {
            frequentStore.recordAccess(item.url)
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
              levels[l].items.indices.contains(focus.index),
              isIndexVisible(focus.index, forLevel: l) else { return }
        let item = levels[l].items[focus.index]
        cancelPendingOpen()
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
        cancelPendingOpen()
        let l = focus.level
        // If a preview is open one level deeper, ← closes just the preview
        // and leaves focus on the current folder listing. If the deeper level
        // is a folder peek (or nothing), ← collapses back to the parent.
        if hasPreviewChild(ofLevel: l) {
            closeDeeperThan(l)
            return
        }
        if l == 0 { onDismiss(); return }
        closeDeeperThan(l - 1)
    }

    // MARK: - Spring-loaded folders (drag hover opens peek)

    /// Called when a drag hovers a folder row long enough. Opens the peek
    /// immediately (no open delay — the spring-load delay already fired).
    func springLoadFolder(level: Int, index: Int) {
        guard levels.indices.contains(level),
              levels[level].items.indices.contains(index) else { return }
        let item = levels[level].items[index]
        guard item.isDirectory else { return }
        cancelPendingOpen()
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
        if level == 0, item.role == .rootShortcut, !item.exists {
            handleMissingShortcut(url: item.url)
            return
        }
        // Everything opens in the default app on click — folders open in
        // Finder, files in their associated app. Hover handles peeks.
        frequentStore.recordAccess(item.url)
        NSWorkspace.shared.open(item.url)
        onDismiss()
    }

    /// Called from the preview window header "Open" button. Records access
    /// (for Frequent ranking) and opens the file in its default app.
    func openPreviewedFile(url: URL) {
        frequentStore.recordAccess(url)
        NSWorkspace.shared.open(url)
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

    private func openFolderPeek(atLevel level: Int, folder: URL, parentIndex: Int, allowAnchorRetry: Bool = true) {
        guard let anchor = parentAnchor(forLevel: level, parentIndex: parentIndex) else {
            if allowAnchorRetry {
                DispatchQueue.main.async { [weak self] in
                    self?.openFolderPeek(atLevel: level,
                                         folder: folder,
                                         parentIndex: parentIndex,
                                         allowAnchorRetry: false)
                }
            } else {
                closeDeeperThan(level - 1)
            }
            return
        }
        closePeeks(atLevelsGreaterThan: level)
        // Install a placeholder level with empty contents; present the peek
        // immediately so hover feels instant. If this level already exists,
        // PeekWindowManager reuses that window and animates it into place.
        let placeholder = Level(source: folder, content: .folder(items: [], sections: [], rowFrames: [:]), isLoading: true)
        guard installLevel(placeholder, atLevel: level, parentIndex: parentIndex) else { return }
        installWatcher(forLevel: level, url: folder)
        let content = AnyView(LevelListView(level: level, model: self))
        presentPeek(atLevel: level,
                    anchor: anchor,
                    size: peekManager.defaultSize,
                    widthPolicy: .flexible(minWidth: peekManager.minimumFolderWidth),
                    content: content)

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
                                           sourceModifiedAt: result.sourceModifiedAt,
                                           readError: result.readError)
        }
    }

    private func openPreviewPeek(atLevel level: Int, url: URL, kind: PreviewKind, parentIndex: Int, allowAnchorRetry: Bool = true) {
        guard let anchor = parentAnchor(forLevel: level, parentIndex: parentIndex) else {
            if allowAnchorRetry {
                DispatchQueue.main.async { [weak self] in
                    self?.openPreviewPeek(atLevel: level,
                                          url: url,
                                          kind: kind,
                                          parentIndex: parentIndex,
                                          allowAnchorRetry: false)
                }
            } else {
                closeDeeperThan(level - 1)
            }
            return
        }
        closePeeks(atLevelsGreaterThan: level)
        removeWatchers(forLevel: level)
        let state = Level(source: url, content: .preview(kind: kind, url: url))
        guard installLevel(state, atLevel: level, parentIndex: parentIndex) else { return }
        let content = AnyView(PreviewLevelView(level: level, url: url, kind: kind, model: self))
        presentPeek(atLevel: level,
                    anchor: anchor,
                    size: PeekWindowManager.previewSize(for: url, kind: kind),
                    content: content)
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

    private func presentPeek(atLevel level: Int,
                             anchor: NSRect,
                             size: NSSize,
                             widthPolicy: PeekWindowManager.WidthPolicy = .fixed,
                             content: AnyView) {
        peekManager.present(atLevel: level,
                            anchor: anchor,
                            size: size,
                            widthPolicy: widthPolicy,
                            content: content)
    }

    private func parentAnchor(forLevel level: Int, parentIndex: Int) -> NSRect? {
        guard levels.indices.contains(level - 1),
              let anchor = levels[level - 1].rowFrames[parentIndex],
              !anchor.isEmpty else { return nil }
        return anchor
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
        cancelPendingOpen()
        pendingClose?.cancel(); pendingClose = nil
        closePeeks(atLevelsGreaterThan: 0)
        focus = Focus(level: 0, index: -1)
    }

    // Convenience: the focused level-0 shortcut, if any.
    var focusedRootShortcut: RootShortcut? {
        guard focus.level == 0,
              levels.indices.contains(0),
              levels[0].items.indices.contains(focus.index) else { return nil }
        return shortcutStore.shortcut(for: levels[0].items[focus.index].url)
    }

    func moveRoot(from: Int, to: Int) {
        shortcutStore.move(from: from, to: to)
    }

    func addToRoot(_ url: URL) {
        shortcutStore.add(url)
    }

    func setRootDisplayName(_ displayName: String?, for url: URL) {
        shortcutStore.setAlias(displayName, for: url)
    }

    func replaceRootShortcut(oldURL: URL, newURL: URL) {
        shortcutStore.replace(oldURL: oldURL, newURL: newURL)
    }

    func isInRoot(_ url: URL) -> Bool {
        shortcutStore.shortcuts.contains { $0.url == url }
    }
}
