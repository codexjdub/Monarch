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
            Image(nsImage: item.icon)
                .resizable()
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
    var removeFromRootHandler: (() -> Void)?

    private var mouseDownEvent: NSEvent?
    private var dragStarted = false

    override var acceptsFirstResponder: Bool { true }

    // Clicks in non-key windows (peek) register as-is rather than being
    // swallowed by window activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return [.copy, .move]
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

        if urlsToAct.count == 1 {
            menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder), keyEquivalent: "").target = self

            if !item.isDirectory, let openWithMenu = buildOpenWithMenu(for: item.url) {
                let owItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
                owItem.submenu = openWithMenu
                menu.addItem(owItem)
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy Path", action: #selector(copyPath), keyEquivalent: "").target = self

        if urlsToAct.count == 1, let dims = item.imageDimensions {
            menu.addItem(withTitle: "Copy Dimensions (\(dims))", action: #selector(copyDimensions), keyEquivalent: "").target = self
        }

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
    var removeFromRootHandler: (() -> Void)? = nil

    func makeNSView(context: Context) -> DraggableNSView {
        let view = DraggableNSView()
        view.fileItem = item
        view.onTap = onTap
        view.selectionState = selectionState
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
