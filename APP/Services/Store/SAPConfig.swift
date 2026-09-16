import Foundation

struct SAPConfig: Codable, Equatable, Sendable {
    let authEndpoint: String
    let setupURL: String
    let certificateURL: String
    let version: UInt32

    static let defaultAuthEndpoint = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
    static let defaultSetupURL = "https://fpinit.itunes.apple.com/v1/signSapSetup/legacy"
    static let defaultSetupCertURL = "https://s.mzstatic.com/sap/setupCert.plist"
    static let defaultVersion: UInt32 = 200

    static var `default`: SAPConfig {
        SAPConfig(
            authEndpoint: defaultAuthEndpoint,
            setupURL: defaultSetupURL,
            certificateURL: defaultSetupCertURL,
            version: defaultVersion
        )
    }

    func validate() throws {
        guard let authURL = URL(string: authEndpoint),
              authURL.scheme == "https",
              let host = authURL.host?.lowercased(),
              host == "buy.itunes.apple.com" || host.hasSuffix("-buy.itunes.apple.com"),
              authURL.path == "/WebObjects/MZFinance.woa/wa/authenticate" else {
            throw SAPSignerError.invalidConfig("invalid auth endpoint: \(authEndpoint)")
        }
        guard let s = URL(string: setupURL), s.scheme == "https", !s.host!.isEmpty else {
            throw SAPSignerError.invalidConfig("invalid setup URL: \(setupURL)")
        }
        guard let c = URL(string: certificateURL), c.scheme == "https", !c.host!.isEmpty else {
            throw SAPSignerError.invalidConfig("invalid certificate URL: \(certificateURL)")
        }
        guard version == 200 else {
            throw SAPSignerError.invalidConfig("unsupported SAP version: \(version)")
        }
    }
}

extension BagManager {

    var sapConfig: SAPConfig {
        let setupKey = "sign-sap-setup"
        let certKey = "sign-sap-setup-cert"
        let versionKey = "sign-sap-version"
        let setupURL = (urlBag[setupKey] as? String)
            ?? (bagData[setupKey] as? String)
            ?? SAPConfig.defaultSetupURL
        let certURL = (urlBag[certKey] as? String)
            ?? (bagData[certKey] as? String)
            ?? SAPConfig.defaultSetupCertURL
        let versionStr = (urlBag[versionKey] as? String)
            ?? (bagData[versionKey] as? String)
            ?? String(SAPConfig.defaultVersion)
        let version = UInt32(versionStr) ?? SAPConfig.defaultVersion
        let auth = authenticateAccountURL.isEmpty ? SAPConfig.defaultAuthEndpoint : authenticateAccountURL
        return SAPConfig(
            authEndpoint: auth,
            setupURL: setupURL,
            certificateURL: certURL,
            version: version
        )
    }

    func resolveAuthEndpoint(for accountEmail: String? = nil) async -> String {
        await loadBagIfNeeded()
        return sapConfig.authEndpoint
    }
}

enum SAPSignerError: LocalizedError, Equatable {
    case invalidConfig(String)
    case signerUnavailable
    case setupFailed(String)
    case signFailed(String)
    case certificateFetchFailed(String)
    case exchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfig(let s): return "SAP config 无效: \(s)"
        case .signerUnavailable: return "SAP signer 不可用"
        case .setupFailed(let s): return "SAP setup 失败: \(s)"
        case .signFailed(let s): return "SAP 签名失败: \(s)"
        case .certificateFetchFailed(let s): return "SAP cert 获取失败: \(s)"
        case .exchangeFailed(let s): return "SAP exchange 失败: \(s)"
        }
    }
}
