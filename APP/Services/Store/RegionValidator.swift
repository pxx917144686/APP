import Foundation

@MainActor
class RegionValidator: ObservableObject {
    static let shared = RegionValidator()

    @Published var lastValidationResult: ValidationResult?
    @Published var validationHistory: [ValidationResult] = []

    private init() {}

    struct ValidationResult {
        let timestamp: Date
        let accountEmail: String
        let accountRegion: String
        let searchRegion: String
        let effectiveRegion: String
        let isValid: Bool
        let errorMessage: String?

        var description: String {
            if isValid {
                return "✅ 地区验证通过: \(accountRegion) -> \(effectiveRegion)"
            } else {
                return "❌ 地区验证失败: \(errorMessage ?? "未知错误")"
            }
        }
    }

    func validateRegionSettings(
        account: Account?,
        searchRegion: String,
        effectiveRegion: String
    ) -> ValidationResult {
        let timestamp = Date()
        let accountEmail = account?.email ?? "未登录"
        let accountRegion = account?.countryCode ?? "未知"

        var isValid = true
        var errorMessage: String?

        guard let account = account else {
            isValid = false
            errorMessage = "未登录账户"
            let result = ValidationResult(
                timestamp: timestamp,
                accountEmail: accountEmail,
                accountRegion: accountRegion,
                searchRegion: searchRegion,
                effectiveRegion: effectiveRegion,
                isValid: isValid,
                errorMessage: errorMessage
            )

            Task { @MainActor in
                lastValidationResult = result
                validationHistory.append(result)
            }
            return result
        }

        if account.countryCode.isEmpty {
            isValid = false
            errorMessage = "账户地区信息为空"
        }

        if effectiveRegion != account.countryCode {
            isValid = false
            errorMessage = "有效地区(\(effectiveRegion))与账户地区(\(account.countryCode))不匹配"
        }

        if account.storeResponse.storeFront.isEmpty {
            isValid = false
            errorMessage = "账户StoreFront信息为空"
        }

        let result = ValidationResult(
            timestamp: timestamp,
            accountEmail: accountEmail,
            accountRegion: accountRegion,
            searchRegion: searchRegion,
            effectiveRegion: effectiveRegion,
            isValid: isValid,
            errorMessage: errorMessage
        )

        Task { @MainActor in
            lastValidationResult = result
            validationHistory.append(result)

            if validationHistory.count > 50 {
                validationHistory.removeFirst()
            }
        }

        return result
    }

    func getRegionValidationAdvice(for result: ValidationResult) -> [String] {
        var advice: [String] = []

        if !result.isValid {
            if result.accountEmail == "未登录" {
                advice.append("请先登录Apple ID账户")
            } else if result.accountRegion == "未知" {
                advice.append("账户地区信息异常，请重新登录")
            } else if result.effectiveRegion != result.accountRegion {
                advice.append("建议将搜索地区设置为账户地区: \(result.accountRegion)")
            } else if result.errorMessage?.contains("StoreFront") == true {
                advice.append("账户StoreFront信息异常，请重新登录")
            }
        } else {
            advice.append("地区设置正确，可以正常下载")
        }

        return advice
    }

    func clearValidationHistory() {
        validationHistory.removeAll()
        lastValidationResult = nil
    }

}
