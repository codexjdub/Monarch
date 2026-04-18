import AppKit
import SwiftUI

private let kPopoverWidth  = "popoverWidth"
private let kPopoverHeight = "popoverHeight"

@MainActor
class StatusItemController: NSObject {
    private let store: ShortcutStore
    private var statusItem: NSStatusItem
    private var popover = NSPopover()
    private var sizeAtResizeStart: NSSize = .zero
    private let model: CascadeModel
    private var keyMonitor: Any?
    private var spaceMonitor: Any?
    private var dragBeginMonitor: Any?
    private var dragEndMonitor: Any?

    init(store: ShortcutStore) {
        self.store = store
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // onDismiss closes the whole UI. Passed a placeholder first; will replace below.
        var dismissRef: () -> Void = {}
        self.model = CascadeModel(folderStore: store, onDismiss: { dismissRef() })
        super.init()
        dismissRef = { [weak self] in
            self?.model.closeAll()
            self?.popover.performClose(nil)
        }

        // Wire "Remove from Monarch" directly — no NotificationCenter needed.
        model.onRemoveRoot = { [weak self] url in
            self?.store.remove(url)
        }

        setupButton()
        buildPopover()
        setupHotkey()
    }

    private func setupHotkey() {
        HotkeyManager.shared.onTrigger = { [weak self] in
            self?.togglePopover()
        }
        HotkeyManager.shared.installFromDefaults()
    }

    deinit {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private var savedPopoverSize: NSSize {
        let w = UserDefaults.standard.double(forKey: kPopoverWidth)
        let h = UserDefaults.standard.double(forKey: kPopoverHeight)
        return NSSize(width: w > 100 ? w : 320, height: h > 100 ? h : 440)
    }

    private func setupButton() {
        guard let button = statusItem.button else { return }
        button.title = ""
        button.image = Self.makeStatusIcon()
        button.setAccessibilityLabel("Monarch")
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.target = self

        // Transparent drag-target overlay. Captures file drops; passes all
        // mouse events through to the button beneath so click/right-click
        // behaviour is unchanged.
        let overlay = DropOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: button.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        overlay.onDrop = { [weak self] urls in
            guard let self else { return }
            for url in urls { self.store.add(url) }
        }
        overlay.onHighlight = { [weak self] on in
            self?.statusItem.button?.highlight(on)
        }
    }

    /// Loads `Resources/StatusIcon.png` from the bundle as a template image.
    /// Marked template so macOS auto-inverts it for dark menu bars and
    /// applies hover/selection tinting.
    private static func makeStatusIcon() -> NSImage {
        let pt: CGFloat = 18
        let fallback = NSImage(size: NSSize(width: pt, height: pt))

        guard let url = Bundle.main.url(forResource: "StatusIcon",
                                        withExtension: "png"),
              let img = NSImage(contentsOf: url)
        else {
            return fallback
        }
        img.size = NSSize(width: pt, height: pt)
        img.isTemplate = true
        return img
    }

    private func buildPopover() {
        let contentView = CascadeRootView(
            model: model,
            onSettingsTapped: { [weak self] in self?.showSettingsMenu() },
            onResizeBegan: { [weak self] in self?.handleResizeBegan() },
            onResizeDrag:  { [weak self] delta in self?.handleResizeDrag(delta) },
            onResizeEnded: { [weak self] in self?.handleResizeEnded() }
        )
        let hc = NSHostingController(rootView: contentView)
        hc.sizingOptions = []
        popover.contentViewController = hc
        popover.contentSize = savedPopoverSize
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showQuitMenu()
        } else {
            togglePopover()
        }
    }

