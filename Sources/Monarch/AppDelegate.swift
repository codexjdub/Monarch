import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var store = ShortcutStore()
    var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController(store: store)
        // First-launch onboarding: if no shortcuts have ever been saved,
        // auto-open the popover so the user sees the empty state. Reading
        // the bookmark count from UserDefaults avoids waiting for the
        // (now async) shortcut resolution to complete — `store.shortcuts`
        // is always empty at this moment regardless of saved state.
        if !Settings.shared.hasStoredFolders { controller?.openPopover() }
    }
}
