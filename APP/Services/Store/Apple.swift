import Foundation

public struct Account: Codable, Identifiable, Sendable {
    public var id: String { email }

    public let name: String
    public let email: String
    public let firstName: String
    public let lastName: String

    public let passwordToken: String
    public let directoryServicesIdentifier: String
    public let dsPersonId: String

    public let cookies: [String]
    public let countryCode: String

    public var pod: String

    public let storeResponse: AccountStoreResponse

    public var deviceGUID: String

    public let hsc: Int
    public let adsid: String
    public let idmsToken: String

    public init(
        name: String,
        email: String,
        firstName: String,
        lastName: String,
        passwordToken: String,
        directoryServicesIdentifier: String,
        dsPersonId: String,
        cookies: [String] = [],
        countryCode: String = "",
        pod: String = "",
        storeResponse: AccountStoreResponse,
        deviceGUID: String = "",
        hsc: Int = 0,
        adsid: String = "",
        idmsToken: String = ""
    ) {
        self.name = name
        self.email = email
        self.firstName = firstName
        self.lastName = lastName
        self.passwordToken = passwordToken
        self.directoryServicesIdentifier = directoryServicesIdentifier
        self.dsPersonId = dsPersonId
        self.cookies = cookies
        self.countryCode = countryCode
        self.pod = pod
        self.storeResponse = storeResponse
        if deviceGUID.isEmpty {
            self.deviceGUID = Account.generateDeviceGUID()
        } else {
            self.deviceGUID = deviceGUID
        }
        self.hsc = hsc
        self.adsid = adsid
        self.idmsToken = idmsToken
    }

    private static func generateDeviceGUID() -> String {
        let guid = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).uppercased()
        return String(guid)
    }


    public var fullName: String {
        let parts = [firstName, lastName].filter { !$0.isEmpty }
        if !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    public struct AccountStoreResponse: Codable, Sendable {
        public let directoryServicesIdentifier: String
        public let passwordToken: String
        public let storeFront: String
        public init(directoryServicesIdentifier: String, passwordToken: String, storeFront: String) {
            self.directoryServicesIdentifier = directoryServicesIdentifier
            self.passwordToken = passwordToken
            self.storeFront = storeFront
        }
    }
    enum CodingKeys: String, CodingKey {
        case name = "n"
        case email = "e"
        case firstName = "fn"
        case lastName = "ln"
        case passwordToken = "p"
        case directoryServicesIdentifier = "dsi"
        case dsPersonId = "d"
        case cookies = "c"
        case countryCode = "cc"
        case pod = "pod"
        case storeResponse = "sr"
        case deviceGUID = "guid"
        case hsc = "hsc"
        case adsid = "adsid"
        case idmsToken = "idms"
    }
}

public enum Apple: @unchecked Sendable {
    static func resolveName(roots: [[String: Any]?], tag _: String = "default") -> (firstName: String, lastName: String, fallbackFull: String) {
        let roots = roots.compactMap { $0 }.filter { !$0.isEmpty }
        let firstKeys: [String] = ["givenName", "firstName", "given", "nameGiven", "preferredName", "firstname", "first_name", "gn", "given_name", "ChristianName", "nameFirst"]
        let lastKeys:  [String] = ["familyName", "lastName", "family", "surname", "lastname", "last_name", "middleName", "ln", "fn", "family_name", "secondName", "nameFamily", "surName", "Surname"]
        let fullKeys:  [String] = ["localizedName", "fullName", "displayName", "formattedName", "name", "customerName", "personName", "fullname", "displayname", "full_name", "display_name", "accountName", "userName", "ownerName", "cardName", "appleName", "iForgotName", "credentialName"]
        let subdictKeys: [String] = ["address", "account", "person", "customer", "user", "profile", "data", "Status", "status", "statusBox", "info", "payload", "identity", "nameParts", "accountInfo", "paymentMethod", "billingAddress", "shippingAddress"]

        var allCandidateDicts: [[String: Any]] = []
        for root in roots {
            allCandidateDicts.append(root)
            for sk in subdictKeys {
                if let sub = root[sk] as? [String: Any], !sub.isEmpty {
                    allCandidateDicts.append(sub)
                    for sk2 in subdictKeys {
                        if let sub2 = sub[sk2] as? [String: Any], !sub2.isEmpty {
                            allCandidateDicts.append(sub2)
                        }
                    }
                }
            }
        }
        var seen: Set<Int> = []
        var uniq: [[String: Any]] = []
        for d in allCandidateDicts {
            let h = d.keys.sorted().hashValue ^ d.values.count.hashValue
            if !seen.contains(h) { seen.insert(h); uniq.append(d) }
        }

        func pick(_ d: [String: Any], _ keys: [String]) -> String {
            for k in keys {
                if let v = d[k] as? String, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return v.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return ""
        }
        for d in uniq {
            let f = pick(d, firstKeys)
            let l = pick(d, lastKeys)
            if !f.isEmpty || !l.isEmpty { return (f, l, "") }
        }
        for d in uniq {
            let full = pick(d, fullKeys)
            if !full.isEmpty && !looksLikeEmail(full) {
                let (f, l) = splitFullName(full)
                return (f, l, full)
            }
        }
        return ("", "", "")
    }

    private static func looksLikeEmail(_ s: String) -> Bool {
        s.contains("@") && s.contains(".")
    }

    private static func splitFullName(_ raw: String) -> (firstName: String, lastName: String) {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return ("", "") }
        let spaceCount = s.filter { $0 == " " }.count
        if spaceCount == 0 {
            return (s, "")
        }
        let parts = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if parts.count == 1 {
            return (parts[0], "")
        }
        let last = parts.last ?? ""
        let first = parts.dropLast().joined(separator: " ")
        return (first, last)
    }

    static let storeFrontCodeMap: [String: String] = [
        "US": "143441", "CN": "143465", "JP": "143462", "GB": "143444",
        "DE": "143443", "FR": "143442", "AU": "143460", "CA": "143455",
        "IT": "143450", "ES": "143454", "KR": "143466", "BR": "143503",
        "MX": "143468", "IN": "143467", "RU": "143469", "NL": "143452",
        "SE": "143456", "NO": "143457", "DK": "143458", "FI": "143447"
    ]
}
