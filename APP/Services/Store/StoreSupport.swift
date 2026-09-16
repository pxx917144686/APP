import Foundation

func mergeRealCookies(dsid: String, lines: [String]) {
    guard !dsid.isEmpty, !lines.isEmpty else { return }
    let incomingNames = Set(lines.map { cookieName($0) })
    let kept = AuthCookieCache.shared.get(dsid: dsid).filter { !incomingNames.contains(cookieName($0)) }
    AuthCookieCache.shared.set(dsid: dsid, cookies: kept + lines)
    storeRealSessionCookies(lines)
    let key = "sap_real_cookies_v1_" + dsid
    let saved = UserDefaults.standard.stringArray(forKey: key) ?? []
    let keptSaved = saved.filter { !incomingNames.contains(cookieName($0)) }
    UserDefaults.standard.set(keptSaved + lines, forKey: key)
}

func cookieName(_ line: String) -> String {
    let first = line.split(separator: ";").first.map(String.init) ?? ""
    return String(first.split(separator: "=", maxSplits: 1).first ?? "")
}

func restorePersistedCookiesIfNeeded(dsid: String) {
    guard !dsid.isEmpty else { return }
    let saved = UserDefaults.standard.stringArray(forKey: "sap_real_cookies_v1_" + dsid) ?? []
    guard !saved.isEmpty else { return }
    let existing = AuthCookieCache.shared.get(dsid: dsid)
    let existingNames = Set(existing.map { cookieName($0) })
    let missing = saved.filter { !existingNames.contains(cookieName($0)) }
    guard !missing.isEmpty else { return }
    AuthCookieCache.shared.set(dsid: dsid, cookies: existing + missing)
    storeRealSessionCookies(missing)
}
