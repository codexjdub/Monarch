import SwiftUI
import AppKit

// MARK: - Row icon
//
// Shows a QuickLook thumbnail when available (previewable files), otherwise
// falls back to the NSWorkspace icon cached on the FileItem. Thumbnail load
// is async via ThumbnailCache — renders the fallback icon immediately so
// rows never show a blank space.

struct RowIconView: View {
    let item: FileItem
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? item.icon)
            .resizable()
            .interpolation(.medium)
            .aspectRatio(contentMode: .fit)
            .onAppear(perform: load)
            .onChange(of: item.url) { _ in
                thumbnail = nil
                load()
            }
    }

    private func load() {
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
