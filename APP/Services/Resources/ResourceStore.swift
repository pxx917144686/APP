import UIKit
import CryptoKit
import ImageIO

struct ResourceID: Hashable {
    let url: URL
    let width: Int
    let height: Int
    let scale: Int

    init(url: URL, pointSize: CGSize, scale: CGFloat) {
        self.url = url
        self.width = max(1, Int(pointSize.width.rounded()))
        self.height = max(1, Int(pointSize.height.rounded()))
        self.scale = max(1, Int(scale.rounded()))
    }

    var pixelSize: CGSize {
        CGSize(width: CGFloat(width * scale), height: CGFloat(height * scale))
    }

    var cacheKey: String {
        "\(url.absoluteString)|\(width)x\(height)@\(scale)"
    }
}

@MainActor
final class ResourceStore {
    static let shared = ResourceStore()

    private struct PendingLoad {
        let token: UUID
        let task: Task<UIImage?, Never>
    }

    private let memory = LRUCache<ResourceID, UIImage>(capacity: 240)
    private var pending: [ResourceID: PendingLoad] = [:]
    private var waiters: [ResourceID: Int] = [:]

    private let ioQueue = DispatchQueue(label: "com.app.resource.store.io", qos: .userInitiated, attributes: .concurrent)
    private let maintenanceQueue = DispatchQueue(label: "com.app.resource.store.maintenance", qos: .utility)
    private let directory: URL

    private let diskLimit = 128 * 1024 * 1024
    private let diskTarget = 96 * 1024 * 1024

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("ResourceStore", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cachedImage(for id: ResourceID) -> UIImage? {
        memory.value(forKey: id)
    }

    func beginLoading(_ id: ResourceID) {
        waiters[id, default: 0] += 1
    }

    func endLoading(_ id: ResourceID) {
        guard let count = waiters[id] else { return }
        if count <= 1 {
            waiters.removeValue(forKey: id)
            if let load = pending[id] {
                load.task.cancel()
                pending.removeValue(forKey: id)
            }
        } else {
            waiters[id] = count - 1
        }
    }

    func image(for id: ResourceID) async -> UIImage? {
        if let cached = memory.value(forKey: id) {
            return cached
        }

        if let load = pending[id] {
            return await load.task.value
        }

        let token = UUID()
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.fetch(id)
        }
        pending[id] = PendingLoad(token: token, task: task)

        let image = await task.value

        if pending[id]?.token == token {
            pending.removeValue(forKey: id)
        }

        return image
    }

    func clearMemory() {
        memory.removeAll()
    }

    private func fetch(_ id: ResourceID) async -> UIImage? {
        if Task.isCancelled { return nil }

        guard let data = await loadData(for: id) else { return nil }
        if Task.isCancelled { return nil }

        let image = await decode(data, pixelSize: id.pixelSize, scale: CGFloat(id.scale))
        guard let image, !Task.isCancelled else { return nil }

        memory.setValue(image, forKey: id)
        return image
    }

    private func loadData(for id: ResourceID) async -> Data? {
        if id.url.isFileURL, let data = try? Data(contentsOf: id.url) {
            return data
        }
        let fileURL = diskURL(for: id)

        if let data = await readDisk(fileURL) {
            return data
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: id.url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            await writeDisk(data, to: fileURL)
            return data
        } catch {
            return nil
        }
    }

    private func diskURL(for id: ResourceID) -> URL {
        let digest = SHA256.hash(data: Data(id.cacheKey.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".res")
    }

    private func readDisk(_ url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                continuation.resume(returning: try? Data(contentsOf: url))
            }
        }
    }

    private func writeDisk(_ data: Data, to url: URL) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async {
                try? data.write(to: url, options: .atomic)
                continuation.resume()
            }
        }
        scheduleDiskTrim()
    }

    private func decode(_ data: Data, pixelSize: CGSize, scale: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            ioQueue.async {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                    continuation.resume(returning: nil)
                    return
                }

                let maxDimension = max(pixelSize.width, pixelSize.height, 1)
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension
                ]

                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: UIImage(cgImage: cgImage, scale: scale, orientation: .up))
            }
        }
    }

    private func scheduleDiskTrim() {
        let directory = self.directory
        let limit = diskLimit
        let target = diskTarget

        maintenanceQueue.async {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
            ) else { return }

            var entries: [(url: URL, size: Int, date: Date)] = []
            var total = 0

            for file in files {
                guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = values.fileSize else { continue }
                entries.append((file, size, values.contentModificationDate ?? .distantPast))
                total += size
            }

            guard total > limit else { return }

            for entry in entries.sorted(by: { $0.date < $1.date }) {
                guard total > target else { break }
                try? fm.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }
}
