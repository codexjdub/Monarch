import Foundation

class FolderStore: ObservableObject {
    @Published var folders: [URL]

    init() {
        folders = Settings.shared.loadFolders()
    }

    func add(_ url: URL) {
        guard !folders.contains(url) else { return }
        folders.append(url)
        Settings.shared.saveFolders(folders)
    }

    func remove(_ url: URL) {
        folders.removeAll { $0 == url }
        Settings.shared.saveFolders(folders)
    }
}
