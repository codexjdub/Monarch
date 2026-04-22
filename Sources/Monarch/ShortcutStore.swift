import Foundation

struct RootShortcut: Hashable {
    let url: URL
    var alias: String?

    init(url: URL, alias: String? = nil) {
        self.url = url
        self.alias = Self.normalizedAlias(alias, for: url)
    }

    var displayName: String { alias ?? url.lastPathComponent }
    var hasAlias: Bool { alias != nil }

    static func normalizedAlias(_ alias: String?, for url: URL) -> String? {
        let trimmed = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed != url.lastPathComponent else { return nil }
        return trimmed
    }
}

@MainActor
final class ShortcutStore: ObservableObject {
    @Published var shortcuts: [RootShortcut]

    init() {
        let aliases = Settings.shared.loadShortcutAliases()
        shortcuts = Settings.shared.loadFolders().map {
            RootShortcut(url: $0, alias: aliases[$0.path])
        }
    }

    private func persist() {
        Settings.shared.saveFolders(shortcuts.map(\.url))
        let aliases = shortcuts.reduce(into: [String: String]()) { partialResult, shortcut in
            guard let alias = shortcut.alias else { return }
            partialResult[shortcut.url.path] = alias
        }
        Settings.shared.saveShortcutAliases(aliases)
    }

    func add(_ url: URL) {
        guard !shortcuts.contains(where: { $0.url == url }) else { return }
        shortcuts.append(RootShortcut(url: url))
        persist()
    }

    func remove(_ url: URL) {
        shortcuts.removeAll { $0.url == url }
        persist()
    }

    /// Replace a broken shortcut with a newly-located URL, preserving its
    /// position in the list. No-op if `oldURL` isn't in the list or `newURL`
    /// is already present at a different index.
    func replace(oldURL: URL, newURL: URL) {
        guard let idx = shortcuts.firstIndex(where: { $0.url == oldURL }) else { return }
        if let existingIdx = shortcuts.firstIndex(where: { $0.url == newURL }), existingIdx != idx { return }
        var updated = shortcuts
        updated[idx] = RootShortcut(url: newURL, alias: updated[idx].alias)
        shortcuts = updated
        persist()
    }

    func move(from: Int, to: Int) {
        guard shortcuts.indices.contains(from), shortcuts.indices.contains(to),
              from != to else { return }
        var updated = shortcuts
        let item = updated.remove(at: from)
        updated.insert(item, at: to)
        shortcuts = updated
        persist()
    }

    func setAlias(_ alias: String?, for url: URL) {
        guard let idx = shortcuts.firstIndex(where: { $0.url == url }) else { return }
        let normalized = RootShortcut.normalizedAlias(alias, for: url)
        guard shortcuts[idx].alias != normalized else { return }
        var updated = shortcuts
        updated[idx].alias = normalized
        shortcuts = updated
        persist()
    }

    func shortcut(for url: URL) -> RootShortcut? {
        shortcuts.first { $0.url == url }
    }
}
