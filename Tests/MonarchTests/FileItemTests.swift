import Testing
import Foundation
@testable import Monarch

/// Tests for FileItem — verifies that properties are correctly computed
/// and cached at init, including the batched resourceValues read.
struct FileItemTests {

    // MARK: - Fixture

    struct TempDir {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: url) }

        func makeFile(_ name: String, content: String = "x") throws -> URL {
            let u = url.appendingPathComponent(name)
            try content.write(to: u, atomically: true, encoding: .utf8)
            return u
        }

        func makeDir(_ name: String) throws -> URL {
            let u = url.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
    }

    // MARK: - isDirectory

    @Test func isDirectoryFalseForFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(!FileItem(url: try tmp.makeFile("test.txt")).isDirectory)
    }

    @Test func isDirectoryTrueForDirectory() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeDir("folder")).isDirectory)
    }

    // MARK: - name / isHidden

    @Test func nameIsLastPathComponent() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("document.txt")).name == "document.txt")
    }

    @Test func isHiddenForDotFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile(".gitignore")).isHidden)
    }

    @Test func isHiddenFalseForNormalFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(!FileItem(url: try tmp.makeFile("normal.txt")).isHidden)
    }

    // MARK: - fileSize

    @Test func fileSizeNilForDirectory() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeDir("folder")).fileSize == nil)
    }

    @Test func fileSizeNonNilForFile() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("sized.txt", content: "hello")).fileSize != nil)
    }

    // MARK: - previewKind

    @Test func previewKindNilForDirectory() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeDir("folder")).previewKind == nil)
    }

    @Test func previewKindNilForUnknownExtension() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("file.xyz123")).previewKind == nil)
    }

    @Test(arguments: ["jpg", "png", "gif", "heic", "webp"])
    func previewKindImage(ext: String) throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("img.\(ext)")).previewKind == .image)
    }

    @Test func previewKindPDF() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("doc.pdf")).previewKind == .pdf)
    }

    @Test(arguments: ["md", "markdown"])
    func previewKindMarkdown(ext: String) throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("readme.\(ext)")).previewKind == .markdown)
    }

    @Test(arguments: ["txt", "swift", "json", "sh"])
    func previewKindText(ext: String) throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("file.\(ext)")).previewKind == .text)
    }

    @Test(arguments: ["mp4", "mov", "mkv"])
    func previewKindVideo(ext: String) throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("vid.\(ext)")).previewKind == .video)
    }

    @Test(arguments: ["mp3", "m4a", "flac"])
    func previewKindAudio(ext: String) throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("track.\(ext)")).previewKind == .audio)
    }

    @Test(arguments: ["docx", "pages", "epub", "zip"])
    func previewKindQuickLook(ext: String) throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("file.\(ext)")).previewKind == .quicklook)
    }

    // MARK: - imageDimensions

    @Test func imageDimensionsNilForNonImage() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("doc.txt")).imageDimensions == nil)
    }

    @Test func imageDimensionsNilForDirectory() throws {
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeDir("imgfolder")).imageDimensions == nil)
    }

    @Test func imageDimensionsNilForFakeImageFile() throws {
        // .png extension but invalid data — CGImageSource should return nil.
        let tmp = try TempDir(); defer { tmp.cleanup() }
        #expect(FileItem(url: try tmp.makeFile("fake.png", content: "not an image")).imageDimensions == nil)
    }
}
