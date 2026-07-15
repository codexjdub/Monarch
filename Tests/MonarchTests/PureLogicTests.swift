import XCTest
@testable import Monarch

/// Pure helpers: alias normalization, syntax inference, preview-kind mapping.
final class PureLogicTests: XCTestCase {

    // MARK: - RootShortcut.normalizedAlias

    func testAliasNormalization() {
        let url = URL(fileURLWithPath: "/Users/x/Documents")
        XCTAssertNil(RootShortcut.normalizedAlias(nil, for: url))
        XCTAssertNil(RootShortcut.normalizedAlias("   ", for: url))
        XCTAssertNil(RootShortcut.normalizedAlias("Documents", for: url),
                     "alias equal to the real name is redundant and dropped")
        XCTAssertEqual(RootShortcut.normalizedAlias("  Docs  ", for: url), "Docs")
    }

    // MARK: - SyntaxKind.infer

    func testSyntaxInference() {
        func kind(_ name: String) -> SyntaxKind {
            SyntaxKind.infer(url: URL(fileURLWithPath: "/tmp/\(name)"))
        }
        XCTAssertEqual(kind("main.swift"), .swift)
        XCTAssertEqual(kind("readme.md"), .markdown)
        XCTAssertEqual(kind("config.yaml"), .yaml)
        XCTAssertEqual(kind("Makefile"), .shell)
        XCTAssertEqual(kind(".env.local"), .yaml)
        XCTAssertEqual(kind("index.tsx"), .cLike)
        XCTAssertEqual(kind("notes.unknownext"), .plain)
    }

    // MARK: - FileItem.previewKind (real temp files: init stats the URL)

    func testPreviewKindMapping() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PureLogicTests-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        func item(_ name: String) throws -> FileItem {
            let url = dir.appendingPathComponent(name)
            try Data().write(to: url)
            return FileItem(url: url)
        }

        XCTAssertEqual(try item("photo.png").previewKind, .image)
        XCTAssertEqual(try item("notes.txt").previewKind, .text)
        XCTAssertEqual(try item("code.swift").previewKind, .text)
        XCTAssertEqual(try item("doc.pdf").previewKind, .pdf)
        XCTAssertEqual(try item("guide.md").previewKind, .markdown)
        XCTAssertEqual(try item("bundle.zip").previewKind, .archive)
        XCTAssertEqual(try item("letter.docx").previewKind, .quicklook)
        XCTAssertEqual(try item(".gitignore").previewKind, .text,
                       "known dotfile names preview as text")
        XCTAssertNil(try item("mystery").previewKind, "no extension, unknown name")

        let folder = FileItem(url: dir)
        XCTAssertNil(folder.previewKind, "directories never get a file preview")
        XCTAssertTrue(folder.isDirectory)
        XCTAssertTrue(folder.exists)

        let missing = FileItem(url: dir.appendingPathComponent("nope.txt"))
        XCTAssertFalse(missing.exists, "missing paths drive the greyed-row treatment")
    }
}
