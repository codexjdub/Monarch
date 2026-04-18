import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var store = ShortcutStore()
    var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController(store: store)
        if store.shortcuts.isEmpty { controller?.openPopover() }
    }
}
