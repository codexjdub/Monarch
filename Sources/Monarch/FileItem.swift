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
private let textFileNames: Set<String> = [
    ".bash_login", ".bash_profile", ".bashrc",
    ".curlrc", ".dockerignore", ".editorconfig", ".env",
    ".gitattributes", ".gitconfig", ".gitignore", ".gitmodules",
    ".hushlogin", ".ideavimrc", ".inputrc", ".node-version",
    ".npmrc", ".nvmrc", ".profile", ".python-version",
    ".ruby-version", ".tool-versions", ".vimrc", ".wgetrc",
    ".yarnrc", ".zprofile", ".zshenv", ".zshrc",
    "brewfile", "dockerfile", "gemfile", "makefile", "podfile",
    "rakefile"
]
private func isTextFileName(_ fileName: String) -> Bool {
    textFileNames.contains(fileName) || fileName.hasPrefix(".env.")
}
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

/// Where the file physically lives. Surfaced as a small trailing badge so
/// users can tell at a glance whether a row is on iCloud Drive (potentially
/// not downloaded), a network share (possibly slow / unavailable), or an
/// external drive (might get unmounted). `nil` for ordinary local files.
enum VolumeKind {
    case iCloud
    case network
    case external
}

extension URL {
    /// If this URL is on an external volume (`/Volumes/<name>/...`) and that
    /// volume directory no longer exists in the filesystem, returns the
    /// volume name. Used to distinguish "file deleted" from "drive ejected"
    /// in error messages, since the user's recovery action is different
    /// (re-locate vs. plug the drive back in).
    var unmountedVolumeName: String? {
        guard path.hasPrefix("/Volumes/") else { return nil }
        let parts = path.components(separatedBy: "/")
        guard parts.count >= 3, !parts[2].isEmpty else { return nil }
        let volumeName = parts[2]
        let volumeRoot = "/Volumes/" + volumeName
        if FileManager.default.fileExists(atPath: volumeRoot) {
            return nil
        }
        return volumeName
    }
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
    let isDirectory: Bool
    let fileSize: String?
    /// `var` only so `loadFolder` can upgrade it to `.text` after a content
    /// sniff resolves a file the metadata layers couldn't classify. Treat it
    /// as read-only everywhere else — nothing should mutate a rendered item.
    var previewKind: PreviewKind?
    /// True when neither the filename allowlists nor the system type database
    /// could classify this file, but its bytes might still be plain text.
    /// `loadFolder` reads a bounded prefix for these and only these.
    let needsContentSniff: Bool
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
    /// Where the file physically lives — drives the trailing badge in the
    /// row. `nil` for ordinary local files (no badge shown).
    let volumeKind: VolumeKind?

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
        // Batch-fetch isDirectory + fileSize + mtime + volume metadata in one
        // syscall. A successful fetch implies the path is reachable, so
        // `exists` is derived from the same call instead of paying for a
        // separate FileManager.fileExists stat per item. Volume keys piggyback
        // on the same call so the trailing badge costs nothing extra.
        let resources = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
            .isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsInternalKey
        ])
        self.exists = resources != nil
        self.contentModifiedAt = resources?.contentModificationDate
        let isDir = resources?.isDirectory ?? false
        self.isDirectory = isDir
        if let bytes = resources?.fileSize, !isDir {
            self.fileSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            self.fileSize = nil
        }

        // Derive volumeKind. Order matters: iCloud first (it's per-item, can
        // live on local volumes too), then network (volumeIsLocal == false),
        // then external (local but not internal). Anything else is plain
        // local storage and gets no badge.
        if resources?.isUbiquitousItem == true {
            self.volumeKind = .iCloud
        } else if resources?.volumeIsLocal == false {
            self.volumeKind = .network
        } else if resources?.volumeIsInternal == false {
            self.volumeKind = .external
        } else {
            self.volumeKind = nil
        }

        // previewKind — routing runs in three layers, cheapest first:
        //   1. the filename / extension allowlists below (pure string work)
        //   2. the system type database (metadata only, ~2.7 µs per item)
        //   3. a bounded content sniff, run later by loadFolder for whatever
        //      the first two couldn't classify (~23 µs, off-main, capped)
        // Layer 3 is what lets arbitrary suffixes (`config.before-systray-…`)
        // and extensionless files preview at all — no allowlist can cover
        // those, and a file that silently refuses to peek reads as a bug.
        let ext = url.pathExtension.lowercased()
        let fileName = url.lastPathComponent.lowercased()
        var sniffCandidate = false
        if isDir {
            self.previewKind = nil
        } else if isTextFileName(fileName)     { self.previewKind = .text }
        else if imageExts.contains(ext)        { self.previewKind = .image }
        else if ext == "pdf"                   { self.previewKind = .pdf }
        else if markdownExts.contains(ext)     { self.previewKind = .markdown }
        else if textExts.contains(ext)         { self.previewKind = .text }
        else if videoExts.contains(ext)        { self.previewKind = .video }
        else if audioExts.contains(ext)        { self.previewKind = .audio }
        else if quicklookExts.contains(ext)    { self.previewKind = .quicklook }
        else if archiveExts.contains(ext)      { self.previewKind = .archive }
        else {
            let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
            if let type, type.conforms(to: .plainText) {
                // System-known plain text: .diff, .mk, .tex, .hs, .command…
                // `.plainText` rather than `.text` on purpose — `.text` also
                // matches rich formats (RTF, SVG, HTML) that the allowlists
                // above route to QuickLook or a dedicated view instead.
                self.previewKind = .text
            } else {
                self.previewKind = nil
                // Sniff unless the system positively identified a non-text
                // type. A dynamic type means "unknown", which tells us
                // nothing, so those still get read.
                sniffCandidate = !(type.map { !$0.isDynamic && !$0.conforms(to: .text) } ?? false)
            }
        }
        // Layer 3 opens and reads the file, so it must not run where a read is
        // expensive or can hang. Opening a dataless iCloud file materializes
        // it — a silent download, up to `contentSniffBudget` of them per
        // folder load — and a regular file on a wedged network mount blocks
        // indefinitely, which `looksLikeText`'s `isRegularFile` guard does not
        // catch (that only excludes fifos, sockets and device nodes).
        // Blocking matters doubly because `loadFolder` runs on the cooperative
        // thread pool, where a parked worker starves every other `Task`.
        // External drives are ordinary local block devices — they still sniff.
        let readCouldStallOrDownload = self.volumeKind == .iCloud || self.volumeKind == .network
        self.needsContentSniff = sniffCandidate && self.exists && !readCouldStallOrDownload

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

    // MARK: - Content sniffing (preview routing layer 3)

    /// Bytes read when deciding whether an unclassified file is plain text.
    /// A fixed prefix means a 2 GB file costs the same as a 2 KB one.
    static let sniffByteCount = 4096

    /// Maximum sniffs `loadFolder` performs for one folder. At ~23 µs each a
    /// full budget costs a few milliseconds; the cap exists so a directory of
    /// thousands of unknown-type files can't inflate load time.
    static let contentSniffBudget = 200

    /// Upgrades every item the metadata layers couldn't classify to `.text`
    /// when its bytes say so, leaving the rest untouched. Capped by `budget`
    /// so a directory of thousands of unknown-type files can't inflate load
    /// time — at ~23 µs per sniff a full budget costs a few milliseconds.
    ///
    /// Does file I/O: call it off the main actor. `loadFolder` already is.
    nonisolated static func resolveUnclassifiedText(in items: inout [FileItem],
                                                    budget: Int = contentSniffBudget) {
        let candidates = items.indices.filter { items[$0].needsContentSniff }
        for i in candidates.prefix(budget) where looksLikeText(at: items[i].url) {
            items[i].previewKind = .text
        }
    }

    /// Does this file's leading data look like UTF-8 text?
    ///
    /// Same rule git and `file(1)` use: a NUL byte means binary, otherwise the
    /// prefix must decode as UTF-8. Only called for items with
    /// `needsContentSniff`, so the cost is paid for a handful per folder.
    nonisolated static func looksLikeText(at url: URL) -> Bool {
        // Never open a fifo, socket, or device node: FileHandle blocks
        // indefinitely on one, which would hang the whole folder load.
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: sniffByteCount),
              !data.isEmpty else { return false }   // empty file: nothing to preview
        if data.contains(0) { return false }
        return String(data: droppingTruncatedTrailingCharacter(data), encoding: .utf8) != nil
    }

    /// Removes a trailing UTF-8 character that the read cut in half — and only
    /// that. Without it a valid text file reads as binary purely because of
    /// where the read stopped.
    ///
    /// Two things it deliberately does *not* do:
    ///
    /// - It doesn't gate on having read exactly `sniffByteCount`. A short read
    ///   is legal — `read(upToCount:)` only promises not to *exceed* the
    ///   request, and network filesystems do return short — so gating on the
    ///   cap left a short read that split a character falling straight through
    ///   to a failed decode, which is the same false negative by another route.
    /// - It only drops bytes that genuinely could be a cut-off character: a
    ///   valid lead byte (0xC2–0xF4) whose declared length runs past the end,
    ///   plus its continuation bytes. A stray 0xFF stays put so the decoder
    ///   still rejects it, and a *complete* character sitting exactly at the
    ///   boundary is left alone instead of being needlessly trimmed.
    nonisolated static func droppingTruncatedTrailingCharacter(_ data: Data) -> Data {
        let tail = data.suffix(4)   // no UTF-8 character is longer than this
        guard var index = tail.indices.last else { return data }

        // Walk back over the final character's continuation bytes.
        var continuations = 0
        while continuations < 3, index > tail.startIndex,
              tail[index] & 0b1100_0000 == 0b1000_0000 {
            index -= 1
            continuations += 1
        }

        let declaredLength: Int
        switch tail[index] {
        case 0xC2...0xDF: declaredLength = 2
        case 0xE0...0xEF: declaredLength = 3
        case 0xF0...0xF4: declaredLength = 4
        default:          return data   // ASCII, or a byte no character starts with
        }

        // Keep it when the character is complete, or when trimming would
        // consume everything we read.
        let present = continuations + 1
        guard present < declaredLength, data.count > present else { return data }
        return data.dropLast(present)
    }
}
