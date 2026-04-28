import SwiftUI
import AppKit

// MARK: - Row icon
//
// Shows a QuickLook thumbnail when available (previewable files), otherwise
// falls back to the NSWorkspace icon loaded lazily on first render.
// Both loads are async so folder contents appear immediately without waiting
// for N icon or thumbnail fetches at load time.

struct RowIconView: View {
    let item: FileItem
    @State private var thumbnail: NSImage?
    @State private var workspaceIcon: NSImage?

    var body: some View {
        Image(nsImage: displayImage)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .onAppear(perform: loadThumbnail)
            .onChange(of: item.url) { _ in
                thumbnail = nil
                workspaceIcon = nil
                loadThumbnail()
            }
            .task(id: item.url) {
                workspaceIcon = NSWorkspace.shared.icon(forFile: item.url.path)
            }
    }

    /// Best available image: QL thumbnail > workspace icon > generic placeholder.
    private var displayImage: NSImage {
        if let img = thumbnail ?? workspaceIcon { return img }
        // Generic placeholder while the workspace icon loads — avoids a blank
        // space on first render. Uses an SF symbol so no extra I/O is needed.
        return NSImage(systemSymbolName: item.isDirectory ? "folder" : "doc",
                       accessibilityDescription: nil) ?? NSImage()
    }

    private func loadThumbnail() {
        // Only request thumbnails for previewable files — everything else
        // would just produce the generic icon we're already showing.
        guard !item.isDirectory, item.previewKind != nil else { return }
        if let cached = ThumbnailCache.shared.cached(for: item) {
            thumbnail = cached
            return
        }
        let url = item.url
        ThumbnailCache.shared.thumbnail(for: item) { img in
            // Guard against row reuse: only accept the image if our URL
            // hasn't changed.
            if item.url == url { self.thumbnail = img }
        }
    }
}
