import Foundation

enum RemoteSAPConfig {
    static let urlKey = "sap_remote_sign_url"
    static let tokenKey = "sap_remote_sign_token"

    static let defaultEndpoint = "https://sap.domplings.com/sign"
    static let defaultToken = "5f131ec5e7360f483e1594c22d3489277984b1d64857129d9461c1d767be312e"

    static var endpoint: String {
        let s = UserDefaults.standard.string(forKey: urlKey) ?? ""
        return s.isEmpty ? defaultEndpoint : s
    }

    static var token: String {
        let s = UserDefaults.standard.string(forKey: tokenKey) ?? ""
        return s.isEmpty ? defaultToken : s
    }

    static var isActive: Bool { !token.isEmpty }
    static var host: String { URL(string: endpoint)?.host ?? endpoint }
}

final class RemoteSAPSigner: SAPActionSigner {
    private let endpoint: URL
    private let token: String
    private let guid: String

    init(endpoint: String = RemoteSAPConfig.endpoint,
         token: String = RemoteSAPConfig.token,
         guid: String) {
        self.endpoint = URL(string: endpoint) ?? URL(string: RemoteSAPConfig.defaultEndpoint)!
        self.token = token
        self.guid = guid
    }

    func sign(_ data: Data) throws -> Data {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "guid": guid,
            "bodyBase64": data.base64EncodedString()
        ])

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        URLSession.shared.dataTask(with: req) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                result = .failure(error)
                return
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data else {
                result = .failure(SAPSignerError.signFailed(
                    "签名服务 HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"))
                return
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let sig = obj?["signature"] as? String,
               let raw = Data(base64Encoded: sig), !raw.isEmpty {
                result = .success(raw)
            } else {
                let msg = (obj?["error"] as? String)
                    ?? String(data: data.prefix(200), encoding: .utf8)
                    ?? "空响应"
                result = .failure(SAPSignerError.signFailed("签名服务: \(msg)"))
            }
        }.resume()
        semaphore.wait()

        guard let result = result else {
            throw SAPSignerError.signFailed("签名服务无结果")
        }
        return try result.get()
    }

    func close() {}
}
