import UIKit

final class AppIconManager: NSObject {
    static let shared = AppIconManager()

    private override init() {
        super.init()
    }

    var currentAlternateIconName: String? {
        if let saved = UserDefaults.standard.string(forKey: "APP.currentAlternateIconName"),
           !saved.isEmpty {
            return saved
        }
        return UIApplication.shared.alternateIconName
    }

    var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    var isTrollStore: Bool {
        EnvironmentDetector.shared.isTrollStore || EnvironmentDetector.shared.isJailbroken
    }

    func setAlternateIconName(_ iconName: String?, completion: ((Bool, Error?) -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            if self.isTrollStore {
                self.setAlternateIconViaFileReplace(iconName, completion: completion)
                return
            }

            if UIApplication.shared.supportsAlternateIcons {
                UIApplication.shared.setAlternateIconName(iconName) { error in
                    if let error = error {
                        DispatchQueue.main.async {
                            completion?(false, error)
                        }
                    } else {
                        UserDefaults.standard.set(iconName, forKey: "APP.currentAlternateIconName")
                        DispatchQueue.main.async {
                            completion?(true, nil)
                        }
                    }
                }
            } else {
                let error = NSError(domain: "AppIconManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "设备不支持备用图标"])
                completion?(false, error)
            }
        }
    }

    private func setAlternateIconViaFileReplace(_ iconName: String?, completion: ((Bool, Error?) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let targetName = iconName ?? "AppIcon"

            do {
                let replacedCount = try self.replaceAllAppIcons(with: targetName)

                guard replacedCount > 0 else {
                    throw NSError(
                        domain: "AppIconManager",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "没有图标文件被替换"]
                    )
                }

                UserDefaults.standard.set(iconName, forKey: "APP.currentAlternateIconName")
                UserDefaults.standard.synchronize()

                self.refreshIconCache()

                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    self.refreshIconCache()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        completion?(true, nil)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion?(false, error)
                }
            }
        }
    }

    @discardableResult
    private func replaceAllAppIcons(with iconName: String) throws -> Int {
        let fileManager = FileManager.default
        let bundlePath = Bundle.main.bundlePath

        guard fileManager.isWritableFile(atPath: bundlePath) else {
            throw NSError(
                domain: "AppIconManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "应用Bundle目录不可写"]
            )
        }

        guard let sourceImage = loadSourceImage(named: iconName) else {
            throw NSError(
                domain: "AppIconManager",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "找不到图标源文件: \(iconName)"]
            )
        }

        let iconSizes: [(fileName: String, size: CGSize)] = [
            ("AppIcon20x20@2x.png", CGSize(width: 40, height: 40)),
            ("AppIcon20x20@3x.png", CGSize(width: 60, height: 60)),
            ("AppIcon29x29@2x.png", CGSize(width: 58, height: 58)),
            ("AppIcon29x29@3x.png", CGSize(width: 87, height: 87)),
            ("AppIcon40x40@2x.png", CGSize(width: 80, height: 80)),
            ("AppIcon40x40@3x.png", CGSize(width: 120, height: 120)),
            ("AppIcon60x60@2x.png", CGSize(width: 120, height: 120)),
            ("AppIcon60x60@3x.png", CGSize(width: 180, height: 180)),
            ("AppIcon20x20~ipad.png", CGSize(width: 20, height: 20)),
            ("AppIcon20x20@2x~ipad.png", CGSize(width: 40, height: 40)),
            ("AppIcon29x29~ipad.png", CGSize(width: 29, height: 29)),
            ("AppIcon29x29@2x~ipad.png", CGSize(width: 58, height: 58)),
            ("AppIcon40x40~ipad.png", CGSize(width: 40, height: 40)),
            ("AppIcon40x40@2x~ipad.png", CGSize(width: 80, height: 80)),
            ("AppIcon76x76~ipad.png", CGSize(width: 76, height: 76)),
            ("AppIcon76x76@2x~ipad.png", CGSize(width: 152, height: 152)),
            ("AppIcon83.5x83.5@2x~ipad.png", CGSize(width: 167, height: 167)),
            ("AppIcon1024x1024.png", CGSize(width: 1024, height: 1024)),
            ("AppIcon.png", CGSize(width: 60, height: 60)),
            ("AppIcon@2x.png", CGSize(width: 120, height: 120)),
            ("AppIcon@3x.png", CGSize(width: 180, height: 180)),
        ]

        var successCount = 0
        for icon in iconSizes {
            let destURL = URL(fileURLWithPath: bundlePath).appendingPathComponent(icon.fileName)
            autoreleasepool {
                do {
                    if fileManager.fileExists(atPath: destURL.path) {
                        try fileManager.removeItem(at: destURL)
                    }
                    let resized = resizeImage(sourceImage, to: icon.size)
                    if let pngData = resized.pngData() {
                        try pngData.write(to: destURL, options: .atomic)
                        successCount += 1
                    }
                } catch {
                }
            }
        }

        try? fileManager.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: bundlePath
        )

        return successCount
    }

    private func refreshIconCache() {
        let workspaceClass: AnyClass? = NSClassFromString("LSApplicationWorkspace")
        let defaultWorkspace = workspaceClass?.value(forKey: "defaultWorkspace") as? NSObject

        if let workspace = defaultWorkspace {
            let uicacheSel = Selector(("uicache"))
            if workspace.responds(to: uicacheSel) {
                workspace.perform(uicacheSel)
            }

            if let bundleId = Bundle.main.bundleIdentifier {
                let notifySel = Selector(("noteIconChangeForDisplayIdentifier:observer:"))
                if workspace.responds(to: notifySel) {
                    workspace.perform(notifySel, with: bundleId, with: nil)
                }
            }

            let invalidateSel = Selector(("invalidateIconCache:"))
            if workspace.responds(to: invalidateSel) {
                workspace.perform(invalidateSel, with: nil)
            }
        }

        let sbClass: AnyClass? = NSClassFromString("SBApplicationController")
        let sbInstance = sbClass?.value(forKey: "sharedInstance") as? NSObject
        if let sb = sbInstance {
            let reloadSel = Selector(("reloadAllIcons"))
            if sb.responds(to: reloadSel) {
                sb.perform(reloadSel)
            }
        }
    }

    private func loadSourceImage(named name: String) -> UIImage? {
        if name == "AppIcon" || name == "app" || name.isEmpty {
            if let imagePath = Bundle.main.path(forResource: "AppIcon1024x1024", ofType: "png") {
                return UIImage(contentsOfFile: imagePath)
            }
            if let image = UIImage(named: "AppLogo") {
                return image
            }
            return nil
        }

        let candidates = [
            "\(name)1024x1024",
            "\(name)60x60@3x",
            "\(name)@3x",
            name,
        ]

        for candidate in candidates {
            if let path = Bundle.main.path(forResource: candidate, ofType: "png") {
                return UIImage(contentsOfFile: path)
            }
        }

        if let image = UIImage(named: name) {
            return image
        }

        return nil
    }

    private func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
