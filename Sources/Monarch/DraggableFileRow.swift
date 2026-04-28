import AppKit
import SwiftUI
import CoreServices

// MARK: - NSView handling drag + click + context menu
//
// Row hover is handled here directly. The window-level WindowMouseTracker is
// still responsible for window enter/exit and cascade close timing.
//
// Stored properties live in the class body (Swift extensions can't add them).
// Behavior is grouped into extensions below: Mouse & Drag Source, Drop Target,
// Context Menu, Context Menu Actions.

class DraggableNSView: NSView, NSDraggingSource {

    // MARK: Configuration (set by DraggableFileRow wrapper)

    var fileItem: FileItem?
    var onTap: (() -> Void)?
    var onHover: (() -> Void)?
    var selectionState: SelectionState?
    var parentFolder: URL?
    var removeFromRootHandler: (() -> Void)?
    var replaceRootHandler: ((URL, URL) -> Void)?
    var updateRootDisplayNameHandler: ((URL, String?) -> Void)?
    var addToRootHandler: ((URL) -> Void)?
    var hideFromFrequentHandler: (() -> Void)?
    /// Called when a drag hovers this folder row long enough to spring-load.
    var onSpringLoad: (() -> Void)?

    // MARK: Mouse / drag state

    fileprivate var mouseDownEvent: NSEvent?
    fileprivate var dragStarted = false
    fileprivate var hoverTrackingArea: NSTrackingArea?
    fileprivate var rowIsFocused = false
    fileprivate var rowIsOnPath = false
    fileprivate var rowIsSelected = false

    // MARK: Drop target state

    fileprivate var isDropTarget = false { didSet { needsDisplay = true } }
    fileprivate var springLoadTimer: DispatchWorkItem?
    fileprivate static let springLoadDelay: TimeInterval = 0.5

    // MARK: Boilerplate

    override var acceptsFirstResponder: Bool { true }
    // Clicks in non-key windows (peek) register as-is rather than being
    // swallowed by window activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        syncHoverIfInside()
    }

    func setRowHighlight(isFocused: Bool, isOnPath: Bool, isSelected: Bool) {
        rowIsFocused = isFocused
        rowIsOnPath = isOnPath
        rowIsSelected = isSelected
        updateRowHighlight()
    }

    private func updateRowHighlight() {
        let color: NSColor
        if rowIsFocused {
            color = NSColor.controlAccentColor.withAlphaComponent(0.30)
        } else if rowIsOnPath {
            color = NSColor.controlAccentColor.withAlphaComponent(0.22)
        } else if rowIsSelected {
            color = NSColor.controlAccentColor.withAlphaComponent(0.25)
        } else {
            color = .clear
        }
        layer?.backgroundColor = color.cgColor
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    private func syncHoverIfInside() {
        guard let window, window.isVisible else { return }
        let mouseInWin = window.mouseLocationOutsideOfEventStream
        let localPoint = convert(mouseInWin, from: nil)
        guard bounds.contains(localPoint) else { return }
        onHover?()
    }
}

// MARK: - Mouse & drag source

extension DraggableNSView /* Mouse & Drag Source */ {

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        [.copy, .move]
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted,
              let item = fileItem,
              let downEvent = mouseDownEvent else { return }

        let a = downEvent.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        dragStarted = true

        let urlsToDrag: [URL]
        if let sel = selectionState, sel.isSelected(item.url), !sel.selectedURLs.isEmpty {
            urlsToDrag = Array(sel.selectedURLs)
        } else {
            urlsToDrag = [item.url]
        }

        let draggingItems: [NSDraggingItem] = urlsToDrag.enumerated().map { index, url in
            let di = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            let offset = CGFloat(index) * 2
            di.setDraggingFrame(
                NSRect(x: offset, y: -offset, width: bounds.width, height: bounds.height),
                contents: icon
            )
            return di
        }
        beginDraggingSession(with: draggingItems, event: downEvent, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragStarted {
            let commandHeld = event.modifierFlags.contains(.command)
            if commandHeld {
                if let url = fileItem?.url { selectionState?.toggle(url) }
            } else {
                selectionState?.clear()
                onTap?()
            }
        }
        mouseDownEvent = nil
        dragStarted = false
    }
}

