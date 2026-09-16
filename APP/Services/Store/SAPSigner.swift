import Foundation

protocol SAPActionSigner: AnyObject, Sendable {
    func sign(_ data: Data) throws -> Data
    func close()
}

typealias SAPSignerFactory = @Sendable (SAPConfig, Data) async throws -> SAPActionSigner

final class DefaultSAPSignerFactory {
    static let shared = DefaultSAPSignerFactory()
    private init() {}

    func makeSigner(config: SAPConfig, machineID: Data) async throws -> SAPActionSigner {
        try config.validate()
        #if os(macOS) || targetEnvironment(macCatalyst)
        if let cli = try? SubprocessSAPSigner(config: config, machineID: machineID) {
            return cli
        }
        #endif
        if let c = CAPISAPSigner(config: config, machineID: machineID) {
            return c
        }
        let detail = CAPISAPSigner.lastInitDetail ?? "原因未知"
        throw SAPSignerError.setupFailed("C API init: \(detail)")
    }
}

typealias sap_signer_create_t = @convention(c) (
    UnsafePointer<Int8>?,
    UnsafePointer<Int8>?,
    UInt32,
    UnsafePointer<UInt8>?,
    CInt,
    UnsafeMutablePointer<CInt>?
) -> UnsafeMutableRawPointer?

typealias sap_signer_sign_t = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<UInt8>?,
    CInt,
    UnsafeMutablePointer<CInt>?,
    UnsafeMutablePointer<CInt>?
) -> UnsafeMutablePointer<UInt8>?

typealias sap_signer_free_sig_t = @convention(c) (UnsafeMutablePointer<UInt8>?, Int) -> Void
typealias sap_signer_destroy_t = @convention(c) (UnsafeMutableRawPointer?) -> Void

enum SAPSymbols {
    static let createName = "sap_signer_create"
    static let signName = "sap_signer_sign"
    static let freeSigName = "sap_signer_free_sig"
    static let destroyName = "sap_signer_destroy"
}

enum SAPAssetInstaller {
    static let files: [(name: String, size: Int)] = [
        ("CommerceKit", 3271840),
        ("CommerceCore", 207744),
        ("CoreFP", 29014912),
        ("CoreFP.icxs", 5288352),
    ]

    static func installIfNeeded(frameworkExecutablePath: String) -> String? {
        let fm = FileManager.default
        let fwDir = (frameworkExecutablePath as NSString).deletingLastPathComponent
        let resourcesDir = fwDir + "/SAPAssets"
        guard let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return "无法定位 Caches 目录"
        }
        let dstDir = caches.appendingPathComponent("ipatool/sap/apple-assets-v2").path

        for (name, size) in files {
            let src = resourcesDir + "/" + name
            guard fm.fileExists(atPath: src) else {
                return "缺少资源 \(name)（于 \(resourcesDir)）"
            }
            let dst = dstDir + "/" + name
            if let attrs = try? fm.attributesOfItem(atPath: dst),
               let sz = attrs[.size] as? Int, sz == size {
                continue
            }
            do {
                try fm.createDirectory(atPath: dstDir, withIntermediateDirectories: true)
                if fm.fileExists(atPath: dst) {
                    try fm.removeItem(atPath: dst)
                }
                try fm.copyItem(atPath: src, toPath: dst)
            } catch {
                return "复制 \(name) 到 \(dst) 失败: \(error.localizedDescription)"
            }
        }
        return nil
    }
}

enum SAPGoLogin {
    struct Result: Codable {
        let passwordToken: String?
        let dsPersonId: String?
        let pod: String?
        let storeFront: String?
        let cookies: [String]?
        let error: String?
    }

