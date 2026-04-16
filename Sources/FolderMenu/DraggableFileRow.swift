import AppKit
import SwiftUI
import CoreServices

// MARK: - Selection state (Cmd-click multi-select for drag-out)

class SelectionState: ObservableObject {
    @Published var selectedURLs: Set<URL> = []

    func toggle(_ url: URL) {
        if selectedURLs.contains(url) { selectedURLs.remove(url) }
        else { selectedURLs.insert(url) }
    }
    func clear() { selectedURLs = [] }
    func isSelected(_ url: URL) -> Bool { selectedURLs.contains(url) }
}

// MARK: - Row icon (tries QL thumbnail, falls back to NSWorkspace icon)

struct RowIconView: View {
    let item: FileItem
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? item.icon)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .onAppear(perform: load)
            .onChange(of: item.url) { _ in
                thumbnail = nil
                load()
            }
    }

    private func load() {
        // Only request thumbnails for previewable files — everything else
        // would just produce the generic icon we're already showing.
        guard !item.isDirectory, item.previewKind != nil else { return }
        if let cached = ThumbnailCache.shared.cached(for: item.url) {
            thumbnail = cached
            return
        }
        let url = item.url
        ThumbnailCache.shared.thumbnail(for: url) { img in
            // Guard against row reuse: only accept the image if our URL
            // hasn't changed.
            if item.url == url { self.thumbnail = img }
        }
    }
}

// MARK: - Row content (pure visual; highlights from props only)

struct FileRowContent: View {
    let item: FileItem
    @ObservedObject var selectionState: SelectionState
    let isFocused: Bool
    let isOnPath: Bool

    var isSelected: Bool { selectionState.isSelected(item.url) }

    var highlightColor: Color {
        if isFocused  { return Color.accentColor.opacity(0.30) }
        if isOnPath   { return Color.accentColor.opacity(0.22) }
        if isSelected { return Color.accentColor.opacity(0.25) }
        return Color.clear
    }

