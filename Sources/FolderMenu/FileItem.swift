import AppKit
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }

    var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var isHidden: Bool {
        name.hasPrefix(".")
    }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    var fileSize: String? {
        guard !isDirectory,
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    var imageDimensions: String? {
        guard !isDirectory else { return nil }
        let imageTypes = ["jpg", "jpeg", "png", "gif", "heic", "tiff", "bmp", "webp"]
        let ext = url.pathExtension.lowercased()
        guard imageTypes.contains(ext) else { return nil }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return "\(w) × \(h)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }

    static func == (lhs: FileItem, rhs: FileItem) -> Bool {
        lhs.url == rhs.url
    }
}
