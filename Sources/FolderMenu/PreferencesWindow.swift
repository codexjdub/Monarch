import AppKit
import SwiftUI
import ServiceManagement
import Carbon.HIToolbox

@MainActor
final class PreferencesWindowController: NSObject {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    func show() {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: PreferencesView())
        let win = NSWindow(contentViewController: hosting)
        win.title = "FolderMenu Preferences"
        win.styleMask = [.titled, .closable]
        win.setContentSize(NSSize(width: 440, height: 260))
        win.isReleasedWhenClosed = false
        win.center()
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Preferences SwiftUI View

struct PreferencesView: View {
    @AppStorage(kHotkeyEnabledKey) private var hotkeyEnabled: Bool = true
    @AppStorage(kHotkeyDisplayKey) private var hotkeyDisplay: String = defaultHotkeyDisplay

    @State private var launchAtLogin: Bool = PreferencesView.readLaunchAtLogin()

    var body: some View {
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

                Text("Press this combination anywhere to open FolderMenu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider().padding(.vertical, 4)

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { newValue in
                        PreferencesView.writeLaunchAtLogin(newValue)
                    }
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 440, height: 260)
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
                NSLog("FolderMenu: launch-at-login change failed: \(error)")
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
