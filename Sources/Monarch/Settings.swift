import Foundation

class Settings {
    static let shared = Settings()
    private let key = "savedFolderBookmarks"

    private init() {}

    func loadFolders() -> [URL] {
        guard let bookmarkList = UserDefaults.standard.array(forKey: key) as? [Data] else {
            return []
        }
        return bookmarkList.compactMap { data in
            var isStale = false
            return try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
        }
    }

    func saveFolders(_ urls: [URL]) {
        let bookmarks = urls.compactMap { url in
            try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        UserDefaults.standard.set(bookmarks, forKey: key)
    }

    func addFolder(_ url: URL) {
        var current = loadFolders()
        guard !current.contains(url) else { return }
        current.append(url)
        saveFolders(current)
    }

    func removeFolder(_ url: URL) {
        let current = loadFolders().filter { $0 != url }
        saveFolders(current)
    }
}
