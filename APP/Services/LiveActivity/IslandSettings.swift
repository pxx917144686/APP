import Foundation

extension Notification.Name {
    static let islandSettingsChanged = Notification.Name("APP.island.settingsChanged")
}

final class IslandSettings: ObservableObject {
    static let shared = IslandSettings()

    private enum Key {
        static let enabled = "APP.island.enabled"
        static let download = "APP.island.download"
        static let sign = "APP.island.sign"
        static let decrypt = "APP.island.decrypt"
        static let install = "APP.island.install"
    }

    @Published var isEnabled: Bool {
        didSet {
            persist()
            notify()
        }
    }

    @Published var showsDownload: Bool {
        didSet {
            persist()
            notify()
        }
    }

    @Published var showsSign: Bool {
        didSet {
            persist()
            notify()
        }
    }

    @Published var showsDecrypt: Bool {
        didSet {
            persist()
            notify()
        }
    }

    @Published var showsInstall: Bool {
        didSet {
            persist()
            notify()
        }
    }

    private let defaults = UserDefaults.standard

    private init() {
        isEnabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        showsDownload = defaults.object(forKey: Key.download) as? Bool ?? true
        showsSign = defaults.object(forKey: Key.sign) as? Bool ?? true
        showsDecrypt = defaults.object(forKey: Key.decrypt) as? Bool ?? true
        showsInstall = defaults.object(forKey: Key.install) as? Bool ?? true
    }

    func isVisible(_ kind: String) -> Bool {
        guard isEnabled else { return false }
        switch kind {
        case IslandTaskKind.download:
            return showsDownload
        case IslandTaskKind.sign:
            return showsSign
        case IslandTaskKind.decrypt:
            return showsDecrypt
        case IslandTaskKind.install:
            return showsInstall
        default:
            return true
        }
    }

    private func persist() {
        defaults.set(isEnabled, forKey: Key.enabled)
        defaults.set(showsDownload, forKey: Key.download)
        defaults.set(showsSign, forKey: Key.sign)
        defaults.set(showsDecrypt, forKey: Key.decrypt)
        defaults.set(showsInstall, forKey: Key.install)
    }

    private func notify() {
        NotificationCenter.default.post(name: .islandSettingsChanged, object: self)
    }
}
