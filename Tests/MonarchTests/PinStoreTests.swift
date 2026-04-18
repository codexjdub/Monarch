import Testing
import Foundation
@testable import Monarch

/// Tests for PinStore — toggle, ordering, and per-folder isolation.
/// Each test generates unique folder URLs via UUID so tests are fully independent
/// and leave no state behind in the shared PinStore.
@MainActor
struct PinStoreTests {

    // MARK: - Helpers

    private func makeURLs() -> (folder: URL, a: URL, b: URL) {
        let folder = URL(fileURLWithPath: "/tmp/monarch-test-\(UUID().uuidString)")
        return (folder,
                folder.appendingPathComponent("a.txt"),
                folder.appendingPathComponent("b.txt"))
    }

    // MARK: - Defaults

    @Test func unpinnedByDefault() {
        let (folder, a, _) = makeURLs()
        #expect(!PinStore.shared.isPinned(a, in: folder))
        #expect(PinStore.shared.pinned(in: folder) == [])
    }

    // MARK: - Toggle

    @Test func togglePinsFile() {
        let (folder, a, _) = makeURLs()
        let result = PinStore.shared.togglePin(a, in: folder)
        #expect(result == true, "togglePin should return true when pinning")
        #expect(PinStore.shared.isPinned(a, in: folder))
    }

    @Test func toggleUnpinsFile() {
        let (folder, a, _) = makeURLs()
        PinStore.shared.togglePin(a, in: folder)
        let result = PinStore.shared.togglePin(a, in: folder)
        #expect(result == false, "togglePin should return false when unpinning")
        #expect(!PinStore.shared.isPinned(a, in: folder))
    }

    // MARK: - Ordering

    @Test func pinsRetainInsertionOrder() {
        let (folder, a, b) = makeURLs()
        PinStore.shared.togglePin(a, in: folder)
        PinStore.shared.togglePin(b, in: folder)
        #expect(PinStore.shared.pinned(in: folder) == [a, b])
    }

    @Test func unpinMiddleItemPreservesRemainingOrder() {
        let (folder, a, b) = makeURLs()
        let c = folder.appendingPathComponent("c.txt")
        PinStore.shared.togglePin(a, in: folder)
        PinStore.shared.togglePin(b, in: folder)
        PinStore.shared.togglePin(c, in: folder)
        PinStore.shared.togglePin(b, in: folder) // unpin middle
        #expect(PinStore.shared.pinned(in: folder) == [a, c])
    }

    // MARK: - Isolation

    @Test func pinsIsolatedByFolder() {
        let (folder1, a, _) = makeURLs()
        let (folder2, _, _) = makeURLs()
        PinStore.shared.togglePin(a, in: folder1)
        #expect(!PinStore.shared.isPinned(a, in: folder2),
                "pin in folder1 should not appear in folder2")
    }

    @Test func unpinLastItemLeavesEmptyResult() {
        let (folder, a, _) = makeURLs()
        PinStore.shared.togglePin(a, in: folder)
        PinStore.shared.togglePin(a, in: folder)
        #expect(PinStore.shared.pinned(in: folder) == [])
    }
}
