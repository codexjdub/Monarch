import XCTest
@testable import Monarch

/// FileDropHelper against real temp directories. The same-parent case is the
/// regression test for the 2026-07-14 fix: a move-drop onto the file's own
/// parent folder used to rename it to "name copy".
///
/// NOTE: the local Command Line Tools ship no XCTest (nor Swift Testing), so
/// this suite runs in CI only (GitHub's macOS runners carry full Xcode).
/// `swift build` locally is unaffected — SwiftPM only builds test targets
/// for `swift test`.
final class FileDropTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileDropTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func makeFile(_ name: String, in dir: URL? = nil) throws -> URL {
        let url = (dir ?? root).appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url
    }

    private func makeDir(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMoveOntoOwnParentIsNoOp() throws {
        let file = try makeFile("report.pdf")

        let succeeded = FileDropHelper.perform(urls: [file], into: root, operation: .move)

        XCTAssertEqual(succeeded, 1, "no-op counts as success so no error alert appears")
        XCTAssertTrue(fm.fileExists(atPath: file.path), "file must keep its name")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("report copy.pdf").path),
                       "file must not be renamed to a copy-suffixed name")
    }

    func testCopyIntoOwnParentDuplicates() throws {
        let file = try makeFile("report.pdf")

        let succeeded = FileDropHelper.perform(urls: [file], into: root, operation: .copy)

        XCTAssertEqual(succeeded, 1)
        XCTAssertTrue(fm.fileExists(atPath: file.path), "original stays")
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("report copy.pdf").path),
                      "copy-into-same-folder duplicates, like Finder")
    }

    func testMoveIntoOtherFolder() throws {
        let file = try makeFile("note.txt")
        let dest = try makeDir("dest")

        let succeeded = FileDropHelper.perform(urls: [file], into: dest, operation: .move)

        XCTAssertEqual(succeeded, 1)
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("note.txt").path))
    }

    func testCollisionNaming() throws {
        let dest = try makeDir("dest")
        _ = try makeFile("note.txt", in: dest)

        let first = try makeFile("note.txt", in: try makeDir("src1"))
        XCTAssertEqual(FileDropHelper.perform(urls: [first], into: dest, operation: .move), 1)
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("note copy.txt").path))

        let second = try makeFile("note.txt", in: try makeDir("src2"))
        XCTAssertEqual(FileDropHelper.perform(urls: [second], into: dest, operation: .move), 1)
        XCTAssertTrue(fm.fileExists(atPath: dest.appendingPathComponent("note copy 2.txt").path))
    }

    func testDropIntoOwnSubtreeIsRejected() throws {
        let dir = try makeDir("outer")
        let sub = dir.appendingPathComponent("inner")
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)

        let succeeded = FileDropHelper.perform(urls: [dir], into: sub, operation: .move)

        XCTAssertEqual(succeeded, 0)
        XCTAssertTrue(fm.fileExists(atPath: dir.path), "folder untouched")
        XCTAssertFalse(fm.fileExists(atPath: sub.appendingPathComponent("outer").path))
    }
}
