import SwiftUI
import AppKit
import PDFKit
import Quartz
import Darwin

// MARK: - Preview Level View
//
// Hosted inside a peek window when the parent row is a previewable file.
// Renders the appropriate view for the file's PreviewKind. Includes a small
// header (filename) and a WindowMouseTracker so hover-exit close semantics
// match folder peeks.

struct PreviewLevelView: View {
    let level: Int
    let url: URL
    let kind: PreviewKind
    @ObservedObject var model: CascadeModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(NSColor.windowBackgroundColor))
        .background(WindowMouseTracker(level: level, model: model))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            Text(url.lastPathComponent)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var iconName: String {
        switch kind {
        case .image:     return "photo"
        case .pdf:       return "doc.richtext"
        case .markdown:  return "text.alignleft"
        case .text:      return "doc.text"
        case .quicklook: return "doc"
        case .video:     return "film"
        case .audio:     return "waveform"
        case .archive:   return "archivebox"
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .image:     ImagePreviewView(url: url)
        case .pdf:       PDFPreviewView(url: url)
        case .markdown:  TextPreviewView(url: url, syntaxHint: .markdown)
        case .text:      TextPreviewView(url: url)
        case .quicklook: QuickLookPreviewView(url: url)
        case .video:     QuickLookPreviewView(url: url)
        case .audio:     QuickLookPreviewView(url: url)
        case .archive:   ArchivePreviewView(url: url)
        }
    }
}

// MARK: - Image

struct ImagePreviewView: View {
    let url: URL
    var body: some View {
        Group {
            if let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Unable to load image").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - PDF

struct PDFPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = NSColor.windowBackgroundColor
        v.document = PDFDocument(url: url)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url {
            v.document = PDFDocument(url: url)
        }
    }
}

// MARK: - Text
//
// Uses NSTextView inside NSScrollView for fast rendering of large files.
// TextKit lays out only the visible line fragments, so a 1MB file opens
// instantly — unlike SwiftUI Text, which lays out the whole string up front.

struct TextPreviewView: NSViewRepresentable {
    let url: URL
    var syntaxHint: SyntaxKind? = nil

    /// Maximum bytes loaded into the preview pane. Large files are truncated
    /// at this boundary to keep the NSTextView responsive.
    nonisolated static let previewMaxBytes = 1_000_000

    final class Coordinator: @unchecked Sendable {
        var requestedURL: URL?
        var requestedSyntaxHint: SyntaxKind?
        var generation = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.windowBackgroundColor
        scroll.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.importsGraphics = false
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.windowBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textColor = NSColor.labelColor
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true

        // Wrap long lines to viewport width (no horizontal scroll).
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                            height: CGFloat.greatestFiniteMagnitude)
        if let tc = tv.textContainer {
            tc.widthTracksTextView = true
            tc.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        scroll.documentView = tv
        reloadIfNeeded(scroll, coordinator: context.coordinator, force: true)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        reloadIfNeeded(nsView, coordinator: context.coordinator)
    }

    private func reloadIfNeeded(_ scroll: NSScrollView, coordinator: Coordinator, force: Bool = false) {
        guard force || coordinator.requestedURL != url || coordinator.requestedSyntaxHint != syntaxHint else { return }
        guard let tv = scroll.documentView as? NSTextView else { return }

        coordinator.requestedURL = url
        coordinator.requestedSyntaxHint = syntaxHint
        coordinator.generation &+= 1
        let generation = coordinator.generation
        let fileURL = self.url
        let kind = self.syntaxHint
        tv.string = "Loading…"
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Self.readTruncated(url: fileURL, maxBytes: Self.previewMaxBytes)
            let highlighted = SyntaxHighlighter.highlight(s, url: fileURL, hint: kind)
            DispatchQueue.main.async { [weak coordinator, weak tv] in
                guard let coordinator,
                      coordinator.generation == generation,
                      coordinator.requestedURL == fileURL else { return }
                tv?.textStorage?.setAttributedString(highlighted)
            }
        }
    }

    nonisolated private static func readTruncated(url: URL, maxBytes: Int) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return "Unable to read file."
        }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxBytes)) ?? Data()
        var s = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
        if data.count >= maxBytes {
            let totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let totalMB = Double(totalBytes) / 1_000_000
            s += String(format: "\n\n… (showing first 1 MB of %.1f MB — open in editor to read full file)", totalMB)
        }
        return s
    }
}

