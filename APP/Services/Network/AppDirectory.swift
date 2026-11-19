import Foundation

struct DirectoryEntry: Codable, Identifiable {
    var id: String { bundleId }
    var bundleId: String
    var name: String
    var trackId: Int?
    var version: String?
    var iconURL: String?
    var updatedAt: Date
}

final class AppDirectory: @unchecked Sendable {
    static let shared = AppDirectory()

    private let lock = NSLock()
    private var entries: [String: DirectoryEntry] = [:]
    private let fileURL: URL
    private var dirty = false

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "APP", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("app-directory.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([DirectoryEntry].self, from: data) {
            var map: [String: DirectoryEntry] = [:]
            for entry in decoded where !entry.bundleId.isEmpty {
                map[entry.bundleId] = entry
            }
            entries = map
        }
    }

    func entry(forBundleId bundleId: String) -> DirectoryEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[bundleId]
    }

    func allEntries() -> [DirectoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    func search(matching term: String) -> [DirectoryEntry] {
        let needle = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter {
            $0.name.lowercased().contains(needle) || $0.bundleId.lowercased().contains(needle)
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func record(apps: [iTunesSearchResult]) {
        guard !apps.isEmpty else { return }
        lock.lock()
        for app in apps {
            guard !app.bundleId.isEmpty, !app.trackName.isEmpty else { continue }
            let existing = entries[app.bundleId]
            let entry = DirectoryEntry(
                bundleId: app.bundleId,
                name: app.trackName,
                trackId: app.trackId > 0 ? app.trackId : existing?.trackId,
                version: app.version.isEmpty ? existing?.version : app.version,
                iconURL: app.artworkUrl512 ?? app.artworkUrl100 ?? existing?.iconURL,
                updatedAt: Date())
            entries[app.bundleId] = entry
        }
        dirty = true
        lock.unlock()
        persistAsync()
    }

    func record(entry: DirectoryEntry) {
        guard !entry.bundleId.isEmpty, !entry.name.isEmpty else { return }
        lock.lock()
        var merged = entry
        if let existing = entries[entry.bundleId] {
            if merged.trackId == nil { merged.trackId = existing.trackId }
            if (merged.version ?? "").isEmpty { merged.version = existing.version }
            if (merged.iconURL ?? "").isEmpty { merged.iconURL = existing.iconURL }
        }
        merged.updatedAt = Date()
        entries[entry.bundleId] = merged
        dirty = true
        lock.unlock()
        persistAsync()
    }

    func record(owned: [OwnedApp]) {
        guard !owned.isEmpty else { return }
        lock.lock()
        for app in owned {
            guard !app.bundleID.isEmpty else { continue }
            let existing = entries[app.bundleID]
            let entry = DirectoryEntry(
                bundleId: app.bundleID,
                name: app.name,
                trackId: Int(app.id) ?? existing?.trackId,
                version: app.version,
                iconURL: app.iconURL?.absoluteString ?? existing?.iconURL,
                updatedAt: Date())
            entries[app.bundleID] = entry
        }
        dirty = true
        lock.unlock()
        persistAsync()
    }

    private func persistAsync() {
        DispatchQueue.global(qos: .utility).async { self.persistNow() }
    }

    private func persistNow() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        dirty = false
        let snapshot = Array(entries.values)
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }
}

struct NameDirectoryEntry: Codable {
    let id: String
    let name: String
    let aliases: [String]?
    let platform: String?
    let source: String?
}

enum NameDirectory {
    private static let entries: [NameDirectoryEntry] = {
        guard let url = Bundle.main.url(forResource: "app-name-directory", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([NameDirectoryEntry].self, from: data) else {
            return []
        }
        return decoded
    }()

    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    static var all: [NameDirectoryEntry] { entries }

    static func matches(_ term: String) -> [NameDirectoryEntry] {
        let needle = normalized(term)
        guard !needle.isEmpty else { return [] }
        return entries.filter { entry in
            let names = [entry.name] + (entry.aliases ?? [])
            return names.contains { candidate in
                let normalizedCandidate = normalized(candidate)
                guard !normalizedCandidate.isEmpty else { return false }
                return normalizedCandidate.contains(needle) || needle.contains(normalizedCandidate)
            }
        }
    }
}
