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
    static let openPopoverOnHover   = "openPopoverOnHover"
    static let preferencesShortcutsHeight = "preferencesShortcutsHeight"
    static let preferredTerminal    = "preferredTerminal"
    static let perFolderSortOrder   = "perFolderSortOrder"
    static let perFolderDescending  = "perFolderDescending"
    static let rootShortcutAliases  = "rootShortcutAliases"
    static let frequentItems        = "frequentItems"
    static let hiddenFrequentItems  = "hiddenFrequentItems"
    static let savedFolderBookmarks = "savedFolderBookmarks"
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

/// Persistence helper for root shortcut bookmarks and aliases. Not main-actor
/// isolated so bookmark resolution can run off the main thread at startup —
/// a saved shortcut on a stuck network share would otherwise freeze app
/// launch (URL(resolvingBookmarkData:) blocks indefinitely on hung I/O).
/// Reads and writes delegate to UserDefaults, which is documented thread-safe;
/// `saveBookmarks` and `saveShortcutAliases` are read-modify-write against the
/// in-memory shortcut list, so ShortcutStore only calls them on the main actor
/// to keep UserDefaults single-writer.
final class Settings: Sendable {
    static let shared = Settings()

    private init() {}

    /// Raw bookmark blobs exactly as stored. Single accessor for the storage
    /// format so the onboarding probe and the startup resolver can't drift
    /// apart on how the list is read.
    var storedBookmarks: [Data] {
        UserDefaults.standard.array(forKey: UDKey.savedFolderBookmarks) as? [Data] ?? []
    }

    /// Cheap "has the user ever added a shortcut?" probe. Reads the bookmark
    /// list without resolving any bookmarks, so it can answer instantly even
    /// if a saved bookmark would block on resolution. Used for the
    /// first-launch onboarding decision.
    var hasStoredFolders: Bool { !storedBookmarks.isEmpty }

    /// Resolves one stored bookmark blob. `.withoutUI` and `.withoutMounting`
    /// keep resolution silent: Monarch never initiates a network mount or
    /// triggers the system "server is not available" dialog — a bookmark on
    /// an unmounted volume simply fails fast and surfaces as an unresolved
    /// row until the user mounts the volume themselves. Still blocking (a
    /// mounted-but-dead share can stall on I/O), so call it off the main
    /// thread.
    func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withoutUI, .withoutMounting],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &isStale) else { return nil }
        return (url, isStale)
    }

    /// Reads the path cached inside bookmark data without resolving it: no
    /// I/O, no mount attempt, no UI. Lets an unresolvable bookmark render as
    /// a visible (greyed-out) shortcut row.
    func cachedBookmarkInfo(_ data: Data) -> (path: String, isDirectory: Bool)? {
        let values = URL.resourceValues(forKeys: [.pathKey, .isDirectoryKey], fromBookmarkData: data)
        guard let path = values?.path else { return nil }
        return (path, values?.isDirectory ?? true)
    }

    /// Fresh bookmark data for a live URL. Generating anew on every save is
    /// also what refreshes stale bookmarks after a folder moves.
    ///
    /// Plain bookmarks (not security-scoped). Monarch is not sandboxed, so
    /// it has direct file system access — security-scoped bookmarks are
    /// unnecessary and only matter for sandboxed apps that need explicit
    /// permission grants per user-selected folder.
    func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func saveBookmarkBlobs(_ blobs: [Data]) {
        UserDefaults.standard.set(blobs, forKey: UDKey.savedFolderBookmarks)
    }

    func loadShortcutAliases() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: UDKey.rootShortcutAliases) as? [String: String] ?? [:]
    }

    func saveShortcutAliases(_ aliases: [String: String]) {
        UserDefaults.standard.set(aliases, forKey: UDKey.rootShortcutAliases)
    }
}
