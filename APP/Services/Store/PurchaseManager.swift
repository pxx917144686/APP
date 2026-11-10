import Foundation

@MainActor
class PurchaseManager: @unchecked Sendable {
    static let shared = PurchaseManager()

    private let searchManager = SearchManager.shared
    private init() {}

    func checkAppOwnership(
        appIdentifier: String,
        account: Account,
        countryCode: String = "",
        isFree: Bool = false
    ) async -> Result<Bool, PurchaseError> {
        do {
            let trackId = try await resolveTrackId(appIdentifier: appIdentifier, countryCode: countryCode)

            do {
                let downloadResponse = try await StoreRequest.shared.download(
                    appIdentifier: trackId,
                    account: account
                )
                return .success(!downloadResponse.songList.isEmpty)
            } catch let storeError as StoreError {
                switch storeError {
                case .licenseExpired:
                    do {
                        let redownloadResponse = try await StoreRequest.shared.redownload(
                            appIdentifier: trackId,
                            account: account
                        )
                        return .success(!redownloadResponse.songList.isEmpty)
                    } catch {
                        return handleOwnershipError(error, isFree: isFree)
                    }
            case .notOwned, .invalidLicense:
                return handleOwnershipError(storeError, isFree: isFree)
                default:
                    return handleOwnershipError(storeError, isFree: isFree)
                }
            } catch {
                return handleOwnershipError(error, isFree: isFree)
            }
        } catch {
            return .failure(.appNotFound(error.localizedDescription))
        }
    }

    private func resolveTrackId(appIdentifier: String, countryCode: String) async throws -> String {
        if Int(appIdentifier) != nil {
            return appIdentifier
        }
        let trackIdResult = await searchManager.getTrackId(
            bundleIdentifier: appIdentifier,
            countryCode: countryCode,
            deviceFamily: .phone
        )
        switch trackIdResult {
        case .success(let id):
            return String(id)
        case .failure(let error):
            throw error
        }
    }

    private func handleOwnershipError(_ error: Error, isFree: Bool) -> Result<Bool, PurchaseError> {
        if let storeError = error as? StoreError {
            switch storeError {
            case .invalidLicense, .notOwned:
                if isFree {
                    return .success(false)
                }
                return .success(false)
            case .codeRequired:
                return .failure(.passwordTokenExpired("dl_err_itunes_session_2fa".localized))
            case .authenticationFailed, .userInteractionRequired, .paymentVerificationRequired, .lockedAccount, .invalidCredentials:
                if isFree {
                    return .success(false)
                }
                return .failure(.passwordTokenExpired(storeError.localizedDescription))
            case .appNotAvailableInStorefront:
                return .failure(.licenseCheckFailed("purchase_err_region_unavailable".localized))
            case .tooManyRequests:
                return .failure(.networkError(storeError))
            default:
                return .failure(.networkError(storeError))
            }
        }
        return .failure(.networkError(error))
    }

    func purchaseAppIfNeeded(
        appIdentifier: String,
        account: Account,
        countryCode: String = "",
        isFree: Bool = false,
        deviceFamily: DeviceFamily = .phone
    ) async -> Result<PurchaseResult, PurchaseError> {
        if isFree {
            let purchaseRes = await performPurchase(appIdentifier: appIdentifier, account: account)
            if case .success = purchaseRes {
                return purchaseRes
            }
            let ownershipFallback = await checkAppOwnership(
                appIdentifier: appIdentifier,
                account: account,
                countryCode: countryCode,
                isFree: true
            )
            switch ownershipFallback {
            case .success(let owned):
                if owned {
                    return .success(PurchaseResult(trackId: appIdentifier, success: true, message: "purchase_ok_existing_license".localized, licenseInfo: nil))
                }
                if case .failure(let pe) = purchaseRes {
                    switch pe {
                    case .passwordTokenExpired:
                        return purchaseRes
                    case .paymentRequired, .licenseCheckFailed, .networkError, .unknownError:
                        return .success(PurchaseResult(trackId: appIdentifier, success: true, message: "purchase_skip_free_purchase".localized, licenseInfo: nil))
                    default:
                        return purchaseRes
                    }
                }
                return purchaseRes
            case .failure(let pe):
                switch pe {
                case .passwordTokenExpired:
                    return .failure(pe)
                case .paymentRequired, .licenseCheckFailed, .networkError, .unknownError:
                    return .success(PurchaseResult(trackId: appIdentifier, success: true, message: "purchase_skip_free_ownership".localized, licenseInfo: nil))
                default:
                    if case .failure = purchaseRes {
                        return purchaseRes
                    }
                    return .failure(pe)
                }
            }
        }

        let ownershipResult = await checkAppOwnership(
            appIdentifier: appIdentifier,
            account: account,
            countryCode: countryCode,
            isFree: false
        )
        switch ownershipResult {
        case .success(let isOwned):
            if isOwned {
                let result = PurchaseResult(
                    trackId: appIdentifier,
                    success: true,
                    message: "purchase_ok_already_owned".localized,
                    licenseInfo: nil
                )
                return .success(result)
            } else {
                return await performPurchase(appIdentifier: appIdentifier, account: account)
            }
        case .failure(let error):
            return .failure(error)
        }
    }

