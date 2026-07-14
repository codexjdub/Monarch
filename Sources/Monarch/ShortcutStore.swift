import AppKit
import Foundation

struct RootShortcut: Hashable {
    let url: URL
    var alias: String?
    /// Last known bookmark blob for this shortcut. For unresolved entries
    /// it's the stored blob that couldn't be resolved (written back to disk
    /// untouched); for resolved entries it's the fallback persist() writes
    /// if regenerating the bookmark fails (file vanished mid-session).
    var bookmarkBlob: Data? = nil
    /// True when the saved bookmark couldn't be resolved (unreachable volume,
    /// deleted file). The row renders from the path cached inside the blob,
    /// greyed out via the missing-shortcut treatment, and upgrades in place
    /// when the blob resolves late or its volume mounts.
    var isUnresolved: Bool = false

    init(url: URL, alias: String? = nil, bookmarkBlob: Data? = nil, isUnresolved: Bool = false) {
        self.url = url
        self.alias = Self.normalizedAlias(alias, for: url)
        self.bookmarkBlob = bookmarkBlob
        self.isUnresolved = isUnresolved
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
    @Published var shortcuts: [RootShortcut] = []

    /// False until the startup bookmark resolution has been applied. While
    /// false, `shortcuts` is a partial view of the saved list (only mutations
    /// made this session), so persist() must not write it to disk — doing so
    /// would destroy every not-yet-loaded shortcut.
    @Published private(set) var initialLoadApplied = false

    /// Safety net for stored blobs whose cached path can't even be read
    /// (corrupt data). Expected to always be empty; carried through every
    /// save and retried on volume mounts so nothing is ever destroyed.
    private var residualBookmarks: [Data] = []

    private enum BlobResolution {
        case resolved(url: URL, isStale: Bool)
        case failed
    }

    /// Snapshot of the stored blobs taken at init; resolution tasks report
    /// back by index into this array.
    private let initialBlobs: [Data]
    private var resolutionResults: [Int: BlobResolution] = [:]
    /// Set when the user mutates the list before the initial load lands, so
    /// the merged result is persisted exactly once at apply time.
    private var mutatedDuringLoad = false
    private var mountObserver: NSObjectProtocol?

    /// How long startup waits for bookmark resolution before publishing
    /// whatever has resolved. Hung resolutions keep running past the deadline
    /// and upgrade their row whenever they complete.
    private static let initialResolveTimeoutNanoseconds: UInt64 = 10_000_000_000

    init() {
        initialBlobs = Settings.shared.storedBookmarks

        // Shortcuts on unreachable volumes recover when the volume comes back.
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.retryUnresolvedBookmarks() }
        }

        guard !initialBlobs.isEmpty else {
            initialLoadApplied = true
            return
        }

