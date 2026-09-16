import Foundation
import CommonCrypto
import JavaScriptCore

struct BigUInt: Equatable, Comparable {
    private var limbs: [UInt64]

    init(_ value: Int = 0) {
        self.limbs = [UInt64(abs(value))]
        self.normalize()
    }

    init(_ value: UInt64) {
        self.limbs = [value]
        self.normalize()
    }

    init(_ data: Data) {

        var result: [UInt64] = []
        var current: UInt64 = 0
        var shift = 0

        for byte in data.reversed() {
            current |= UInt64(byte) << shift
            shift += 8
            if shift == 64 {
                result.append(current)
                current = 0
                shift = 0
            }
        }
        if shift > 0 {
            result.append(current)
        }
        self.limbs = result.isEmpty ? [0] : result
        self.normalize()
    }

    static func fromHex(_ hex: String) -> BigUInt {
        var cleanHex = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        cleanHex = cleanHex.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\\", with: "")

        if cleanHex.count % 2 != 0 {
            cleanHex = "0" + cleanHex
        }
        guard let data = Data(hexString: cleanHex) else {
            return BigUInt(0)
        }
        return BigUInt(data)
    }

    var isZero: Bool {
        return limbs.allSatisfy { $0 == 0 }
    }

    var bitCount: Int {
        guard !isZero else { return 0 }
        var count = (limbs.count - 1) * 64
        var top = limbs.last!
        while top != 0 {
            count += 1
            top >>= 1
        }
        return count
    }

    func serialize() -> Data {
        if isZero { return Data([0]) }
        var result = Data()
        for i in stride(from: limbs.count - 1, through: 0, by: -1) {
            var word = limbs[i]
            var bytes = [UInt8](repeating: 0, count: 8)
            for j in stride(from: 7, through: 0, by: -1) {
                bytes[j] = UInt8(word & 0xFF)
                word >>= 8
            }
            if result.isEmpty {
                var startIdx = 0
                while startIdx < 7 && bytes[startIdx] == 0 {
                    startIdx += 1
                }
                result.append(Data(bytes[startIdx...]))
            } else {
                result.append(Data(bytes))
            }
        }
        return result
    }

    func serialize(paddedTo byteCount: Int) -> Data {
        let raw = serialize()
        if raw.count < byteCount {
            return Data(repeating: 0, count: byteCount - raw.count) + raw
        }
        return raw
    }

    mutating func normalize() {
        while limbs.count > 1 && limbs.last == 0 {
            limbs.removeLast()
        }
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = lhs
        result.add(rhs)
        return result
    }

    mutating func add(_ other: BigUInt) {
        while limbs.count < other.limbs.count {
            limbs.append(0)
        }
        var carry = false
        for i in 0..<other.limbs.count {
            let (sum, overflow) = limbs[i].addingReportingOverflow(other.limbs[i])
            let (sum2, overflow2) = sum.addingReportingOverflow(carry ? 1 : 0)
            limbs[i] = sum2
            carry = overflow || overflow2
        }
        var idx = other.limbs.count
        while carry && idx < limbs.count {
            let (sum, overflow) = limbs[idx].addingReportingOverflow(1)
            limbs[idx] = sum
            carry = overflow
            idx += 1
        }
        if carry {
            limbs.append(1)
        }
        normalize()
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt(0) }

        let n = lhs.limbs.count
        let m = rhs.limbs.count
        var resultLimbs = [UInt64](repeating: 0, count: n + m)

        for i in 0..<n {
            var carry: UInt64 = 0
            for j in 0..<m {
                let product = UInt128(lhs.limbs[i]) * UInt128(rhs.limbs[j])
                let existing = UInt128(resultLimbs[i + j]) + UInt128(carry)
                let sum = product + existing
                resultLimbs[i + j] = sum.low
                carry = sum.high
            }
            resultLimbs[i + m] += carry
        }