// MARK: - Syntax highlighting

enum SyntaxKind: Equatable {
    case markdown
    case html
    case css
    case json
    case yaml
    case shell
    case python
    case ruby
    case swift
    case sql
    case cLike
    case plain

    static func infer(url: URL) -> SyntaxKind {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        switch ext {
        case "md", "markdown", "mdown": return .markdown
        case "html", "htm", "xml", "plist", "entitlements": return .html
        case "css", "scss", "sass": return .css
        case "json", "ipynb": return .json
        case "yaml", "yml", "toml", "ini", "conf", "cfg": return .yaml
        case "sh", "bash", "zsh", "fish": return .shell
        case "py": return .python
        case "rb": return .ruby
        case "swift": return .swift
        case "sql": return .sql
        case "c", "h", "cpp", "hpp", "cc", "m", "mm", "js", "mjs", "cjs", "ts", "tsx", "jsx",
             "go", "rs", "java", "kt", "kts", "scala", "pl", "lua", "php": return .cLike
        default:
            if name == "makefile" || name == "dockerfile" || name == "gemfile" || name == "rakefile" || name == "podfile" {
                return .shell
            }
            if name.hasPrefix(".env") || name == ".gitignore" || name == ".dockerignore" || name == ".npmrc" {
                return .yaml
            }
            return .plain
        }
    }
}

