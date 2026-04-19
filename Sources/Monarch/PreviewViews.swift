import SwiftUI
import AppKit
import PDFKit
import Quartz

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
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .image:     ImagePreviewView(url: url)
        case .pdf:       PDFPreviewView(url: url)
        case .markdown:  TextPreviewView(url: url)
        case .text:      TextPreviewView(url: url)
        case .quicklook: QuickLookPreviewView(url: url)
        case .video:     QuickLookPreviewView(url: url)
        case .audio:     QuickLookPreviewView(url: url)
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
    private static let previewMaxBytes = 1_000_000

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

    private static func readTruncated(url: URL, maxBytes: Int) -> String {
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
        let v = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
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
