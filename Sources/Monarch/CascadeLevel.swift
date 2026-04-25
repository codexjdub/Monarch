import AppKit

// MARK: - Sort order (shared)

enum FileSortOrder: String, CaseIterable {
    case name         = "name"
    case dateModified = "modified"
    case dateCreated  = "created"
    case fileType     = "type"

    var label: String {
        switch self {
        case .name:         return "Name"
        case .dateModified: return "Date Modified"
        case .dateCreated:  return "Date Created"
        case .fileType:     return "File Type"
        }
    }
}

// MARK: - CascadeModel nested data types
//
// The value types the model operates on: Focus, Content, Section, Level,
// and FolderContents. Declared here as nested extensions so CascadeModel
// itself stays focused on behavior.

extension CascadeModel {

    struct Focus: Equatable {
        var level: Int
        var index: Int
        /// Sentinel value meaning "no row is focused in this window".
        static let noFocus = -1
    }

    /// A level renders one of two things: a folder's contents (list of rows),
    /// or a file preview (image / PDF / markdown / text).
    enum Content {
        case folder(items: [FileItem], sections: [Section], rowFrames: [Int: NSRect])
        case preview(kind: PreviewKind, url: URL)
    }

    /// A named section in a folder level. Indices refer to the flat `items` array.
    struct Section: Hashable {
        let title: String
        let range: Range<Int>
    }

    struct Level {
        /// Source URL for this level:
        ///   - nil for level 0 (the root list of configured folders)
        ///   - folder URL for .folder content
        ///   - file URL for .preview content
        let source: URL?
        var content: Content
        /// Sum of direct-child file sizes (bytes). 0 for level 0 and preview levels.
        var totalSize: Int64
        /// True when the folder could not be read (e.g. permission denied).
        var readError: Bool
        /// True while an async load is in flight and no contents have arrived yet.
        /// Used by views to distinguish a genuinely empty folder from "still loading".
        var isLoading: Bool

        init(source: URL?, content: Content, totalSize: Int64 = 0, readError: Bool = false, isLoading: Bool = false) {
            self.source = source
            self.content = content
            self.totalSize = totalSize
            self.readError = readError
            self.isLoading = isLoading
        }

        // Convenience accessors (return empty for preview levels).
        var items: [FileItem] {
            if case .folder(let items, _, _) = content { return items }
            return []
        }
        var sections: [Section] {
            if case .folder(_, let secs, _) = content { return secs }
            return []
        }
        var rowFrames: [Int: NSRect] {
            if case .folder(_, _, let frames) = content { return frames }
            return [:]
        }
        /// For .folder levels, swap in new items + sections without touching frames.
        /// Clears `isLoading` — by the time contents arrive, loading is done.
        mutating func setContents(_ newItems: [FileItem], _ newSections: [Section], totalSize: Int64? = nil, readError: Bool = false) {
            if case .folder(_, _, let frames) = content {
                content = .folder(items: newItems, sections: newSections, rowFrames: frames)
            }
            if let totalSize { self.totalSize = totalSize }
            self.readError = readError
            self.isLoading = false
        }
        /// For .folder levels, record a row's screen frame.
        mutating func setRowFrame(_ index: Int, _ frame: NSRect) {
            if case .folder(let items, let secs, var frames) = content {
                frames[index] = frame
                content = .folder(items: items, sections: secs, rowFrames: frames)
            }
        }
        var isPreview: Bool {
            if case .preview = content { return true }
            return false
        }
    }

    struct FolderContents {
        let items: [FileItem]
        let sections: [Section]
        let totalSize: Int64
        var readError: Bool = false
    }

    // MARK: - Folder loading