    func openPopover() {
        guard let button = statusItem.button else { return }
        popover.contentSize = savedPopoverSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        model.reloadAll()
        installKeyMonitor()
        installDragMonitor()
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let fl = self.model.focus.level

            // ⌘,: open Preferences.
            if event.keyCode == 43,
               event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command {
                self.openPreferences()
                return nil
            }

            // ⌘F: show/focus search bar (intercept even when a text field is active).
            if event.keyCode == 3,
               event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command {
                self.model.showSearch(forLevel: fl)
                return nil
            }

            // Escape: dismiss search before normal escape handling.
            if event.keyCode == 53, self.model.searchVisible[fl] == true {
                self.model.hideSearch(forLevel: fl)
                return nil
            }

            // Virtual typing for peek search bars.
            // Peek windows can't become key, so their text fields can't receive
            // focus. Intercept printable characters and write them directly into
            // model.filterText for the active peek level.
            if fl > 0, self.model.searchVisible[fl] == true {
                let noMod = event.modifierFlags
                    .intersection([.command, .option, .control]).isEmpty
                if noMod {
                    if event.keyCode == 51 {  // ⌫ backspace
                        let cur = self.model.filterText[fl] ?? ""
                        self.model.setFilter(String(cur.dropLast()), forLevel: fl)
                        return nil
                    }
                    if let chars = event.characters, !chars.isEmpty,
                       chars.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
                        let cur = self.model.filterText[fl] ?? ""
                        self.model.setFilter(cur + chars, forLevel: fl)
                        return nil
                    }
                }
            }

            // Don't intercept other keys while the level-0 real text field is focused.
            let textFieldActive = NSApp.windows.contains {
                $0.isVisible && $0.firstResponder is NSTextView
            }
            if textFieldActive { return event }