    var body: some View {
        HStack(spacing: 8) {
            RowIconView(item: item)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                subtitleView
            }

            Spacer()

            if item.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(highlightColor)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var subtitleView: some View {
        let parts: [String?] = item.imageDimensions != nil
            ? [item.fileSize, item.imageDimensions]
            : (!item.isDirectory ? [item.fileSize] : [])
        let subtitle = parts.compactMap { $0 }.joined(separator: "  ·  ")
        if !subtitle.isEmpty {
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - NSView handling drag + click + context menu
//
// No hover tracking here. The window-level WindowMouseTracker owns hover.

class DraggableNSView: NSView, NSDraggingSource {
    var fileItem: FileItem?
    var onTap: (() -> Void)?
    var selectionState: SelectionState?
    var parentFolder: URL?
    var removeFromRootHandler: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var dragStarted = false
    private var isDropTarget = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }

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

    // Clicks in non-key windows (peek) register as-is rather than being
    // swallowed by window activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .move]
    }

    // MARK: - Drop target (folder rows accept file drops)

    private func incomingURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
    }

    /// Only folder rows accept drops, and only for URLs that don't land inside
    /// their own subtree.
    private func acceptableDrop(_ sender: NSDraggingInfo) -> (URLs: [URL], dest: URL)? {
        guard let item = fileItem, item.isDirectory else { return nil }
        let urls = incomingURLs(sender).filter { src in
            // Reject self-drops and drops into own subtree.
            src != item.url && !item.url.path.hasPrefix(src.path + "/")
        }
        guard !urls.isEmpty else { return nil }
        return (urls, item.url)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (urls, dest) = acceptableDrop(sender) else { return [] }
        isDropTarget = true
        return FileDropHelper.preferredOperation(sources: urls, dest: dest)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let (urls, dest) = acceptableDrop(sender) else { return [] }
        return FileDropHelper.preferredOperation(sources: urls, dest: dest)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        acceptableDrop(sender) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let (urls, dest) = acceptableDrop(sender) else { return false }
        let op = FileDropHelper.preferredOperation(sources: urls, dest: dest)
        let n = FileDropHelper.perform(urls: urls, into: dest, operation: op)
        isDropTarget = false
        return n > 0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if isDropTarget {
            let inset = bounds.insetBy(dx: 3, dy: 2)
            let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
    }

    // MARK: Mouse

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

    override func rightMouseDown(with event: NSEvent) {
        guard let item = fileItem else { return }
        let menu = NSMenu()

        let urlsToAct: [URL] = {
            if let sel = selectionState, sel.isSelected(item.url), sel.selectedURLs.count > 1 {
                return Array(sel.selectedURLs)
            }
            return [item.url]
        }()

        let openTitle = urlsToAct.count > 1 ? "Open \(urlsToAct.count) Items" : "Open"
        menu.addItem(withTitle: openTitle, action: #selector(openFiles), keyEquivalent: "").target = self

        // Quick Look — single file only (directories fall back to Finder).
        if urlsToAct.count == 1, !item.isDirectory {
            menu.addItem(withTitle: "Quick Look", action: #selector(showQuickLook), keyEquivalent: " ").target = self
        }

        if urlsToAct.count == 1 {
            menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "").target = self

            if !item.isDirectory, let openWithMenu = buildOpenWithMenu(for: item.url) {
                let owItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                owItem.submenu = openWithMenu
                menu.addItem(owItem)
            }
        }

        menu.addItem(.separator())

        // Share… — system-provided submenu (AirDrop, Mail, Messages, …).
        if !urlsToAct.isEmpty {
            let picker = NSSharingServicePicker(items: urlsToAct)
            let shareItem = picker.standardShareMenuItem
            menu.addItem(shareItem)
            menu.addItem(.separator())
        }

        let copyTitle = urlsToAct.count > 1 ? "Copy \(urlsToAct.count) Items" : "Copy"
        menu.addItem(withTitle: copyTitle, action: #selector(copyFiles), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self
        if urlsToAct.count == 1 {
            menu.addItem(withTitle: "Copy Name", action: #selector(copyName), keyEquivalent: "").target = self
        }

        if urlsToAct.count == 1, let dims = item.imageDimensions {
            menu.addItem(withTitle: "Copy Dimensions (\(dims))", action: #selector(copyDimensions), keyEquivalent: "").target = self
        }

        // Pin / Unpin (only in folder levels, not level 0 roots).
        if urlsToAct.count == 1, let folder = parentFolder {
            let pinned = PinStore.shared.isPinned(item.url, in: folder)
            let pinItem = menu.addItem(
                withTitle: pinned ? "Unpin" : "Pin to Top",
                action: #selector(togglePin),
                keyEquivalent: ""
            )
            pinItem.target = self
        }

        menu.addItem(.separator())
        let trashTitle = urlsToAct.count > 1 ? "Move \(urlsToAct.count) Items to Trash" : "Move to Trash"
        let trashItem = menu.addItem(withTitle: trashTitle, action: #selector(moveToTrash), keyEquivalent: "\u{8}") // backspace
        trashItem.keyEquivalentModifierMask = [.command]
        trashItem.target = self

        // Root-folder rows get a "Remove from FolderMenu" item.
        if removeFromRootHandler != nil {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Remove from FolderMenu",
                         action: #selector(removeFromRoot),
                         keyEquivalent: "").target = self
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }


    // MARK: Actions

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

    @objc private func openWithApp(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [URL], pair.count == 2 else { return }
        NSWorkspace.shared.open([pair[0]], withApplicationAt: pair[1],
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openFiles() {
        let urls: [URL] = {
            if let sel = selectionState, sel.isSelected(fileItem?.url ?? URL(fileURLWithPath: "")), sel.selectedURLs.count > 1 {
                return Array(sel.selectedURLs)
            }
            return [fileItem?.url].compactMap { $0 }
        }()
        for url in urls { NSWorkspace.shared.open(url) }
    }

    @objc private func showInFinder() {
        guard let url = fileItem?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func copyPath() {
        guard let url = fileItem?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    @objc private func copyName() {
        guard let url = fileItem?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.lastPathComponent, forType: .string)
    }

    @objc private func copyFiles() {
        let urls = currentActionURLs()
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
    }

    @objc private func moveToTrash() {
        let urls = currentActionURLs()
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls, completionHandler: nil)
    }

    @objc private func showQuickLook() {
        guard let url = fileItem?.url, !url.hasDirectoryPath else { return }
        QuickLookManager.shared.show(urls: [url])
    }

    /// URLs the context menu should act on: the multi-selection if this row
    /// is part of it, otherwise just this row's URL.
    private func currentActionURLs() -> [URL] {
        guard let item = fileItem else { return [] }
        if let sel = selectionState, sel.isSelected(item.url), sel.selectedURLs.count > 1 {
            return Array(sel.selectedURLs)
        }
        return [item.url]
    }

    @objc private func togglePin() {
        guard let item = fileItem, let folder = parentFolder else { return }
        PinStore.shared.togglePin(item.url, in: folder)
    }

    @objc private func copyDimensions() {
        guard let dims = fileItem?.imageDimensions else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dims, forType: .string)
    }

    @objc private func removeFromRoot() {
        removeFromRootHandler?()
    }
}

// MARK: - SwiftUI wrapper

struct DraggableFileRow: NSViewRepresentable {
    let item: FileItem
    let onTap: () -> Void
    @ObservedObject var selectionState: SelectionState
    var isFocused: Bool = false
    var isOnPath: Bool = false
    var parentFolder: URL? = nil
    var removeFromRootHandler: (() -> Void)? = nil

    func makeNSView(context: Context) -> DraggableNSView {
        let view = DraggableNSView()
        view.fileItem = item
        view.onTap = onTap
        view.selectionState = selectionState
        view.parentFolder = parentFolder
        view.removeFromRootHandler = removeFromRootHandler

        let hosting = NSHostingView(rootView: makeContent())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
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
        nsView.selectionState = selectionState
        nsView.parentFolder = parentFolder
        nsView.removeFromRootHandler = removeFromRootHandler
        if let hosting = nsView.subviews.first as? NSHostingView<FileRowContent> {
            hosting.rootView = makeContent()
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
