import AppKit

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var store = FolderStore()
    var controller: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusItemController(store: store)
        if store.folders.isEmpty { controller?.openPopover() }
    }
}
