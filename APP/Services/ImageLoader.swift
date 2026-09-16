import UIKit

@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    private let memoryCache = LRUCache<URL, UIImage>(capacity: 200)
    private let lowQualityCache = LRUCache<URL, UIImage>(capacity: 300)
    private let session = URLSession.shared

    private var pendingTasks: [URL: Task<UIImage?, Never>] = [:]
    private let decodingQueue = DispatchQueue(label: "com.app.imageloader.decoding", qos: .userInitiated, attributes: .concurrent)

    private init() {}

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

        let task = Task<UIImage?, Never> {
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

        return await task.value
    }

    private func decodeImageAndCreateLowQuality(from data: Data) async -> (fullQuality: UIImage?, lowQuality: UIImage?) {
        await withCheckedContinuation { continuation in
            decodingQueue.async {
                guard let image = UIImage(data: data) else {
                    continuation.resume(returning: (nil, nil))
                    return
                }

                UIGraphicsBeginImageContextWithOptions(image.size, false, 1.0)
                image.draw(at: .zero)
                let fullQualityImage = UIGraphicsGetImageFromCurrentImageContext()
                UIGraphicsEndImageContext()

                let maxDimension: CGFloat = 100
                let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1.0)
                let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

                UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
                image.draw(in: CGRect(origin: .zero, size: newSize))
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

                let targetImage: UIImage?

                if lowQuality {
                    let maxDimension: CGFloat = 100
                    let scale = min(maxDimension / image.size.width, maxDimension / image.size.height, 1.0)
                    let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

                    UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
                    image.draw(in: CGRect(origin: .zero, size: newSize))
                    let lowQualityImage = UIGraphicsGetImageFromCurrentImageContext()
                    UIGraphicsEndImageContext()
                    targetImage = lowQualityImage
                } else {
                    UIGraphicsBeginImageContextWithOptions(image.size, false, 1.0)
                    image.draw(at: .zero)
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
