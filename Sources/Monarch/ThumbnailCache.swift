import AppKit
import QuickLookThumbnailing

/// Tiny row-thumbnail cache. Keyed by URL path + modification date so edits
/// invalidate automatically. Returns cached NSImage synchronously when
/// available; otherwise kicks off a QuickLook thumbnail request and calls
/// `completion` on the main queue when ready.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let pointSize = CGSize(width: 20, height: 20)
    /// Scale used when requesting thumbnails. QLThumbnailGenerator multiplies
    /// this with pointSize to get a bitmap size — retina-friendly.
    private var scale: CGFloat {
        NSScreen.main?.backingScaleFactor ?? 2.0
    }

    // LRU-ish: cap the cache and drop the oldest inserts when full.
    private let maxEntries = 400
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []

    // In-flight requests — dedupe concurrent requests for the same key.
    private var inflight: [String: [(NSImage) -> Void]] = [:]

    private func key(for url: URL) -> String {
        let path = url.path
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(path)|\(mtime)"
    }

    /// Synchronously returns a cached thumbnail if present.
    func cached(for url: URL) -> NSImage? {
        cache[key(for: url)]
    }

    /// Requests a thumbnail; `completion` fires on main when ready (may be
    /// immediately if cached). If no thumbnail can be produced, completion
    /// is not called.
    func thumbnail(for url: URL, completion: @escaping (NSImage) -> Void) {
        let k = key(for: url)
        if let img = cache[k] { completion(img); return }

        if inflight[k] != nil {
            inflight[k]?.append(completion)
            return
        }
        inflight[k] = [completion]

        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: pointSize,
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let self else { return }
            Task { @MainActor in
                let cbs = self.inflight.removeValue(forKey: k) ?? []
                guard let rep else { return }
                let img = rep.nsImage
                self.insert(key: k, image: img)
                for cb in cbs { cb(img) }
            }
        }
    }

    private func insert(key: String, image: NSImage) {
        if cache[key] == nil {
            order.append(key)
            if order.count > maxEntries {
                let drop = order.removeFirst()
                cache.removeValue(forKey: drop)
            }
        }
        cache[key] = image
    }
}