    private func performPurchase(
        appIdentifier: String,
        account: Account
    ) async -> Result<PurchaseResult, PurchaseError> {
        do {
            let _ = try await StoreRequest.shared.purchase(
                appIdentifier: String(appIdentifier),
                account: account
            )
            let result = PurchaseResult(
                trackId: appIdentifier,
                success: true,
                message: "purchase_ok_zero_price".localized,
                licenseInfo: nil
            )
            return .success(result)
        } catch let storeError as StoreError {
            switch storeError {
            case .authenticationFailed, .invalidCredentials:
                if let refreshed = await attemptRefreshToken(account: account) {
                    do {
                        let _ = try await StoreRequest.shared.purchase(
                            appIdentifier: String(appIdentifier),
                            account: refreshed
                        )
                        NotificationCenter.default.post(name: .accountStoreTokensRefreshed, object: refreshed)
                        let result = PurchaseResult(
                            trackId: appIdentifier,
                            success: true,
                            message: "purchase_ok_token_refreshed".localized,
                            licenseInfo: nil
                        )
                        return .success(result)
                    } catch {
                        return await handlePurchaseError(
                            error as? StoreError ?? .unknownError,
                            appIdentifier: appIdentifier,
                            account: refreshed
                        )
                    }
                }
            default:
                break
            }
            return await handlePurchaseError(storeError, appIdentifier: appIdentifier, account: account)
        } catch {
            return .failure(.networkError(error))
        }
    }

    private func attemptRefreshToken(account: Account) async -> Account? {
        let refreshed = AuthenticationManager.shared.refreshCookies(for: account)
        let isValid = await AuthenticationManager.shared.validateAccount(refreshed)
        return isValid ? refreshed : nil
    }

    private func handlePurchaseError(
        _ error: StoreError,
        appIdentifier: String,
        account: Account
    ) async -> Result<PurchaseResult, PurchaseError> {
        switch error {
        case .licenseExpired, .invalidLicense:
            do {
                let redownloadResponse = try await StoreRequest.shared.redownload(
                    appIdentifier: appIdentifier,
                    account: account
                )
                if !redownloadResponse.songList.isEmpty {
                    let result = PurchaseResult(
                        trackId: appIdentifier,
                        success: true,
                        message: "purchase_ok_redownload".localized,
                        licenseInfo: nil
                    )
                    return .success(result)
                }
                return .failure(.licenseCheckFailed("purchase_err_no_license".localized))
            } catch {
                return .failure(.networkError(error))
            }
        case .codeRequired:
            return .failure(.passwordTokenExpired("dl_err_itunes_session_2fa".localized))
        case .authenticationFailed, .invalidCredentials:
            let detail = "purchase_err_itunes_session_expired".localized(error.localizedDescription)
            return .failure(.passwordTokenExpired(detail))
        case .userInteractionRequired:
            return .failure(.paymentRequired("purchase_err_identity_verification".localized))
        case .paymentVerificationRequired:
            return .failure(.paymentRequired("purchase_err_payment_verification".localized))
        case .termsOfServiceUpdateRequired:
            return .failure(.licenseCheckFailed("purchase_err_terms".localized))
        case .ageVerificationRequired:
            return .failure(.licenseCheckFailed("purchase_err_age_verification".localized))
        case .storefrontChangeRequired, .appNotAvailableInStorefront:
            return .failure(.invalidCountry("purchase_err_region_unavailable".localized))
        case .tooManyRequests:
            return .failure(.networkError(error))
        case .lockedAccount:
            return .failure(.licenseCheckFailed("purchase_err_account_locked".localized))
        default:
            return .failure(.unknownError(error.localizedDescription))
        }
    }

}

struct PurchaseResult {
    let trackId: String
    let success: Bool
    let message: String
    let licenseInfo: LicenseInfo?
}

struct LicenseInfo {
    let licenseId: String
    let purchaseDate: Date
    let expirationDate: Date?
    let isValid: Bool
}

enum PurchaseError: LocalizedError {
    case invalidIdentifier(String)
    case appNotFound(String)
    case priceMismatch(String)
    case invalidCountry(String)
    case passwordTokenExpired(String)
    case licenseAlreadyExists(String)
    case paymentRequired(String)
    case licenseCheckFailed(String)
    case networkError(Error)
    case unknownError(String)
    var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let message):
            return "purchase_err_invalid_app_id".localized(message)
        case .appNotFound(let message):
            return "dl_err_app_not_found".localized(message)
        case .priceMismatch(let message):
            return "purchase_err_price_mismatch".localized(message)
        case .invalidCountry(let message):
            return "purchase_err_invalid_country".localized(message)
        case .passwordTokenExpired(let message):
            return "purchase_err_session_expired".localized(message)
        case .licenseAlreadyExists(let message):
            return "purchase_err_license_exists".localized(message)
        case .paymentRequired(let message):
            return "purchase_err_payment_required".localized(message)
        case .licenseCheckFailed(let message):
            return "dl_err_license_check".localized(message)
        case .networkError(let error):
            return "dl_err_network".localized(error.localizedDescription)
        case .unknownError(let message):
            return "dl_err_unknown_detail".localized(message)
        }
    }
}
