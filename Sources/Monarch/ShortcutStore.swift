import Foundation

class ShortcutStore: ObservableObject {
    @Published var shortcuts: [URL]

    init() {
        shortcuts = Settings.shared.loadFolders()
    }

    func add(_ url: URL) {
        guard !shortcuts.contains(url) else { return }
        shortcuts.append(url)
        Settings.shared.saveFolders(shortcuts)
    }

    func remove(_ url: URL) {
        shortcuts.removeAll { $0 == url }
        Settings.shared.saveFolders(shortcuts)
    }

    func move(from: Int, to: Int) {
        guard shortcuts.indices.contains(from), shortcuts.indices.contains(to),
              from != to else { return }
        var updated = shortcuts
        let item = updated.remove(at: from)
        updated.insert(item, at: to)
        shortcuts = updated
        Settings.shared.saveFolders(shortcuts)
    }
}