    static func login(email: String, password: String, guid: String, authCode: String = "", pod: String = "") -> Result? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Frameworks/SAPSigner.framework/SAPSigner").path
        guard let lib = dlopen(path, RTLD_NOW) else { return nil }
        defer { dlclose(lib) }
        guard let p = dlsym(lib, "sap_login") else { return nil }
        let fn = unsafeBitCast(p, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>).self)

        _ = SAPAssetInstaller.installIfNeeded(frameworkExecutablePath: path)
        if let setEnvP = dlsym(lib, "sap_set_env") {
            let setEnvFn = unsafeBitCast(setEnvP, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void).self)
            let unicornLib = (path as NSString).deletingLastPathComponent + "/SAPAssets/libunicorn.2.dylib"
            if FileManager.default.fileExists(atPath: unicornLib) {
                "IPATOOL_UNICORN_LIB".withCString { key in
                    unicornLib.withCString { value in setEnvFn(key, value) }
                }
            }
        }

        let json: String? = email.withCString { e in
            password.withCString { p in
                guid.withCString { g in
                    authCode.withCString { c in
                        pod.withCString { pd in
                            let cstr = fn(e, p, g, c, pd)
                            defer {
                                if let freeP = dlsym(lib, "sap_free_string") {
                                    let freeFn = unsafeBitCast(freeP, to: (@convention(c) (UnsafeMutablePointer<CChar>) -> Void).self)
                                    freeFn(cstr)
                                }
                            }
                            return String(cString: cstr)
                        }
                    }
                }
            }
        }
        guard let json else { return nil }
        return try? JSONDecoder().decode(Result.self, from: Data(json.utf8))
    }
}

final class CAPISAPSigner: SAPActionSigner, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private let handle: UnsafeMutableRawPointer
    private let fnSign: sap_signer_sign_t
    private let fnFreeSig: sap_signer_free_sig_t
    private let fnDestroy: sap_signer_destroy_t

    static var lastInitDetail: String?

    convenience init?(config: SAPConfig, machineID: Data) {
        let fwPaths: [String?] = [
            Bundle.main.bundleURL.appendingPathComponent("Frameworks/SAPSigner.framework/SAPSigner").path,
            Bundle.main.privateFrameworksURL?.appendingPathComponent("SAPSigner.framework/SAPSigner").path,
            Bundle.main.bundleURL.appendingPathComponent("Frameworks/libsapsigner.dylib").path,
            "/usr/local/lib/libsapsigner.dylib",
            "/tmp/libsapsigner.dylib",
        ]
        var loaded: UnsafeMutableRawPointer?
        var loadedPath: String?
        var dlopenErrors: [String] = []
        for p in fwPaths {
            guard let path = p else { continue }
            if let h = dlopen(path, RTLD_NOW) {
                loaded = h
                loadedPath = path
                break
            } else {
                dlopenErrors.append(String(cString: dlerror()))
            }
        }
        guard let lib = loaded, let dylibPath = loadedPath else {
            Self.lastInitDetail = "dlopen 失败: " + dlopenErrors.prefix(2).joined(separator: " | ")
            return nil
        }
        if let installError = SAPAssetInstaller.installIfNeeded(frameworkExecutablePath: dylibPath) {
            Self.lastInitDetail = installError
            return nil
        }

        let unicornLib = (dylibPath as NSString).deletingLastPathComponent + "/SAPAssets/libunicorn.2.dylib"
        guard FileManager.default.fileExists(atPath: unicornLib) else {
            Self.lastInitDetail = "libunicorn 缺失: \(unicornLib)"
            return nil
        }
        if let setEnvP = dlsym(lib, "sap_set_env") {
            let setEnvFn = unsafeBitCast(setEnvP, to: (@convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void).self)
            "IPATOOL_UNICORN_LIB".withCString { key in
                unicornLib.withCString { value in
                    setEnvFn(key, value)
                }
            }
        } else {
            setenv("IPATOOL_UNICORN_LIB", unicornLib, 1)
        }

        guard
            let createP = dlsym(lib, SAPSymbols.createName),
            let signP = dlsym(lib, SAPSymbols.signName),
            let freeP = dlsym(lib, SAPSymbols.freeSigName),
            let destroyP = dlsym(lib, SAPSymbols.destroyName)
        else {
            Self.lastInitDetail = "dlsym 符号缺失: \(SAPSymbols.createName)"
            return nil
        }

        let createFn = unsafeBitCast(createP, to: sap_signer_create_t.self)
        let signFn = unsafeBitCast(signP, to: sap_signer_sign_t.self)
        let freeFn = unsafeBitCast(freeP, to: sap_signer_free_sig_t.self)
        let destroyFn = unsafeBitCast(destroyP, to: sap_signer_destroy_t.self)

        let setup = (config.setupURL as NSString).utf8String
        let cert = (config.certificateURL as NSString).utf8String
        var err: CInt = 0
        let h: UnsafeMutableRawPointer? = machineID.withUnsafeBytes { bytes in
            let p = bytes.bindMemory(to: UInt8.self).baseAddress
            return createFn(
                setup, cert, config.version,
                p, CInt(machineID.count), &err
            )
        }
        if err != 0 || h == nil {
            var detail = "sap_signer_create err=\(err)"
            if let lastErrP = dlsym(lib, "sap_signer_last_error") {
                let fn = unsafeBitCast(lastErrP, to: (@convention(c) () -> UnsafePointer<CChar>).self)
                let msg = String(cString: fn())
                if !msg.isEmpty && msg != "no error recorded" {
                    detail = msg
                }
            }
            switch err {
            case 1: Self.lastInitDetail = "参数无效 (err=1)"
            case 2: Self.lastInitDetail = "machineID MAC 地址格式错误 (err=2)"
            default: Self.lastInitDetail = "SAP init 失败 (err=\(err)): \(detail)"
            }
            return nil
        }
        self.init(handle: h!, fnSign: signFn, fnFreeSig: freeFn, fnDestroy: destroyFn)
    }

    init(handle: UnsafeMutableRawPointer,
         fnSign: @escaping sap_signer_sign_t,
         fnFreeSig: @escaping sap_signer_free_sig_t,
         fnDestroy: @escaping sap_signer_destroy_t) {
        self.handle = handle
        self.fnSign = fnSign
        self.fnFreeSig = fnFreeSig
        self.fnDestroy = fnDestroy
    }

    func sign(_ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw SAPSignerError.signerUnavailable }
        return try data.withUnsafeBytes { body in
            let p = body.bindMemory(to: UInt8.self).baseAddress
            var sigLen: CInt = 0
            var err: CInt = 0
            let sigPtr = fnSign(handle, p, CInt(data.count), &sigLen, &err)
            if err != 0 || sigPtr == nil {
                throw SAPSignerError.signFailed("code=\(err)")
            }
            let out = Data(bytes: sigPtr!, count: Int(sigLen))
            fnFreeSig(sigPtr!, Int(sigLen))
            return out
        }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        fnDestroy(handle)
        lock.unlock()
    }
}

