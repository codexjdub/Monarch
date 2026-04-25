import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

@MainActor
final class PreferencesWindowController: NSObject {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var store: ShortcutStore?
    private var appearanceObserver: NSKeyValueObservation?

    func show(store: ShortcutStore) {
        self.store = store
        if let win = window {
            applyAppearance(to: win)
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: PreferencesView(store: store))
        hosting.sizingOptions = []
        let win = NSWindow(contentViewController: hosting)
        win.title = "Monarch Preferences"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 480, height: 580))
        win.contentMinSize = NSSize(width: 420, height: 440)
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win
        applyAppearance(to: win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        appearanceObserver = UserDefaults.standard.observe(
            \.appearanceMode, options: [.new]
        ) { [weak self] _, _ in
            DispatchQueue.main.async {
                if let win = self?.window { self?.applyAppearance(to: win) }
            }
        }
    }

    private func applyAppearance(to win: NSWindow) {
        let mode = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: UDKey.appearanceMode) ?? ""
        ) ?? .system
        win.appearance = mode.nsAppearance
    }
}

// MARK: - Preferences SwiftUI View

struct PreferencesView: View {
    private static let defaultShortcutsHeight = 220.0
    private static let shortcutsHeightRange: ClosedRange<Double> = 140...360

    @ObservedObject var store: ShortcutStore

    @AppStorage(kHotkeyEnabledKey) private var hotkeyEnabled: Bool = true
    @AppStorage(kHotkeyDisplayKey) private var hotkeyDisplay: String = defaultHotkeyDisplay

    @AppStorage(UDKey.showFooterBar) private var showFooterBar: Bool = true
    @AppStorage(UDKey.showFrequentSection) private var showFrequentSection: Bool = true
    @AppStorage(UDKey.frequentDisplayLimit) private var frequentDisplayLimit: Int = FrequentSectionConfig.defaultDisplayLimit
    @AppStorage(UDKey.rowDensity) private var densityRaw: String = RowDensity.medium.rawValue
    @AppStorage(UDKey.appearanceMode) private var appearanceModeRaw: String = AppearanceMode.system.rawValue
    @AppStorage(UDKey.openPopoverOnHover) private var openPopoverOnHover: Bool = false
    @AppStorage(UDKey.preferencesShortcutsHeight) private var shortcutsHeightRaw: Double = PreferencesView.defaultShortcutsHeight
    @AppStorage(UDKey.preferredTerminal) private var preferredTerminal: String = ""
    @State private var launchAtLogin: Bool = PreferencesView.readLaunchAtLogin()
    @State private var showingResetFrequentAlert = false
    @State private var shortcutsHeightAtDragStart: Double?
    private var installedTerminals: [TerminalApp] { TerminalApp.installed }
    private var shortcutsHeight: Double {
        min(max(shortcutsHeightRaw, Self.shortcutsHeightRange.lowerBound), Self.shortcutsHeightRange.upperBound)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                shortcutsSection
                Divider()
                settingsSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .frame(minWidth: 420, minHeight: 440)
        .alert("Reset Frequent?", isPresented: $showingResetFrequentAlert) {
            Button("Reset", role: .destructive) {
                FrequentStore.shared.clear()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears Monarch's Frequent ranking and starts it over from scratch.")
        }
    }

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts")
                .font(.headline)

            if store.shortcuts.isEmpty {
                Text("No shortcuts yet. Click ··· in the menu bar to add one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                List {
                    ForEach(store.shortcuts, id: \.url) { shortcut in
                        HStack(spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: shortcut.url.path))
                                .resizable()
                                .frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(shortcut.displayName)
                                    .lineLimit(1)
                                Text(shortcut.hasAlias ? shortcut.url.path : shortcut.url.deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button {
                                store.remove(shortcut.url)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.8))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove { from, to in
                        guard let src = from.first else { return }
                        let dst = to > src ? to - 1 : to
                        store.move(from: src, to: dst)
                    }
                }
                .listStyle(.inset)
                .frame(maxWidth: .infinity)
                .frame(height: shortcutsHeight)

                shortcutsResizeHandle
            }

            Text("Drag rows to reorder. Changes appear immediately in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutsResizeHandle: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 46, height: 5)
                .padding(.vertical, 6)
            Spacer()
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if shortcutsHeightAtDragStart == nil {
                        shortcutsHeightAtDragStart = shortcutsHeight
                    }
                    let baseHeight = shortcutsHeightAtDragStart ?? shortcutsHeight
                    let proposedHeight = baseHeight + value.translation.height
                    shortcutsHeightRaw = min(
                        max(proposedHeight, Self.shortcutsHeightRange.lowerBound),
                        Self.shortcutsHeightRange.upperBound
                    )
                }
                .onEnded { _ in
                    shortcutsHeightAtDragStart = nil
                    shortcutsHeightRaw = shortcutsHeight
                }
        )
        .help("Drag to resize the shortcuts list.")
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance")
                .font(.headline)

