import Foundation

@MainActor
class SearchManager: ObservableObject, @unchecked Sendable {
    static let shared = SearchManager()
    private var itunesClient: iTunesClient {
        return iTunesClient.shared
    }
    private init() {}

    func lookupApp(
        bundleIdentifier: String,
        countryCode: String = "",
        deviceFamily: DeviceFamily = .phone
    ) async -> Result<iTunesSearchResult, SearchError> {
        guard !bundleIdentifier.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .failure(.invalidBundleId)
        }
        do {
            let result = try await itunesClient.lookup(
                bundleIdentifier: bundleIdentifier,
                countryCode: countryCode,
                deviceFamily: deviceFamily
            )
            if let appInfo = result {
                return .success(appInfo)
            } else {
                return .failure(.appNotFound)
            }
        } catch {
            return .failure(.networkError(error))
        }
    }

    func getTrackId(
        bundleIdentifier: String? = nil,
        trackId: String? = nil,
        countryCode: String = "",
        deviceFamily: DeviceFamily = .phone
    ) async -> Result<Int, SearchError> {
        if let trackIdString = trackId {
            if let trackIdInt = Int(trackIdString) {
                return .success(trackIdInt)
            } else {
                return .failure(.invalidTrackId)
            }
        }
        if let bundleId = bundleIdentifier {
            let lookupResult = await lookupApp(
                bundleIdentifier: bundleId,
                countryCode: countryCode,
                deviceFamily: deviceFamily
            )
            switch lookupResult {
            case .success(let appInfo):
                return .success(appInfo.trackId)
            case .failure(let error):
                return .failure(error)
            }
        }
        return .failure(.missingIdentifier)
    }

    func suggest(term: String) async -> Result<[iTunesClient.SuggestTerm], SearchError> {
        do {
            let list = try await itunesClient.suggest(term: term)
            return .success(list)
        } catch let err as SearchError {
            return .failure(err)
        } catch {
            return .failure(.networkError(error))
        }
    }
}

extension iTunesSearchResult {
    var isFree: Bool {
        return (price ?? 0.0) == 0.0
    }
    var displayPrice: String {
        if isFree {
            return "price_free".localized
        } else {
            return formattedPrice ?? "\(price ?? 0.0)"
        }
    }
}
