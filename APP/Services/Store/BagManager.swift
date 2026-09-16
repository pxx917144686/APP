import Foundation

@MainActor
class BagManager: ObservableObject {
    static let shared = BagManager()

    @Published private(set) var isLoaded: Bool = false
    private(set) var bagData: [String: Any] = [:]
    private(set) var urlBag: [String: Any] = [:]
    private var lastLoadTime: Date?
    private let cacheDuration: TimeInterval = 3600
    private let bagSession: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.bagSession = URLSession(configuration: cfg)
    }

    var buyURL: String {
        if let url = bagData["buyProductURL"] as? String {
            return url
        }
        return "https://buy.itunes.apple.com"
    }

    var downloadURL: String {
        if let url = bagData["downloadProductURL"] as? String {
            return url
        }
        return "https://p25-buy.itunes.apple.com"
    }

    var searchURL: String {
        if let url = bagData["searchURL"] as? String {
            return url
        }
        return "https://itunes.apple.com"
    }

    var authenticateAccountURL: String {
        if let ub = urlBag["authenticateAccount"] as? String, !urlBag.isEmpty {
            return ub
        }
        if let url = bagData["authenticateAccount"] as? String, !url.isEmpty {
            return url
        }
        return "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
    }

    func value(forKey key: String) -> Any? {
        return bagData[key]
    }

    func loadBagIfNeeded(storeFront: String = "143441-1,32") async {
        let needsReload = !isLoaded ||
            bagData.isEmpty ||
            lastLoadTime == nil ||
            Date().timeIntervalSince(lastLoadTime!) > cacheDuration

        guard needsReload else { return }

        await loadBag(storeFront: storeFront)
    }

    private static let fallback: [String: Any] = [
        "bagVersion": "CFNetwork-1446.0.5",
        "bagType": "MapData",
        "buyProductURL": "https://buy.itunes.apple.com",
        "buyProductDSIDAuthURL": "https://buy.itunes.apple.com",
        "downloadProductURL": "https://p25-buy.itunes.apple.com",
        "downloadRedownloadProductURL": "https://p25-buy.itunes.apple.com",
        "incrementDownloadTaskURL": "https://p25-buy.itunes.apple.com",
        "downloadCompleteTaskURL": "https://p25-buy.itunes.apple.com",
        "purchaseAccountInfoURL": "https://buy.itunes.apple.com",
        "searchURL": "https://itunes.apple.com",
        "wishListAddURL": "https://se.itunes.apple.com",
        "wishListRemoveURL": "https://se.itunes.apple.com",
        "wishListDisplayURL": "https://se.itunes.apple.com",
        "pingURL": "https://play.itunes.apple.com",
        "hostnameMap": [:] as [String: Any],
        "storePrefix": "https://itunes.apple.com",
        "authenticateAccount": "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
    ]

    func loadBag(storeFront: String = "143441-1,32") async {
        let bagCandidates = [
            "https://init.itunes.apple.com/bag.xml?ignoring-cache=true",
            "https://play.itunes.apple.com/WebObjects/MZPlay.woa/wa/bag?ignoring-cache=true"
        ]
        var loaded = false
        for bagURL in bagCandidates {
            guard let url = URL(string: bagURL) else { continue }
            var request = URLRequest(url: url)
            request.setValue("application/x-apple-plist", forHTTPHeaderField: "Content-Type")
            request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6", forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            request.setValue("zh-cn, zh, en-us, en", forHTTPHeaderField: "Accept-Language")
            request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
            request.setValue(storeFront, forHTTPHeaderField: "X-Apple-Store-Front")
            request.httpShouldHandleCookies = true
            request.timeoutInterval = 10
            do {
                let (data, resp) = try await bagSession.data(for: request)
                if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
                    continue
                }
                if data.isEmpty { continue }
                if let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any] {
                    parseBagData(plist)
                    loaded = true
                    break
                }
            } catch {
                continue
            }
        }
        if !loaded {
            parseBagData(Self.fallback)
        }
    }

    private func parseBagData(_ plist: [String: Any]) {
        bagData.removeAll()
        urlBag.removeAll()

        if let ub = plist["urlBag"] as? [String: Any] {
            urlBag = ub
        }

        if let buyURL = plist["buyProductURL"] as? String {
            bagData["buyProductURL"] = buyURL
        } else if let buy = urlBag["buyProductURL"] as? String {
            bagData["buyProductURL"] = buy
        }
        if let downloadURL = plist["downloadProductURL"] as? String {
            bagData["downloadProductURL"] = downloadURL
        } else if let dl = urlBag["downloadProductURL"] as? String {
            bagData["downloadProductURL"] = dl
        } else if let musicURL = plist["musicStoreURL"] as? String {
            bagData["downloadProductURL"] = musicURL
        }
        if let searchURL = plist["searchURL"] as? String {
            bagData["searchURL"] = searchURL
        } else if let s = urlBag["searchURL"] as? String {
            bagData["searchURL"] = s
        }

        if let auth = plist["authenticateAccount"] as? String {
            bagData["authenticateAccount"] = auth
        } else if let auth = urlBag["authenticateAccount"] as? String {
            bagData["authenticateAccount"] = auth
        }

        for (key, value) in plist {
            if bagData[key] == nil {
                bagData[key] = value
            }
        }
        for (key, value) in urlBag {
            if bagData[key] == nil {
                bagData[key] = value
            }
        }

        lastLoadTime = Date()
        isLoaded = true
    }

    func reset() {
        bagData.removeAll()
        lastLoadTime = nil
        isLoaded = false
    }
}
