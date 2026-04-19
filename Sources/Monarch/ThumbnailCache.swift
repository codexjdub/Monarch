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

    // True LRU: `order[0]` is least-recently-used, `order.last` is most-recent.
    // On every cache hit we promote the key to the end; on eviction we drop
    // the front.
    private let maxEntries = 400
    private var cache: [String: NSImage] = [:]
    private var order: [String] = []

    /// Move a key to the end of the order array (mark it most-recently-used).
    /// No-op if the key isn't tracked.
    private func touch(_ key: String) {
        guard let idx = order.firstIndex(of: key) else { return }
        order.remove(at: idx)
        order.append(key)
    }

    // In-flight requests — dedupe concurrent requests for the same key.
    private var inflight: [String: [(NSImage) -> Void]] = [:]

    private func key(for url: URL) -> String {
        let path = url.path
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        return "\(path)|\(mtime)"
    }

    /// Build a cache key from a pre-fetched mtime — avoids the per-row
    /// `resourceValues` syscall on the hot row-render path.
    private func key(path: String, mtime: Date?) -> String {
        "\(path)|\(mtime?.timeIntervalSinceReferenceDate ?? 0)"
    }

    /// Synchronously returns a cached thumbnail if present. Promotes the
    /// entry so it won't be evicted under LRU pressure.
    func cached(for url: URL) -> NSImage? {
        let k = key(for: url)
        guard let img = cache[k] else { return nil }
        touch(k)
        return img
    }

    /// FileItem-keyed lookup: uses the mtime cached on the item, saving a
    /// per-row filesystem stat. Preferred on the row-render hot path.
    func cached(for item: FileItem) -> NSImage? {
        let k = key(path: item.url.path, mtime: item.contentModifiedAt)
        guard let img = cache[k] else { return nil }
        touch(k)
        return img
    }

    /// FileItem variant of `thumbnail(for:completion:)`. Same semantics; uses
    /// the cached mtime to build the key without a stat call.
    func thumbnail(for item: FileItem, completion: @escaping (NSImage) -> Void) {
        let k = key(path: item.url.path, mtime: item.contentModifiedAt)
        request(key: k, url: item.url, completion: completion)
    }

    /// Requests a thumbnail; `completion` fires on main when ready (may be
    /// immediately if cached). If no thumbnail can be produced, completion
    /// is not called.
    func thumbnail(for url: URL, completion: @escaping (NSImage) -> Void) {
        let k = key(for: url)
        request(key: k, url: url, completion: completion)
    }

    private func request(key k: String, url: URL, completion: @escaping (NSImage) -> Void) {
        if let img = cache[k] { touch(k); completion(img); return }

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
            // Extract the NSImage here (off-main, but nsImage is a read-once
            // accessor on the representation). Wrap in a pointer-identity box
            // so the non-Sendable NSImage can be passed to the main actor.
            let img: NSImage? = rep?.nsImage
            Task { @MainActor in
                guard let self else { return }
                let cbs = self.inflight.removeValue(forKey: k) ?? []
                guard let img else { return }
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
