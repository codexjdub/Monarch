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
        // Unresolved at init — layer 3 decides these, in loadFolder.
        let mystery = try item("mystery")
        XCTAssertNil(mystery.previewKind, "no extension: init leaves it unresolved")
        XCTAssertTrue(mystery.needsContentSniff, "extensionless files are sniff candidates")

        let folder = FileItem(url: dir)
        XCTAssertNil(folder.previewKind, "directories never get a file preview")
        XCTAssertTrue(folder.isDirectory)
        XCTAssertTrue(folder.exists)

        let missing = FileItem(url: dir.appendingPathComponent("nope.txt"))
        XCTAssertFalse(missing.exists, "missing paths drive the greyed-row treatment")
        XCTAssertFalse(missing.needsContentSniff, "never sniff a path that isn't there")
    }

    // MARK: - Preview routing layers 2 and 3

    /// Temp directory helper shared by the sniffing tests.
    private func makeDir(_ label: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PureLogicTests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every plain text file must end up previewable, whichever layer gets it.
    ///
    /// Deliberately does NOT assert which layer resolves a given extension.
    /// Layer 2's coverage depends on installed software — `.tex` resolves as
    /// `org.tug.tex` on a machine with TeX and `.hs` as a Haskell script where
    /// GHC is present, but both fall through to layer 3 on a clean CI runner.
    /// That variation is the design working, not a defect, so assert the
    /// contract that actually holds everywhere: nothing plain text is dropped.
    func testPlainTextAlwaysReachesTextPreview() throws {
        let dir = try makeDir("layers")
        defer { try? FileManager.default.removeItem(at: dir) }

        let names = ["patch.diff", "rules.mk", "paper.tex", "main.hs", "run.command",
                     "window.qml", "config.before-systray-after-scratchpad", "COPYING"]
        for name in names {
            try "plain text content\n".data(using: .utf8)!
                .write(to: dir.appendingPathComponent(name))
        }
        var items = names.map { FileItem(url: dir.appendingPathComponent($0)) }

        // Before the sniff pass every one is either already routed or queued
        // for layer 3 — never silently unpreviewable.
        for item in items {
            XCTAssertTrue(item.previewKind == .text || item.needsContentSniff,
                          "\(item.name) must be resolved or queued, not dropped")
        }

        FileItem.resolveUnclassifiedText(in: &items)
        for item in items {
            XCTAssertEqual(item.previewKind, .text,
                           "\(item.name) is plain text and must preview as text")
        }
    }

    /// A type the system positively knows is not text must never cost a read.
    /// `public.png` is an Apple-declared type, present on every machine.
    func testKnownBinaryTypeSkipsSniff() throws {
        let dir = try makeDir("binaryskip")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        let item = FileItem(url: url)
        XCTAssertEqual(item.previewKind, .image)
        XCTAssertFalse(item.needsContentSniff)
    }

    /// Layer 3 gate: only genuinely unclassified files become candidates.
    func testContentSniffCandidates() throws {
        let dir = try makeDir("candidates")
        defer { try? FileManager.default.removeItem(at: dir) }

        func item(_ name: String) throws -> FileItem {
            let url = dir.appendingPathComponent(name)
            try "content".data(using: .utf8)!.write(to: url)
            return FileItem(url: url)
        }

        // Suffixes nothing can plausibly register, plus an extensionless file
        // (empty extension always means "ask the bytes"). Real-world examples
        // like .qml aren't used here: they'd start failing the day someone
        // installs an app that claims the type — the same machine-dependence
        // that broke the first version of these tests in CI.
        for name in ["notes.zzqqx", "config.before-systray-after-scratchpad", "COPYING"] {
            XCTAssertTrue(try item(name).needsContentSniff, "\(name) must be sniffed")
        }
        // Already routed by the allowlists — nothing left to decide.
        for name in ["notes.txt", "photo.png", "letter.docx"] {
            XCTAssertFalse(try item(name).needsContentSniff, "\(name) is already routed")
        }
    }

    func testLooksLikeText() throws {
        let dir = try makeDir("sniff")
        defer { try? FileManager.default.removeItem(at: dir) }

        func write(_ name: String, _ data: Data) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }

        XCTAssertTrue(FileItem.looksLikeText(
            at: try write("utf8", "import QtQuick\nRectangle { }\n".data(using: .utf8)!)))

        XCTAssertFalse(FileItem.looksLikeText(
            at: try write("binary", Data([0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01, 0x02]))),
            "a NUL byte means binary")

        XCTAssertFalse(FileItem.looksLikeText(at: try write("empty", Data())),
                       "nothing to preview in an empty file")

        XCTAssertFalse(FileItem.looksLikeText(at: dir.appendingPathComponent("absent")))
        XCTAssertFalse(FileItem.looksLikeText(at: dir), "a directory is not text")

        // The read cap can land mid-character. Both of these are valid UTF-8
        // files whose multi-byte character straddles the 4096-byte boundary;
        // without trimming the incomplete tail they'd be misread as binary.
        for pad in [FileItem.sniffByteCount - 1, FileItem.sniffByteCount - 2] {
            var data = Data(repeating: UInt8(ascii: "a"), count: pad)
            data.append("€ trailing text".data(using: .utf8)!)   // € is 3 bytes
            XCTAssertTrue(FileItem.looksLikeText(at: try write("straddle-\(pad)", data)),
                          "character split across the read cap must still read as text")
        }
    }

    /// The sniff pass is capped so a directory of thousands of unknown-type
    /// files can't inflate folder load time.
    func testContentSniffRespectsBudget() throws {
        let dir = try makeDir("budget")
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<50 {
            try "text".data(using: .utf8)!
                .write(to: dir.appendingPathComponent("f\(i).unknownext"))
        }
        var items = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .map { FileItem(url: $0) }
        XCTAssertEqual(items.filter(\.needsContentSniff).count, 50)

        FileItem.resolveUnclassifiedText(in: &items, budget: 10)
        XCTAssertEqual(items.filter { $0.previewKind == .text }.count, 10,
                       "only `budget` files are read; the rest stay unresolved")
    }

    /// End-to-end: loadFolder must upgrade unclassified text files to `.text`
    /// and leave binaries alone. This is the behaviour that makes .qml and
    /// arbitrary suffixes previewable at all.
    func testLoadFolderResolvesUnknownTextViaSniff() throws {
        let dir = try makeDir("loadfolder")
        defer { try? FileManager.default.removeItem(at: dir) }

        try "import QtQuick\nRectangle { }\n".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("window.qml"))
        try "port = 8080\n".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("config.before-systray-after-scratchpad"))
        try Data([0x00, 0x01, 0x02, 0x03])
            .write(to: dir.appendingPathComponent("blob.bin"))
        try "plain\n".data(using: .utf8)!
            .write(to: dir.appendingPathComponent("readme.txt"))

        let contents = CascadeModel.loadFolder(dir, pinnedURLs: [], sortOrder: .name,
                                               showHidden: false, descending: false)
        func kind(_ name: String) -> PreviewKind?? {
            contents.items.first { $0.name == name }?.previewKind
        }

        XCTAssertEqual(kind("window.qml"), .text, "unknown extension, text content")
        XCTAssertEqual(kind("config.before-systray-after-scratchpad"), .text,
                       "arbitrary suffix no allowlist could ever cover")
        XCTAssertEqual(kind("readme.txt"), .text, "allowlist path still works")
        XCTAssertEqual(kind("blob.bin"), PreviewKind?.none,
                       "binary content stays unpreviewable")
    }
}