            switch event.keyCode {
            case 126: self.model.keyUp();     return nil
            case 125: self.model.keyDown();   return nil
            case 124: self.model.keyRight();  return nil
            case 123: self.model.keyLeft();   return nil
            case 36, 76: self.model.keyReturn(); return nil
            case 49:  // Space → QuickLook the focused row
                if let item = self.focusedItem() {
                    QuickLookManager.shared.show(urls: [item.url])
                }
                return nil
            case 53:  // Esc
                self.model.keyEscape()
                if !self.popover.isShown { return nil }
                // If nothing to back out of, close popover.
                if self.model.levels.count == 1 { self.popover.performClose(nil) }
                return nil
            default: return event
            }
        }
    }

    private func focusedItem() -> FileItem? {
        let f = model.focus
        guard model.levels.indices.contains(f.level),
              model.levels[f.level].items.indices.contains(f.index) else { return nil }
        return model.levels[f.level].items[f.index]
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func installDragMonitor() {
        guard dragBeginMonitor == nil else { return }
        // Global monitors fire for events in OTHER apps — exactly what we need
        // to detect a Finder drag. leftMouseDragged marks the drag active;
        // leftMouseUp clears it once the drag ends (drop or cancel).
        dragBeginMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            DispatchQueue.main.async { self?.model.externalDragActive = true }
        }
        dragEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async { self?.model.externalDragActive = false }
        }
    }

    private func removeDragMonitor() {
        if let m = dragBeginMonitor { NSEvent.removeMonitor(m); dragBeginMonitor = nil }
        if let m = dragEndMonitor   { NSEvent.removeMonitor(m); dragEndMonitor = nil }
        model.externalDragActive = false
    }

    private func handleResizeBegan() {
        sizeAtResizeStart = popover.contentSize
        popover.animates = false
    }

    private func handleResizeDrag(_ delta: CGSize) {
        let newW = max(240, sizeAtResizeStart.width  + delta.width)
        let newH = max(200, sizeAtResizeStart.height + delta.height)
        popover.contentSize = NSSize(width: newW, height: newH)
    }

    private func handleResizeEnded() {
        popover.animates = true
        let sz = popover.contentSize
        guard sz.width > 100, sz.height > 100 else { return }
        UserDefaults.standard.set(Double(sz.width),  forKey: kPopoverWidth)
        UserDefaults.standard.set(Double(sz.height), forKey: kPopoverHeight)
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            openPopover()
        }
    }

    private func showQuitMenu() {
        guard let event = NSApp.currentEvent,
              let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Quit Monarch", action: #selector(quitApp), keyEquivalent: "q")
            .target = self
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    private func showSettingsMenu() {
        guard let event = NSApp.currentEvent,
              let button = statusItem.button else { return }

        let menu = NSMenu()
        menu.addItem(withTitle: "Add…", action: #selector(addShortcutAction), keyEquivalent: "")
            .target = self

        if let shortcut = model.focusedRootShortcut {
            menu.addItem(
                withTitle: "Remove \"\(shortcut.lastPathComponent)\"",
                action: #selector(removeCurrentShortcut),
                keyEquivalent: ""
            ).target = self
        }

        menu.addItem(.separator())

        let hiddenItem = NSMenuItem(title: "Show Hidden Files", action: #selector(toggleHiddenFiles), keyEquivalent: "")
        hiddenItem.target = self
        hiddenItem.state = UserDefaults.standard.bool(forKey: "showHiddenFiles") ? .on : .off
        menu.addItem(hiddenItem)

        let sortByItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Sort By")
        let currentSort = UserDefaults.standard.string(forKey: "sortOrder") ?? FileSortOrder.name.rawValue
        for order in FileSortOrder.allCases {
            let item = NSMenuItem(title: order.label, action: #selector(setSortOrder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order.rawValue
            item.state = currentSort == order.rawValue ? .on : .off
            sortMenu.addItem(item)
        }
        sortMenu.addItem(.separator())
        let defaultDescending = (currentSort == FileSortOrder.dateModified.rawValue
                                 || currentSort == FileSortOrder.dateCreated.rawValue)
        let descending = UserDefaults.standard.object(forKey: "sortDescending") as? Bool ?? defaultDescending
        let reverseItem = NSMenuItem(title: "Reverse Order", action: #selector(toggleSortDirection), keyEquivalent: "")
        reverseItem.target = self
        reverseItem.state = descending ? .on : .off
        sortMenu.addItem(reverseItem)
        sortByItem.submenu = sortMenu
        menu.addItem(sortByItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Quit Monarch", action: #selector(quitApp), keyEquivalent: "q")
            .target = self

        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.show(store: store)
    }

    @objc private func addShortcutAction() {
        popover.performClose(nil)
        let panel = NSOpenPanel()
        panel.title = "Add to Monarch"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls {
                self?.store.add(url)
            }
        }
    }

    @objc private func removeCurrentShortcut() {
        if let shortcut = model.focusedRootShortcut {
            store.remove(shortcut)
        }
    }

    @objc private func toggleHiddenFiles() {
        let current = UserDefaults.standard.bool(forKey: "showHiddenFiles")
        UserDefaults.standard.set(!current, forKey: "showHiddenFiles")
        model.reloadAll()
    }

    @objc private func setSortOrder(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let oldRaw = UserDefaults.standard.string(forKey: "sortOrder") ?? FileSortOrder.name.rawValue
        if raw != oldRaw {
            // Reset direction to the new mode's default when switching fields.
            UserDefaults.standard.removeObject(forKey: "sortDescending")
        }
        UserDefaults.standard.set(raw, forKey: "sortOrder")
        model.reloadAll()
    }

    @objc private func toggleSortDirection() {
        let currentSort = UserDefaults.standard.string(forKey: "sortOrder") ?? FileSortOrder.name.rawValue
        let defaultDescending = (currentSort == FileSortOrder.dateModified.rawValue
                                 || currentSort == FileSortOrder.dateCreated.rawValue)
        let current = UserDefaults.standard.object(forKey: "sortDescending") as? Bool ?? defaultDescending
        UserDefaults.standard.set(!current, forKey: "sortDescending")
        model.reloadAll()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        // Don't close while a cross-app drag is in flight.
        if model.externalDragActive { return false }
        // Don't close if the click landed inside a peek window.
        let mouse = NSEvent.mouseLocation
        for win in NSApp.windows where win is PeekNSWindow && win.isVisible {
            if win.frame.contains(mouse) { return false }
        }
        return true
    }

    func popoverWillClose(_ notification: Notification) {
        removeKeyMonitor()
        removeDragMonitor()
        model.closeAll()
        guard let window = popover.contentViewController?.view.window,
              let sz = window.contentView?.frame.size,
              sz.width > 100, sz.height > 100 else { return }
        UserDefaults.standard.set(Double(sz.width),  forKey: kPopoverWidth)
        UserDefaults.standard.set(Double(sz.height), forKey: kPopoverHeight)
    }
}

// MARK: - Drag-to-add overlay

/// Invisible view that sits over the status bar button and accepts file drops.
/// Overrides hitTest → nil so all mouse events fall through to the button.
private class DropOverlayView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onHighlight: ((Bool) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // Transparent to clicks — lets the NSStatusBarButton handle them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        onHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onHighlight?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        onHighlight?(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