        var result = BigUInt(0)
        result.limbs = resultLimbs
        result.normalize()
        return result
    }

    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs < rhs {

            return BigUInt(0)
        }
        var result = lhs
        var borrow = false
        for i in 0..<rhs.limbs.count {
            let (diff, overflow1) = result.limbs[i].subtractingReportingOverflow(rhs.limbs[i])
            let (diff2, overflow2) = diff.subtractingReportingOverflow(borrow ? 1 : 0)
            result.limbs[i] = diff2
            borrow = overflow1 || overflow2
        }
        var idx = rhs.limbs.count
        while borrow && idx < result.limbs.count {
            let (diff, overflow) = result.limbs[idx].subtractingReportingOverflow(1)
            result.limbs[idx] = diff
            borrow = overflow
            idx += 1
        }
        result.normalize()
        return result
    }

    static func % (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if rhs.isZero { return BigUInt(0) }
        if lhs < rhs { return lhs }
        let (_, remainder) = lhs.divmod(rhs)
        return remainder
    }

    func divmod(_ divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        if divisor.isZero { return (BigUInt(0), BigUInt(0)) }
        if self < divisor { return (BigUInt(0), self) }
        if self == divisor { return (BigUInt(1), BigUInt(0)) }

        var quotient = BigUInt(0)
        var remainder = BigUInt(0)

        let totalBits = bitCount
        for i in stride(from: totalBits - 1, through: 0, by: -1) {
            remainder = remainder << 1
            if self.bit(at: i) {
                remainder.limbs[0] |= 1
            }
            if remainder >= divisor {
                remainder = remainder - divisor
                quotient = quotient.setBit(at: i)
            }
        }
        quotient.normalize()
        remainder.normalize()
        return (quotient, remainder)
    }

    func modPow(_ exp: BigUInt, _ n: BigUInt) -> BigUInt {
        if n.isZero { return BigUInt(0) }
        if exp.isZero { return BigUInt(1) % n }
        if n == BigUInt(1) { return BigUInt(0) }

        var result = BigUInt(1)
        var base = self % n
        var exponent = exp

        while !exponent.isZero {
            if exponent.limbs[0] & 1 == 1 {
                result = (result * base) % n
            }
            exponent = exponent >> 1
            if !exponent.isZero {
                base = (base * base) % n
            }
        }
        return result
    }

    static func >> (lhs: BigUInt, _ rhs: Int) -> BigUInt {
        let wordShift = rhs / 64
        let bitShift = rhs % 64
        var result = lhs

        if wordShift >= result.limbs.count { return BigUInt(0) }
        if wordShift > 0 {
            result.limbs.removeSubrange(0..<wordShift)
        }
        if bitShift > 0 && !result.limbs.isEmpty {
            for i in 0..<result.limbs.count - 1 {
                result.limbs[i] = (result.limbs[i] >> bitShift) | (result.limbs[i + 1] << (64 - bitShift))
            }
            result.limbs[result.limbs.count - 1] >>= bitShift
        }
        result.normalize()
        return result
    }

    static func << (lhs: BigUInt, _ rhs: Int) -> BigUInt {
        let wordShift = rhs / 64
        let bitShift = rhs % 64
        var result = lhs

        if wordShift > 0 {
            result.limbs.insert(contentsOf: [UInt64](repeating: 0, count: wordShift), at: 0)
        }
        if bitShift > 0 && !result.limbs.isEmpty {
            result.limbs.append(0)
            for i in stride(from: result.limbs.count - 1, through: 1, by: -1) {
                result.limbs[i] = (result.limbs[i] << bitShift) | (result.limbs[i - 1] >> (64 - bitShift))
            }
            result.limbs[0] <<= bitShift
        }
        result.normalize()
        return result
    }

    func bit(at index: Int) -> Bool {
        let wordIndex = index / 64
        let bitIndex = index % 64
        guard wordIndex < limbs.count else { return false }
        return (limbs[wordIndex] >> bitIndex) & 1 == 1
    }

    func setBit(at index: Int) -> BigUInt {
        var result = self
        let wordIndex = index / 64
        let bitIndex = index % 64
        while result.limbs.count <= wordIndex {
            result.limbs.append(0)
        }
        result.limbs[wordIndex] |= (1 << bitIndex)
        return result
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        let lNorm = lhs.limbs
        let rNorm = rhs.limbs
        if lNorm.count != rNorm.count {
            return lNorm.count < rNorm.count
        }
        for i in stride(from: lNorm.count - 1, through: 0, by: -1) {
            if lNorm[i] != rNorm[i] {
                return lNorm[i] < rNorm[i]
            }
        }
        return false
    }
}

private struct UInt128 {
    let high: UInt64
    let low: UInt64

    init(_ value: UInt64) {
        self.high = 0
        self.low = value
    }

    init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    static func * (lhs: UInt128, rhs: UInt128) -> UInt128 {

        let aLo = lhs.low & 0xFFFFFFFF
        let aHi = lhs.low >> 32
        let bLo = rhs.low & 0xFFFFFFFF
        let bHi = rhs.low >> 32

        let p0: UInt64 = aLo &* bLo
        let p1: UInt64 = aLo &* bHi
        let p2: UInt64 = aHi &* bLo
        let p3: UInt64 = aHi &* bHi

        let mid1: UInt64 = p1 &<< 32
        let mid2: UInt64 = p2 &<< 32

        let (low1, c1) = p0.addingReportingOverflow(mid1)
        let (low2, c2) = low1.addingReportingOverflow(mid2)
        let low = low2

        var high: UInt64 = p3
        high &+= p1 &>> 32
        high &+= p2 &>> 32
        high &+= c1 ? 1 : 0
        high &+= c2 ? 1 : 0
        high &+= lhs.high &* rhs.low
        high &+= lhs.low &* rhs.high

        return UInt128(high: high, low: low)
    }

    static func + (lhs: UInt128, rhs: UInt128) -> UInt128 {
        let (low, overflow) = lhs.low.addingReportingOverflow(rhs.low)
        let high = lhs.high &+ rhs.high &+ (overflow ? 1 : 0)
        return UInt128(high: high, low: low)
    }
}

extension Data {
    init?(hexString: String) {
        let clean = hexString.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .lowercased()
        guard clean.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = clean.startIndex
        while index < clean.endIndex {
            let nextIndex = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(byte)
            index = nextIndex
        }
        self.init(bytes)
    }

    func base64Encoded() -> String {
        return self.base64EncodedString(options: [])
    }
}


class SRPClient {

    private var aDataBase: Data
    private var ADataBase: Data

    private static var sharedContext: JSContext?

    init() {

        let js = SRPClient.getJSContext()

        let aBytes = SRPClient.generateRandomBytes(256)
        let aB64 = aBytes.base64EncodedString()

        let result = js.evaluateScript("srpInit('\(aB64)')")

        guard let AB64 = result?.toString(), let AData = Data(base64Encoded: AB64) else {

            self.aDataBase = aBytes
            let aBig = BigUInt(aBytes).setBit(at: 2047)
            let ABig = BigUInt(2).modPow(aBig, SRPClient.N)
            self.ADataBase = ABig.serialize(paddedTo: 256)
            return
        }

        var aBig = BigUInt(aBytes)
        aBig = aBig.setBit(at: 2047)
        self.aDataBase = aBig.serialize(paddedTo: 256)
        self.ADataBase = AData
    }

    func getPublicKeyA() -> Data {
        return ADataBase
    }

