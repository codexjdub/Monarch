import Foundation

/// Per-folder pinned files. Persists as a single UserDefaults JSON dict
/// keyed by the parent folder's path. Within a folder, pins keep their
/// user-chosen order.
@MainActor
final class PinStore {
    static let shared = PinStore()

    private let key = "pinnedFiles_v1"
    private var data: [String: [String]] = [:]

    private init() {
        if let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] {
            data = raw
        }
    }

    private func save() {
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Pinned URLs for the given parent folder, in user-ordered sequence.
    func pinned(in folder: URL) -> [URL] {
        (data[folder.path] ?? []).map { URL(fileURLWithPath: $0) }
    }

    func isPinned(_ url: URL, in folder: URL) -> Bool {
        (data[folder.path] ?? []).contains(url.path)
    }

    /// Toggles pin state. Returns the new state (true = pinned).
    @discardableResult
    func togglePin(_ url: URL, in folder: URL) -> Bool {
        var list = data[folder.path] ?? []
        let newState: Bool
        if let i = list.firstIndex(of: url.path) {
            list.remove(at: i)
            newState = false
        } else {
            list.append(url.path)
            newState = true
        }
        data[folder.path] = list.isEmpty ? nil : list
        save()
        NotificationCenter.default.post(name: .folderMenuPinsChanged, object: folder)
        return newState
    }
}

extension Notification.Name {
    static let folderMenuPinsChanged = Notification.Name("FolderMenuPinsChanged")
}
