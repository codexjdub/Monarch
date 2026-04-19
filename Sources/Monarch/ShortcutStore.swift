import Foundation

@MainActor
final class ShortcutStore: ObservableObject {
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

    /// Replace a broken shortcut with a newly-located URL, preserving its
    /// position in the list. No-op if `oldURL` isn't in the list or `newURL`
    /// is already present at a different index.
    func replace(oldURL: URL, newURL: URL) {
        guard let idx = shortcuts.firstIndex(of: oldURL) else { return }
        if let existingIdx = shortcuts.firstIndex(of: newURL), existingIdx != idx { return }
        var updated = shortcuts
        updated[idx] = newURL
        shortcuts = updated
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
