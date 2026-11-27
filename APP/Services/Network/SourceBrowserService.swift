import Foundation
import UIKit

// MARK: - Models

struct SourceEntry: Identifiable, Sendable, Codable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64

    var id: String { path }
}

struct SourceCommit: Identifiable, Sendable, Codable {
    let sha: String
    let message: String
    let author: String
    let date: Date
    let avatarURL: URL?

    var id: String { sha }
    var shortSha: String { String(sha.prefix(7)) }
    var title: String { message.components(separatedBy: "\n").first ?? message }
}

struct SourceRepoMeta: Sendable, Codable {
    let repoDescription: String?
    let stars: Int
    let forks: Int
    let language: String?
    let pushedAt: Date?
}

enum SourceFileKind: String, Sendable, Codable {
    case text
    case image
    case binary
}

struct SourceFile: Sendable, Codable {
    let path: String
    let size: Int64
    let sha: String
    let text: String?
    let imageData: Data?
    let kind: SourceFileKind

    var shortSha: String { String(sha.prefix(7)) }
}

// MARK: - Errors

enum SourceBrowserError: LocalizedError {
    case rateLimited
    case notFound
    case http(Int)
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .rateLimited:
            return "source_browser_rate_limited".localized
        case .notFound:
            return "source_browser_not_found".localized
        case .http(let code):
            return "source_browser_load_failed".localized + " (HTTP \(code))"
        case .unexpectedResponse:
            return "source_browser_load_failed".localized
        }
    }
}

// MARK: - Service

@MainActor
final class SourceBrowserService {
    static let shared = SourceBrowserService()

    static let repoOwner = "pxx917144686"
    static let repoName = "APP"
    nonisolated static let defaultRef = "main"
    static let repoWebURL = URL(string: "https://github.com/\(repoOwner)/\(repoName)")!

    static func fileWebURL(path: String, ref: String) -> URL {
        URL(string: "\(repoWebURL.absoluteString)/blob/\(ref)/\(path)")!
    }

