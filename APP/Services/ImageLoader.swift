import UIKit

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let memoryCache = LRUCache<URL, UIImage>(capacity: 200)
    private let lowQualityCache = LRUCache<URL, UIImage>(capacity: 300)
    private let session = URLSession.shared

    private var pendingTasks: [URL: Task<UIImage?, Never>] = [:]
    private var pendingLowQualityTasks: [URL: Task<UIImage?, Never>] = [:]
    private let decodingQueue = DispatchQueue(label: "com.app.imageloader.decoding", qos: .userInitiated, attributes: .concurrent)

    /// 缓存位图的最大边长（pt）。全 App 图标展示最大 ~60pt@3x，超出部分无需保留：
    /// 原尺寸 512² 位图解码后 ~1MB/张，200 张即 ~200MB 常驻脏内存，
    /// 大图源（1024²）可达 ~800MB —— 是长下载会话中内存膨胀直至 jetsam 闪退的主因。
    private static let maxCachedDimension: CGFloat = 240

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.clearMemoryCache()
            }
        }
    }

    func prefetch(_ urls: [URL]) {
        let unique = Array(Set(urls)).prefix(24)
        guard !unique.isEmpty else { return }
        Task { [weak self] in
            for url in unique {
                _ = await self?.loadLowQualityImage(from: url)
            }
        }
    }

    func loadImage(from url: URL, lowQualityFirst: Bool = false) async -> UIImage? {
        if let cached = memoryCache.value(forKey: url) {
            return cached
        }

        if lowQualityFirst, let lowQuality = lowQualityCache.value(forKey: url) {
            return lowQuality
        }

        if let existingTask = pendingTasks[url] {
            return await existingTask.value
        }

        let task = Task<UIImage?, Never> {
            defer {
                pendingTasks.removeValue(forKey: url)
            }

            do {
                let (data, response) = try await session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    return nil
                }

                let result = await decodeImageAndCreateLowQuality(from: data)

                if let image = result.fullQuality {
                    memoryCache.setValue(image, forKey: url)

                    if let lowQuality = result.lowQuality {
                        lowQualityCache.setValue(lowQuality, forKey: url)
                    }
                }

                return result.fullQuality
            } catch {
                return nil
            }
        }

        pendingTasks[url] = task

        return await task.value
    }

    func loadLowQualityImage(from url: URL) async -> UIImage? {
        if let cached = memoryCache.value(forKey: url) {
            return cached
        }

        if let lowQuality = lowQualityCache.value(forKey: url) {
            return lowQuality
        }

        if let existingTask = pendingLowQualityTasks[url] {
            return await existingTask.value
        }

        let task = Task<UIImage?, Never> {
            defer {
                pendingLowQualityTasks.removeValue(forKey: url)
            }

            do {
                let (data, response) = try await session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    return nil
                }

                let image = await decodeImage(from: data, lowQuality: true)

                if let image = image {
                    lowQualityCache.setValue(image, forKey: url)
                }

                return image
            } catch {
                return nil
            }
        }

        pendingLowQualityTasks[url] = task

        return await task.value
    }

    /// 按缓存上限降采样后的目标尺寸（保持纵横比）
    private static func clampedSize(for size: CGSize, maxDimension: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return size }
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func decodeImageAndCreateLowQuality(from data: Data) async -> (fullQuality: UIImage?, lowQuality: UIImage?) {
        await withCheckedContinuation { continuation in
            decodingQueue.async {
                guard let image = UIImage(data: data) else {
                    continuation.resume(returning: (nil, nil))
                    return
                }

                guard image.size.width > 0, image.size.height > 0 else {
                    continuation.resume(returning: (image, nil))
                    return
                }

                let cachedSize = Self.clampedSize(for: image.size, maxDimension: Self.maxCachedDimension)
                UIGraphicsBeginImageContextWithOptions(cachedSize, false, 1.0)
                image.draw(in: CGRect(origin: .zero, size: cachedSize))
                let fullQualityImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()

                let lowSize = Self.clampedSize(for: image.size, maxDimension: 100)
                UIGraphicsBeginImageContextWithOptions(lowSize, false, 1.0)
                image.draw(in: CGRect(origin: .zero, size: lowSize))
                let lowQualityImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()

                continuation.resume(returning: (fullQualityImage, lowQualityImage))
            }
        }
    }

    private func decodeImage(from data: Data, lowQuality: Bool = false) async -> UIImage? {
        await withCheckedContinuation { continuation in
            decodingQueue.async {
                guard let image = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }

                guard image.size.width > 0, image.size.height > 0 else {
                    continuation.resume(returning: image)
                    return
                }

                let targetImage: UIImage?

                if lowQuality {
                    let newSize = Self.clampedSize(for: image.size, maxDimension: 100)

                    UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                    let lowQualityImage = UIGraphicsGetImageFromCurrentImageContext()
                    UIGraphicsEndImageContext()
                    targetImage = lowQualityImage
                } else {
                    let newSize = Self.clampedSize(for: image.size, maxDimension: Self.maxCachedDimension)
                    UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                    let decodedImage = UIGraphicsGetImageFromCurrentImageContext()
                    UIGraphicsEndImageContext()
                    targetImage = decodedImage
                }

                continuation.resume(returning: targetImage)
            }
        }
    }

    func prefetchImage(from url: URL) {
        Task {
            let _ = await loadImage(from: url)
        }
    }

    func prefetchLowQualityImage(from url: URL) {
        Task {
            let _ = await loadLowQualityImage(from: url)
        }
    }

    func clearMemoryCache() {
        memoryCache.removeAll()
        lowQualityCache.removeAll()
    }

    func getCachedImage(for url: URL) -> UIImage? {
        memoryCache.value(forKey: url)
    }

    func getLowQualityCachedImage(for url: URL) -> UIImage? {
        lowQualityCache.value(forKey: url) ?? memoryCache.value(forKey: url)
    }
}