        // Resolve each bookmark independently and off the main thread so one
        // hung volume can neither freeze launch nor delay the other
        // shortcuts. Results funnel back to the main actor; the deadline task
        // applies whatever has resolved (the rest appear as unresolved rows),
        // and stragglers upgrade their row when they eventually finish.
        for (index, blob) in initialBlobs.enumerated() {
            Task { [weak self] in
                let result = await Self.resolveOffMain(blob)
                self?.bookmarkResolved(index: index, result: result)
            }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.initialResolveTimeoutNanoseconds)
            self?.applyInitialLoad()
        }
    }

    // MARK: - Startup resolution

    /// Bridges the blocking bookmark resolution onto a GCD global queue. GCD
    /// spawns replacement threads when one blocks on a dead volume; running
    /// the same blocking call on the Swift concurrency pool would starve it.
    private static func resolveOffMain(_ data: Data) async -> (url: URL, isStale: Bool)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Settings.shared.resolveBookmark(data))
            }
        }
    }

    private func bookmarkResolved(index: Int, result: (url: URL, isStale: Bool)?) {
        guard !initialLoadApplied else {
            // Straggler that finished after the deadline already published.
            promoteUnresolvedBookmark(initialBlobs[index], resolvedURL: result?.url)
            return
        }
        resolutionResults[index] = result.map { .resolved(url: $0.url, isStale: $0.isStale) } ?? .failed
        if resolutionResults.count == initialBlobs.count { applyInitialLoad() }
    }

    private func applyInitialLoad() {
        guard !initialLoadApplied else { return }
        initialLoadApplied = true

        let aliases = Settings.shared.loadShortcutAliases()
        var loaded: [RootShortcut] = []
        var seenPaths = Set<String>()
        var anyStale = false
        for (index, blob) in initialBlobs.enumerated() {
            switch resolutionResults[index] {
            case .resolved(let url, let isStale):
                guard seenPaths.insert(url.path).inserted else { continue }
                loaded.append(RootShortcut(url: url, alias: aliases[url.path], bookmarkBlob: blob))
                anyStale = anyStale || isStale
            case .failed, nil:
                // Failed (deleted file, unplugged volume) or still resolving
                // (dead share): surface it as an unresolved row built from
                // the path cached inside the blob — visible, greyed out, and
                // removable like any other shortcut.
                if let info = Settings.shared.cachedBookmarkInfo(blob) {
                    guard seenPaths.insert(info.path).inserted else { continue }
                    let url = URL(fileURLWithPath: info.path, isDirectory: info.isDirectory)
                    loaded.append(RootShortcut(url: url, alias: aliases[info.path],
                                               bookmarkBlob: blob, isUnresolved: true))
                } else {
                    residualBookmarks.append(blob)
                }
            }
        }
        resolutionResults = [:]

        // Merge with anything the user did while resolution was pending: the
        // stored order wins, session adds append at the end, and an alias the
        // user just set on a URL that also loaded beats the stored alias.
        let pendingByURL = Dictionary(shortcuts.map { ($0.url, $0) },
                                      uniquingKeysWith: { first, _ in first })
        let loadedURLs = Set(loaded.map(\.url))
        var merged = loaded.map { stored in
            if let pending = pendingByURL[stored.url], pending.alias != nil { return pending }
            return stored
        }
        merged += shortcuts.filter { !loadedURLs.contains($0.url) }
        shortcuts = merged

        // Disk already matches the stored blobs unless the user mutated the
        // list (merge needs writing) or a bookmark resolved stale (persist
        // regenerates fresh bookmark data, which is the refresh).
        if mutatedDuringLoad || anyStale { persist() }
    }

    /// Re-resolves unresolved bookmarks after a volume mounts, upgrading any
    /// that succeed. Idempotent: duplicate in-flight resolutions of the same
    /// blob no-op in promoteUnresolvedBookmark once the first one lands.
    private func retryUnresolvedBookmarks() {
        guard initialLoadApplied else { return }
        let blobs = shortcuts.filter(\.isUnresolved).compactMap(\.bookmarkBlob) + residualBookmarks
        for blob in blobs {
            Task { [weak self] in
                let result = await Self.resolveOffMain(blob)
                self?.promoteUnresolvedBookmark(blob, resolvedURL: result?.url)
            }
        }
    }

    private func promoteUnresolvedBookmark(_ blob: Data, resolvedURL: URL?) {
        guard let url = resolvedURL else { return }
        if let idx = shortcuts.firstIndex(where: { $0.isUnresolved && $0.bookmarkBlob == blob }) {
            var updated = shortcuts
            if updated.contains(where: { $0.url == url && !$0.isUnresolved }) {
                // A live entry already covers this URL — drop the duplicate.
                updated.remove(at: idx)
            } else {
                updated[idx] = RootShortcut(url: url, alias: updated[idx].alias, bookmarkBlob: blob)
            }
            shortcuts = updated
            persist()
        } else if let pos = residualBookmarks.firstIndex(of: blob) {
            residualBookmarks.remove(at: pos)
            if !shortcuts.contains(where: { $0.url == url }) {
                shortcuts.append(RootShortcut(url: url,
                                              alias: Settings.shared.loadShortcutAliases()[url.path],
                                              bookmarkBlob: blob))
            }
            persist()
        }
    }

    // MARK: - Persistence

    private func persist() {
        guard initialLoadApplied else {
            // The in-memory list is a partial view until the initial load
            // lands; writing it wholesale would destroy every not-yet-loaded
            // shortcut. Remember that something changed and write once,
            // merged, at apply time.
            mutatedDuringLoad = true
            return
        }
        let blobs = shortcuts.compactMap { shortcut in
            shortcut.isUnresolved
                ? shortcut.bookmarkBlob
                : Settings.shared.makeBookmark(for: shortcut.url) ?? shortcut.bookmarkBlob
        }
        Settings.shared.saveBookmarkBlobs(blobs + residualBookmarks)

        var aliases: [String: String] = [:]
        for shortcut in shortcuts {
            if let alias = shortcut.alias { aliases[shortcut.url.path] = alias }
        }
        Settings.shared.saveShortcutAliases(aliases)
    }

    // MARK: - Mutations

    func add(_ url: URL) {
        // Path-based match so re-adding an unresolved shortcut's location
        // (e.g. the folder was recreated) acts as a relink instead of a no-op
        // against a placeholder row.
        if let idx = shortcuts.firstIndex(where: { $0.url.path == url.path }) {
            guard shortcuts[idx].isUnresolved else { return }
            var updated = shortcuts
            updated[idx] = RootShortcut(url: url, alias: updated[idx].alias,
                                        bookmarkBlob: Settings.shared.makeBookmark(for: url))
            shortcuts = updated
            persist()
            return
        }
        shortcuts.append(RootShortcut(url: url, bookmarkBlob: Settings.shared.makeBookmark(for: url)))
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
        updated[idx] = RootShortcut(url: newURL, alias: updated[idx].alias,
                                    bookmarkBlob: Settings.shared.makeBookmark(for: newURL))
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
