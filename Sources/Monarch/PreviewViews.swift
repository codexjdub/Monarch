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
        case .markdown:  MarkdownPreviewView(url: url)
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

    /// Maximum bytes loaded into the preview pane. Large files are truncated
    /// at this boundary to keep the NSTextView responsive.
    nonisolated static let previewMaxBytes = 1_000_000

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
        tv.isRichText = false
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
        loadAsync(into: tv)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // URL is captured at make-time; previews aren't reused across URLs
        // (a new peek replaces the old one), so no update needed.
    }

    private func loadAsync(into tv: NSTextView) {
        let fileURL = url
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Self.readTruncated(url: fileURL, maxBytes: Self.previewMaxBytes)
            DispatchQueue.main.async {
                tv.string = s
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

// MARK: - Markdown

struct MarkdownPreviewView: View {
    let url: URL
    @State private var content: AttributedString = .init()
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 40)
            } else {
                Text(content)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear(perform: load)
    }

    private func load() {
        let fileURL = url
        Task.detached(priority: .userInitiated) {
            let raw = (try? String(contentsOf: fileURL, encoding: .utf8))
                   ?? (try? String(contentsOf: fileURL, encoding: .isoLatin1))
                   ?? ""
            let attributed = (try? AttributedString(
                markdown: raw,
                options: .init(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )) ?? AttributedString(raw)
            await MainActor.run {
                self.content = attributed
                self.isLoading = false
            }
        }
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
