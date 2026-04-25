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
        static let maxStoredRecords = 500
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
        if records.count > Ranking.maxStoredRecords {
            capRecords(at: .now)
            save(notify: false)
        }
    }

    func recordAccess(_ url: URL, at date: Date = .now) {
        let path = url.path
        guard !path.isEmpty else { return }
        var record = records[path] ?? FrequentRecord(accessCount: 0, lastAccessedAt: date)
        record.accessCount += 1
        record.lastAccessedAt = date
        records[path] = record
        capRecords(at: date)
        save(notify: true)
    }

    func topItems(within roots: [URL], excluding excludedPaths: Set<String>, limit: Int) -> [URL] {
        guard !roots.isEmpty, limit > 0 else { return [] }

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
            .map(\.key)

        return validatedTopPaths(from: sortedPaths, limit: limit)
            .map { URL(fileURLWithPath: $0) }
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

    private func validatedTopPaths(from sortedPaths: [String], limit: Int) -> [String] {
        var result: [String] = []
        var stalePaths: [String] = []
        let validationBudget = max(limit + 8, limit * 4)

        for path in sortedPaths.prefix(validationBudget) {
            if FileManager.default.fileExists(atPath: path) {
                result.append(path)
                if result.count == limit { break }
            } else {
                stalePaths.append(path)
            }
        }

        if !stalePaths.isEmpty {
            for path in stalePaths {
                records.removeValue(forKey: path)
            }
            save(notify: false)
        }

        return result
    }

    private func decayedScore(for record: FrequentRecord, at now: Date) -> Double {
        let ageDays = max(0, now.timeIntervalSince(record.lastAccessedAt)) / 86_400
        let decay = pow(0.5, ageDays / Ranking.decayHalfLifeDays)
        return Double(record.accessCount) * decay
    }

    private func capRecords(at date: Date) {
        guard records.count > Ranking.maxStoredRecords else { return }
        let kept = records
            .sorted { lhs, rhs in
                let lhsScore = decayedScore(for: lhs.value, at: date)
                let rhsScore = decayedScore(for: rhs.value, at: date)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                if lhs.value.lastAccessedAt != rhs.value.lastAccessedAt {
                    return lhs.value.lastAccessedAt > rhs.value.lastAccessedAt
                }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .prefix(Ranking.maxStoredRecords)
        records = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private func isWithinRoots(_ path: String, roots: [URL]) -> Bool {
        roots.contains { root in
            let rootPath = root.path
            return path == rootPath || path.hasPrefix(rootPath + "/")
        }
    }
}
