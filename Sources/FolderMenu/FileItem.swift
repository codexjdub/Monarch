import AppKit
import UniformTypeIdentifiers

/// A previewable file kind. Files with a non-nil previewKind open a preview
/// peek to the right (same hover/keyboard mechanics as folder peeks).
enum PreviewKind {
    case image
    case pdf
    case markdown
    case text
    /// Rich document and misc formats rendered via QLPreviewView (docx, epub,
    /// pages, numbers, keynote, rtf, odt, webarchive, svg, raw photos, fonts,
    /// 3D models, archives, etc.).
    case quicklook
    /// Video via QLPreviewView (gets a playable scrubber).
    case video
    /// Audio via QLPreviewView (play/scrub UI).
    case audio
}

private let imageExts: Set<String> = [
    "jpg", "jpeg", "png", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp"
]
private let markdownExts: Set<String> = ["md", "markdown", "mdown"]
private let textExts: Set<String> = [
    "txt", "text", "log", "csv", "tsv",
    "swift", "py", "rb", "js", "mjs", "cjs", "ts", "tsx", "jsx",
    "json", "yaml", "yml", "toml", "ini", "conf", "cfg",
    "xml", "html", "htm", "css", "scss", "sass",
    "sh", "bash", "zsh", "fish",
    "c", "h", "cpp", "hpp", "cc", "m", "mm",
    "go", "rs", "java", "kt", "kts", "scala",
    "pl", "lua", "php", "sql",
    "plist", "entitlements", "strings",
    "env", "gitignore", "gitconfig", "dockerignore",
    "srt", "vtt"
]
private let quicklookExts: Set<String> = [
    // Office Open XML
    "docx", "xlsx", "pptx",
    // Legacy Office
    "doc", "xls", "ppt",
    // Apple iWork
    "pages", "numbers", "key",
    // OpenDocument
    "odt", "ods", "odp",
    // Rich text / archives
    "rtf", "rtfd", "webarchive",
    // eBooks
    "epub",
    // Vector / misc images
    "svg", "ico", "icns",
    // Raw photos
    "cr2", "cr3", "nef", "arw", "dng", "raf", "orf", "rw2", "pef", "srw",
    // Fonts
    "ttf", "otf", "ttc", "woff", "woff2",
    // 3D
    "usdz", "usd", "usda", "usdc", "obj", "stl", "dae",
    // Notebooks (rendered as JSON text by QL; good enough)
    "ipynb",
    // Archives (QL shows file listing / metadata)
    "zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "xz"
]
private let videoExts: Set<String> = [
    "mp4", "m4v", "mov", "avi", "mkv", "webm", "mpg", "mpeg", "3gp", "ogv", "wmv", "flv"
]
private let audioExts: Set<String> = [
    "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "oga", "opus", "wma"
]

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }

    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var isHidden: Bool {
        name.hasPrefix(".")
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    var fileSize: String? {
        guard !isDirectory,
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// Non-nil if this file can be previewed in a peek pane. Folders never preview
    /// (they open a folder peek instead).
    var previewKind: PreviewKind? {
        guard !isDirectory else { return nil }
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return nil }
        if imageExts.contains(ext)     { return .image }
        if ext == "pdf"                { return .pdf }
        if markdownExts.contains(ext)  { return .markdown }
        if textExts.contains(ext)      { return .text }
        if videoExts.contains(ext)     { return .video }
        if audioExts.contains(ext)     { return .audio }
        if quicklookExts.contains(ext) { return .quicklook }
        return nil
    }

    var imageDimensions: String? {
        guard !isDirectory else { return nil }
        let imageTypes = ["jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp"]
        let ext = url.pathExtension.lowercased()
        guard imageTypes.contains(ext) else { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return "\(w) × \(h)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}