    static func commitWebURL(sha: String) -> URL {
        URL(string: "\(repoWebURL.absoluteString)/commit/\(sha)")!
    }

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "ico"
    ]
    private static let codeExtensions: Set<String> = [
        "swift", "js", "ts", "py", "rb", "go", "c", "h", "cpp", "hpp", "m", "mm",
        "kt", "java", "sh", "zsh", "bash", "css", "scss", "html", "yml", "yaml",
        "json", "xml", "plist", "toml", "sql", "wasm"
    ]
    private static let archiveExtensions: Set<String> = ["ipa", "zip", "tar", "gz", "xz", "7z", "dylib", "so", "a"]
    private static let certExtensions: Set<String> = ["key", "pem", "cer", "crt", "der", "p12", "mobileprovision"]

    private let directoryCache = LRUCache<String, [SourceEntry]>(capacity: 40)
    private let fileCache = LRUCache<String, SourceFile>(capacity: 20)
    private let commitCache = LRUCache<String, [SourceCommit]>(capacity: 6)
    private let tagCache = LRUCache<String, [String]>(capacity: 2)
    private let metaCache = LRUCache<String, SourceRepoMeta>(capacity: 2)

    private let decoder = JSONDecoder()
    private let isoFormatter = ISO8601DateFormatter()

    // MARK: API

    func fetchDirectory(_ path: String, ref: String, force: Bool = false) async throws -> [SourceEntry] {
        let key = "\(ref)#\(path)"
        if !force {
            if let cached = directoryCache.value(forKey: key) { return cached }
            if let disk = SourceDiskCache.shared.directory(key, maxAge: 600) {
                directoryCache[key] = disk
                return disk
            }
        }

        do {
            let url = Self.apiURL("contents/\(Self.encodedPath(path))", query: [URLQueryItem(name: "ref", value: ref)])
            let data = try await request(url, accept: "application/vnd.github+json")
            let items = try decoder.decode([GitHubContent].self, from: data)

            let entries = items
                .map { SourceEntry(path: $0.path, name: $0.name, isDirectory: $0.type == "dir", size: Int64($0.size)) }
                .sorted { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                }
            directoryCache[key] = entries
            SourceDiskCache.shared.setDirectory(key, entries)
            return entries
        } catch {
            if let stale = SourceDiskCache.shared.directory(key, maxAge: 0, ignoreAge: true) {
                return stale
            }
            throw error
        }
    }

    func fetchFile(_ path: String, ref: String, force: Bool = false) async throws -> SourceFile {
        let key = "\(ref)#\(path)"
        if !force {
            if let cached = fileCache.value(forKey: key) { return cached }
            if let disk = SourceDiskCache.shared.file(key, maxAge: 7 * 24 * 3600) {
                fileCache[key] = disk
                return disk
            }
        }

        do {
            let url = Self.apiURL("contents/\(Self.encodedPath(path))", query: [URLQueryItem(name: "ref", value: ref)])
            let data = try await request(url, accept: "application/vnd.github+json")
            let content = try decoder.decode(GitHubContent.self, from: data)

            let size = Int64(content.size)
            let ext = (path as NSString).pathExtension.lowercased()
            let file: SourceFile

            if Self.imageExtensions.contains(ext) {
                let payload = await contentPayload(for: content)
                let image = UIImage(data: payload)
                file = SourceFile(path: path, size: size, sha: content.sha,
                                  text: nil, imageData: image == nil ? nil : payload, kind: .image)
            } else {
                let payload = await contentPayload(for: content)
                if let text = Self.decodeText(payload) {
                    file = SourceFile(path: path, size: size, sha: content.sha,
                                      text: text, imageData: nil, kind: .text)
                } else {
                    file = SourceFile(path: path, size: size, sha: content.sha,
                                      text: nil, imageData: nil, kind: .binary)
                }
            }

            fileCache[key] = file
            SourceDiskCache.shared.setFile(key, file)
            return file
        } catch {
            if let stale = SourceDiskCache.shared.file(key, maxAge: 0, ignoreAge: true) {
                return stale
            }
            throw error
        }
    }

    func fetchCommits(ref: String, force: Bool = false) async throws -> [SourceCommit] {
        if !force {
            if let cached = commitCache.value(forKey: ref) { return cached }
            if let disk = SourceDiskCache.shared.commits(ref, maxAge: 600) {
                commitCache[ref] = disk
                return disk
            }
        }

        do {
            let url = Self.apiURL("commits", query: [
                URLQueryItem(name: "per_page", value: "30"),
                URLQueryItem(name: "sha", value: ref)
            ])
            let data = try await request(url, accept: "application/vnd.github+json")
            let list = try decoder.decode([GitHubCommit].self, from: data)

            let commits = list.map { item in
                SourceCommit(sha: item.sha,
                             message: item.commit.message,
                             author: item.commit.author.name,
                             date: isoFormatter.date(from: item.commit.author.date) ?? Date(),
                             avatarURL: item.avatarURL)
            }
            commitCache[ref] = commits
            SourceDiskCache.shared.setCommits(ref, commits)
            return commits
        } catch {
            if let stale = SourceDiskCache.shared.commits(ref, maxAge: 0, ignoreAge: true) {
                return stale
            }
            throw error
        }
    }

    func fetchTags(force: Bool = false) async throws -> [String] {
        if !force {
            if let cached = tagCache.value(forKey: "tags") { return cached }
            if let disk = SourceDiskCache.shared.tags(maxAge: 24 * 3600) {
                tagCache["tags"] = disk
                return disk
            }
        }

        do {
            let url = Self.apiURL("tags", query: [URLQueryItem(name: "per_page", value: "30")])
            let data = try await request(url, accept: "application/vnd.github+json")
            let list = try decoder.decode([GitHubTag].self, from: data)

            let names = list.map(\.name)
            tagCache["tags"] = names
            SourceDiskCache.shared.setTags(names)
            return names
        } catch {
            if let stale = SourceDiskCache.shared.tags(maxAge: 0, ignoreAge: true) {
                return stale
            }
            throw error
        }
    }

    func fetchRepoMeta(force: Bool = false) async throws -> SourceRepoMeta {
        if !force {
            if let cached = metaCache.value(forKey: "meta") { return cached }
            if let disk = SourceDiskCache.shared.meta(maxAge: 1800) {
                metaCache["meta"] = disk
                return disk
            }
        }

        do {
            let url = Self.apiGitHubRepoURL
            let data = try await request(url, accept: "application/vnd.github+json")
            let repo = try decoder.decode(GitHubRepo.self, from: data)

            let meta = SourceRepoMeta(repoDescription: repo.description,
                                      stars: repo.stargazersCount,
                                      forks: repo.forksCount,
                                      language: repo.language,
                                      pushedAt: repo.pushedAt.flatMap { isoFormatter.date(from: $0) })
            metaCache["meta"] = meta
            SourceDiskCache.shared.setMeta(meta)
            return meta
        } catch {
            if let stale = SourceDiskCache.shared.meta(maxAge: 0, ignoreAge: true) {
                return stale
            }
            throw error
        }
    }

    // MARK: 缓存失效（下拉刷新）

    func invalidateDirectory(_ path: String, ref: String) {
        directoryCache.removeValue(forKey: "\(ref)#\(path)")
    }

    func invalidateCommits(ref: String) {
        commitCache.removeValue(forKey: ref)
    }

    func invalidateRepoMeta() {
        metaCache.removeValue(forKey: "meta")
    }

    func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.locale = Locale.current
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func formattedSize(_ size: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    // MARK: Icon mapping

    func icon(for entry: SourceEntry) -> String {
        if entry.isDirectory { return "folder.fill" }
        return Self.icon(forFileExtension: (entry.path as NSString).pathExtension)
    }

    static func icon(forFileExtension ext: String) -> String {
        let lower = ext.lowercased()
        if imageExtensions.contains(lower) { return "photo" }
        if codeExtensions.contains(lower) { return "curlybraces" }
        if archiveExtensions.contains(lower) { return "archivebox" }
        if certExtensions.contains(lower) { return "key.fill" }
        if lower == "md" || lower == "txt" || lower == "log" { return "doc.plaintext" }
        if lower == "strings" { return "globe" }
        if lower == "pdf" { return "doc.richtext" }
        return "doc.text"
    }

    // MARK: Private

    /// JSON 版 contents API 对 <1MB 文件返回 base64 content；更大或图片按 download_url 拉 raw。
    private func contentPayload(for content: GitHubContent) async -> Data {
        if let base64 = content.content?.replacingOccurrences(of: "\n", with: ""),
           let decoded = Data(base64Encoded: base64) {
            return decoded
        }
        guard let rawURL = content.downloadURL, let url = URL(string: rawURL) else { return Data() }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github.raw", forHTTPHeaderField: "Accept")
        if let (data, _) = try? await URLSession.shared.data(for: request) {
            return data
        }
        return Data()
    }

    static func decodeText(_ data: Data) -> String? {
        guard !data.isEmpty, data.firstIndex(of: 0) == nil else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    private func request(_ url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("APP/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceBrowserError.unexpectedResponse
        }
        switch http.statusCode {
        case 200:
            return data
        case 403, 429:
            throw SourceBrowserError.rateLimited
        case 404:
            throw SourceBrowserError.notFound
        case let code:
            throw SourceBrowserError.http(code)
        }
    }

    private static func encodedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static var apiGitHubRepoURL: URL {
        URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)")!
    }

    private static func apiURL(_ endpoint: String, query: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)")!
        if !endpoint.isEmpty {
            components.path += "/" + endpoint
        }
        components.queryItems = query
        return components.url!
    }
}