    /// Pure function — no UserDefaults/PinStore access. Safe to call off the
    /// main thread. The caller gathers inputs on main and passes them in.
    nonisolated static func loadFolder(_ folder: URL,
                           pinnedURLs: [URL],
                           sortOrder: FileSortOrder,
                           showHidden: Bool,
                           descending: Bool) -> FolderContents {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey,
                                      .contentModificationDateKey, .creationDateKey]
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: folder,
                                                  includingPropertiesForKeys: keys,
                                                  options: [])
        } catch {
            return FolderContents(items: [], sections: [], totalSize: 0, readError: true)
        }

        // Pre-fetch all file attributes in one pass so that sort comparators
        // and the totalSize reduce can do plain dictionary lookups instead of
        // calling resourceValues() O(N log N) times.
        struct Attrs {
            var modDate: Date
            var createDate: Date
            var fileSize: Int
        }
        var attrs = [URL: Attrs](minimumCapacity: contents.count)
        for url in contents {
            let r = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                      .creationDateKey, .fileSizeKey])
            attrs[url] = Attrs(
                modDate:    r?.contentModificationDate ?? .distantPast,
                createDate: r?.creationDate            ?? .distantPast,
                fileSize:   r?.fileSize                ?? 0
            )
        }

        let visibleItems = contents
            .map { FileItem(url: $0) }
            .filter { showHidden || !$0.isHidden }

        // Footer total reflects what the user actually sees: when hidden files
        // are filtered out, their bytes are excluded too.
        let totalSize: Int64 = visibleItems.reduce(0) { $0 + Int64(attrs[$1.url]?.fileSize ?? 0) }

        // Three-way comparator. Returning the raw `ComparisonResult` (and a
        // name tie-break for ties on the primary key) keeps the sort closure
        // a strict weak ordering — Bool inversion of an `ascending` flag was
        // unsafe because equal keys mapped to `true` in both directions.
        let allSorted = visibleItems.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            let primary: ComparisonResult
            switch sortOrder {
            case .name:
                primary = a.name.localizedCaseInsensitiveCompare(b.name)
            case .dateModified:
                let da = attrs[a.url]?.modDate ?? .distantPast
                let db = attrs[b.url]?.modDate ?? .distantPast
                primary = da < db ? .orderedAscending : (da > db ? .orderedDescending : .orderedSame)
            case .dateCreated:
                let da = attrs[a.url]?.createDate ?? .distantPast
                let db = attrs[b.url]?.createDate ?? .distantPast
                primary = da < db ? .orderedAscending : (da > db ? .orderedDescending : .orderedSame)
            case .fileType:
                primary = a.url.pathExtension.localizedCaseInsensitiveCompare(b.url.pathExtension)
            }
            // Tie-break by name so equal primary keys (same extension, same
            // mtime, etc.) fall into a stable, human-readable order. The
            // tie-break direction follows the chosen direction so descending
            // sorts feel consistent.
            let cmp: ComparisonResult
            if primary == .orderedSame {
                cmp = a.name.localizedCaseInsensitiveCompare(b.name)
            } else {
                cmp = primary
            }
            return descending ? cmp == .orderedDescending : cmp == .orderedAscending
        }

        // Build sections: Pinned, Recent, All.
        let pinnedSet = Set(pinnedURLs.map(\.path))
        let itemByURL = Dictionary(uniqueKeysWithValues: allSorted.map { ($0.url, $0) })
        let pinnedItems = pinnedURLs.compactMap { itemByURL[$0] }

        // Recent: top 5 non-pinned files by modification date (skip dirs).
        let recentCount = 5
        let recentCandidates = allSorted
            .filter { !$0.isDirectory && !pinnedSet.contains($0.url.path) }
            .sorted { a, b in
                (attrs[a.url]?.modDate ?? .distantPast) > (attrs[b.url]?.modDate ?? .distantPast)
            }
        let recentItems: [FileItem]
        // Show Recent only when the folder has enough items to make it useful.
        if allSorted.count >= 10, recentCandidates.count >= 3 {
            recentItems = Array(recentCandidates.prefix(recentCount))
        } else {
            recentItems = []
        }
        let recentSet = Set(recentItems.map(\.url.path))

        // All — minus pinned and recent (they already appear above).
        let remainingItems = allSorted.filter {
            !pinnedSet.contains($0.url.path) && !recentSet.contains($0.url.path)
        }

        // No sections needed if there are no pins and no recent.
        if pinnedItems.isEmpty && recentItems.isEmpty {
            return FolderContents(items: allSorted, sections: [], totalSize: totalSize)
        }

        // Compose flat item list and build section descriptors.
        var items: [FileItem] = []
        var sections: [Section] = []

        if !pinnedItems.isEmpty {
            let start = items.count
            items.append(contentsOf: pinnedItems)
            sections.append(Section(title: "Pinned", range: start..<items.count))
        }
        if !recentItems.isEmpty {
            let start = items.count
            items.append(contentsOf: recentItems)
            sections.append(Section(title: "Recent", range: start..<items.count))
        }
        let start = items.count
        items.append(contentsOf: remainingItems)
        sections.append(Section(title: "All", range: start..<items.count))

        return FolderContents(items: items, sections: sections, totalSize: totalSize)
    }
}
