import AppKit
import SwiftUI


@MainActor
class StatusItemController: NSObject {
    private static let hoverOpenDelay: TimeInterval = 0.20
    private static let postOpenActivationDelayNanoseconds: UInt64 = 40_000_000
    private static let postOpenRefreshDelayNanoseconds: UInt64 = 260_000_000

    private let store: ShortcutStore
    private var statusItem: NSStatusItem
    private var popover = NSPopover()
    private var sizeAtResizeStart: NSSize = .zero
    private let model: CascadeModel
    private var hoverOpenTask: DispatchWorkItem?
    private var popoverPostOpenTask: Task<Void, Never>?
    private var keyMonitor: Any?
    private var dragBeginMonitor: Any?
    private var dragEndMonitor: Any?
    private var appearanceObserver: NSKeyValueObservation?

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

        // Live-apply appearance when changed in Preferences.
        appearanceObserver = UserDefaults.standard.observe(
            \.appearanceMode, options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
    }

    private func setupHotkey() {
        HotkeyManager.shared.onTrigger = { [weak self] in
            self?.togglePopover()
        }
        HotkeyManager.shared.installFromDefaults()
    }

    deinit {
        // Class is @MainActor; deinit is nonisolated by default in Swift 6.
        // NSStatusItem is main-thread-only, so assume isolation to access it.
        MainActor.assumeIsolated {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }

    private var savedPopoverSize: NSSize {
        let w = UserDefaults.standard.double(forKey: UDKey.popoverWidth)
        let h = UserDefaults.standard.double(forKey: UDKey.popoverHeight)
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
        overlay.onHoverChange = { [weak self] inside in
            self?.handleStatusItemHover(inside)
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
        let visualEffect = NSVisualEffectView()
        visualEffect.material = .sidebar
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active

        let hc = NSHostingController(rootView: contentView)
        hc.sizingOptions = []
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
        let vc = NSViewController()
        vc.view = visualEffect
        popover.contentViewController = vc
        popover.contentSize = savedPopoverSize
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    @objc private func handleClick() {
        cancelHoverOpen()
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showQuitMenu()
        } else {
            togglePopover()
        }
    }

    func openPopover() {
        guard let button = statusItem.button else { return }
        cancelHoverOpen()
        applyAppearance()
        popover.contentSize = savedPopoverSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        schedulePopoverPostOpenWork()
    }

    private func schedulePopoverPostOpenWork() {
        popoverPostOpenTask?.cancel()
        popoverPostOpenTask = Task { @MainActor [weak self] in
            defer { self?.popoverPostOpenTask = nil }
            try? await Task.sleep(nanoseconds: Self.postOpenActivationDelayNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.popover.isShown else { return }
            self.popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
            self.installKeyMonitor()
            self.installDragMonitor()
            try? await Task.sleep(nanoseconds: Self.postOpenRefreshDelayNanoseconds)
            guard !Task.isCancelled, self.popover.isShown else { return }
            self.model.reloadAll()
        }
    }

    private func handleStatusItemHover(_ inside: Bool) {
        guard UserDefaults.standard.bool(forKey: UDKey.openPopoverOnHover) else {
            cancelHoverOpen()
            return
        }
        if inside {
            scheduleHoverOpen()
        } else {
            cancelHoverOpen()
        }
    }

    private func scheduleHoverOpen() {
        guard !popover.isShown, !model.externalDragActive else { return }
        cancelHoverOpen()
        let task = DispatchWorkItem { [weak self] in
            guard let self,
                  UserDefaults.standard.bool(forKey: UDKey.openPopoverOnHover),
                  !self.popover.isShown,
                  !self.model.externalDragActive else { return }
            self.openPopover()
        }
        hoverOpenTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverOpenDelay, execute: task)
    }

    private func cancelHoverOpen() {
        hoverOpenTask?.cancel()
        hoverOpenTask = nil
    }

    private func applyAppearance() {
        let mode = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: UDKey.appearanceMode) ?? ""
        ) ?? .system
        popover.appearance = mode.nsAppearance
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            // ⌘,: open Preferences.
            if event.keyCode == 43,
               event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command {
                self.openPreferences()
                return nil
            }

            let textFieldActive = self.isPopoverTextFieldActive
            if let intent = self.keyIntent(for: event, popoverTextFieldActive: textFieldActive) {
                return self.handleKeyIntent(intent) ? nil : event
            }
            if self.shouldSuppressStalePopoverTextInput(event, popoverTextFieldActive: textFieldActive) {
                return nil
            }
            return event
        }
    }

    private var isPopoverTextFieldActive: Bool {
        popover.contentViewController?.view.window?.firstResponder is NSTextView
    }

    private func keyIntent(for event: NSEvent,
                           popoverTextFieldActive: Bool) -> CascadeModel.KeyIntent? {
        // ⌘F: show/focus search bar, even when the search field is active.
        if event.keyCode == 3,
           event.modifierFlags.intersection([.command, .option, .shift, .control]) == .command {
            return .showSearch
        }

        // Let system/app shortcuts that use these modifiers pass through.
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else {
            return nil
        }

        let activeLevel = model.focus.level
        let activeSearchVisible = model.searchVisible[activeLevel] == true

        switch event.keyCode {
        case 126: return .moveUp
        case 125: return .moveDown
        case 124: return .moveRight
        case 123:
            // In the level-0 search field, left arrow should still edit the query
            // unless a preview is open; then it should close that preview first.
            if popoverTextFieldActive,
               activeLevel == 0,
               activeSearchVisible,
               !model.hasPreviewChild(ofLevel: activeLevel) {
                return nil
            }
            return .moveLeft
        case 36, 76:
            return .openFocused
        case 53:
            return .escape
        case 49:
            if activeSearchVisible {
                if popoverTextFieldActive, activeLevel == 0 { return nil }
                return .insertSearchText(" ")
            }
            return .quickLookFocused
        case 51:
            guard activeSearchVisible else { return nil }
            if popoverTextFieldActive, activeLevel == 0 { return nil }
            return .deleteSearchBackward
        default:
            guard activeSearchVisible,
                  let text = printableText(from: event) else { return nil }
            if popoverTextFieldActive, activeLevel == 0 { return nil }
            return .insertSearchText(text)
        }
    }

    private func handleKeyIntent(_ intent: CascadeModel.KeyIntent) -> Bool {
        switch model.handleKeyIntent(intent) {
        case .handled:
            return true
        case .quickLook(let url):
            QuickLookManager.shared.show(urls: [url])
            return true
        case .unhandled:
            return false
        }
    }

    private func printableText(from event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty,
              chars.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
        else { return nil }
        return chars
    }

    private func shouldSuppressStalePopoverTextInput(_ event: NSEvent,
                                                     popoverTextFieldActive: Bool) -> Bool {
        guard popoverTextFieldActive,
              model.focus.level > 0,
              model.searchVisible[0] == true,
              model.searchVisible[model.focus.level] != true,
              event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        else { return false }
        return event.keyCode == 51 || printableText(from: event) != nil
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
        UserDefaults.standard.set(Double(sz.width),  forKey: UDKey.popoverWidth)
        UserDefaults.standard.set(Double(sz.height), forKey: UDKey.popoverHeight)
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
                withTitle: "Remove \"\(shortcut.displayName)\"",
                action: #selector(removeCurrentShortcut),
                keyEquivalent: ""
            ).target = self
        }

        menu.addItem(.separator())

        let hiddenItem = NSMenuItem(title: "Show Hidden Files", action: #selector(toggleHiddenFiles), keyEquivalent: "")
        hiddenItem.target = self
        hiddenItem.state = UserDefaults.standard.bool(forKey: UDKey.showHiddenFiles) ? .on : .off
        menu.addItem(hiddenItem)

        let sortByItem = NSMenuItem(title: "Sort By", action: nil, keyEquivalent: "")
        let sortMenu = NSMenu(title: "Sort By")
        let currentSort = UserDefaults.standard.string(forKey: UDKey.sortOrder) ?? FileSortOrder.name.rawValue
        for order in FileSortOrder.allCases {
            let item = NSMenuItem(title: order.label, action: #selector(setSortOrder(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = order.rawValue
            item.state = currentSort == order.rawValue ? .on : .off
            sortMenu.addItem(item)
        }
        sortMenu.addItem(.separator())
        let descending = UserDefaults.standard.object(forKey: UDKey.sortDescending) as? Bool ?? isDescendingByDefault(for: currentSort)
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
            store.remove(shortcut.url)
        }
    }

    @objc private func toggleHiddenFiles() {
        let current = UserDefaults.standard.bool(forKey: UDKey.showHiddenFiles)
        UserDefaults.standard.set(!current, forKey: UDKey.showHiddenFiles)
        model.reloadAll()
    }

    @objc private func setSortOrder(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let oldRaw = UserDefaults.standard.string(forKey: UDKey.sortOrder) ?? FileSortOrder.name.rawValue
        if raw != oldRaw {
            // Reset direction to the new mode's default when switching fields.
            UserDefaults.standard.removeObject(forKey: UDKey.sortDescending)
        }
        UserDefaults.standard.set(raw, forKey: UDKey.sortOrder)
        model.reloadAll()
    }

    @objc private func toggleSortDirection() {
        let currentSort = UserDefaults.standard.string(forKey: UDKey.sortOrder) ?? FileSortOrder.name.rawValue
        let current = UserDefaults.standard.object(forKey: UDKey.sortDescending) as? Bool ?? isDescendingByDefault(for: currentSort)
        UserDefaults.standard.set(!current, forKey: UDKey.sortDescending)
        model.reloadAll()
    }

    /// Date-based sorts default to descending (newest first); all others default to ascending.
    private func isDescendingByDefault(for sortRaw: String) -> Bool {
        sortRaw == FileSortOrder.dateModified.rawValue || sortRaw == FileSortOrder.dateCreated.rawValue
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
        cancelHoverOpen()
        popoverPostOpenTask?.cancel()
        popoverPostOpenTask = nil
        removeKeyMonitor()
        removeDragMonitor()
        model.closeAll()
        guard let window = popover.contentViewController?.view.window,
              let sz = window.contentView?.frame.size,
              sz.width > 100, sz.height > 100 else { return }
        UserDefaults.standard.set(Double(sz.width),  forKey: UDKey.popoverWidth)
        UserDefaults.standard.set(Double(sz.height), forKey: UDKey.popoverHeight)
    }
}

// MARK: - Drag-to-add overlay

/// Invisible view that sits over the status bar button and accepts file drops.
/// Overrides hitTest → nil so all mouse events fall through to the button.
private class DropOverlayView: NSView {
    var onDrop: (([URL]) -> Void)?
    var onHighlight: ((Bool) -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

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

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) else { return [] }
        onHoverChange?(false)
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
