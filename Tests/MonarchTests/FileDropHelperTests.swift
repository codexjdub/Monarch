import Testing
import Foundation
@testable import Monarch

/// Tests for FileDropHelper — collision naming and perform() behaviour.
/// Uses a real temp directory so the filesystem logic is exercised end-to-end.
struct FileDropHelperTests {

    // MARK: - Fixture

    struct Dirs {
        let src: URL
        let dst: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            src = base.appendingPathComponent("src")
            dst = base.appendingPathComponent("dst")
            try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: src.deletingLastPathComponent()) }

        @discardableResult
        func touch(_ name: String, in dir: URL) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try "x".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
    }

    // MARK: - Copy (no conflict)

    @Test func copyNoConflict() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let src = try dirs.touch("file.txt", in: dirs.src)
        let n = FileDropHelper.perform(urls: [src], into: dirs.dst, operation: .copy)

        #expect(n == 1)
        #expect(FileManager.default.fileExists(atPath: dirs.dst.appendingPathComponent("file.txt").path))
        #expect(FileManager.default.fileExists(atPath: src.path), "copy should leave source intact")
    }

    // MARK: - Collision naming

    @Test func copyFirstConflict() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let src = try dirs.touch("file.txt", in: dirs.src)
        try dirs.touch("file.txt", in: dirs.dst)       // pre-existing conflict

        FileDropHelper.perform(urls: [src], into: dirs.dst, operation: .copy)
        #expect(FileManager.default.fileExists(atPath: dirs.dst.appendingPathComponent("file copy.txt").path))
    }

    @Test func copySecondConflict() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let src = try dirs.touch("file.txt", in: dirs.src)
        try dirs.touch("file.txt", in: dirs.dst)
        try dirs.touch("file copy.txt", in: dirs.dst)

        FileDropHelper.perform(urls: [src], into: dirs.dst, operation: .copy)
        #expect(FileManager.default.fileExists(atPath: dirs.dst.appendingPathComponent("file copy 2.txt").path))
    }

    @Test func copyThirdConflict() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let src = try dirs.touch("file.txt", in: dirs.src)
        try dirs.touch("file.txt", in: dirs.dst)
        try dirs.touch("file copy.txt", in: dirs.dst)
        try dirs.touch("file copy 2.txt", in: dirs.dst)

        FileDropHelper.perform(urls: [src], into: dirs.dst, operation: .copy)
        #expect(FileManager.default.fileExists(atPath: dirs.dst.appendingPathComponent("file copy 3.txt").path))
    }

    @Test func copyNoExtensionConflict() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let src = try dirs.touch("README", in: dirs.src)
        try dirs.touch("README", in: dirs.dst)

        FileDropHelper.perform(urls: [src], into: dirs.dst, operation: .copy)
        #expect(FileManager.default.fileExists(atPath: dirs.dst.appendingPathComponent("README copy").path))
    }

    @Test func copyNoExtensionSecondConflict() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let src = try dirs.touch("README", in: dirs.src)
        try dirs.touch("README", in: dirs.dst)
        try dirs.touch("README copy", in: dirs.dst)

        FileDropHelper.perform(urls: [src], into: dirs.dst, operation: .copy)
        #expect(FileManager.default.fileExists(atPath: dirs.dst.appendingPathComponent("README copy 2").path))
    }

    // MARK: - Move

    @Test func moveRemovesSource() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let src = try dirs.touch("toMove.txt", in: dirs.src)
        let n = FileDropHelper.perform(urls: [src], into: dirs.dst, operation: .move)

        #expect(n == 1)
        #expect(!FileManager.default.fileExists(atPath: src.path), "move should remove source")
        #expect(FileManager.default.fileExists(atPath: dirs.dst.appendingPathComponent("toMove.txt").path))
    }

    // MARK: - Rejected drops

    @Test func skipsSelfDrop() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let n = FileDropHelper.perform(urls: [dirs.src], into: dirs.src, operation: .copy)
        #expect(n == 0)
    }

    @Test func skipsSubtreeDrop() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let child = dirs.src.appendingPathComponent("child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let n = FileDropHelper.perform(urls: [dirs.src], into: child, operation: .move)
        #expect(n == 0)
    }

    @Test func returnsCountOfSuccesses() throws {
        let dirs = try Dirs()
        defer { dirs.cleanup() }

        let a = try dirs.touch("a.txt", in: dirs.src)
        let b = try dirs.touch("b.txt", in: dirs.src)
        let n = FileDropHelper.perform(urls: [a, b], into: dirs.dst, operation: .copy)
        #expect(n == 2)
    }
}