// MARK: - Drop target

extension DraggableNSView /* Drop Target */ {

    private func incomingURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    /// Only folder rows accept drops, and only for URLs that don't land inside
    /// their own subtree.
    private func acceptableDrop(_ sender: NSDraggingInfo) -> (URLs: [URL], dest: URL)? {
        guard let item = fileItem, item.isDirectory else { return nil }
        let urls = incomingURLs(sender).filter { src in
            src != item.url && !item.url.path.hasPrefix(src.path + "/")
        }
        guard !urls.isEmpty else { return nil }
        return (urls, item.url)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (urls, dest) = acceptableDrop(sender) else { return [] }
        isDropTarget = true
        scheduleSpringLoad()
        return FileDropHelper.preferredOperation(sources: urls, dest: dest)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (urls, dest) = acceptableDrop(sender) else { return [] }
        return FileDropHelper.preferredOperation(sources: urls, dest: dest)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
        cancelSpringLoad()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
        cancelSpringLoad()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptableDrop(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (urls, dest) = acceptableDrop(sender) else { return false }
        let op = FileDropHelper.preferredOperation(sources: urls, dest: dest)
        isDropTarget = false
        flashDropAccepted()

        // Run copy/move work off-main so large or cross-volume drops don't
        // freeze the popover. The drag system needs a synchronous Bool here,
        // so we optimistically report success — failures surface as an alert
        // once the work finishes (Finder behaves the same way).
        Task.detached(priority: .userInitiated) {
            let n = FileDropHelper.perform(urls: urls, into: dest, operation: op)
            let failed = urls.count - n
            guard failed > 0 else { return }
            await MainActor.run {
                let alert = NSAlert()
                alert.messageText = failed == urls.count
                    ? "The operation couldn't be completed."
                    : "\(failed) of \(urls.count) items couldn't be moved."
                alert.informativeText = "You may not have permission to write to \"\(dest.lastPathComponent)\"."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isDropTarget else { return }
        let inset = bounds.insetBy(dx: 3, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    /// Brief accent-color flash on the row's backing layer to confirm a drop
    /// was accepted. Distinct from the drop-target highlight (which only
    /// shows during hover) so the user gets a clear "received it" signal even
    /// after they've released the drag.
    private func flashDropAccepted() {
        wantsLayer = true
        guard let layer else { return }
        let accent = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
        let pulse = CABasicAnimation(keyPath: "backgroundColor")
        pulse.fromValue = accent
        pulse.toValue = NSColor.clear.cgColor
        pulse.duration = 0.40
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(pulse, forKey: "dropAcceptedFlash")
    }

    // MARK: Spring-load

    private func scheduleSpringLoad() {
        cancelSpringLoad()
        guard fileItem?.isDirectory == true, onSpringLoad != nil else { return }
        let task = DispatchWorkItem { [weak self] in self?.onSpringLoad?() }
        springLoadTimer = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.springLoadDelay, execute: task)
    }

    private func cancelSpringLoad() {
        springLoadTimer?.cancel()
        springLoadTimer = nil
    }
}

// MARK: - Context menu

extension DraggableNSView /* Context Menu */ {

    private enum ContextMenuKind {
        case multiSelection
        case rootShortcut
        case frequent
        case standard
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let item = fileItem else { return }
        let urlsToAct = contextMenuURLs(for: item)
        let menu = buildContextMenu(for: item, urlsToAct: urlsToAct)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func contextMenuURLs(for item: FileItem) -> [URL] {
        if let sel = selectionState, sel.isSelected(item.url), sel.selectedURLs.count > 1 {
            return Array(sel.selectedURLs)
        }
        return [item.url]
    }

    private func buildContextMenu(for item: FileItem, urlsToAct: [URL]) -> NSMenu {
        let menu = NSMenu()
        switch contextMenuKind(for: item, urlsToAct: urlsToAct) {
        case .multiSelection:
            appendSection(to: menu) { self.addOpenItems(to: menu, item: item, urlsToAct: urlsToAct, includeFinderAndAppActions: false) }
            appendSection(to: menu) { self.addCopyAndShareItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addTrashItem(to: menu, urlsToAct: urlsToAct) }
        case .rootShortcut:
            appendSection(to: menu) { self.addOpenItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addCopyAndShareItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addDisplayNameItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addFileManagementItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addTrashItem(to: menu, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addRemoveFromMonarchItem(to: menu) }
        case .frequent:
            appendSection(to: menu) { self.addOpenItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addCopyAndShareItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addMonarchItems(to: menu, item: item, urlsToAct: urlsToAct, includePin: false) }
            appendSection(to: menu) { self.addFileManagementItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addTrashItem(to: menu, urlsToAct: urlsToAct) }
        case .standard:
            appendSection(to: menu) { self.addOpenItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addCopyAndShareItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addMonarchItems(to: menu, item: item, urlsToAct: urlsToAct, includePin: true) }
            appendSection(to: menu) { self.addFileManagementItems(to: menu, item: item, urlsToAct: urlsToAct) }
            appendSection(to: menu) { self.addTrashItem(to: menu, urlsToAct: urlsToAct) }
        }
        return menu
    }

    private func contextMenuKind(for item: FileItem, urlsToAct: [URL]) -> ContextMenuKind {
        if urlsToAct.count > 1 { return .multiSelection }
        switch item.role {
        case .rootShortcut: return .rootShortcut
        case .frequent: return .frequent
        case .standard: return .standard
        }
    }

    private func appendSection(to menu: NSMenu, builder: () -> Void) {
        let insertionIndex = menu.items.count
        builder()
        guard menu.items.count > insertionIndex else { return }
        if insertionIndex > 0 {
            menu.insertItem(.separator(), at: insertionIndex)
        }
    }

    private func addOpenItems(to menu: NSMenu,
                              item: FileItem,
                              urlsToAct: [URL],
                              includeQuickLook: Bool = true,
                              includeFinderAndAppActions: Bool = true) {
        let openTitle = urlsToAct.count > 1 ? "Open \(urlsToAct.count) Items" : "Open"
        menu.addItem(withTitle: openTitle, action: #selector(openFiles), keyEquivalent: "").target = self

        if includeQuickLook {
            let previewableCount = urlsToAct.filter { !isDirectoryURL($0) }.count
            if previewableCount == 1, urlsToAct.count == 1, !item.isDirectory {
                menu.addItem(withTitle: "Quick Look", action: #selector(showQuickLook), keyEquivalent: " ").target = self
            } else if previewableCount > 0, urlsToAct.count > 1 {
                let title = previewableCount == urlsToAct.count
                    ? "Quick Look \(urlsToAct.count) Items"
                    : "Quick Look \(previewableCount) Files"
                menu.addItem(withTitle: title, action: #selector(showQuickLook), keyEquivalent: " ").target = self
            }
        }

        guard includeFinderAndAppActions, urlsToAct.count == 1 else { return }
        menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "").target = self
        if !item.isDirectory, let openWithMenu = buildOpenWithMenu(for: item.url) {
            let owItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            owItem.submenu = openWithMenu
            menu.addItem(owItem)
        }
        if item.isDirectory {
            let terminalName = TerminalApp.resolved().rawValue
            menu.addItem(withTitle: "Open in \(terminalName)", action: #selector(openInTerminal), keyEquivalent: "").target = self
        }
    }

    private func addCopyAndShareItems(to menu: NSMenu, item: FileItem, urlsToAct: [URL]) {
        let copyTitle = urlsToAct.count > 1 ? "Copy \(urlsToAct.count) Items" : "Copy"
        menu.addItem(withTitle: copyTitle, action: #selector(copyFiles), keyEquivalent: "").target = self
        let copyPathTitle = urlsToAct.count > 1 ? "Copy Paths" : "Copy Path"
        menu.addItem(withTitle: copyPathTitle, action: #selector(copyPath), keyEquivalent: "").target = self
        if urlsToAct.count == 1 {
            menu.addItem(withTitle: "Copy Name", action: #selector(copyName), keyEquivalent: "").target = self
        }
        if urlsToAct.count == 1, let dims = item.imageDimensions {
            menu.addItem(withTitle: "Copy Dimensions (\(dims))", action: #selector(copyDimensions), keyEquivalent: "").target = self
        }
        if !urlsToAct.isEmpty {
            menu.addItem(NSSharingServicePicker(items: urlsToAct).standardShareMenuItem)
        }
    }

    private func addMonarchItems(to menu: NSMenu, item: FileItem, urlsToAct: [URL], includePin: Bool) {
        if includePin, urlsToAct.count == 1, let folder = parentFolder {
            let pinned = PinStore.shared.isPinned(item.url, in: folder)
            menu.addItem(withTitle: pinned ? "Unpin" : "Pin to Top",
                         action: #selector(togglePin),
                         keyEquivalent: "").target = self
        }
        if addToRootHandler != nil, urlsToAct.count == 1 {
            menu.addItem(withTitle: "Add to Monarch", action: #selector(addToRoot), keyEquivalent: "").target = self
        }
        if hideFromFrequentHandler != nil, urlsToAct.count == 1 {
            menu.addItem(withTitle: "Hide from Frequent", action: #selector(hideFromFrequent), keyEquivalent: "").target = self
        }
    }

    private func addFileManagementItems(to menu: NSMenu, item: FileItem, urlsToAct: [URL]) {
        guard urlsToAct.count == 1 || parentFolder != nil else { return }
        if urlsToAct.count == 1, item.isDirectory {
            menu.addItem(withTitle: "New Folder Inside", action: #selector(newFolderInsideAction), keyEquivalent: "").target = self
        }
        if parentFolder != nil {
            menu.addItem(withTitle: "New Folder Here", action: #selector(newFolderHereAction), keyEquivalent: "").target = self
        }
        if urlsToAct.count == 1 {
            menu.addItem(withTitle: "Rename…", action: #selector(renameAction), keyEquivalent: "").target = self
        }
    }

    private func addDisplayNameItems(to menu: NSMenu, item: FileItem, urlsToAct: [URL]) {
        guard urlsToAct.count == 1, updateRootDisplayNameHandler != nil else { return }
        let title = item.displayNameOverride == nil ? "Set Display Name…" : "Edit Display Name…"
        menu.addItem(withTitle: title, action: #selector(editDisplayNameAction), keyEquivalent: "").target = self
        if item.displayNameOverride != nil {
            menu.addItem(withTitle: "Clear Display Name", action: #selector(clearDisplayNameAction), keyEquivalent: "").target = self
        }
    }

    private func addTrashItem(to menu: NSMenu, urlsToAct: [URL]) {
        let trashTitle = urlsToAct.count > 1 ? "Move \(urlsToAct.count) Items to Trash" : "Move to Trash"
        let trashItem = menu.addItem(withTitle: trashTitle, action: #selector(moveToTrash), keyEquivalent: "\u{8}")
        trashItem.keyEquivalentModifierMask = [.command]
        trashItem.target = self
    }

    private func addRemoveFromMonarchItem(to menu: NSMenu) {
        guard removeFromRootHandler != nil else { return }
        menu.addItem(withTitle: "Remove from Monarch", action: #selector(removeFromRoot), keyEquivalent: "").target = self
    }

    private func buildOpenWithMenu(for url: URL) -> NSMenu? {
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let allApps = LSCopyApplicationURLsForURL(url as CFURL, .all)?
            .takeRetainedValue() as? [URL] ?? []

        var seen = Set<String>()
        var apps: [URL] = []
        if let d = defaultApp {
            let id = Bundle(url: d)?.bundleIdentifier ?? d.path
            if seen.insert(id).inserted { apps.append(d) }
        }
        for app in allApps {
            guard apps.count < 12 else { break }
            let id = Bundle(url: app)?.bundleIdentifier ?? app.path
            if seen.insert(id).inserted { apps.append(app) }
        }
        guard !apps.isEmpty else { return nil }

        let menu = NSMenu(title: "Open With")
        for (i, appURL) in apps.enumerated() {
            let name = FileManager.default.displayName(atPath: appURL.path)
            let isDefault = i == 0 && defaultApp != nil
            let item = NSMenuItem(
                title: isDefault ? "\(name) (default)" : name,
                action: #selector(openWithApp(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = [url, appURL] as NSArray
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        return menu
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue
        }
        return url.hasDirectoryPath
    }
}

// MARK: - Context menu actions

extension DraggableNSView /* Actions */ {

    /// URLs the context menu should act on: the multi-selection if this row
    /// is part of it, otherwise just this row's URL.
    private func currentActionURLs() -> [URL] {
        guard let item = fileItem else { return [] }
        if let sel = selectionState, sel.isSelected(item.url), sel.selectedURLs.count > 1 {
            return sel.selectedURLs.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        }
        return [item.url]
    }

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        FrequentStore.shared.recordAccess(pair[0])
        NSWorkspace.shared.open([pair[0]], withApplicationAt: pair[1],
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openFiles() {
        let urls = currentActionURLs()
        for url in urls {
            FrequentStore.shared.recordAccess(url)
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showQuickLook() {
        let urls = currentActionURLs().filter { !isDirectoryURL($0) }
        guard !urls.isEmpty else { return }
        QuickLookManager.shared.show(urls: urls)
    }

    @objc private func showInFinder() {
        guard let url = fileItem?.url else { return }
        FrequentStore.shared.recordAccess(url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openInTerminal() {
        guard let url = fileItem?.url, fileItem?.isDirectory == true else { return }
        FrequentStore.shared.recordAccess(url)
        TerminalApp.resolved().open(folder: url)
    }

    @objc private func copyFiles() {
        let urls = currentActionURLs()
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    @objc private func copyPath() {
        let urls = currentActionURLs()
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    @objc private func copyName() {
        guard let url = fileItem?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.lastPathComponent, forType: .string)
    }

    @objc private func copyDimensions() {
        guard let dims = fileItem?.imageDimensions else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dims, forType: .string)
    }

    @objc private func togglePin() {
        guard let item = fileItem, let folder = parentFolder else { return }
        PinStore.shared.togglePin(item.url, in: folder)
    }

    @objc private func addToRoot() {
        guard let url = fileItem?.url else { return }
        addToRootHandler?(url)
    }

    @objc private func hideFromFrequent() {
        hideFromFrequentHandler?()
    }

    @objc private func removeFromRoot() {
        removeFromRootHandler?()
    }

    @objc private func editDisplayNameAction() {
        guard let item = fileItem else { return }
        let alert = NSAlert()
        alert.messageText = "Display Name"
        alert.informativeText = "Shown only in Monarch. Leave it blank to use the real file or folder name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        input.placeholderString = item.name
        input.stringValue = item.displayNameOverride ?? ""
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let alias = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updateRootDisplayNameHandler?(item.url, alias.isEmpty ? nil : alias)
    }

    @objc private func clearDisplayNameAction() {
        guard let url = fileItem?.url else { return }
        updateRootDisplayNameHandler?(url, nil)
    }

    @objc private func moveToTrash() {
        let urls = currentActionURLs()
        guard !urls.isEmpty else { return }
        if urls.count == 1,
           fileItem?.role == .rootShortcut,
           removeFromRootHandler != nil {
            NSWorkspace.shared.recycle(urls) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let error {
                        self.showFileOperationError(title: "Couldn't Move to Trash", error: error)
                    } else {
                        self.removeFromRootHandler?()
                    }
                }
            }
            return
        }
        NSWorkspace.shared.recycle(urls, completionHandler: nil)
    }

    @objc private func renameAction() {
        guard let item = fileItem else { return }
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "Enter a new name for \"\(item.name)\"."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        input.stringValue = item.name
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != item.name else { return }

        let dest = item.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            if item.role == .rootShortcut {
                replaceRootHandler?(item.url, dest)
            }
        } catch {
            showFileOperationError(title: "Couldn't Rename", error: error)
        }
    }

    private func showFileOperationError(title: String, error: Error) {
        let err = NSAlert()
        err.messageText = title
        err.informativeText = error.localizedDescription
        err.runModal()
    }

    @objc private func newFolderInsideAction() {
        guard let dir = fileItem?.url, dir.hasDirectoryPath else { return }
        createNewFolder(in: dir)
    }

    @objc private func newFolderHereAction() {
        guard let dir = parentFolder else { return }
        createNewFolder(in: dir)
    }

    private func createNewFolder(in directory: URL) {
        let alert = NSAlert()
        alert.messageText = "New Folder"
        alert.informativeText = "Enter a name for the new folder."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        input.placeholderString = "New Folder"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = raw.isEmpty ? "New Folder" : raw

        var dest = directory.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: dest.path) {
            var i = 2
            repeat { dest = directory.appendingPathComponent("\(name) \(i)"); i += 1 }
            while FileManager.default.fileExists(atPath: dest.path)
        }

        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
        } catch {
            let err = NSAlert()
            err.messageText = "Couldn't Create Folder"
            err.informativeText = error.localizedDescription
            err.runModal()
        }
    }
}

// MARK: - SwiftUI wrapper

struct DraggableFileRow: NSViewRepresentable {
    let item: FileItem
    let onTap: () -> Void
    @ObservedObject var selectionState: SelectionState
    var isFocused: Bool = false
    var isOnPath: Bool = false
    var onHover: (() -> Void)? = nil
    var parentFolder: URL? = nil
    var onSpringLoad: (() -> Void)? = nil
    var removeFromRootHandler: (() -> Void)? = nil
    var replaceRootHandler: ((URL, URL) -> Void)? = nil
    var updateRootDisplayNameHandler: ((URL, String?) -> Void)? = nil
    var addToRootHandler: ((URL) -> Void)? = nil
    var hideFromFrequentHandler: (() -> Void)? = nil

    func makeNSView(context: Context) -> DraggableNSView {
        let view = DraggableNSView()
        view.fileItem = item
        view.onTap = onTap
        view.onHover = onHover
        view.selectionState = selectionState
        view.parentFolder = parentFolder
        view.onSpringLoad = onSpringLoad
        view.removeFromRootHandler = removeFromRootHandler
        view.replaceRootHandler = replaceRootHandler
        view.updateRootDisplayNameHandler = updateRootDisplayNameHandler
        view.addToRootHandler = addToRootHandler
        view.hideFromFrequentHandler = hideFromFrequentHandler

        let hosting = NSHostingView(rootView: makeContent())
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        view.setRowHighlight(
            isFocused: isFocused,
            isOnPath: isOnPath,
            isSelected: selectionState.isSelected(item.url)
        )
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    func updateNSView(_ nsView: DraggableNSView, context: Context) {
        nsView.fileItem = item
        nsView.onTap = onTap
        nsView.onHover = onHover
        nsView.selectionState = selectionState
        nsView.parentFolder = parentFolder
        nsView.onSpringLoad = onSpringLoad
        nsView.removeFromRootHandler = removeFromRootHandler
        nsView.replaceRootHandler = replaceRootHandler
        nsView.updateRootDisplayNameHandler = updateRootDisplayNameHandler
        nsView.addToRootHandler = addToRootHandler
        nsView.hideFromFrequentHandler = hideFromFrequentHandler
        nsView.setRowHighlight(
            isFocused: isFocused,
            isOnPath: isOnPath,
            isSelected: selectionState.isSelected(item.url)
        )
        if let hosting = nsView.subviews.first as? NSHostingView<FileRowContent> {
            hosting.rootView = makeContent()
            hosting.needsDisplay = true
        }
    }

    private func makeContent() -> FileRowContent {
        FileRowContent(
            item: item,
            selectionState: selectionState,
            isFocused: isFocused,
            isOnPath: isOnPath
        )
    }
}