    func processChallenge(
        username: String,
        passwordData: Data,
        salt: Data,
        serverB: Data,
        iterations: Int = 20000,
        protocol: String = "s2k"
    ) throws -> (m1: Data, m2: Data) {
        let password = String(data: passwordData, encoding: .utf8) ?? ""

        let uData = SRPClient.sha256(SRPClient.pad(ADataBase, to: 256) + SRPClient.pad(serverB, to: 256))
        let u = BigUInt(uData)

        let passwordHash = SRPClient.sha256(Data(password.utf8))
        let passwordDigest: Data
        if `protocol` == "s2k_fo" {
            let hexString = passwordHash.map { String(format: "%02x", $0) }.joined()
            passwordDigest = Data(hexString.utf8)
        } else {
            passwordDigest = passwordHash
        }
        let passwordBytes = SRPClient.pbkdf2(password: passwordDigest, salt: salt, iterations: iterations, keyLength: 32)

        let colonPassword = Data([0x3a]) + passwordBytes
        let innerHash = SRPClient.sha256(colonPassword)
        let xData = SRPClient.sha256(salt + innerHash)
        let x = BigUInt(xData)

        let NData = SRPClient.N.serialize(paddedTo: 256)
        let gData = BigUInt(2).serialize(paddedTo: 256)
        let kData = SRPClient.sha256(NData + gData)
        let k = BigUInt(kData)

        let js = SRPClient.getJSContext()

        let xB64 = xData.base64EncodedString()
        let vResult = js.evaluateScript("modPowB64('\(xB64)')")
        guard let vB64 = vResult?.toString(), let vData = Data(base64Encoded: vB64) else {
            throw SRPError.invalidChallenge
        }
        let v = BigUInt(vData)

        let baseVal = (BigUInt(serverB) + SRPClient.N - (k * v % SRPClient.N)) % SRPClient.N
        let exponent = BigUInt(aDataBase) + u * x

        let baseB64 = baseVal.serialize(paddedTo: 256).base64EncodedString()
        let expB64 = exponent.serialize().base64EncodedString()
        let sResult = js.evaluateScript("modPowB64('\(baseB64)', '\(expB64)')")
        guard let sB64 = sResult?.toString(), let sData = Data(base64Encoded: sB64) else {
            throw SRPError.invalidChallenge
        }

        let K = SRPClient.sha256(sData)

        let hN = SRPClient.sha256(NData)
        let hg = SRPClient.sha256(gData)
        let hNxorg = Data(zip(hN, hg).map { $0 ^ $1 })
        let hI = SRPClient.sha256(Data(username.utf8))

        let m1Data = SRPClient.sha256(hNxorg + hI + salt + ADataBase + serverB + K)

        let m2Data = SRPClient.sha256(ADataBase + m1Data + K)

        return (m1: m1Data, m2: m2Data)
    }

    static func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return Data(hash)
    }

    static func pbkdf2(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derivedKey = [UInt8](repeating: 0, count: keyLength)
        let _ = password.withUnsafeBytes { pwdPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwdPtr.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                    saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                    UInt32(iterations),
                    &derivedKey, keyLength
                )
            }
        }
        return Data(derivedKey)
    }

    static func pad(_ data: Data, to length: Int) -> Data {
        if data.count >= length { return data }
        return Data(repeating: 0, count: length - data.count) + data
    }

    private static func getJSContext() -> JSContext {
        if let ctx = sharedContext {
            return ctx
        }

        let ctx = JSContext()!

        ctx.evaluateScript(srpJavaScript)

        ctx.exceptionHandler = { context, exception in
        }

        sharedContext = ctx
        return ctx
    }

    private static let srpJavaScript = """
    const N = 0xAC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73n;
    const g = 2n;

    function b64ToBytes(b64) {
        const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        b64 = b64.replace(/=+$/, '');
        const bytes = new Uint8Array(Math.floor(b64.length * 3 / 4));
        let byteIdx = 0;
        for (let i = 0; i < b64.length; i += 4) {
            const a = chars.indexOf(b64[i]);
            const b = i + 1 < b64.length ? chars.indexOf(b64[i + 1]) : 0;
            const c = i + 2 < b64.length ? chars.indexOf(b64[i + 2]) : 0;
            const d = i + 3 < b64.length ? chars.indexOf(b64[i + 3]) : 0;
            const triple = (a << 18) | (b << 12) | (c << 6) | d;
            if (byteIdx < bytes.length) bytes[byteIdx++] = (triple >> 16) & 0xff;
            if (byteIdx < bytes.length) bytes[byteIdx++] = (triple >> 8) & 0xff;
            if (byteIdx < bytes.length) bytes[byteIdx++] = triple & 0xff;
        }
        return bytes;
    }

    function bytesToB64(bytes) {
        const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        let result = '';
        for (let i = 0; i < bytes.length; i += 3) {
            const a = bytes[i];
            const b = i + 1 < bytes.length ? bytes[i + 1] : 0;
            const c = i + 2 < bytes.length ? bytes[i + 2] : 0;
            const triple = (a << 16) | (b << 8) | c;
            result += chars[(triple >> 18) & 0x3f];
            result += chars[(triple >> 12) & 0x3f];
            result += i + 1 < bytes.length ? chars[(triple >> 6) & 0x3f] : '=';
            result += i + 2 < bytes.length ? chars[triple & 0x3f] : '=';
        }
        return result;
    }

    function bytesToLong(bytes) {
        let result = 0n;
        for (let i = 0; i < bytes.length; i++) {
            result = (result << 8n) | BigInt(bytes[i]);
        }
        return result;
    }

    function longToBytes(n) {
        if (n === 0n) return new Uint8Array([0]);
        let hex = n.toString(16);
        if (hex.length % 2) hex = '0' + hex;
        const bytes = new Uint8Array(hex.length / 2);
        for (let i = 0; i < hex.length; i += 2) {
            bytes[i / 2] = parseInt(hex.substr(i, 2), 16);
        }
        return bytes;
    }

    function modPow(base, exp, mod) {
        if (mod === 1n) return 0n;
        let result = 1n;
        base = base % mod;
        while (exp > 0n) {
            if (exp & 1n) {
                result = (result * base) % mod;
            }
            exp = exp >> 1n;
            base = (base * base) % mod;
        }
        return result;
    }

    function srpInit(aB64) {
        const aBytes = b64ToBytes(aB64);
        let a = bytesToLong(aBytes);
        a = a | (1n << 2047n);
        const A = modPow(g, a, N);
        const ABytes = longToBytes(A);
        if (ABytes.length < 256) {
            const padded = new Uint8Array(256);
            padded.set(ABytes, 256 - ABytes.length);
            return bytesToB64(padded);
        }
        return bytesToB64(ABytes);
    }

    function modPowB64(baseB64, expB64) {
        if (expB64) {
            const base = bytesToLong(b64ToBytes(baseB64));
            const exp = bytesToLong(b64ToBytes(expB64));
            const result = modPow(base, exp, N);
            const resultBytes = longToBytes(result);
            if (resultBytes.length < 256) {
                const padded = new Uint8Array(256);
                padded.set(resultBytes, 256 - resultBytes.length);
                return bytesToB64(padded);
            }
            return bytesToB64(resultBytes);
        } else {
            const x = bytesToLong(b64ToBytes(baseB64));
            const result = modPow(g, x, N);
            const resultBytes = longToBytes(result);
            if (resultBytes.length < 256) {
                const padded = new Uint8Array(256);
                padded.set(resultBytes, 256 - resultBytes.length);
                return bytesToB64(padded);
            }
            return bytesToB64(resultBytes);
        }
    }
    """

    static func generateRandomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func b64Encode(_ data: Data) -> String {
        return data.base64EncodedString(options: [])
    }

    static func b64Decode(_ string: String) -> Data? {
        return Data(base64Encoded: string)
    }

    static let N = BigUInt.fromHex(
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050" +
        "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50" +
        "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8" +
        "55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B" +
        "CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748" +
        "544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6" +
        "AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6" +
        "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73"
    )
}

