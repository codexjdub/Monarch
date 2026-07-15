import XCTest
import AppKit
@testable import Monarch

/// End-to-end tests of shortcut persistence: bookmark blobs are seeded into
/// UserDefaults (the xctest runner's own domain — never the real app's),
/// a ShortcutStore is constructed, and the published result is asserted.
///
/// The mutation-during-load test is the permanent regression test for the
/// data-loss window shipped in 11ff660: any persist() before the async
/// resolution landed used to overwrite the saved bookmark list with the
/// nearly-empty in-memory list.
///
/// Tests share the runner's UserDefaults keys, so this class must not run
/// with `swift test --parallel`. CI uses plain `swift test` (serial).
final class ShortcutStoreTests: XCTestCase {
    private var tempDirs: [URL] = []
    private let fm = FileManager.default

    override func setUpWithError() throws {
        resetDefaults()
    }

    override func tearDownWithError() throws {
        resetDefaults()
        for dir in tempDirs { try? fm.removeItem(at: dir) }
        tempDirs = []
    }

    private func resetDefaults() {
        UserDefaults.standard.removeObject(forKey: UDKey.savedFolderBookmarks)
        UserDefaults.standard.removeObject(forKey: UDKey.rootShortcutAliases)
    }

    private func makeTempDir(_ label: String) throws -> URL {
        let raw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ShortcutStoreTests-\(label)-\(UUID().uuidString)")
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        // Canonicalize via .canonicalPathKey: bookmark resolution returns
        // /private/var/... while NSTemporaryDirectory() hands out the
        // /var/... symlink form. Note resolvingSymlinksInPath() can NOT do
        // this — it strips the /private prefix as a documented special case,
        // returning the alias form. Verified: canonicalPath matches bookmark
        // resolution output exactly.
        let canonical = try XCTUnwrap(
            raw.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
        let url = URL(fileURLWithPath: canonical, isDirectory: true)
        tempDirs.append(url)
        return url
    }

    private func seedBookmarks(_ urls: [URL]) throws {
        let blobs = try urls.map { url -> Data in
            try XCTUnwrap(Settings.shared.makeBookmark(for: url),
                          "bookmark creation for \(url.path)")
        }
        UserDefaults.standard.set(blobs, forKey: UDKey.savedFolderBookmarks)
    }

    private func storedBlobCount() -> Int {
        (UserDefaults.standard.array(forKey: UDKey.savedFolderBookmarks) as? [Data])?.count ?? 0
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 5,
                           _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: - Tests

    @MainActor
    func testLoadsSavedBookmarksInOrderWithAliases() async throws {
        let a = try makeTempDir("a")
        let b = try makeTempDir("b")
        try seedBookmarks([a, b])
        UserDefaults.standard.set([a.path: "Alias A"], forKey: UDKey.rootShortcutAliases)

        let store = ShortcutStore()
        let loaded = await waitUntil { store.initialLoadApplied }

        XCTAssertTrue(loaded, "initial load must apply")
        XCTAssertEqual(store.shortcuts.map(\.url.path), [a.path, b.path], "stored order preserved")
        XCTAssertEqual(store.shortcuts.first?.alias, "Alias A")
        XCTAssertNil(store.shortcuts.last?.alias)
        XCTAssertFalse(store.shortcuts.contains(where: \.isUnresolved))
    }

    @MainActor
    func testAddDuringPendingLoadPreservesSavedShortcuts() async throws {
        // The 11ff660 data-loss regression: adding a shortcut while the
        // startup resolution was still pending permanently destroyed every
        // previously saved bookmark.
        let a = try makeTempDir("a")
        let b = try makeTempDir("b")
        try seedBookmarks([a, b])

        let store = ShortcutStore()
        XCTAssertFalse(store.initialLoadApplied,
                       "load must still be pending synchronously after init")

        let c = try makeTempDir("c")
        store.add(c)
        XCTAssertEqual(store.shortcuts.map(\.url.path), [c.path],
                       "only the session mutation is visible pre-apply")
        XCTAssertEqual(storedBlobCount(), 2,
                       "persist() must not touch disk while the load is pending")

        let loaded = await waitUntil { store.initialLoadApplied }
        XCTAssertTrue(loaded)
        XCTAssertEqual(store.shortcuts.map(\.url.path), [a.path, b.path, c.path],
                       "saved shortcuts first in stored order, session add appended")
        XCTAssertEqual(storedBlobCount(), 3, "merged list persisted once at apply")
    }

    @MainActor
    func testUnresolvableBookmarkSurfacesAsRowAndSurvivesPersist() async throws {
        let gone = try makeTempDir("gone")
        try seedBookmarks([gone])
        try fm.removeItem(at: gone)

        let store = ShortcutStore()
        let loaded = await waitUntil { store.initialLoadApplied }
        XCTAssertTrue(loaded)

        XCTAssertEqual(store.shortcuts.count, 1, "unresolved bookmark is a visible entry")
        let entry = try XCTUnwrap(store.shortcuts.first)
        XCTAssertTrue(entry.isUnresolved)
        XCTAssertEqual(entry.url.path, gone.path, "row renders the path cached in the blob")

        // Any later persist must carry the unresolved blob through untouched.
        let other = try makeTempDir("other")
        store.add(other)
        XCTAssertEqual(storedBlobCount(), 2, "unresolved blob survives the save")
    }

    @MainActor
    func testUnresolvedEntryPromotesInPlaceOnVolumeMount() async throws {
        let flaky = try makeTempDir("flaky")
        let stable = try makeTempDir("stable")
        try seedBookmarks([flaky, stable])
        try fm.removeItem(at: flaky)

        let store = ShortcutStore()
        let loaded = await waitUntil { store.initialLoadApplied }
        XCTAssertTrue(loaded)
        XCTAssertTrue(try XCTUnwrap(store.shortcuts.first).isUnresolved)

        // Recreate the folder, then simulate a volume mount — the retry
        // resolves the carried blob and upgrades the row in place.
        try fm.createDirectory(at: flaky, withIntermediateDirectories: true)
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didMountNotification, object: nil)

        let promoted = await waitUntil { store.shortcuts.first?.isUnresolved == false }
        XCTAssertTrue(promoted, "row upgrades once the bookmark resolves")
        XCTAssertEqual(store.shortcuts.map(\.url.path), [flaky.path, stable.path],
                       "promotion keeps the entry's original position")
    }
}
