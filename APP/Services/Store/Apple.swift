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

    public var kbsync: String?

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
        idmsToken: String = "",
        kbsync: String? = nil
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
        self.kbsync = kbsync
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
        case kbsync = "kbs"
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
        var seen: Set<String> = []
        var uniq: [[String: Any]] = []
        for d in allCandidateDicts {
            let h = d.map { String($0.key) + "=" + String(describing: $0.value) }.sorted().joined()
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
        "AE": "143481", "AG": "143540", "AI": "143538", "AL": "143575", "AM": "143524",
        "AO": "143564", "AR": "143505", "AT": "143445", "AU": "143460", "AZ": "143568",
        "BB": "143541", "BD": "143490", "BE": "143446", "BG": "143526", "BH": "143559",
        "BM": "143542", "BN": "143560", "BO": "143556", "BR": "143503", "BS": "143539",
        "BW": "143525", "BY": "143565", "BZ": "143555", "CA": "143455", "CH": "143459",
        "CI": "143527", "CL": "143483", "CN": "143465", "CO": "143501", "CR": "143495",
        "CY": "143557", "CZ": "143489", "DE": "143443", "DK": "143458", "DM": "143545",
        "DO": "143508", "DZ": "143563", "EC": "143509", "EE": "143518", "EG": "143516",
        "ES": "143454", "FI": "143447", "FR": "143442", "GB": "143444", "GD": "143546",
        "GE": "143615", "GH": "143573", "GR": "143448", "GT": "143504", "GY": "143553",
        "HK": "143463", "HN": "143510", "HR": "143494", "HU": "143482", "ID": "143476",
        "IE": "143449", "IL": "143491", "IN": "143467", "IS": "143558", "IT": "143450",
        "JM": "143511", "JO": "143528", "JP": "143462", "KE": "143529", "KN": "143548",
        "KR": "143466", "KW": "143493", "KY": "143544", "KZ": "143517", "LB": "143497",
        "LC": "143549", "LI": "143522", "LK": "143486", "LT": "143520", "LU": "143451",
        "LV": "143519", "MD": "143523", "MG": "143531", "MK": "143530", "ML": "143532",
        "MN": "143592", "MO": "143515", "MS": "143547", "MT": "143521", "MU": "143533",
        "MV": "143488", "MX": "143468", "MY": "143473", "NE": "143534", "NG": "143561",
        "NI": "143512", "NL": "143452", "NO": "143457", "NP": "143484", "NZ": "143461",
        "OM": "143562", "PA": "143485", "PE": "143507", "PH": "143474", "PK": "143477",
        "PL": "143478", "PT": "143453", "PY": "143513", "QA": "143498", "RO": "143487",
        "RS": "143500", "RU": "143469", "SA": "143479", "SE": "143456", "SG": "143464",
        "SI": "143499", "SK": "143496", "SN": "143535", "SR": "143554", "SV": "143506",
        "TC": "143552", "TH": "143475", "TN": "143536", "TR": "143480", "TT": "143551",
        "TW": "143470", "TZ": "143572", "UA": "143492", "UG": "143537", "US": "143441",
        "UY": "143514", "UZ": "143566", "VC": "143550", "VE": "143502", "VG": "143543",
        "VN": "143471", "YE": "143571", "ZA": "143472"
    ]

    static let storeFrontCountryMap: [String: String] = Dictionary(
        uniqueKeysWithValues: storeFrontCodeMap.map { ($0.value, $0.key) }
    )
}
