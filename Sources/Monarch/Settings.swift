import Foundation
import AppKit

// MARK: - UserDefaults key constants
//
// All UserDefaults keys in one place. The hotkey keys (kHotkeyKeyCodeKey etc.)
// live in HotkeyManager.swift because they're tightly coupled to that subsystem.

enum UDKey {
    static let appearanceMode  = "appearanceMode"
    static let rowDensity      = "rowDensity"
    static let showFooterBar   = "showFooterBar"
    static let sortOrder       = "sortOrder"
    static let sortDescending  = "sortDescending"
    static let showHiddenFiles = "showHiddenFiles"
    static let popoverWidth    = "popoverWidth"
    static let popoverHeight   = "popoverHeight"
}

// MARK: - Appearance mode

enum AppearanceMode: String, CaseIterable {
    case system, light, dark

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

extension UserDefaults {
    @objc dynamic var appearanceMode: String {
        return string(forKey: UDKey.appearanceMode) ?? AppearanceMode.system.rawValue
    }
}

@MainActor
final class Settings {
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
