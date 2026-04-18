import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

@MainActor
final class PreferencesWindowController: NSObject {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?
    private var store: ShortcutStore?

    func show(store: ShortcutStore) {
        self.store = store
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: PreferencesView(store: store))
        hosting.sizingOptions = []
        let win = NSWindow(contentViewController: hosting)
        win.title = "Monarch Preferences"
        win.styleMask = [.titled, .closable, .resizable]
        win.setContentSize(NSSize(width: 440, height: 460))
        win.contentMinSize = NSSize(width: 380, height: 340)
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Preferences SwiftUI View

struct PreferencesView: View {
    @ObservedObject var store: ShortcutStore

    @AppStorage(kHotkeyEnabledKey) private var hotkeyEnabled: Bool = true
    @AppStorage(kHotkeyDisplayKey) private var hotkeyDisplay: String = defaultHotkeyDisplay

    @AppStorage("showFooterBar") private var showFooterBar: Bool = true
    @State private var launchAtLogin: Bool = PreferencesView.readLaunchAtLogin()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Shortcuts reorder section
            VStack(alignment: .leading, spacing: 6) {
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
                        ForEach(store.shortcuts, id: \.self) { url in
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 18, height: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(url.lastPathComponent)
                                        .lineLimit(1)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button {
                                    store.remove(url)
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
                            // SwiftUI onMove gives destination index in the shifted array
                            let dst = to > src ? to - 1 : to
                            store.move(from: src, to: dst)
                        }
                    }
                    .listStyle(.inset)
                    .frame(maxHeight: .infinity)

                    Text("Drag rows to reorder. Changes appear immediately in the menu bar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .layoutPriority(1)

            Divider().padding(.vertical, 12)

            Form {
                Section {
                    HStack {
                        Toggle(isOn: $hotkeyEnabled) {
                            Text("Global hotkey")
                        }
                        .toggleStyle(.checkbox)
                        Spacer()
                        HotkeyRecorderView()
                            .disabled(!hotkeyEnabled)
                            .opacity(hotkeyEnabled ? 1 : 0.5)
                    }
                    .onChange(of: hotkeyEnabled) { _ in
                        HotkeyManager.shared.installFromDefaults()
                    }

                    Text("Press this combination anywhere to open Monarch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 4)

                Section {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { newValue in
                            PreferencesView.writeLaunchAtLogin(newValue)
                        }
                    Toggle("Show item count and size footer", isOn: $showFooterBar)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 380, minHeight: 340)
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