struct AppleAuthEndpoint {
    static func idmsaEndpoint(isChinaMainland: Bool = false) -> String {
        return isChinaMainland ? "https://idmsa.apple.com.cn" : "https://idmsa.apple.com"
    }

    static func authEndpoint(isChinaMainland: Bool = false) -> String {
        return "\(idmsaEndpoint(isChinaMainland: isChinaMainland))/appleauth/auth"
    }


    static func setupEndpoint(isChinaMainland: Bool = false) -> String {
        return isChinaMainland ? "https://setup.icloud.com.cn/setup/ws/1" : "https://setup.icloud.com/setup/ws/1"
    }

    static let oAuthClientId = "d39ba9916b7251055b22c7f910e2ea796ee65e98b2ddecea8f5dde8d9d1a815d"

}


final class LegacySRPURLSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = LegacySRPURLSessionDelegate()

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let host = challenge.protectionSpace.host
        if host.hasSuffix(".apple.com") || host.hasSuffix(".itunes.apple.com") {
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {

        completionHandler(nil)
    }
}

final class LegacyIDMSAuthenticator: @unchecked Sendable {
    static let shared = LegacyIDMSAuthenticator()

    private var srpClient: SRPClient?

    private var sessionData: [String: String] = [:]

    private var cookies: [String: String] = [:]

    private var savedEmail: String = ""
    private var savedPassword: String = ""
    private var savedMFACode: String = ""
    
    private var attemptCount: Int = 0
    