private enum SyntaxHighlighter {
    private static var baseFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .regular) }
    private static var boldFont: NSFont { NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold) }
    private static var commentColor: NSColor { NSColor.secondaryLabelColor.withAlphaComponent(0.82) }
    private static var keywordColor: NSColor { NSColor.systemBlue.blended(withFraction: 0.22, of: .labelColor) ?? .systemBlue }
    private static var stringColor: NSColor { NSColor.systemGreen.blended(withFraction: 0.28, of: .labelColor) ?? .systemGreen }
    private static var numberColor: NSColor { NSColor.systemOrange.blended(withFraction: 0.24, of: .labelColor) ?? .systemOrange }
    private static var typeColor: NSColor { NSColor.systemTeal.blended(withFraction: 0.30, of: .labelColor) ?? .systemTeal }
    private static var keyColor: NSColor { NSColor.systemBlue.blended(withFraction: 0.12, of: .labelColor) ?? .systemBlue }
    private static var punctuationColor: NSColor { NSColor.tertiaryLabelColor.withAlphaComponent(0.78) }
    private static var markdownColor: NSColor { NSColor.controlAccentColor.blended(withFraction: 0.20, of: .labelColor) ?? .controlAccentColor }

    static func highlight(_ text: String, url: URL, hint: SyntaxKind?) -> NSAttributedString {
        let kind = hint ?? SyntaxKind.infer(url: url)
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor
            ]
        )

        switch kind {
        case .markdown:
            highlightMarkdown(attributed, full: full)
        case .html:
            highlightHTML(attributed, full: full)
        case .css:
            highlightCSS(attributed, full: full)
        case .json:
            highlightJSON(attributed, full: full)
        case .yaml:
            highlightYAML(attributed, full: full)
        case .shell:
            highlightGeneralCode(attributed, full: full, keywords: shellKeywords, hashComments: true)
        case .python:
            highlightGeneralCode(attributed, full: full, keywords: pythonKeywords, hashComments: true)
        case .ruby:
            highlightGeneralCode(attributed, full: full, keywords: rubyKeywords, hashComments: true)
        case .swift:
            highlightGeneralCode(attributed, full: full, keywords: swiftKeywords, slashComments: true)
        case .sql:
            highlightGeneralCode(attributed, full: full, keywords: sqlKeywords, dashComments: true)
        case .cLike:
            highlightGeneralCode(attributed, full: full, keywords: cLikeKeywords, slashComments: true)
        case .plain:
            break
        }

        return attributed
    }

    private static func apply(_ pattern: String,
                              to attributed: NSMutableAttributedString,
                              full: NSRange,
                              color: NSColor,
                              font: NSFont? = nil,
                              options: NSRegularExpression.Options = []) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
        var attrs: [NSAttributedString.Key: Any] = [.foregroundColor: color]
        if let font { attrs[.font] = font }
        regex.enumerateMatches(in: attributed.string, options: [], range: full) { match, _, _ in
            guard let range = match?.range, range.location != NSNotFound else { return }
            attributed.addAttributes(attrs, range: range)
        }
    }

    private static func wordPattern(_ words: Set<String>) -> String {
        #"\b("# + words.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + #")\b"#
    }

    private static func highlightGeneralCode(_ attributed: NSMutableAttributedString,
                                             full: NSRange,
                                             keywords: Set<String>,
                                             slashComments: Bool = false,
                                             hashComments: Bool = false,
                                             dashComments: Bool = false) {
        apply(wordPattern(keywords), to: attributed, full: full, color: keywordColor, font: boldFont)
        apply(#"\b(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)\b"#, to: attributed, full: full, color: numberColor)
        apply(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#, to: attributed, full: full, color: stringColor)
        if slashComments {
            apply(#"/\*[\s\S]*?\*/"#, to: attributed, full: full, color: commentColor)
            apply(#"//.*$"#, to: attributed, full: full, color: commentColor, options: [.anchorsMatchLines])
        }
        if hashComments {
            apply(#"(?<!\\)#.*$"#, to: attributed, full: full, color: commentColor, options: [.anchorsMatchLines])
        }
        if dashComments {
            apply(#"--.*$"#, to: attributed, full: full, color: commentColor, options: [.anchorsMatchLines])
        }
    }

    private static func highlightMarkdown(_ attributed: NSMutableAttributedString, full: NSRange) {
        apply(#"^#{1,6}\s.*$"#, to: attributed, full: full, color: markdownColor, font: boldFont, options: [.anchorsMatchLines])
        apply(#"^>\s.*$"#, to: attributed, full: full, color: commentColor, options: [.anchorsMatchLines])
        apply(#"^\s*(```|~~~).*$"#, to: attributed, full: full, color: punctuationColor, font: boldFont, options: [.anchorsMatchLines])
        apply(#"`[^`\n]+`"#, to: attributed, full: full, color: stringColor)
        apply(#"\[[^\]\n]+\]\([^)]+\)"#, to: attributed, full: full, color: keyColor)
        apply(#"^\s*(?:[-*+]|\d+\.)\s+"#, to: attributed, full: full, color: punctuationColor, font: boldFont, options: [.anchorsMatchLines])
        apply(#"\*\*[^*\n]+\*\*|__[^_\n]+__"#, to: attributed, full: full, color: typeColor, font: boldFont)
    }

    private static func highlightHTML(_ attributed: NSMutableAttributedString, full: NSRange) {
        apply(#"</?[A-Za-z][\w:.-]*"#, to: attributed, full: full, color: keywordColor, font: boldFont)
        apply(#"\b[A-Za-z_:][\w:.-]*(?=\=)"#, to: attributed, full: full, color: keyColor)
        apply(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, to: attributed, full: full, color: stringColor)
        apply(#"<!--[\s\S]*?-->"#, to: attributed, full: full, color: commentColor)
    }

    private static func highlightCSS(_ attributed: NSMutableAttributedString, full: NSRange) {
        apply(#"\b[A-Za-z-]+(?=\s*:)"#, to: attributed, full: full, color: keyColor)
        apply(#"#[0-9A-Fa-f]{3,8}\b"#, to: attributed, full: full, color: numberColor)
        apply(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, to: attributed, full: full, color: stringColor)
        apply(#"/\*[\s\S]*?\*/"#, to: attributed, full: full, color: commentColor)
    }

    private static func highlightJSON(_ attributed: NSMutableAttributedString, full: NSRange) {
        apply(#""(?:\\.|[^"\\])*""#, to: attributed, full: full, color: stringColor)
        apply(#""(?:\\.|[^"\\])*"(?=\s*:)"#, to: attributed, full: full, color: keyColor, font: boldFont)
        apply(#"\b(?:true|false|null)\b"#, to: attributed, full: full, color: keywordColor, font: boldFont)
        apply(#"\b-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b"#, to: attributed, full: full, color: numberColor)
    }

    private static func highlightYAML(_ attributed: NSMutableAttributedString, full: NSRange) {
        apply(#"^\s*[A-Za-z0-9_.-]+(?=\s*:)"#, to: attributed, full: full, color: keyColor, font: boldFont, options: [.anchorsMatchLines])
        apply(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, to: attributed, full: full, color: stringColor)
        apply(#"\b(?:true|false|null|yes|no|on|off)\b"#, to: attributed, full: full, color: keywordColor)
        apply(#"\b-?\d+(?:\.\d+)?\b"#, to: attributed, full: full, color: numberColor)
        apply(#"#.*$"#, to: attributed, full: full, color: commentColor, options: [.anchorsMatchLines])
    }

    private static let swiftKeywords: Set<String> = [
        "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
        "continue", "default", "defer", "do", "else", "enum", "extension", "false", "for", "func",
        "guard", "if", "import", "in", "init", "inout", "is", "let", "nil", "private", "protocol",
        "public", "return", "self", "static", "struct", "switch", "throw", "throws", "true", "try",
        "var", "where", "while"
    ]
    private static let cLikeKeywords: Set<String> = [
        "abstract", "async", "await", "break", "case", "catch", "class", "const", "continue", "default",
        "defer", "do", "else", "enum", "export", "extends", "false", "final", "for", "func", "function",
        "if", "import", "interface", "let", "new", "nil", "null", "package", "private", "protected",
        "public", "return", "static", "struct", "switch", "this", "throw", "throws", "true", "try",
        "type", "var", "void", "while"
    ]
    private static let pythonKeywords: Set<String> = [
        "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif",
        "else", "except", "false", "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "none", "nonlocal", "not", "or", "pass", "raise", "return", "true", "try", "while",
        "with", "yield"
    ]
    private static let rubyKeywords: Set<String> = [
        "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def", "defined", "do",
        "else", "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
        "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef", "unless",
        "until", "when", "while", "yield"
    ]
    private static let shellKeywords: Set<String> = [
        "case", "do", "done", "elif", "else", "esac", "export", "fi", "for", "function", "if", "in",
        "local", "readonly", "return", "select", "set", "then", "trap", "unset", "until", "while"
    ]
    private static let sqlKeywords: Set<String> = [
        "alter", "and", "as", "asc", "between", "by", "case", "create", "delete", "desc", "distinct",
        "drop", "else", "end", "false", "from", "group", "having", "in", "insert", "into", "is",
        "join", "left", "like", "limit", "not", "null", "on", "or", "order", "outer", "right",
        "select", "set", "table", "then", "true", "union", "update", "values", "when", "where"
    ]
}

// MARK: - QuickLook (rich documents)
//
// Uses QLPreviewView for docx, epub, pages, numbers, keynote, rtf, odt,
// webarchive, and other rich formats macOS knows how to render.

struct QuickLookPreviewView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        // QLPreviewView(frame:style:) returns optional on older SDKs but cannot
        // realistically fail — force-unwrap is intentional.
        let v = QLPreviewView(frame: .zero, style: .normal)!
        v.autostarts = true
        v.shouldCloseWithWindow = false
        v.previewItem = url as QLPreviewItem
        return v
    }

    func updateNSView(_ nsView: QLPreviewView, context: Context) {
        if (nsView.previewItem as? URL) != url {
            nsView.previewItem = url as QLPreviewItem
        }
    }

    static func dismantleNSView(_ nsView: QLPreviewView, coordinator: ()) {
        nsView.close()
    }
}

// MARK: - Archive TOC
//
// Reads the table of contents of a zip or tar archive off the main thread
// using standard CLI tools — no decompression, just the entry list.

private struct ArchiveEntry: Identifiable {
    let id = UUID()
    let path: String
    var isDirectory: Bool { path.hasSuffix("/") }
    var displayName: String {
        let p = isDirectory ? String(path.dropLast()) : path
        return URL(fileURLWithPath: p).lastPathComponent
    }
    var parentPath: String {
        let p = isDirectory ? String(path.dropLast()) : path
        let parent = URL(fileURLWithPath: p).deletingLastPathComponent().path
        return (parent == "." || parent == "/") ? "" : parent
    }
    var sfIcon: String {
        if isDirectory { return "folder" }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "jpg","jpeg","png","gif","heic","heif","tiff","bmp","webp": return "photo"
        case "pdf":                                                       return "doc.richtext"
        case "mp4","m4v","mov","avi","mkv","webm":                       return "film"
        case "mp3","m4a","aac","wav","aiff","flac":                      return "waveform"
        case "zip","tar","gz","tgz","bz2","7z","rar":                    return "archivebox"
        case "swift","py","js","ts","rb","go","rs","c","cpp","h":        return "doc.text"
        default:                                                          return "doc"
        }
    }
}

struct ArchivePreviewView: View {
    let url: URL
    @State private var entries: [ArchiveEntry] = []
    @State private var isLoading = true
    @State private var failed = false
    @State private var listingWasLimited = false

    private enum ListingLimits {
        static let timeoutMilliseconds = 3_000
        static let maxOutputBytes = 512 * 1_024
        static let maxEntries = 2_000
    }

    private struct ArchiveCommandResult {
        let lines: [String]
        let success: Bool
        let timedOut: Bool
        let outputTruncated: Bool
    }

    private final class LimitedOutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        func append(_ chunk: Data, maxBytes: Int) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }

            let remaining = max(0, maxBytes - data.count)
            if remaining > 0 {
                data.append(contentsOf: chunk.prefix(remaining))
            }
            if chunk.count > remaining {
                truncated = true
            }
        }

        func snapshot() -> (data: Data, truncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, truncated)
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if failed {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Could not read archive")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 26)).foregroundStyle(.tertiary)
                    Text("Empty archive")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                HStack(spacing: 7) {
                                    Image(systemName: entry.sfIcon)
                                        .font(.system(size: 11))
                                        .foregroundStyle(entry.isDirectory
                                            ? Color.accentColor.opacity(0.8) : .secondary)
                                        .frame(width: 14, alignment: .center)
                                    Text(entry.displayName)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if !entry.parentPath.isEmpty {
                                        Text(entry.parentPath)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.head)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                Divider().padding(.leading, 33)
                            }
                        }
                    }
                    Divider()
                    let fileCount = entries.filter { !$0.isDirectory }.count
                    Text(listingWasLimited
                         ? "Showing first \(entries.count) entries"
                         : "\(fileCount) file\(fileCount == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 5)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        let fileURL = url
        Task.detached(priority: .userInitiated) {
            let ext = fileURL.pathExtension.lowercased()
            let (lines, result) = ext == "zip"
                ? Self.run("/usr/bin/unzip", args: ["-Z1", fileURL.path])
                : Self.run("/usr/bin/tar",   args: ["-tf",  fileURL.path])
            let completeLines = result.outputTruncated || result.timedOut ? Array(lines.dropLast()) : lines
            let parsed = Array(completeLines
                .map  { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .prefix(ListingLimits.maxEntries)
                .map  { ArchiveEntry(path: $0) })
            let entryLimited = completeLines.count > parsed.count
            await MainActor.run {
                self.entries = parsed
                self.listingWasLimited = result.timedOut || result.outputTruncated || entryLimited
                self.failed = !result.success && parsed.isEmpty
                self.isLoading = false
            }
        }
    }

    /// Run an executable with bounded time and output. Uses Process directly,
    /// never a shell, so archive paths are passed as arguments.
    nonisolated private static func run(_ exe: String, args: [String]) -> ([String], ArchiveCommandResult) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()   // suppress stderr

        let output = LimitedOutputBuffer()
        let completed = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in completed.signal() }

        do { try proc.run() } catch {
            return ([], ArchiveCommandResult(lines: [], success: false, timedOut: false, outputTruncated: false))
        }

        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData, maxBytes: ListingLimits.maxOutputBytes)
        }

        let deadline = DispatchTime.now() + .milliseconds(ListingLimits.timeoutMilliseconds)
        let timedOut = completed.wait(timeout: deadline) == .timedOut
        var didExit = !timedOut

        if timedOut {
            proc.terminate()
            didExit = completed.wait(timeout: .now() + .milliseconds(300)) == .success
            if !didExit {
                kill(proc.processIdentifier, SIGKILL)
                didExit = completed.wait(timeout: .now() + .milliseconds(300)) == .success
            }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        if didExit {
            output.append(pipe.fileHandleForReading.readDataToEndOfFile(),
                          maxBytes: ListingLimits.maxOutputBytes)
        }

        let snapshot = output.snapshot()
        let data = snapshot.data
        guard let output = String(data: data, encoding: .utf8) else {
            let result = ArchiveCommandResult(
                lines: [],
                success: false,
                timedOut: timedOut,
                outputTruncated: snapshot.truncated
            )
            return ([], result)
        }
        let result = ArchiveCommandResult(
            lines: output.components(separatedBy: "\n"),
            success: didExit && !timedOut && proc.terminationStatus == 0,
            timedOut: timedOut,
            outputTruncated: snapshot.truncated
        )
        return (result.lines, result)
    }
}