#if os(macOS) || targetEnvironment(macCatalyst)
enum DefaultSAPSignerLocator {
    static let searchPaths: [String] = [
        "/tmp/ipatool240-signer",
        "/usr/local/bin/ipatool-sap-signer",
    ]

    static func resolve() throws -> String {
        for p in searchPaths {
            if FileManager.default.isExecutableFile(atPath: p) {
                return p
            }
        }
        if let bundled = Bundle.main.path(forAuxiliaryExecutable: "ipatool-sap-signer"),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        throw SAPSignerError.signerUnavailable
    }
}

final class SubprocessSAPSigner: SAPActionSigner {
    private let lock = NSLock()
    private var closed = false
    private let signerPath: String
    private let config: SAPConfig
    private let machineID: Data

    convenience init?(config: SAPConfig, machineID: Data) {
        guard let p = try? DefaultSAPSignerLocator.resolve() else { return nil }
        self.init(config: config, machineID: machineID, signerPath: p)
    }

    init(config: SAPConfig, machineID: Data, signerPath: String) {
        self.config = config
        self.machineID = machineID
        self.signerPath = signerPath
    }

    func sign(_ data: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw SAPSignerError.signerUnavailable }

        let macHex = machineID.map { String(format: "%02x", $0) }.joined()
        let input = SignerInput(
            setupURL: config.setupURL,
            certificateURL: config.certificateURL,
            version: String(config.version),
            machineMAC: macHex,
            bodyBase64: data.base64EncodedString()
        )
        guard let inputData = try? JSONEncoder().encode(input) else {
            throw SAPSignerError.signFailed("encode input")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: signerPath)
        process.arguments = ["sap-signer"]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        stdinPipe.fileHandleForWriting.write(inputData)
        try? stdinPipe.fileHandleForWriting.close()
        process.waitUntilExit()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "exit=\(process.terminationStatus)"
            throw SAPSignerError.signFailed(msg)
        }

        let output = try JSONDecoder().decode(SignerOutput.self, from: outData)
        if !output.error.isEmpty {
            throw SAPSignerError.signFailed(output.error)
        }
        guard let sig = Data(base64Encoded: output.signatureBase64), !sig.isEmpty else {
            throw SAPSignerError.signFailed("empty signature")
        }
        return sig
    }

    func close() {
        lock.lock(); closed = true; lock.unlock()
    }

    private struct SignerInput: Codable {
        let setupURL: String
        let certificateURL: String
        let version: String
        let machineMAC: String
        let bodyBase64: String
    }

    private struct SignerOutput: Codable {
        let signatureBase64: String
        let signLen: Int
        let error: String
    }
}
#endif
