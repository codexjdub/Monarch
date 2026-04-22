import Foundation

struct FrequentRecord: Codable {
    var accessCount: Int
    var lastAccessedAt: Date
}

@MainActor
final class FrequentStore {
    private enum Ranking {
        static let minimumAccessCount = 2
        static let decayHalfLifeDays = 21.0
    }

    static let shared = FrequentStore()

    private let key = UDKey.frequentItems
    private let hiddenKey = UDKey.hiddenFrequentItems
    private var records: [String: FrequentRecord] = [:]
    private var hiddenPaths: Set<String> = []

    /// Called whenever the persisted usage ranking changes.
    var onChanged: (() -> Void)?

    private init() {
        hiddenPaths = Set(UserDefaults.standard.stringArray(forKey: hiddenKey) ?? [])
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: FrequentRecord].self, from: data)
        else { return }
        records = decoded
    }

    func recordAccess(_ url: URL, at date: Date = .now) {
        let path = url.path
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return }
        var record = records[path] ?? FrequentRecord(accessCount: 0, lastAccessedAt: date)
        record.accessCount += 1
        record.lastAccessedAt = date
        records[path] = record
        save(notify: true)
    }

    func topItems(within roots: [URL], excluding excludedPaths: Set<String>, limit: Int) -> [URL] {
        guard !roots.isEmpty, limit > 0 else { return [] }
        pruneMissingEntries()

        let now = Date()
        let sortedPaths = records
            .filter { path, record in
                !excludedPaths.contains(path)
                    && isWithinRoots(path, roots: roots)
                    && record.accessCount >= Ranking.minimumAccessCount
                    && !hiddenPaths.contains(path)
            }
            .sorted { lhs, rhs in
                let lhsScore = decayedScore(for: lhs.value, at: now)
                let rhsScore = decayedScore(for: rhs.value, at: now)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                if lhs.value.lastAccessedAt != rhs.value.lastAccessedAt {
                    return lhs.value.lastAccessedAt > rhs.value.lastAccessedAt
                }
                if lhs.value.accessCount != rhs.value.accessCount {
                    return lhs.value.accessCount > rhs.value.accessCount
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .prefix(limit)
            .map(\.key)

        return sortedPaths.map { URL(fileURLWithPath: $0) }
    }

    func clear() {
        guard !records.isEmpty || !hiddenPaths.isEmpty else { return }
        records = [:]
        hiddenPaths = []
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: hiddenKey)
        onChanged?()
    }

    func hide(_ url: URL) {
        let path = url.path
        guard !path.isEmpty, !hiddenPaths.contains(path) else { return }
        hiddenPaths.insert(path)
        UserDefaults.standard.set(Array(hiddenPaths).sorted(), forKey: hiddenKey)
        onChanged?()
    }

    static func subtitle(for url: URL) -> String? {
        let parentPath = url.deletingLastPathComponent().path
        guard !parentPath.isEmpty else { return nil }
        return "in \(NSString(string: parentPath).abbreviatingWithTildeInPath)"
    }

    static var minimumQualifiedAccessCount: Int {
        Ranking.minimumAccessCount
    }

    private func save(notify: Bool) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: key)
        if notify { onChanged?() }
    }

    private func pruneMissingEntries() {
        let existingPaths = records.keys.filter { FileManager.default.fileExists(atPath: $0) }
        let staleHidden = hiddenPaths.filter { !FileManager.default.fileExists(atPath: $0) }
        if !staleHidden.isEmpty {
            hiddenPaths.subtract(staleHidden)
            UserDefaults.standard.set(Array(hiddenPaths).sorted(), forKey: hiddenKey)
        }
        guard existingPaths.count != records.count else { return }
        let existingSet = Set(existingPaths)
        records = records.filter { existingSet.contains($0.key) }
        save(notify: false)
    }

    private func decayedScore(for record: FrequentRecord, at now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(record.lastAccessedAt)) / 86_400
        let decay = pow(0.5, ageDays / Ranking.decayHalfLifeDays)
        return Double(record.accessCount) * decay
    }

    private func isWithinRoots(_ path: String, roots: [URL]) -> Bool {
        roots.contains { root in
            let rootPath = root.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }
}
