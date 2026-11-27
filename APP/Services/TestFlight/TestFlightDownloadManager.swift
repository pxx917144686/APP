import Foundation
import Combine
import Security
import AppleAuth

struct TestFlightApp: Identifiable, Hashable, Codable {
    var bundle: String
    let name: String
    let appID: String?
    var version: String? = nil
    var iconURL: URL? = nil

    init(bundle: String, name: String, appID: String?, version: String? = nil, iconURL: URL? = nil) {
        self.bundle = bundle
        self.name = name
        self.appID = appID
        self.version = version
        self.iconURL = iconURL
    }

    var id: String { appID ?? (bundle.isEmpty ? name : bundle) }
}

private struct StoredTestFlightSession: Codable {
    let body: Data
    let hardware20: Data
    let storefront: String
    let headers: [String: String]
    let dsid: String
    let storeCookies: [String: String]
    let sessionID: String
    let sessionDsid: String
    let account: String
    let baseHeaders: [String: String]
    let email: String?
    let apps: [TestFlightApp]
}

@MainActor
final class TestFlightDownloadManager: ObservableObject {
    static let shared = TestFlightDownloadManager()

    @Published private(set) var imported = false
    @Published private(set) var apps: [TestFlightApp] = []
    @Published private(set) var isLoading = false
    @Published private(set) var downloadingBundle: String?
    @Published private(set) var downloadProgress: Double = 0
    @Published private(set) var builds: [TFBuild] = []
    @Published private(set) var buildsBundle: String?
    @Published private(set) var isLoadingBuilds = false
    @Published var buildError: String?
    @Published private(set) var downloadingBuildID: String?
    private var transferHandles: [UUID: TFTransferHandle] = [:]
    private var buildsGeneration = 0
    @Published var showsErrorAlert = false
    @Published private(set) var isValidatingCatalog = false
    @Published private(set) var lastOutput: URL?
    @Published private(set) var status: String?
    @Published private(set) var isLoggingIn = false
    @Published private(set) var appleIDLoggedIn = false
    @Published private(set) var accountEmail: String?
    @Published private(set) var settingsAccountEmail: String?
    @Published private(set) var preferredRegion: String = ""
    @Published var requiresCode = false
    @Published var error: String?

    private var client: TestFlightClient?
    private var swiftSession: SwiftTestFlightSession?
    private var device: Device?
    private var storeSession: StoreSession?
    private var codeContinuation: CheckedContinuation<String, Error>?
    private var codeRelay: TFLogin.CodeRelay?
    private var tfContext: TFContext?
    private var tfSession: TFSession?
    private var settingsAutoAttempted = false
    private var loadingIcons: Set<String> = []
    private let transport = TestFlightHTTPTransport()

    var diagnosticsURL: URL { transport.diagnosticsURL }

    private var sessionFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("TestFlight", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    private var accountsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("TestFlight", isDirectory: true)
            .appendingPathComponent("Accounts", isDirectory: true)
    }

    private var lastAccountKey: String { "testflight_last_account" }
    private var regionKey: String { "testflight_region" }

    var effectiveStorefront: String? {
        let code = preferredRegion.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, let front = Apple.storeFrontCodeMap[code] else { return nil }
        return "\(front)-1,29"
    }

    var metadataRegion: String {
        preferredRegion.isEmpty ? (AppStore.this.selectedAccount?.countryCode ?? "US") : preferredRegion
    }

    private func storeFront(for context: TFContext) -> String {
        effectiveStorefront ?? context.storefront
    }

    private func storeHeaders(for context: TFContext) -> [String: String] {
        guard let override = effectiveStorefront else { return context.headers }
        var headers = context.headers
        headers["X-Apple-Store-Front"] = override
        return headers
    }

    func setPreferredRegion(_ code: String) {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let resolved = Apple.storeFrontCodeMap[normalized] != nil ? normalized : ""
        guard resolved != preferredRegion else { return }
        preferredRegion = resolved
        UserDefaults.standard.set(resolved, forKey: regionKey)
        applyRegionToSession()
        transport.logStage("region: \(resolved.isEmpty ? "auto" : resolved) front \(effectiveStorefront ?? "-")")
        if imported, tfSession != nil {
            Task { await refreshCatalog() }
        }
    }

    private func applyRegionToSession() {
        guard let session = tfSession else { return }
        tfSession = TFSession(id: session.id, dsid: session.dsid, account: session.account,
                              baseHeaders: session.baseHeaders, storefrontOverride: effectiveStorefront)
    }

    @Published private(set) var savedAccountEmails: [String] = []

    private func accountSnapshotURL(_ email: String) -> URL {
        let safe = email.lowercased().replacingOccurrences(of: "/", with: "_")
        return accountsDirectory.appendingPathComponent(safe + ".json")
    }

    private func loadSavedAccountEmails() {
        let files = (try? FileManager.default.contentsOfDirectory(at: accountsDirectory, includingPropertiesForKeys: nil)) ?? []
        savedAccountEmails = files
            .filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    private var storedSessionURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("TestFlight", isDirectory: true)
            .appendingPathComponent("ipadn-session.json")
    }

