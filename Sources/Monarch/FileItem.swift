import AppKit

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

    // Cheap derived properties — computed on every access (trivial cost).
    var name: String { url.lastPathComponent }
    var isHidden: Bool { name.hasPrefix(".") }

    // Cached at init — these involve filesystem or image-header reads that
    // would otherwise repeat on every row render.
    let icon: NSImage
    let isDirectory: Bool
    let fileSize: String?
    let previewKind: PreviewKind?
    let imageDimensions: String?

    init(url: URL) {
        self.url = url
        self.icon = NSWorkspace.shared.icon(forFile: url.path)

        // Batch-fetch isDirectory + fileSize in one syscall.
        let resources = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let isDir = resources?.isDirectory ?? false
        self.isDirectory = isDir
        if let bytes = resources?.fileSize, !isDir {
            self.fileSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            self.fileSize = nil
        }

        // previewKind — pure string comparisons, but depends on isDirectory.
        let ext = url.pathExtension.lowercased()
        if isDir || ext.isEmpty {
            self.previewKind = nil
        } else if imageExts.contains(ext)     { self.previewKind = .image }
        else if ext == "pdf"                   { self.previewKind = .pdf }
        else if markdownExts.contains(ext)     { self.previewKind = .markdown }
        else if textExts.contains(ext)         { self.previewKind = .text }
        else if videoExts.contains(ext)        { self.previewKind = .video }
        else if audioExts.contains(ext)        { self.previewKind = .audio }
        else if quicklookExts.contains(ext)    { self.previewKind = .quicklook }
        else                                   { self.previewKind = nil }

        // imageDimensions — fast header-only CGImageSource read, images only.
        if self.previewKind == .image,
           let src   = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w     = props[kCGImagePropertyPixelWidth]  as? Int,
           let h     = props[kCGImagePropertyPixelHeight] as? Int {
            self.imageDimensions = "\(w) × \(h)"
        } else {
            self.imageDimensions = nil
        }
    }

    func hash(into hasher: inout Hasher) { hasher.combine(url) }
    static func == (lhs: FileItem, rhs: FileItem) -> Bool { lhs.url == rhs.url }
}
