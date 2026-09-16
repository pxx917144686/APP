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
                    if isFree {
                    }
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
                return .failure(.passwordTokenExpired("iTunes 会话已失效且需要双重认证验证码，请重新登录该 Apple ID 完成验证后重试"))
            case .authenticationFailed, .userInteractionRequired, .paymentVerificationRequired, .lockedAccount, .invalidCredentials:
                if isFree {
                    return .success(false)
                }
                return .failure(.passwordTokenExpired(storeError.localizedDescription))
            case .appNotAvailableInStorefront:
                return .failure(.licenseCheckFailed("此应用在当前地区商店不可用"))
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
                    return .success(PurchaseResult(trackId: appIdentifier, success: true, message: "应用已通过现有许可证获取", licenseInfo: nil))
                }
                if case .failure(let pe) = purchaseRes {
                    switch pe {
                    case .passwordTokenExpired:
                        return purchaseRes
                    case .paymentRequired, .licenseCheckFailed, .networkError, .unknownError:
                        return .success(PurchaseResult(trackId: appIdentifier, success: true, message: "免费应用：跳过购买验证，下载时最终判定", licenseInfo: nil))
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
                    return .success(PurchaseResult(trackId: appIdentifier, success: true, message: "免费应用：跳过所有权检查，下载时最终判定", licenseInfo: nil))
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
                    message: "应用已拥有，无需购买",
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
                message: "已完成获取（零元购买）",
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
                            message: "自动刷新令牌后完成获取",
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
        if !account.passwordToken.isEmpty {
            return account
        }
        return nil
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
                        message: "已通过重新下载获取",
                        licenseInfo: nil
                    )
                    return .success(result)
                }
                return .failure(.licenseCheckFailed("无法获取应用许可证"))
            } catch {
                return .failure(.networkError(error))
            }
        case .codeRequired:
            return .failure(.passwordTokenExpired("iTunes 会话已失效且需要双重认证验证码，请重新登录该 Apple ID 完成验证后重试"))
        case .authenticationFailed, .invalidCredentials:
            let detail = "iTunes 会话已失效，请重新登录 Apple ID 刷新密码令牌 (\(error.localizedDescription))"
            return .failure(.passwordTokenExpired(detail))
        case .userInteractionRequired:
            return .failure(.paymentRequired("需要在 App Store 完成一次身份验证"))
        case .paymentVerificationRequired:
            return .failure(.paymentRequired("需要验证付款信息"))
        case .termsOfServiceUpdateRequired:
            return .failure(.licenseCheckFailed("需要同意新的服务条款"))
        case .ageVerificationRequired:
            return .failure(.licenseCheckFailed("需要进行年龄验证"))
        case .storefrontChangeRequired, .appNotAvailableInStorefront:
            return .failure(.invalidCountry("此应用在当前地区商店不可用"))
        case .tooManyRequests:
            return .failure(.networkError(error))
        case .lockedAccount:
            return .failure(.licenseCheckFailed("账户已被锁定"))
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
            return "无效的应用标识符: \(message)"
        case .appNotFound(let message):
            return "应用未找到: \(message)"
        case .priceMismatch(let message):
            return "价格不匹配: \(message)"
        case .invalidCountry(let message):
            return "无效的国家/地区: \(message)"
        case .passwordTokenExpired(let message):
            return "Apple ID 会话已过期，请退出当前账户并重新登录 (\(message))"
        case .licenseAlreadyExists(let message):
            return "许可证已存在: \(message)"
        case .paymentRequired(let message):
            return "需要付款: \(message)"
        case .licenseCheckFailed(let message):
            return "许可证检查失败: \(message)"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .unknownError(let message):
            return "未知错误: \(message)"
        }
    }
}