    var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TestFlight", isDirectory: true)
    }

    private var deviceDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("TestFlight", isDirectory: true)
            .appendingPathComponent("device-v2", isDirectory: true)
    }

    private init() {
        preferredRegion = UserDefaults.standard.string(forKey: "testflight_region") ?? ""
        Task { await restoreSession() }
    }

    func importSession(from url: URL) async {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            transport.logStage("Import TestFlight session \(url.lastPathComponent)")
            let data = try Data(contentsOf: url)
            let client = try await makeClient(from: data)
            try? await self.client?.close()
            self.client = client
            imported = true
            appleIDLoggedIn = false
            storeSession = nil
            status = nil
            lastOutput = nil
            try persistSession(data)
            await refreshCatalog()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func login(email: String, password: String) async {
        showsErrorAlert = true
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !password.isEmpty else {
            error = "testflight_login_empty".localized
            return
        }
        guard !isLoggingIn else { return }
        isLoggingIn = true
        defer { isLoggingIn = false }

        do {
            transport.logStage("iPadn TestFlight sign-in start \(email)")
            let relay = TFLogin.CodeRelay(onRequest: { [weak self] in
                Task { @MainActor in self?.requiresCode = true }
            })
            codeRelay = relay
            let context = try await TFLogin.signIn(
                email: email,
                password: password,
                relay: relay,
                log: { [weak self] line in
                    self?.transport.logStage(line)
                }
            )
            transport.logStage("iPadn TestFlight context ready")
            tfContext = context
            let session = try await TFAPI.authenticate(context: context, log: { [weak self] line in
                self?.transport.logStage(line)
            })
            tfSession = session
            applyRegionToSession()
            transport.logStage("iPadn TestFlight session ready")
            if let features = try? StoreSupport.features() {
                transport.logStage("AppleAuth features: \(features)")
            }
            let betaApps = try await TFAPI.catalog(session: session, log: { [weak self] line in
                self?.transport.logStage(line)
            })
            apps = betaApps.map { app in
                TestFlightApp(bundle: app.bundleID, name: app.name, appID: app.id,
                              version: app.latestVersion, iconURL: TFIcon.cached(appID: app.id))
            }
            transport.logStage("iPadn catalog: \(apps.count) apps")
            imported = true
            appleIDLoggedIn = true
            accountEmail = email
            UserDefaults.standard.set(email, forKey: lastAccountKey)
            saveStoredSession()
            loadSavedAccountEmails()
            Task { await self.preloadIcons() }
            Task { await self.filterUnavailableApps() }
            status = nil
            lastOutput = nil
            requiresCode = false
            showsErrorAlert = false
            saveStoredSession()
        } catch {
            cancelPendingCode()
            transport.logStage("iPadn TestFlight login failed: \(error.localizedDescription)")
            self.error = String(format: "testflight_error_session".localized, error.localizedDescription)
        }
    }

    private func loginAccount(device: Device, email: String, password: String,
                              verification: Verification) async throws -> AccountSession {
        var lastError: Error?
        for attempt in 1...2 {
            do {
                return try await device.login(email: email, password: password, verification: verification)
            } catch {
                lastError = error
                if attempt == 1, Self.is503(error) {
                    transport.logStage("Apple ID 503, retry \(attempt)")
                    try await Task.sleep(for: .seconds(1))
                    continue
                }
                throw error
            }
        }
        throw lastError ?? CancellationError()
    }

    private static func is503(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("503") || text.contains("service temporarily")
    }

    func loadLocalCatalogIfNeeded() {
        guard apps.isEmpty else { return }
        let file = outputDirectory.appendingPathComponent("catalog.json")
        guard let data = try? Data(contentsOf: file) else { return }
        let loaded = parseCatalog(data)
        guard !loaded.isEmpty else { return }
        apps = loaded
        status = String(format: "testflight_local_catalog_loaded".localized, loaded.count)
        transport.logStage("Local TestFlight catalog loaded: \(loaded.count) apps")
    }

    func autoLoginFromSettingsIfNeeded() async {
        guard !settingsAutoAttempted, !imported, !isLoggingIn else { return }
        guard let account = AppStore.this.selectedAccount else { return }
        settingsAutoAttempted = true
        settingsAccountEmail = account.email
        accountEmail = account.email
        isLoggingIn = true
        defer { isLoggingIn = false }
        transport.logStage("Settings account bridge start \(account.email)")
        do {
            let context = try await makeTestFlightContext(from: account)
            do {
                let client = try await TestFlightClient.fromStoreCookies(context, transport: transport.transport)
                transport.logStage("Settings account bridge native success")
                try? await self.client?.close()
                self.client = client
                swiftSession = nil
                imported = true
                appleIDLoggedIn = true
                status = nil
                lastOutput = nil
                let data = try await client.serialize()
                try persistSession(data)
                await refreshCatalog()
            } catch {
                transport.logStage("Native TestFlight unavailable: \(error.localizedDescription); using Swift session")
                let session = try await SwiftTestFlightSession.create(context: context, transport: transport)
                transport.logStage("Settings account bridge Swift session success")
                swiftSession = session
                client = nil
                imported = true
                appleIDLoggedIn = true
                status = nil
                lastOutput = nil
                await refreshCatalog()
            }
        } catch {
            transport.logStage("Settings account bridge failed: \(error.localizedDescription)")
            self.error = String(format: "testflight_error_settings".localized, error.localizedDescription)
        }
    }

    func retryTestFlightSession() async {
        await useSettingsAccount()
    }

    func useSettingsAccount() async {
        settingsAutoAttempted = false
        await autoLoginFromSettingsIfNeeded()
    }

    private func makeTestFlightContext(from account: Account) async throws -> Data {
        let guid = account.deviceGUID
        guard guid.count == 12, guid.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            transport.logStage("Settings bridge: invalid guid")
            throw TestFlightHTTPError.invalidAccount
        }
        transport.logStage("Settings bridge: guid \(guid), cookies \(account.cookies.count)")
        guard let proof = try await SAPSigner.shared.storeProofHeaders(guid: guid, useCache: true),
              let amdM = proof["X-Apple-AMD-M"], !amdM.isEmpty else {
            transport.logStage("Settings bridge: AMD-M proof unavailable")
            throw TestFlightHTTPError.missingProof
        }
        var cookies: [String: String] = [:]
        for raw in account.cookies {
            let fields = raw.components(separatedBy: ";")
            guard let first = fields.first else { continue }
            let pair = first.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespaces)
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty else { continue }
            if name == "X-Dsid" {
                cookies[name] = account.dsPersonId
                continue
            }
            if let suffix = name.split(separator: "-").last,
               suffix.count >= 6, suffix.allSatisfy({ $0.isNumber }),
               String(suffix) != account.dsPersonId {
                continue
            }
            cookies[name] = value
        }
        if cookies["X-Dsid"] == nil { cookies["X-Dsid"] = account.dsPersonId }
        transport.logStage("Settings bridge: cookie names \(cookies.keys.sorted().joined(separator: ","))")
        guard !cookies.isEmpty else {
            transport.logStage("Settings bridge: no cookies")
            throw TestFlightHTTPError.missingCookies
        }
        transport.logStage("Settings bridge: cookies \(cookies.count), proof ready")
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        let udid = bytes.map { String(format: "%02x", $0) }.joined()
        let storeFront = account.storeResponse.storeFront.isEmpty ? "143441-1,29" : account.storeResponse.storeFront
        let headers: [String: String] = [
            "User-Agent": "Oasis/4.3.0 OasisBuild/659.1 iOS/17.6.1 model/iPhone12,1 hwp/t8030 build/21G101 (6; dt:189) AMS/1 TSE/0",
            "X-Apple-AMD": proof["X-Apple-AMD"] ?? "",
            "X-Apple-AMD-M": amdM,
            "X-Token": account.storeResponse.passwordToken,
            "X-Apple-Store-Front": storeFront,
            "X-Apple-Device-Model": "iPhone17,2",
            "X-Apple-TA-Device": "iPhone17,2",
            "X-Apple-TestFlight-iOS": "1",
            "X-Apple-Rosetta-Available": "0"
        ]
        let context: [String: Any] = [
            "dsid": account.dsPersonId,
            "udid": udid,
            "storeCookies": cookies,
            "headers": headers
        ]
        return try JSONSerialization.data(withJSONObject: context)
    }

    func submitCode(_ code: String) {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return }
        requiresCode = false
        transport.logStage("2FA code submitted")
        if let relay = codeRelay {
            Task { await relay.submit(code) }
            return
        }
        codeContinuation?.resume(returning: code)
        codeContinuation = nil
    }

    func cancelCode() {
        cancelPendingCode()
    }

    private func requestCode() async throws -> String {
        transport.logStage("2FA code requested")
        return try await withCheckedThrowingContinuation { continuation in
            codeContinuation = continuation
            requiresCode = true
        }
    }

    private func cancelPendingCode() {
        requiresCode = false
        if let relay = codeRelay {
            Task { await relay.cancel() }
            codeRelay = nil
        }
        codeContinuation?.resume(throwing: CancellationError())
        codeContinuation = nil
    }

    private func randomHardware20() -> Data {
        var bytes = [UInt8](repeating: 0, count: 20)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
        }
        return Data(bytes)
    }

    private var macTestFlightHeaders: [String: String] {
        [
            "User-Agent": "TestFlight/4.4.0 (Macintosh; macOS 27.2)",
            "X-Apple-Device-Model": "Mac17,8",
            "X-Apple-TA-Device": "Mac17,8",
            "X-Apple-TestFlight-iOS": "0",
            "X-Apple-Rosetta-Available": "0"
        ]
    }

    func refreshCatalog() async {
        isLoading = true
        defer { isLoading = false }
        do {
            transport.logStage("Catalog request")
            if let session = tfSession {
                let betaApps = try await TFAPI.catalog(session: session, log: { [weak self] line in
                    self?.transport.logStage(line)
                })
                let mapped = betaApps.map { app in
                    TestFlightApp(bundle: app.bundleID, name: app.name, appID: app.id,
                                  version: app.latestVersion, iconURL: TFIcon.cached(appID: app.id))
                }
                apps = await filteredApps(mapped, session: session)
                transport.logStage("iPadn catalog: \(apps.count)/\(mapped.count) apps")
                saveStoredSession()
                return
            }
            let data: Data
            if let swiftSession {
                data = try await swiftSession.catalog(transport: transport)
            } else if let client {
                data = try await client.catalog()
            } else {
                return
            }
            transport.logStage("Catalog success \(data.count) bytes")
            apps = parseCatalog(data)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadBuilds(for app: TestFlightApp) async {
        guard let appID = app.appID, let session = tfSession else {
            buildError = "testflight_login_required".localized
            return
        }
        buildsGeneration += 1
        let generation = buildsGeneration
        buildsBundle = app.bundle
        builds = []
        buildError = nil
        isLoadingBuilds = true
        defer {
            if generation == buildsGeneration { isLoadingBuilds = false }
        }
        var serverBuilds: [TFBuild] = []
        do {
            serverBuilds = try await TFAPI.buildHistory(appID: appID, session: session) { [weak self] line in
                self?.transport.logStage(line)
            }
        } catch {
            transport.logStage("history unavailable for \(appID): \(error.localizedDescription)")
            guard generation == buildsGeneration else { return }
            if savedBuilds(appID: appID).isEmpty, downloadedBuilds(bundle: app.bundle).isEmpty {
                buildError = error.localizedDescription
                return
            }
        }
        guard generation == buildsGeneration else { return }
        let serverIDs = Set(serverBuilds.map(\.id))
        let merged = mergeBuilds(serverBuilds + downloadedBuilds(bundle: app.bundle), appID: appID)
        builds = serverIDs.isEmpty ? merged : merged.map { serverIDs.contains($0.id) ? $0 : $0.markingExpired() }
        if builds.isEmpty {
            buildError = "testflight_no_builds".localized
        }
    }

    private func downloadedBuilds(bundle: String) -> [TFBuild] {
        guard !bundle.isEmpty else { return [] }
        let folder = outputDirectory.appendingPathComponent(bundle, isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [TFBuild] = []
        for item in items {
            let product = item.appendingPathComponent("product.json")
            guard let data = try? Data(contentsOf: product),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let buildID = json["buildId"] as? String, !buildID.isEmpty else { continue }
            result.append(TFBuild(
                id: buildID,
                shortVersion: (json["version"] as? String) ?? "",
                buildVersion: "",
                platform: (json["platform"] as? String) ?? "ios",
                expirationISO: nil,
                releaseDateISO: json["downloadedAt"] as? String,
                fileSizeBytes: (json["bytes"] as? NSNumber)?.int64Value,
                whatsNew: nil,
                expired: false
            ))
        }
        return result
    }

    func loadIcon(for app: TestFlightApp) async {
        guard let appID = app.appID,
              let index = apps.firstIndex(where: { $0.id == app.id }),
              apps[index].iconURL == nil,
              !loadingIcons.contains(app.id) else { return }
        loadingIcons.insert(app.id)
        defer { loadingIcons.remove(app.id) }

        let log: @Sendable (String) -> Void = { [weak self] line in
            self?.transport.logStage(line)
        }
        var asset: TFIconAsset?
        if let session = tfSession {
            asset = await TFAPI.iconAsset(appID: appID, session: session, log: log)
        }
        if asset == nil {
            asset = await TFIcon.publicArtworkAsset(appID: appID, log: log)
        }
        if asset == nil, !app.bundle.isEmpty {
            asset = await Self.publicArtwork(bundleID: app.bundle, log: log)
        }
        guard let asset else { return }
        let cached = await TFIcon.cache(appID: appID, asset: asset, log: log)
        let url = cached ?? asset.urlTemplate.flatMap { TFIcon.url(from: $0, side: 128) }
        guard let url else { return }
        if let current = apps.firstIndex(where: { $0.id == app.id }) {
            apps[current].iconURL = url
            saveStoredSession()
        }
    }

    private func preloadIcons() async {
        let missing = apps.filter { $0.iconURL == nil && $0.appID != nil }
        guard !missing.isEmpty else { return }
        let transport = self.transport
        let region = metadataRegion
        let log: @Sendable (String) -> Void = { line in transport.logStage(line) }

        var resolved: [(id: String, url: URL)] = []
        let batchSize = 12
        var offset = 0
        while offset < missing.count {
            let end = min(offset + batchSize, missing.count)
            let batch = Array(missing[offset..<end])
            let results: [(String, URL)] = await withTaskGroup(of: (String, URL)?.self) { group in
                for app in batch {
                    guard let appID = app.appID else { continue }
                    let appIDValue = appID
                    let id = app.id
                    group.addTask {
                        guard let asset = await TFIcon.publicArtworkAsset(appID: appIDValue, country: region, log: log) else {
                            return nil
                        }
                        let cached = await TFIcon.cache(appID: appIDValue, asset: asset, log: log)
                        guard let url = cached ?? asset.urlTemplate.flatMap({ TFIcon.url(from: $0, side: 128) }) else {
                            return nil
                        }
                        return (id, url)
                    }
                }
                var collected: [(String, URL)] = []
                for await entry in group {
                    if let entry { collected.append(entry) }
                }
                return collected
            }
            resolved.append(contentsOf: results)
            offset = end
        }

        for (id, url) in resolved {
            if let current = apps.firstIndex(where: { $0.id == id }), apps[current].iconURL == nil {
                apps[current].iconURL = url
            }
        }
        saveStoredSession()
    }

    func startDownloadFromUI(app: TestFlightApp, buildID: String? = nil) {
        SoundEffects.play(.press)
        let version = buildID.flatMap { id in builds.first(where: { $0.id == id })?.versionSummary } ?? app.version
        transport.logStage("UI download button tapped app=\(app.appID ?? "-") bundled=\(app.bundle) build=\(buildID ?? "latest") version=\(version ?? "-")")
        Task { await download(app: app, buildID: buildID, versionLabel: version) }
    }

    func download(app: TestFlightApp, buildID: String? = nil, versionLabel: String? = nil) async {
        guard let appID = app.appID, let session = tfSession else {
            error = "testflight_login_required".localized
            return
        }
        var bundle = app.bundle
        if bundle.isEmpty {
            transport.logStage("resolve bundle for app \(appID)")
            bundle = await TFAPI.resolveBundle(appID: appID, session: session) { [weak self] line in
                self?.transport.logStage(line)
            }
            if bundle.isEmpty {
                bundle = (try? await TFAPI.publicBundleID(appID: appID) { [weak self] line in
                    self?.transport.logStage(line)
                }) ?? ""
            }
            if !bundle.isEmpty, let index = apps.firstIndex(where: { $0.id == app.id }) {
                apps[index].bundle = bundle
                saveStoredSession()
                transport.logStage("resolved bundle \(bundle) for \(appID)")
            }
        }
        guard !bundle.isEmpty else {
            error = "testflight_bundle_missing".localized
            SoundEffects.play(.error)
            transport.logStage("bundle resolve failed for app \(appID)")
            return
        }
        if app.iconURL == nil {
            await loadIcon(for: app)
        }
        await download(bundle: bundle, buildID: buildID, versionLabel: versionLabel)
    }

    func startDownloadFromUI(bundle: String, buildID: String? = nil) {
        transport.logStage("UI download button tapped bundle=\(bundle) build=\(buildID ?? "latest")")
        Task { await download(bundle: bundle, buildID: buildID) }
    }

    func pauseUnifiedDownload(taskID: UUID) {
        transferHandles[taskID]?.pause()
    }

    func resumeUnifiedDownload(taskID: UUID, bundle: String) {
        if let handle = transferHandles[taskID] {
            handle.resume()
            return
        }
        Task { await download(bundle: bundle) }
    }

    func cancelUnifiedDownload(taskID: UUID) {
        transferHandles[taskID]?.cancel()
    }

    func ensureSinf(ipaPath: String, appID: String, buildID: String? = nil) async -> Bool? {
        let url = URL(fileURLWithPath: ipaPath)
        let members = TFSINF.members(ipa: url)
        if members.contains(where: { $0.contains("/SC_Info/") && $0.hasSuffix(".sinf") }) {
            return true
        }
        guard let context = tfContext, let session = tfSession,
              !appID.isEmpty, UInt64(appID) != nil else { return nil }
        var resolvedBuild = buildID ?? ""
        if resolvedBuild.isEmpty,
           let data = try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("product.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = json["buildId"] as? String {
            resolvedBuild = value
        }
        guard !resolvedBuild.isEmpty, resolvedBuild != "unknown" else { return nil }
        let log: @Sendable (String) -> Void = { [weak self] line in
            self?.transport.logStage(line)
        }
        do {
            let metadata = try await TFAPI.installMetadata(
                appID: appID, buildID: resolvedBuild, session: session,
                headers: storeHeaders(for: context), dsid: context.dsid,
                hardware20: context.hardware20, storefront: storeFront(for: context),
                log: log
            )
            let report = try TFSINF.install(metadata: metadata, ipa: url)
            transport.logStage("sinf repair: added \(report.addedCount) for \(url.lastPathComponent)")
            return report.addedCount > 0 ? true : nil
        } catch {
            transport.logStage("sinf repair failed: \(error.localizedDescription)")
            return nil
        }
    }

    func download(bundle: String, buildID requestedBuildID: String? = nil, versionLabel: String? = nil) async {
        let bundle = bundle.trimmingCharacters(in: .whitespacesAndNewlines)
        transport.logStage("download call bundle=\(bundle) build=\(requestedBuildID ?? "latest") tfContext=\(tfContext != nil) tfSession=\(tfSession != nil)")
        guard !bundle.isEmpty else {
            error = "testflight_bundle_missing".localized
            return
        }
        transport.logStage("download tap bundle=\(bundle) build=\(requestedBuildID ?? "latest") tfContext=\(tfContext != nil) tfSession=\(tfSession != nil) swiftSession=\(swiftSession != nil) client=\(client != nil)")
        guard tfContext != nil || tfSession != nil || swiftSession != nil || client != nil else {
            error = "testflight_login_required".localized
            return
        }

        if let context = tfContext, let session = tfSession {
            guard let app = apps.first(where: { $0.bundle == bundle }), let appID = app.appID else {
                error = "testflight_download_unavailable".localized
                return
            }
            downloadingBundle = bundle
            downloadingBuildID = requestedBuildID
            lastOutput = nil
            status = nil
            downloadProgress = 0
            showsErrorAlert = false
            if app.iconURL == nil {
                await loadIcon(for: app)
            }
            let storedIconURL = apps.first(where: { $0.id == app.id })?.iconURL ?? app.iconURL
            let resolvedIconURL = TFIcon.resolvedURL(storedURL: storedIconURL, appID: appID)
            let iconURLString = resolvedIconURL?.absoluteString
            if let iconIndex = apps.firstIndex(where: { $0.id == app.id }),
               apps[iconIndex].iconURL != resolvedIconURL {
                apps[iconIndex].iconURL = resolvedIconURL
                saveStoredSession()
            }
            var resolvedVersion = versionLabel ?? app.version ?? ""
            if resolvedVersion.isEmpty, let appID = app.appID {
                let detail = await TFAPI.appDetailV3(appID: appID, session: session) { [weak self] line in
                    self?.transport.logStage(line)
                }
                if let detail = detail, !detail.versionSummary.isEmpty {
                    resolvedVersion = detail.versionSummary
                    if let index = apps.firstIndex(where: { $0.id == app.id }) {
                        apps[index].version = resolvedVersion
                        saveStoredSession()
                    }
                }
            }
            let unifiedTaskID = UnifiedDownloadManager.shared.addDownload(
                bundleIdentifier: bundle,
                name: app.name,
                version: resolvedVersion,
                identifier: Int(appID) ?? 0,
                iconURL: iconURLString,
                isTestFlight: true
            )
            let transferHandle = TFTransferHandle()
            transferHandles[unifiedTaskID] = transferHandle
            defer { transferHandles[unifiedTaskID] = nil }
            var unifiedMaxConnections: Int?
            if let task = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == unifiedTaskID }) {
                task.runtime.status = .downloading
                task.runtime.error = nil
                unifiedMaxConnections = task.maxConnections
            }
            UnifiedDownloadManager.shared.saveDownloadTasks()
            UnifiedDownloadManager.shared.beginTestFlightTask(taskID: unifiedTaskID)
            defer {
                downloadingBundle = nil
                downloadingBuildID = nil
            }
            do {
                let log: @Sendable (String) -> Void = { [weak self] line in
                    self?.transport.logStage(line)
                }
                let buildID: String
                if let requestedBuildID, !requestedBuildID.isEmpty {
                    buildID = requestedBuildID
                    downloadingBuildID = requestedBuildID
                } else {
                    buildID = try await TFAPI.buildID(appID: appID, platform: "ios",
                                                     session: session, log: log)
                    downloadingBuildID = buildID
                }
                let metadata = try await TFAPI.installMetadata(
                    appID: appID, buildID: buildID, session: session,
                    headers: storeHeaders(for: context), dsid: context.dsid,
                    hardware20: context.hardware20, storefront: storeFront(for: context),
                    log: log
                )
                let envelope = try TFDownload.envelope(
                    dsid: context.dsid, headers: storeHeaders(for: context),
                    storeCookies: context.storeCookies,
                    udid: context.hardware20.map { String(format: "%02x", $0) }.joined()
                )
                let report = try await TFDownload.run(
                    bundle: bundle,
                    context: envelope,
                    hardware20: context.hardware20,
                    identity: storeHeaders(for: context),
                    metadata: metadata,
                    buildID: buildID,
                    versionLabel: versionLabel ?? app.version,
                    platform: "ios",
                    handle: transferHandle,
                    maxConnections: unifiedMaxConnections,
                    progress: { [weak self] done, total in
                        guard total > 0 else { return }
                        Task { @MainActor in
                            self?.downloadProgress = Double(done) / Double(total)
                            if let task = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == unifiedTaskID }),
                               task.runtime.status == .downloading {
                                task.runtime.updateProgress(completed: done, total: total)
                            }
                        }
                    },
                    onActiveConnections: { connections in
                        Task { @MainActor in
                            if let task = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == unifiedTaskID }),
                               task.runtime.status == .downloading {
                                task.runtime.activeConnections = connections
                            }
                        }
                    },
                    stage: { stage in
                        guard stage != "downloading" else { return }
                        Task { @MainActor [weak self] in
                            self?.downloadProgress = min(self?.downloadProgress ?? 0, 0.99)
                            if let task = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == unifiedTaskID }) {
                                task.runtime.speed = "download_processing".localized
                            }
                        }
                    },
                    log: log
                )
                lastOutput = report.output
                SoundEffects.play(.success)
                if let task = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == unifiedTaskID }) {
                    task.runtime.updateProgress(completed: Int64(report.outputBytes), total: Int64(report.outputBytes))
                    task.runtime.status = .completed
                    task.runtime.activeConnections = 0
                    task.localFilePath = report.output.path
                    task.runtime.error = nil
                    task.runtime.speed = ""
                }
                UnifiedDownloadManager.shared.completedRequests.insert(unifiedTaskID)
                UnifiedDownloadManager.shared.saveDownloadTasks()
                UnifiedDownloadManager.shared.finishTestFlightTask(taskID: unifiedTaskID)
                let megabytes = Double(report.outputBytes) / 1_048_576.0
                status = String(format: "testflight_downloaded_format".localized,
                                report.output.lastPathComponent, megabytes)
            } catch {
                if let tfError = error as? TFError, case .cancelled = tfError {
                    UnifiedDownloadManager.shared.failTestFlightTask(taskID: unifiedTaskID)
                    return
                }
                let detail = error.localizedDescription
                let isUnavailable: Bool
                if let tfError = error as? TFError {
                    switch tfError {
                    case .appUnavailable:
                        isUnavailable = true
                    case let .http(status, _, _) where status == 404 || status == 410:
                        isUnavailable = true
                    default:
                        isUnavailable = false
                    }
                } else {
                    isUnavailable = detail.contains("404") || detail.contains("410")
                }
                let friendly = isUnavailable
                    ? String(format: "testflight_no_build".localized, app.name)
                    : detail
                self.error = friendly
                self.showsErrorAlert = false
                SoundEffects.play(.error)
                if let task = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == unifiedTaskID }) {
                    task.runtime.status = .failed
                    task.runtime.activeConnections = 0
                    task.runtime.error = friendly
                }
                UnifiedDownloadManager.shared.saveDownloadTasks()
                UnifiedDownloadManager.shared.failTestFlightTask(taskID: unifiedTaskID)
            }
            return
        }

        if swiftSession != nil {
            error = "testflight_download_unavailable".localized
            return
        }
        guard let client else {
            error = "testflight_login_required".localized
            return
        }
        downloadingBundle = bundle
        lastOutput = nil
        status = nil
        defer { downloadingBundle = nil }
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970)
            let output = outputDirectory.appendingPathComponent("\(bundle)-\(stamp).ipa")
            transport.logStage("Download start \(bundle)")
            let result = try await client.download(bundle: bundle, to: output)
            transport.logStage("Download success \(bundle)")
            lastOutput = output
            let megabytes = Double(result.downloadedBytes) / 1_048_576.0
            status = String(format: "testflight_downloaded_format".localized, output.lastPathComponent, megabytes)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func switchAccount(email: String, saveCurrent: Bool = true) async {
        let target = email.lowercased()
        guard target != accountEmail?.lowercased() else { return }
        if saveCurrent { saveStoredSession() }
        guard let data = try? Data(contentsOf: accountSnapshotURL(target)),
              let stored = try? JSONDecoder().decode(StoredTestFlightSession.self, from: data) else { return }
        try? await client?.close()
        client = nil
        swiftSession = nil
        storeSession = nil
        device = nil
        apply(stored: stored)
        accountEmail = stored.email ?? target
        imported = true
        appleIDLoggedIn = true
        status = nil
        error = nil
        UserDefaults.standard.set(accountEmail, forKey: lastAccountKey)
        saveStoredSession()
        loadSavedAccountEmails()
        await refreshCatalog()
    }

    func beginAddAccount() async {
        saveStoredSession()
        try? await client?.close()
        client = nil
        swiftSession = nil
        tfContext = nil
        tfSession = nil
        device = nil
        storeSession = nil
        imported = false
        appleIDLoggedIn = false
        accountEmail = nil
        apps = []
        status = nil
        error = nil
        cancelPendingCode()
    }

    func logoutCurrentAccount() async {
        let current = accountEmail
        if let current, !current.isEmpty {
            try? FileManager.default.removeItem(at: accountSnapshotURL(current))
        }
        loadSavedAccountEmails()
        if let next = savedAccountEmails.first {
            accountEmail = nil
            await switchAccount(email: next, saveCurrent: false)
        } else {
            await clearSession()
        }
    }

    func deleteSavedAccount(email: String) async {
        if email.lowercased() == accountEmail?.lowercased() {
            await logoutCurrentAccount()
        } else {
            try? FileManager.default.removeItem(at: accountSnapshotURL(email))
            loadSavedAccountEmails()
        }
    }

    func cancelAddAccount() async -> Bool {
        guard !savedAccountEmails.isEmpty else { return false }
        let email = UserDefaults.standard.string(forKey: lastAccountKey) ?? savedAccountEmails[0]
        await switchAccount(email: email.lowercased(), saveCurrent: false)
        return imported
    }

    func clearSession() async {
        try? await client?.close()
        try? await device?.close()
        client = nil
        swiftSession = nil
        tfContext = nil
        tfSession = nil
        device = nil
        storeSession = nil
        imported = false
        appleIDLoggedIn = false
        accountEmail = nil
        UserDefaults.standard.removeObject(forKey: lastAccountKey)
        settingsAccountEmail = nil
        settingsAutoAttempted = false
        apps = []
        lastOutput = nil
        status = nil
        cancelPendingCode()
        try? FileManager.default.removeItem(at: sessionFileURL)
        try? FileManager.default.removeItem(at: storedSessionURL)
        loadSavedAccountEmails()
    }

    private func restoreSession() async {
        loadSavedAccountEmails()
        if restoreStoredSession() {
            if !ProcessInfo.processInfo.arguments.contains("-noCatalogRefresh") {
                await refreshCatalog()
            }
            return
        }
        if let email = UserDefaults.standard.string(forKey: lastAccountKey),
           savedAccountEmails.contains(email.lowercased()) {
            await switchAccount(email: email.lowercased(), saveCurrent: false)
            return
        }
        guard let data = try? Data(contentsOf: sessionFileURL) else { return }
        do {
            let client = try await makeClient(from: data)
            self.client = client
            imported = true
            await refreshCatalog()
        } catch {
            try? FileManager.default.removeItem(at: sessionFileURL)
        }
    }

    private static func publicArtwork(bundleID: String, log: @escaping @Sendable (String) -> Void) async -> TFIconAsset? {
        for country in ["us", "cn", "hk", "jp", "tw"] {
            guard let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(encoded)&country=\(country)") else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = root["results"] as? [[String: Any]],
                  let first = results.first else { continue }
            let raw = (first["artworkUrl512"] as? String)
                ?? (first["artworkUrl100"] as? String)
                ?? (first["artworkUrl60"] as? String)
            if let raw, raw.contains("http") {
                log("icon: \(bundleID) 命中 App Store 图标 (\(country))")
                return TFIconAsset(urlTemplate: raw)
            }
        }
        return nil
    }

    private func buildHistoryURL(appID: String) -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("TestFlight/build-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(appID).json")
    }

    private func savedBuilds(appID: String) -> [TFBuild] {
        guard let data = try? Data(contentsOf: buildHistoryURL(appID: appID)),
              let list = try? JSONDecoder().decode([TFBuild].self, from: data) else { return [] }
        return list
    }

    private func mergeBuilds(_ server: [TFBuild], appID: String) -> [TFBuild] {
        var map: [String: TFBuild] = [:]
        for build in savedBuilds(appID: appID) { map[build.id] = build }
        for build in server { map[build.id] = build }
        let merged = map.values.sorted {
            (Int64($0.id) ?? 0, $0.buildVersion) > (Int64($1.id) ?? 0, $1.buildVersion)
        }
        if !merged.isEmpty, let data = try? JSONEncoder().encode(merged) {
            try? data.write(to: buildHistoryURL(appID: appID), options: .atomic)
        }
        return merged
    }

    func revalidateCatalog() async {
        guard imported, !isValidatingCatalog else { return }
        await filterUnavailableApps()
    }

    private func filterUnavailableApps() async {
        guard !isValidatingCatalog, let session = tfSession else { return }
        isValidatingCatalog = true
        defer { isValidatingCatalog = false }
        let kept = await filteredApps(apps, session: session)
        if kept.count != apps.count {
            transport.logStage("availability: kept \(kept.count)/\(apps.count) apps")
            apps = kept
            saveStoredSession()
        }
    }

    private func filteredApps(_ list: [TestFlightApp], session: TFSession) async -> [TestFlightApp] {
        var seen = Set<String>()
        let catalog = list.compactMap { app -> TFBetaApp? in
            guard let appID = app.appID, !appID.isEmpty, seen.insert(appID).inserted else { return nil }
            return TFBetaApp(id: appID, name: app.name, bundleID: app.bundle,
                             latestVersion: app.version, buildCount: 0)
        }
        guard !catalog.isEmpty else { return list }
        let details = await TFAPI.allAppDetailsV3(for: catalog, session: session) { [weak self] line in
            self?.transport.logStage(line)
        }
        guard !details.isEmpty else {
            transport.logStage("availability: bulk detail empty, keep all \(list.count)")
            return list
        }
        let kept = list.filter { app in
            guard let appID = app.appID, let detail = details[appID] else { return false }
            let builds = detail.platformBuilds ?? []
            return builds.contains { $0.platform.lowercased().contains("ios") }
        }
        transport.logStage("availability: \(kept.count)/\(list.count) apps have an iOS build")
        return kept
    }

    private func normalizeIconURLs() {
        for index in apps.indices {
            guard let appID = apps[index].appID, !appID.isEmpty,
                  let iconURL = apps[index].iconURL, iconURL.isFileURL else { continue }
            if FileManager.default.fileExists(atPath: iconURL.path) { continue }
            apps[index].iconURL = TFIcon.cached(appID: appID)
        }
    }

    private func saveStoredSession() {
        guard let context = tfContext, let session = tfSession else { return }
        normalizeIconURLs()
        let stored = StoredTestFlightSession(
            body: context.body,
            hardware20: context.hardware20,
            storefront: context.storefront,
            headers: context.headers,
            dsid: context.dsid,
            storeCookies: context.storeCookies,
            sessionID: session.id,
            sessionDsid: session.dsid,
            account: session.account,
            baseHeaders: session.baseHeaders,
            email: accountEmail,
            apps: apps
        )
        do {
            let directory = storedSessionURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.protectionKey: FileProtectionType.complete])
            let data = try JSONEncoder().encode(stored)
            try data.write(to: storedSessionURL, options: [.atomic, .completeFileProtection])
            if let email = accountEmail, !email.isEmpty {
                try? FileManager.default.createDirectory(at: accountsDirectory, withIntermediateDirectories: true)
                try? data.write(to: accountSnapshotURL(email), options: [.atomic, .completeFileProtection])
                if !savedAccountEmails.contains(email.lowercased()) {
                    loadSavedAccountEmails()
                }
            }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var url = storedSessionURL
            try? url.setResourceValues(values)
        } catch {
            transport.logStage("TestFlight session save failed: \(error.localizedDescription)")
        }
    }

    private func restoreStoredSession() -> Bool {
        guard let data = try? Data(contentsOf: storedSessionURL),
              let stored = try? JSONDecoder().decode(StoredTestFlightSession.self, from: data) else {
            return false
        }
        apply(stored: stored)
        accountEmail = stored.email
        imported = true
        appleIDLoggedIn = true
        status = "testflight_session_imported".localized
        if let email = stored.email, !email.isEmpty {
            UserDefaults.standard.set(email, forKey: lastAccountKey)
            saveStoredSession()
        }
        loadSavedAccountEmails()
        transport.logStage("TestFlight session restored (\(apps.count) cached apps)")
        if apps.contains(where: { $0.iconURL == nil && $0.appID != nil }) {
            Task { await self.preloadIcons() }
        }
        return true
    }

    private func apply(stored: StoredTestFlightSession) {
        tfContext = TFContext(body: stored.body, hardware20: stored.hardware20,
                              storefront: stored.storefront, headers: stored.headers,
                              dsid: stored.dsid, storeCookies: stored.storeCookies)
        tfSession = TFSession(id: stored.sessionID, dsid: stored.sessionDsid,
                              account: stored.account, baseHeaders: stored.baseHeaders,
                              storefrontOverride: effectiveStorefront)
        apps = stored.apps
        normalizeIconURLs()
    }

    private func makeClient(from data: Data) async throws -> TestFlightClient {
        do {
            return try await TestFlightClient(savedSession: data, transport: transport.transport)
        } catch {
            return try await TestFlightClient.fromStoreCookies(data, transport: transport.transport)
        }
    }

    private func persistSession(_ data: Data) throws {
        let fileManager = FileManager.default
        let directory = sessionFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try data.write(to: sessionFileURL, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = sessionFileURL
        try? url.setResourceValues(values)
    }

    private func parseCatalog(_ data: Data) -> [TestFlightApp] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var found: [String: TestFlightApp] = [:]

        func stringValue(_ value: Any?) -> String? {
            if let string = value as? String, !string.isEmpty { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }

        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                let bundle = stringValue(dictionary["bundleId"])
                    ?? stringValue(dictionary["bundleIdentifier"])
                    ?? stringValue(dictionary["bundleID"])
                    ?? stringValue(dictionary["bundle"])
                if let bundle, bundle.contains(".") {
                    let name = stringValue(dictionary["name"])
                        ?? stringValue(dictionary["appName"])
                        ?? stringValue(dictionary["title"])
                        ?? bundle
                    let appID = stringValue(dictionary["appAdamId"])
                        ?? stringValue(dictionary["adamId"])
                        ?? stringValue(dictionary["appId"])
                    found[bundle] = TestFlightApp(bundle: bundle, name: name, appID: appID)
                }
                for child in dictionary.values {
                    walk(child)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    walk(child)
                }
            }
        }

        walk(root)
        return found.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
