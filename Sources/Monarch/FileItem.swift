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
    /// 3D models, etc.).
    case quicklook
    /// Video via QLPreviewView (gets a playable scrubber).
    case video
    /// Audio via QLPreviewView (play/scrub UI).
    case audio
    /// Archives with a readable TOC (zip, tar, tar.gz, etc.).
    case archive
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
    // Formats without standard CLI tools — fall back to QL
    "7z", "rar", "xz"
]
private let archiveExts: Set<String> = [
    "zip", "tar", "gz", "tgz", "bz2"
]
private let videoExts: Set<String> = [
    "mp4", "m4v", "mov", "avi", "mkv", "webm", "mpg", "mpeg", "3gp", "ogv", "wmv", "flv"
]
private let audioExts: Set<String> = [
    "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "oga", "opus", "wma"
]

enum FileItemRole {
    case standard
    case rootShortcut
    case frequent
}

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let role: FileItemRole
    let displayNameOverride: String?
    let subtitleOverride: String?

    // Cheap derived properties — computed on every access (trivial cost).
    var name: String { url.lastPathComponent }
    var displayName: String { displayNameOverride ?? name }
    var isHidden: Bool { name.hasPrefix(".") }

    // Cached at init — these involve filesystem or image-header reads that
    // would otherwise repeat on every row render.
    let icon: NSImage
    let isDirectory: Bool
    let fileSize: String?
    let previewKind: PreviewKind?
    let imageDimensions: String?
    /// True if the backing path existed at construction time. Meaningful
    /// mainly for root shortcuts — deep-folder items are always true (they
    /// were just enumerated). When false, UI dims the row and intercepts
    /// clicks with a "Remove / Locate" alert.
    let exists: Bool
    /// Content modification date at construction time. Used as a cache-bust
    /// component for thumbnail keys so edits invalidate automatically without
    /// re-stat'ing on every row render.
    let contentModifiedAt: Date?

    init(url: URL,
         role: FileItemRole = .standard,
         displayNameOverride: String? = nil,
         subtitleOverride: String? = nil) {
        self.url = url
        self.role = role
        let trimmedDisplayName = displayNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayNameOverride = trimmedDisplayName.isEmpty ? nil : trimmedDisplayName
        let trimmedSubtitle = subtitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.subtitleOverride = trimmedSubtitle.isEmpty ? nil : trimmedSubtitle
        self.icon = NSWorkspace.shared.icon(forFile: url.path)

        // Batch-fetch isDirectory + fileSize + mtime in one syscall. A
        // successful fetch implies the path is reachable, so `exists` is
        // derived from the same call instead of paying for a separate
        // FileManager.fileExists stat per item.
        let resources = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        self.exists = resources != nil
        self.contentModifiedAt = resources?.contentModificationDate
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
        else if archiveExts.contains(ext)      { self.previewKind = .archive }
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
