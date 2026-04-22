import Foundation
import AppKit

// MARK: - UserDefaults key constants
//
// All UserDefaults keys in one place. The hotkey keys (kHotkeyKeyCodeKey etc.)
// live in HotkeyManager.swift because they're tightly coupled to that subsystem.

enum UDKey {
    static let appearanceMode       = "appearanceMode"
    static let rowDensity           = "rowDensity"
    static let showFooterBar        = "showFooterBar"
    static let showFrequentSection  = "showFrequentSection"
    static let frequentDisplayLimit = "frequentDisplayLimit"
    static let sortOrder            = "sortOrder"
    static let sortDescending       = "sortDescending"
    static let showHiddenFiles      = "showHiddenFiles"
    static let popoverWidth         = "popoverWidth"
    static let popoverHeight        = "popoverHeight"
    static let preferredTerminal    = "preferredTerminal"
    static let perFolderSortOrder   = "perFolderSortOrder"
    static let perFolderDescending  = "perFolderDescending"
    static let rootShortcutAliases  = "rootShortcutAliases"
    static let frequentItems        = "frequentItems"
    static let hiddenFrequentItems  = "hiddenFrequentItems"
}

enum FrequentSectionConfig {
    static let defaultDisplayLimit = 3
    static let displayLimitRange = 1...10
}

// MARK: - Per-folder sort helpers

extension UserDefaults {
    @objc dynamic var showFrequentSection: Bool {
        object(forKey: UDKey.showFrequentSection) as? Bool ?? true
    }

    @objc dynamic var frequentDisplayLimit: Int {
        let raw = object(forKey: UDKey.frequentDisplayLimit) as? Int
            ?? FrequentSectionConfig.defaultDisplayLimit
        return min(
            max(raw, FrequentSectionConfig.displayLimitRange.lowerBound),
            FrequentSectionConfig.displayLimitRange.upperBound
        )
    }

    /// Sort order for a specific folder, falling back to the global setting.
    func sortOrder(for url: URL) -> FileSortOrder {
        let dict = dictionary(forKey: UDKey.perFolderSortOrder) as? [String: String] ?? [:]
        if let raw = dict[url.path], let order = FileSortOrder(rawValue: raw) { return order }
        return FileSortOrder(rawValue: string(forKey: UDKey.sortOrder) ?? "") ?? .name
    }

    /// Sort direction for a specific folder, falling back to the global setting.
    func sortDescending(for url: URL) -> Bool {
        let dict = dictionary(forKey: UDKey.perFolderDescending) as? [String: Bool] ?? [:]
        if let val = dict[url.path] { return val }
        let order = sortOrder(for: url)
        return (object(forKey: UDKey.sortDescending) as? Bool)
            ?? (order == .dateModified || order == .dateCreated)
    }

    /// Persist sort order + direction for a specific folder.
    func setSortOrder(_ order: FileSortOrder, descending: Bool, for url: URL) {
        var orders = dictionary(forKey: UDKey.perFolderSortOrder) as? [String: String] ?? [:]
        orders[url.path] = order.rawValue
        set(orders, forKey: UDKey.perFolderSortOrder)

        var descs = dictionary(forKey: UDKey.perFolderDescending) as? [String: Bool] ?? [:]
        descs[url.path] = descending
        set(descs, forKey: UDKey.perFolderDescending)
    }
}

// MARK: - Terminal app

/// Known terminal emulators, in preferred auto-detect order.
/// `Terminal` is always last — it ships with macOS and is the guaranteed fallback.
enum TerminalApp: String, CaseIterable, Identifiable {
    case ghostty  = "Ghostty"
    case iterm2   = "iTerm"
    case warp     = "Warp"
    case kitty    = "kitty"
    case alacritty = "Alacritty"
    case terminal = "Terminal"

    var id: String { rawValue }

    /// Bundle path to check for installation.
    var appPath: String {
        switch self {
        case .ghostty:   return "/Applications/Ghostty.app"
        case .iterm2:    return "/Applications/iTerm.app"
        case .warp:      return "/Applications/Warp.app"
        case .kitty:     return "/Applications/kitty.app"
        case .alacritty: return "/Applications/Alacritty.app"
        case .terminal:  return "/System/Applications/Utilities/Terminal.app"
        }
    }

    var isInstalled: Bool {
        FileManager.default.fileExists(atPath: appPath)
    }

    /// All terminals installed on this machine, Terminal.app always included.
    static var installed: [TerminalApp] {
        allCases.filter { $0.isInstalled }
    }

    /// Best available terminal: user preference if installed, else first installed.
    static func resolved() -> TerminalApp {
        let saved = UserDefaults.standard.string(forKey: UDKey.preferredTerminal) ?? ""
        if let pref = TerminalApp(rawValue: saved), pref.isInstalled { return pref }
        return installed.first ?? .terminal
    }

    /// Open a folder URL in this terminal.
    func open(folder: URL) {
        NSWorkspace.shared.open(
            [folder],
            withApplicationAt: URL(fileURLWithPath: appPath),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

// MARK: - NSImage resize helper

extension NSImage {
    /// Returns a new NSImage drawn into the given size. Used to pin app icons
    /// to a specific pixel size before handing them to SwiftUI/NSMenuItem.
    func resizedCopy(to size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        draw(in: NSRect(origin: .zero, size: size),
             from: .zero, operation: .copy, fraction: 1)
        img.unlockFocus()
        return img
    }
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

    func loadShortcutAliases() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: UDKey.rootShortcutAliases) as? [String: String] ?? [:]
    }

    func saveShortcutAliases(_ aliases: [String: String]) {
        UserDefaults.standard.set(aliases, forKey: UDKey.rootShortcutAliases)
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