    private static var lastFailureDate: Date? {
        get { UserDefaults.standard.object(forKey: "AppleID_LastFailureDate") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "AppleID_LastFailureDate") }
    }
    
    private static var consecutiveFailures: Int {
        get { UserDefaults.standard.integer(forKey: "AppleID_ConsecutiveFailures") }
        set { UserDefaults.standard.set(newValue, forKey: "AppleID_ConsecutiveFailures") }
    }
    
    private static var cooldownInterval: TimeInterval {
        let failures = consecutiveFailures
        if failures >= 10 { return 86400 }
        if failures >= 7 { return 21600 }
        if failures >= 5 { return 3600 }
        if failures >= 3 { return 900 }
        if failures >= 2 { return 300 }
        return 0
    }

    private let clientId: String
    private let urlSession: URLSession
    
    private static var deviceGUID: String {
        get {
            if let guid = UserDefaults.standard.string(forKey: "AppleID_DeviceGUID") {
                return guid
            }
            let guid = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).uppercased()
            let guidStr = String(guid)
            UserDefaults.standard.set(guidStr, forKey: "AppleID_DeviceGUID")
            return guidStr
        }
    }

    private init() {
        self.clientId = "auth-\(UUID().uuidString.lowercased())"

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60

        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        config.tlsMaximumSupportedProtocolVersion = .TLSv13

        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        self.urlSession = URLSession(configuration: config, delegate: LegacySRPURLSessionDelegate.shared, delegateQueue: delegateQueue)
    }

    private func randomDelay(minSeconds: TimeInterval, _ maxSeconds: TimeInterval) async {
        let delay = TimeInterval.random(in: minSeconds...maxSeconds)
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    private func parseSetCookieHeader(_ header: String) {

        var cookies_raw: [String] = []
        var current = ""
        for part in header.components(separatedBy: ", ") {
            if current.isEmpty {
                current = part
            } else if part.contains("=") && !part.hasPrefix(" ") {

                cookies_raw.append(current)
                current = part
            } else {
                current += ", " + part
            }
        }
        if !current.isEmpty {
            cookies_raw.append(current)
        }

        for cookieStr in cookies_raw {
            let parts = cookieStr.split(separator: ";", maxSplits: 1)
            if let first = parts.first {
                let keyValue = first.split(separator: "=", maxSplits: 1)
                if keyValue.count == 2 {
                    let name = String(keyValue[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(keyValue[1]).trimmingCharacters(in: .whitespaces)
                    cookies[name] = value
                }
            }
        }
    }

    private func getAuthHeaders(overrides: [String: String] = [:]) -> [String: String] {
        let clientId = AppleAuthEndpoint.oAuthClientId
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15"

        let timeZone = TimeZone.current.identifier
        let language = Locale.preferredLanguages.first ?? "en-US"

        let fdClientInfo = [
            "U": userAgent,
            "L": language,
            "Z": timeZone,
            "V": "1.1",
            "F": ""
        ] as [String: Any]
        let fdClientInfoJSON = (try? JSONSerialization.data(withJSONObject: fdClientInfo)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let guid = Self.deviceGUID

        var headers: [String: String] = [
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Accept-Language": language,
            "Accept-Encoding": "gzip, deflate, br",
            "Content-Type": "application/json",
            "User-Agent": userAgent,
            "X-Apple-GUID": guid,
            "X-Apple-OAuth-Client-Id": clientId,
            "X-Apple-OAuth-Client-Type": "firstPartyAuth",
            "X-Apple-OAuth-Redirect-URI": "https://www.icloud.com",
            "X-Apple-OAuth-Require-Grant-Code": "true",
            "X-Apple-OAuth-Response-Mode": "web_message",
            "X-Apple-OAuth-Response-Type": "code",
            "X-Apple-OAuth-State": self.clientId,
            "X-Apple-Widget-Key": clientId,
            "X-Apple-FD-Client-Info": fdClientInfoJSON,
            "X-Apple-Frame-Id": self.clientId,
            "X-Apple-Subject": "software",
            "X-Apple-P12-FullClientVersion": "0",
            "Origin": "https://idmsa.apple.com",
            "Referer": "https://idmsa.apple.com/",
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": "same-origin",
        ]

        if let scnt = sessionData["scnt"] {
            headers["scnt"] = scnt
        }
        if let sessionId = sessionData["session_id"] {
            headers["X-Apple-ID-Session-Id"] = sessionId
        }
        if let authAttributes = sessionData["auth_attributes"] {
            headers["X-Apple-Auth-Attributes"] = authAttributes
        }

        for (key, value) in overrides {
            headers[key] = value
        }
        return headers
    }

    private func parseServiceErrors(from data: Data) -> StoreError? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let serviceErrors = json["serviceErrors"] as? [[String: Any]],
              let firstError = serviceErrors.first,
              let codeString = firstError["code"] as? String,
              let code = Int(codeString) else {
            return nil
        }

        switch code {
        case -20209, -20210:
            return .lockedAccount
        case -20207, -20206, -20204, -20203, -20101, -20100:
            return .invalidCredentials
        case -20201, -20200:
            return .accountNotFound
        default:
            return nil
        }
    }

    private func request(url: URL, method: String = "POST", headers: [String: String], body: Any? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if !cookies.isEmpty {
            let cookieString = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            request.setValue(cookieString, forHTTPHeaderField: "Cookie")
        }

        if let body = body {
            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            } catch {
                throw error
            }
        }


        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StoreError.invalidResponse
        }

        if let allHeaders = httpResponse.allHeaderFields as? [String: String] {

            for (key, value) in allHeaders {
                if key.lowercased() == "set-cookie" {
                    parseSetCookieHeader(value)
                }
            }
        }

        let headerMapping: [String: String] = [
            "X-Apple-ID-Account-Country": "account_country",
            "X-Apple-ID-Session-Id": "session_id",
            "X-Apple-Auth-Attributes": "auth_attributes",
            "X-Apple-Session-Token": "session_token",
            "X-Apple-Repair-Session-Token": "repair_session_token",
            "X-Apple-TwoSV-Trust-Token": "trust_token",
            "X-Apple-TwoSV-Trust-Eligible": "trust_eligible",
            "X-Apple-OAuth-Grant-Code": "grant_code",
            "scnt": "scnt",
        ]
        for (header, key) in headerMapping {
            if let value = httpResponse.value(forHTTPHeaderField: header) {
                sessionData[key] = value
            }
        }

        return (data, httpResponse)
    }

    func authenticate(
        email: String,
        password: String,
        mfaCode: String? = nil,
        isChinaMainland: Bool = false
    ) async throws -> StoreAuthResponse {
        
        let cooldown = Self.cooldownInterval
        if cooldown > 0, let lastFail = Self.lastFailureDate {
            let elapsed = Date().timeIntervalSince(lastFail)
            if elapsed < cooldown {
                throw StoreError.lockedAccount
            }
        }
        
        attemptCount = 0

        savedEmail = email
        savedPassword = password
        if let mfaCode = mfaCode { savedMFACode = mfaCode }

        let authEndpoint = AppleAuthEndpoint.authEndpoint(isChinaMainland: isChinaMainland)
        let idmsaEndpoint = AppleAuthEndpoint.idmsaEndpoint(isChinaMainland: isChinaMainland)

        let authorizeParams = [
            "frame_id": self.clientId,
            "skVersion": "7",
            "iframeid": self.clientId,
            "client_id": AppleAuthEndpoint.oAuthClientId,
            "response_type": "code",
            "redirect_uri": "https://www.icloud.com",
            "response_mode": "web_message",
            "state": self.clientId,
            "authVersion": "latest",
        ]
        let authorizeQuery = authorizeParams.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }.joined(separator: "&")
        let authorizeUrl = URL(string: "\(idmsaEndpoint)/appleauth/auth/authorize/signin?\(authorizeQuery)")!

        do {
            _ = try await request(url: authorizeUrl, method: "GET", headers: getAuthHeaders())
        } catch {
        }

        await randomDelay(minSeconds: 0.5, 1.5)


        srpClient = SRPClient()
        guard let client = srpClient else {
            throw StoreError.authenticationFailed
        }

        let aData = client.getPublicKeyA()
        let aBase64 = SRPClient.b64Encode(aData)

        let initData: [String: Any] = [
            "a": aBase64,
            "accountName": email,
            "protocols": ["s2k", "s2k_fo"]
        ]

        let initUrl = URL(string: "\(authEndpoint)/signin/init")!
        let headers = getAuthHeaders()

        let (initResponseData, initHttpResponse): (Data, HTTPURLResponse)
        do {
            (initResponseData, initHttpResponse) = try await request(url: initUrl, headers: headers, body: initData)
        } catch {
            throw StoreError.authenticationFailed
        }

        guard initHttpResponse.statusCode == 200 else {
            if let parsedError = parseServiceErrors(from: initResponseData) {
                throw parsedError
            }
            throw StoreError.authenticationFailed
        }

        guard let initJson = try JSONSerialization.jsonObject(with: initResponseData) as? [String: Any] else {
            throw StoreError.invalidResponse
        }

        guard let saltBase64 = initJson["salt"] as? String,
              let bBase64 = initJson["b"] as? String,
              let c = initJson["c"],
              let iteration = initJson["iteration"] as? Int,
              let protocolStr = initJson["protocol"] as? String else {
            throw StoreError.invalidResponse
        }


        guard let saltData = SRPClient.b64Decode(saltBase64),
              let bData = SRPClient.b64Decode(bBase64) else {
            throw StoreError.authenticationFailed
        }


        let (m1, m2): (Data, Data)
        do {

            (m1, m2) = try client.processChallenge(
                username: email,
                passwordData: Data(password.utf8),
                salt: saltData,
                serverB: bData,
                iterations: iteration,
                protocol: protocolStr
            )
        } catch {
            throw StoreError.authenticationFailed
        }

        await randomDelay(minSeconds: 0.8, 2.0)

        var completeData: [String: Any] = [
            "accountName": email,
            "c": c,
            "m1": SRPClient.b64Encode(m1),
            "m2": SRPClient.b64Encode(m2),
            "rememberMe": true,
            "trustTokens": []
        ]

        if let trustToken = sessionData["trust_token"] {
            completeData["trustTokens"] = [trustToken]
        }

        let completeUrl = URL(string: "\(authEndpoint)/signin/complete?isRememberMeEnabled=true")!
        let completeHeaders = getAuthHeaders()

        let (completeResponseData, completeHttpResponse): (Data, HTTPURLResponse)
        do {
            (completeResponseData, completeHttpResponse) = try await request(url: completeUrl, headers: completeHeaders, body: completeData)
        } catch {
            throw StoreError.authenticationFailed
        }

        let isSuccessStatus = (completeHttpResponse.statusCode == 200 || completeHttpResponse.statusCode == 204)

        let authTypeSa: Bool = {
            if completeHttpResponse.statusCode == 412,
               let json = try? JSONSerialization.jsonObject(with: completeResponseData) as? [String: Any],
               let authType = json["authType"] as? String,
               authType.lowercased() == "sa" {
                return true
            }
            return false
        }()

        if authTypeSa {
            
            if sessionData["session_token"] == nil {
                do {
                    let trustUrl = URL(string: "\(authEndpoint)/2sv/trust")!
                    _ = try await request(url: trustUrl, method: "GET", headers: getAuthHeaders())
                    if sessionData["session_token"] != nil {
                    } else {
                        if let repairToken = sessionData["repair_session_token"] {
                            sessionData["session_token"] = repairToken
                        }
                    }
                } catch {
                    if let repairToken = sessionData["repair_session_token"] {
                        sessionData["session_token"] = repairToken
                    }
                }
            }
        }

        if completeHttpResponse.statusCode == 409 {

            _ = await trigger2FAPush(isChinaMainland: isChinaMainland)
            throw StoreError.codeRequired
        }

        if completeHttpResponse.statusCode == 421 || completeHttpResponse.statusCode == 450 {
            let (retryData, retryResponse) = try await request(url: completeUrl, headers: getAuthHeaders(), body: completeData)
            if retryResponse.statusCode == 409 {
                throw StoreError.codeRequired
            }
            if retryResponse.statusCode != 200 && retryResponse.statusCode != 204 {
                if let parsedError = parseServiceErrors(from: retryData) {
                    throw parsedError
                }
                throw StoreError.authenticationFailed
            }
        }

        if !isSuccessStatus && !authTypeSa {
            if let parsedError = parseServiceErrors(from: completeResponseData) {
                throw parsedError
            }
            throw StoreError.authenticationFailed
        }

        await randomDelay(minSeconds: 0.5, 1.2)
        do {
            let storeAuthResponse = try await authenticateWithToken(isChinaMainland: isChinaMainland)
            Self.consecutiveFailures = 0
            Self.lastFailureDate = nil
            return storeAuthResponse
        } catch let error as StoreError {
            switch error {
            case .lockedAccount:
                Self.consecutiveFailures = 10
                Self.lastFailureDate = Date()
            case .invalidCredentials, .invalidVerificationCode, .accountNotFound:
                Self.consecutiveFailures += 1
                Self.lastFailureDate = Date()
            default:
                break
            }
            throw error
        } catch {
            Self.consecutiveFailures += 1
            Self.lastFailureDate = Date()
            throw error
        }
    }

    func trigger2FAPush(isChinaMainland: Bool = false) async -> Bool {
        let authEndpoint = AppleAuthEndpoint.authEndpoint(isChinaMainland: isChinaMainland)
        let headers = getAuthHeaders()

        let url = URL(string: "\(authEndpoint)/verify/trusteddevice")!
        do {
            let (_, httpResponse) = try await request(url: url, method: "GET", headers: headers)
            let success = (200...299).contains(httpResponse.statusCode)
            if success {
            } else {
            }
            return success
        } catch {
            return false
        }
    }

    func validate2FACode(_ code: String, isChinaMainland: Bool = false) async throws -> StoreAuthResponse {

        savedMFACode = code

        let authEndpoint = AppleAuthEndpoint.authEndpoint(isChinaMainland: isChinaMainland)
        let headers = getAuthHeaders(overrides: ["Accept": "application/json"])

        let data: [String: Any] = ["securityCode": ["code": code]]
        let url = URL(string: "\(authEndpoint)/verify/trusteddevice/securitycode")!

        do {
            let (responseData, httpResponse) = try await request(url: url, headers: headers, body: data)

            let successStatus = (httpResponse.statusCode == 204 || httpResponse.statusCode == 200)
            
            let isValidCode: Bool = {
                if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                   let securityCode = json["securityCode"] as? [String: Any],
                   let valid = securityCode["valid"] as? Bool {
                    return valid
                }
                return false
            }()
            
            if successStatus || (httpResponse.statusCode == 409 && isValidCode) {
            } else {
                if let parsedError = parseServiceErrors(from: responseData) {
                    throw parsedError
                }
                if httpResponse.statusCode == 409 {
                    throw StoreError.invalidVerificationCode
                }
                throw StoreError.invalidResponse
            }
        } catch let error as StoreError {
            switch error {
            case .codeRequired:
                break
            default:
                Self.consecutiveFailures += 1
                Self.lastFailureDate = Date()
            }
            throw error
        } catch {
            Self.consecutiveFailures += 1
            Self.lastFailureDate = Date()
            throw StoreError.invalidCredentials
        }

        return try await trustSession(isChinaMainland: isChinaMainland)
    }

    private func trustSession(isChinaMainland: Bool = false) async throws -> StoreAuthResponse {
        let authEndpoint = AppleAuthEndpoint.authEndpoint(isChinaMainland: isChinaMainland)
        let headers = getAuthHeaders()

        let url = URL(string: "\(authEndpoint)/2sv/trust")!
        _ = try await request(url: url, method: "GET", headers: headers)

        return try await authenticateWithToken(isChinaMainland: isChinaMainland)
    }

    private func authenticateWithToken(isChinaMainland: Bool = false) async throws -> StoreAuthResponse {
        guard let sessionToken = sessionData["session_token"] else {
            throw StoreError.authenticationFailed
        }

        let setupEndpoint = AppleAuthEndpoint.setupEndpoint(isChinaMainland: isChinaMainland)
        let loginUrl = URL(string: "\(setupEndpoint)/accountLogin")!

        let loginData: [String: Any] = [
            "accountCountryCode": sessionData["account_country"] ?? "",
            "dsWebAuthToken": sessionToken,
            "extended_login": true,
            "trustToken": sessionData["trust_token"] ?? "",
        ]

        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.3.1 Safari/605.1.15"
        let headers: [String: String] = [
            "User-Agent": userAgent,
            "Accept": "application/json",
            "Content-Type": "application/json",
            "Origin": "https://www.icloud.com",
        ]
        var (data, httpResponse) = try await request(url: loginUrl, headers: headers, body: loginData)

        let shouldRetryWithChinaMainland: Bool = {
            if httpResponse.statusCode == 302 || httpResponse.statusCode == 301 {
                if let redirectJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let domainToUse = redirectJson["domainToUse"] as? String {
                    let needsChinaMainland = domainToUse.lowercased().contains("icloud.com.cn")
                    return needsChinaMainland != isChinaMainland && needsChinaMainland
                }
            }
            return false
        }()

        if shouldRetryWithChinaMainland {
            let newEndpoint = AppleAuthEndpoint.setupEndpoint(isChinaMainland: true)
            let newUrl = URL(string: "\(newEndpoint)/accountLogin")!
            var newHeaders = headers
            newHeaders["Origin"] = "https://www.icloud.com.cn"
            (data, httpResponse) = try await request(url: newUrl, headers: newHeaders, body: loginData)
        }

        guard httpResponse.statusCode == 200 else {
            throw StoreError.authenticationFailed
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StoreError.invalidResponse
        }


        let dsInfo = json["dsInfo"] as? [String: Any] ?? [:]
        let hsaVersion = dsInfo["hsaVersion"] as? Int ?? 0
        let hsaChallengeRequired = json["hsaChallengeRequired"] as? Bool ?? false
        let hsaTrustedBrowser = json["hsaTrustedBrowser"] as? Bool ?? false

        if hsaVersion == 2 && (hsaChallengeRequired || !hsaTrustedBrowser) {
            throw StoreError.codeRequired
        }

        let dsPersonId: String
        if let dsidInt = dsInfo["dsid"] as? Int {
            dsPersonId = String(dsidInt)
        } else if let dsidStr = dsInfo["dsid"] as? String {
            dsPersonId = dsidStr
        } else {
            dsPersonId = ""
        }

        let actualIsChinaMainland = (httpResponse.url?.host?.contains("icloud.com.cn") ?? false) || isChinaMainland

        let storeResponse = try await getStoreCredentials(
            dsPersonId: dsPersonId,
            isChinaMainland: actualIsChinaMainland
        )

        return storeResponse
    }

    private func getStoreCredentials(dsPersonId: String, isChinaMainland: Bool = false) async throws -> StoreAuthResponse {

        let guid = Self.deviceGUID
        StoreRequest.setGUID(guid)

        let passwordWithMFA = savedPassword + savedMFACode.replacingOccurrences(of: " ", with: "")

        let urlString = "https://auth.itunes.apple.com/auth/v1/native/fast/?guid=\(guid)"
        let storeUrl = URL(string: urlString)!

        let language = Locale.preferredLanguages.first ?? "en-US"

        var request = URLRequest(url: storeUrl)
        request.httpMethod = "POST"

        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        request.setValue("Configurator/2.17 (Macintosh; OS X 15.2; 24C5089c) AppleWebKit/0620.1.16.11.6", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        
        request.setValue(guid, forHTTPHeaderField: "X-Apple-GUID")
        request.setValue("0", forHTTPHeaderField: "X-Apple-P12-FullClientVersion")
        request.setValue("software", forHTTPHeaderField: "X-Apple-Subject")
        request.setValue("4.0.0", forHTTPHeaderField: "iCloud-Control")

        var formComponents: [String] = []
        attemptCount += 1
        let formParams: [(String, String)] = [
            ("appleId", savedEmail),
            ("attempt", "\(attemptCount)"),
            ("guid", guid),
            ("password", passwordWithMFA),
            ("rmp", "0"),
            ("why", "signIn")
        ]
        for (key, value) in formParams {
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            formComponents.append("\(encodedKey)=\(encodedValue)")
        }
        let formBody = formComponents.joined(separator: "&")
        request.httpBody = formBody.data(using: .utf8)


        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil

        let storeSession = URLSession(configuration: config, delegate: LegacySRPURLSessionDelegate.shared, delegateQueue: nil)

        var (data, response) = try await storeSession.data(for: request)
        var redirectHops = 0
        while let httpResp = response as? HTTPURLResponse,
              (300..<400).contains(httpResp.statusCode),
              let loc = httpResp.value(forHTTPHeaderField: "Location"),
              let base = request.url,
              var next = URLComponents(url: URL(string: loc, relativeTo: base)!, resolvingAgainstBaseURL: false), redirectHops < 3 {
            if (next.queryItems ?? []).isEmpty {
                next.queryItems = [URLQueryItem(name: "guid", value: guid)]
            }
            redirectHops += 1
            var req2 = request
            req2.url = next.url
            (data, response) = try await storeSession.data(for: req2)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StoreError.invalidResponse
        }


        let storefrontHeader = httpResponse.value(forHTTPHeaderField: "X-Set-Apple-Store-Front") ?? ""

        return try parseStoreResponse(data: data, httpResponse: httpResponse, dsPersonId: dsPersonId, headerStoreFront: storefrontHeader)
    }

    private func parseStoreResponse(data: Data, httpResponse: HTTPURLResponse, dsPersonId: String, headerStoreFront: String = "") throws -> StoreAuthResponse {

        var plist: [String: Any] = [:]
        if let parsed = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
            plist = parsed
        } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            plist = json
        } else {
            throw StoreError.invalidResponse
        }


        if let customerMessage = plist["customerMessage"] as? String {

            let codeRequiredMessages = [
                "verification code is required",
                "An Apple ID verification code is required",
                "Type your password followed by the verification code",
                "两步验证", "双重认证", "验证码", "verification code"
            ]
            for msg in codeRequiredMessages {
                if customerMessage.contains(msg) {
                    throw StoreError.codeRequired
                }
            }
        }
        if let failureType = plist["failureType"] as? String {
            if failureType == "-1" {
                throw StoreError.codeRequired
            }
        }

        let passwordToken = plist["passwordToken"] as? String ?? ""
        let accountInfo = plist["accountInfo"] as? [String: Any] ?? [:]
        let address = accountInfo["address"] as? [String: Any] ?? [:]
        let firstName = address["firstName"] as? String ?? ""
        let lastName = address["lastName"] as? String ?? ""
        let appleId = accountInfo["appleId"] as? String ?? savedEmail
        let storeDsPersonId = (plist["dsPersonId"] as? String) ?? (plist["dsPersonID"] as? String) ?? dsPersonId
        let countryCode = accountInfo["countryCode"] as? String ?? ""

        let storeFront = !headerStoreFront.isEmpty ? headerStoreFront : (accountInfo["storeFront"] as? String ?? "143441-1,29")


        return StoreAuthResponse(
            accountInfo: StoreAuthResponse.AccountInfo(
                appleId: appleId,
                address: StoreAuthResponse.AccountInfo.Address(firstName: firstName, lastName: lastName),
                dsPersonId: storeDsPersonId,
                countryCode: countryCode,
                storeFront: storeFront
            ),
            passwordToken: passwordToken,
            dsPersonId: storeDsPersonId,
            pings: (plist["pings"] as? [Any])?.compactMap { $0 as? String } ?? nil
        )
    }

    func resetSession() {
        sessionData = [:]
        cookies = [:]
        srpClient = nil
        savedEmail = ""
        savedPassword = ""
        savedMFACode = ""
        attemptCount = 0
    }
}

enum SRPError: Error, LocalizedError {
    case invalidChallenge
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidChallenge:
            return "Invalid SRP challenge"
        case .authenticationFailed:
            return "SRP authentication failed"
        }
    }
}
