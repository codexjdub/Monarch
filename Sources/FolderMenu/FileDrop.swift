import AppKit

/// Shared file-drop helper. Copies or moves a set of file URLs into a
/// destination folder, handling same-name collisions by suffixing
/// "copy", "copy 2", etc. — matching Finder's convention.
enum FileDropHelper {
    /// Performs the drop. If `operation` contains `.move`, items are moved
    /// (preferred when the source and destination share a volume); otherwise
    /// copied. Returns the number of successful operations.
    @discardableResult
    static func perform(urls: [URL], into dest: URL, operation: NSDragOperation) -> Int {
        let fm = FileManager.default
        let isMove = operation.contains(.move) && !operation.contains(.copy)
        var success = 0
        for src in urls {
            // Don't drop an item into itself or its own subtree.
            if dest == src || dest.path.hasPrefix(src.path + "/") { continue }
            // Don't drop into the folder the item is already in with the same name.
            let target = uniqueDestination(for: src, in: dest)
            do {
                if isMove {
                    try fm.moveItem(at: src, to: target)
                } else {
                    try fm.copyItem(at: src, to: target)
                }
                success += 1
            } catch {
                NSLog("FolderMenu: drop failed for \(src.path) -> \(target.path): \(error)")
            }
        }
        return success
    }

    /// "foo.txt" → "foo.txt", then "foo copy.txt", "foo copy 2.txt", ...
    private static func uniqueDestination(for src: URL, in dir: URL) -> URL {
        let fm = FileManager.default
        let first = dir.appendingPathComponent(src.lastPathComponent)
        if !fm.fileExists(atPath: first.path) { return first }

        let base = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        let sep = ext.isEmpty ? "" : ".\(ext)"
        var n = 0
        while true {
            let suffix = n == 0 ? "copy" : "copy \(n + 1)"
            let candidate = dir.appendingPathComponent("\(base) \(suffix)\(sep)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
            if n > 9999 { return candidate }
        }
    }

    /// Chooses copy vs move based on same-volume heuristic and modifier keys.
    /// - Same volume: default move; Option forces copy.
    /// - Different volume: default copy; Command forces move.
    static func preferredOperation(sources: [URL], dest: URL) -> NSDragOperation {
        let modifiers = NSEvent.modifierFlags
        let allSame = sources.allSatisfy { sameVolume($0, dest) }
        if allSame {
            return modifiers.contains(.option) ? .copy : .move
        } else {
            return modifiers.contains(.command) ? .move : .copy
        }
    }

    private static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let av = try? a.resourceValues(forKeys: keys).volumeIdentifier as? NSObject
        let bv = try? b.resourceValues(forKeys: keys).volumeIdentifier as? NSObject
        guard let av, let bv else { return false }
        return av.isEqual(bv)
    }
}