            HStack {
                Text("Text size")
                Spacer()
                Picker("", selection: $densityRaw) {
                    ForEach(RowDensity.allCases, id: \.rawValue) { d in
                        Text(d.label).tag(d.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            HStack {
                Text("Appearance")
                Spacer()
                Picker("", selection: $appearanceModeRaw) {
                    ForEach(AppearanceMode.allCases, id: \.rawValue) { m in
                        Text(m.label).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            Toggle("Show item count and size footer", isOn: $showFooterBar)

            Divider()

            Text("Behavior")
                .font(.headline)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    PreferencesView.writeLaunchAtLogin(newValue)
                }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Open when hovering over the menu bar icon", isOn: $openPopoverOnHover)
                Text("After a short delay, hovering over Monarch's menu bar icon opens the popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show Frequent section", isOn: $showFrequentSection)
                Text("Show a Frequent section at the top of Monarch's main list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text("Items to show")
                    Spacer()
                    Text("\(frequentDisplayLimit)")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .frame(minWidth: 24, alignment: .trailing)
                    Stepper("", value: $frequentDisplayLimit, in: FrequentSectionConfig.displayLimitRange)
                        .labelsHidden()
                }
                .disabled(!showFrequentSection)
                .opacity(showFrequentSection ? 1 : 0.5)
                Text("Items need at least \(FrequentStore.minimumQualifiedAccessCount) opens before they appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reset Frequent…") {
                        showingResetFrequentAlert = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Spacer()
                }
                .padding(.leading, 16)
            }

            HStack {
                Toggle(isOn: $hotkeyEnabled) {
                    Text("Global hotkey")
                }
                .toggleStyle(.checkbox)
                .onChange(of: hotkeyEnabled) { _ in
                    HotkeyManager.shared.installFromDefaults()
                }
                Spacer()
                HotkeyRecorderView()
                    .disabled(!hotkeyEnabled)
                    .opacity(hotkeyEnabled ? 1 : 0.5)
            }
            Text("Press this combination anywhere to open Monarch.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, -10)

            if installedTerminals.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Preferred terminal")
                        Spacer()
                        Picker("", selection: $preferredTerminal) {
                            ForEach(installedTerminals) { app in
                                HStack(spacing: 5) {
                                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.appPath)
                                        .resizedCopy(to: NSSize(width: 17, height: 17)))
                                    Text(app.rawValue)
                                }
                                .tag(app.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity)
                    Text("Used for \"Open in Terminal\" in the right-click menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Launch at Login (SMAppService, macOS 13+)

    private static func readLaunchAtLogin() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    private static func writeLaunchAtLogin(_ enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                NSLog("Monarch: launch-at-login change failed: \(error)")
            }
        }
    }
}

// MARK: - Hotkey Recorder

struct HotkeyRecorderView: View {
    @AppStorage(kHotkeyDisplayKey) private var hotkeyDisplay: String = defaultHotkeyDisplay
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            Text(recording ? "Press keys…" : hotkeyDisplay)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .frame(minWidth: 100)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(recording ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(recording ? Color.accentColor : Color.secondary.opacity(0.4),
                                      lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        // Tear the local key monitor down when the view goes away (e.g. user
        // closes Preferences mid-recording). Otherwise the monitor outlives
        // the view and silently consumes the next modifier-keystroke.
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        if recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Require at least one modifier so we don't capture plain keys
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !mods.isEmpty else {
                // Esc cancels
                if event.keyCode == UInt16(kVK_Escape) {
                    stopRecording()
                    return nil
                }
                return event
            }
            let keyCode = UInt32(event.keyCode)
            let carbonMods = HotkeyManager.carbonModifiers(from: event.modifierFlags)
            let display = HotkeyManager.displayString(for: event)

            let d = UserDefaults.standard
            d.set(Int(keyCode), forKey: kHotkeyKeyCodeKey)
            d.set(Int(carbonMods), forKey: kHotkeyModifiersKey)
            d.set(display, forKey: kHotkeyDisplayKey)
            hotkeyDisplay = display

            HotkeyManager.shared.installFromDefaults()
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