// MARK: - 磁盘缓存（限流/断网时回退旧数据）

private struct DiskCacheEnvelope: Codable {
    var directories: [String: TimedDirectory] = [:]
    var files: [String: TimedFile] = [:]
    var commits: [String: TimedCommits] = [:]
    var tags: TimedTags?
    var meta: TimedMeta?
}

private struct TimedDirectory: Codable {
    let value: [SourceEntry]
    let savedAt: Date
}

private struct TimedFile: Codable {
    let value: SourceFile
    let savedAt: Date
}

private struct TimedCommits: Codable {
    let value: [SourceCommit]
    let savedAt: Date
}

private struct TimedTags: Codable {
    let value: [String]
    let savedAt: Date
}

private struct TimedMeta: Codable {
    let value: SourceRepoMeta
    let savedAt: Date
}

@MainActor
final class SourceDiskCache {
    static let shared = SourceDiskCache()

    private let fileURL: URL
    private var envelope = DiskCacheEnvelope()

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SourceBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("cache.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(DiskCacheEnvelope.self, from: data) {
            envelope = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func directory(_ key: String, maxAge: TimeInterval, ignoreAge: Bool = false) -> [SourceEntry]? {
        guard let hit = envelope.directories[key], ignoreAge || Date().timeIntervalSince(hit.savedAt) < maxAge else { return nil }
        return hit.value
    }

    func setDirectory(_ key: String, _ value: [SourceEntry]) {
        envelope.directories[key] = TimedDirectory(value: value, savedAt: Date())
        save()
    }

    func file(_ key: String, maxAge: TimeInterval, ignoreAge: Bool = false) -> SourceFile? {
        guard let hit = envelope.files[key], ignoreAge || Date().timeIntervalSince(hit.savedAt) < maxAge else { return nil }
        return hit.value
    }

    func setFile(_ key: String, _ value: SourceFile) {
        // 超过 1 MB 的文件（图片/大文本）不落盘，避免缓存膨胀
        if value.imageData?.count ?? 0 > 1_048_576 { return }
        if value.text?.utf8.count ?? 0 > 1_048_576 { return }
        envelope.files[key] = TimedFile(value: value, savedAt: Date())
        save()
    }

    func commits(_ ref: String, maxAge: TimeInterval, ignoreAge: Bool = false) -> [SourceCommit]? {
        guard let hit = envelope.commits[ref], ignoreAge || Date().timeIntervalSince(hit.savedAt) < maxAge else { return nil }
        return hit.value
    }

    func setCommits(_ ref: String, _ value: [SourceCommit]) {
        envelope.commits[ref] = TimedCommits(value: value, savedAt: Date())
        save()
    }

    func tags(maxAge: TimeInterval, ignoreAge: Bool = false) -> [String]? {
        guard let hit = envelope.tags, ignoreAge || Date().timeIntervalSince(hit.savedAt) < maxAge else { return nil }
        return hit.value
    }

    func setTags(_ value: [String]) {
        envelope.tags = TimedTags(value: value, savedAt: Date())
        save()
    }

    func meta(maxAge: TimeInterval, ignoreAge: Bool = false) -> SourceRepoMeta? {
        guard let hit = envelope.meta, ignoreAge || Date().timeIntervalSince(hit.savedAt) < maxAge else { return nil }
        return hit.value
    }

    func setMeta(_ value: SourceRepoMeta) {
        envelope.meta = TimedMeta(value: value, savedAt: Date())
        save()
    }
}

// MARK: - GitHub API DTOs

private struct GitHubContent: Decodable {
    let name: String
    let path: String
    let type: String
    let size: Int
    let sha: String
    let content: String?
    let downloadURL: String?

    enum CodingKeys: String, CodingKey {
        case name, path, type, size, sha, content
        case downloadURL = "download_url"
    }
}

private struct GitHubCommit: Decodable {
    struct Detail: Decodable {
        struct Author: Decodable {
            let name: String
            let date: String
        }
        let message: String
        let author: Author
    }
    struct Account: Decodable {
        let avatarURL: URL?

        enum CodingKeys: String, CodingKey {
            case avatarURL = "avatar_url"
        }
    }
    let sha: String
    let commit: Detail
    let author: Account?

    var avatarURL: URL? { author?.avatarURL }
}

private struct GitHubTag: Decodable {
    let name: String
}

private struct GitHubRepo: Decodable {
    let description: String?
    let stargazersCount: Int
    let forksCount: Int
    let language: String?
    let pushedAt: String?

    enum CodingKeys: String, CodingKey {
        case description
        case language
        case stargazersCount = "stargazers_count"
        case forksCount = "forks_count"
        case pushedAt = "pushed_at"
    }
}
