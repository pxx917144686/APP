import SwiftUI
import Combine
import Foundation
import Network
import NIOSSL

let installServerHost = "localhost.flarestore.vip"

#if canImport(UIKit)
import UIKit
import SafariServices
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(Vapor)
import Vapor
#endif

public struct AppInfo {
    public let name: String
    public let version: String
    public let bundleIdentifier: String
    public let path: String
    public let localPath: String?

    public init(name: String, version: String, bundleIdentifier: String, path: String, localPath: String? = nil) {
        self.name = name
        self.version = version
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.localPath = localPath
    }

    public var bundleId: String {
        return bundleIdentifier
    }
}

@MainActor
class GlobalInstallationManager: ObservableObject, @unchecked Sendable {
    static let shared = GlobalInstallationManager()
    @Published var isAnyInstalling = false
    @Published var currentInstallingRequestId: UUID? = nil

    private init() {}

    func startInstallation(for requestId: UUID, title: String = "") -> Bool {
        guard !isAnyInstalling else { return false }
        isAnyInstalling = true
        currentInstallingRequestId = requestId
        InstallActivityManager.shared.start(
            key: IslandTaskKey.install(requestId),
            title: title.isEmpty ? "install".localized : title,
            step: "install_stage_preparing".localized
        )
        return true
    }

    func updateInstallationStep(for requestId: UUID, step: String) {
        InstallActivityManager.shared.update(key: IslandTaskKey.install(requestId), step: step)
    }

    func finishInstallation() {
        let pending = currentInstallingRequestId
        isAnyInstalling = false
        currentInstallingRequestId = nil
        if let pending {
            InstallActivityManager.shared.finish(
                key: IslandTaskKey.install(pending),
                detail: "install_handed_off".localized
            )
        }
    }

    func finishInstallation(for requestId: UUID) {
        if currentInstallingRequestId == requestId || currentInstallingRequestId == nil {
            isAnyInstalling = false
            currentInstallingRequestId = nil
            InstallActivityManager.shared.finish(
                key: IslandTaskKey.install(requestId),
                detail: "install_handed_off".localized
            )
        }
    }

    func failInstallation(for requestId: UUID, reason: String) {
        InstallActivityManager.shared.fail(
            key: IslandTaskKey.install(requestId),
            reason: reason
        )
    }
}

@MainActor
class HTTPServerManager: ObservableObject, @unchecked Sendable {
    static let shared = HTTPServerManager()
    private var activeServers: [UUID: SimpleHTTPServer] = [:]

    private init() {}

    func allocatePort() -> Int {
        SimpleHTTPServer.randomPort(excluding: Set(activeServers.values.map { $0.port }))
    }

    func startServer(for requestId: UUID, port: Int, host: String, ipaPath: String, appInfo: AppInfo) {
        stopServer(for: requestId)
        let server = SimpleHTTPServer(port: port, host: host, ipaPath: ipaPath, appInfo: appInfo)
        server.start()
        activeServers[requestId] = server
        InstallHeartbeat.shared.start(for: 600)
    }

    func stopServer(for requestId: UUID) {
        if let server = activeServers[requestId] {
            server.stop()
            activeServers.removeValue(forKey: requestId)
        }
        if activeServers.isEmpty {
            InstallHeartbeat.shared.stop()
        }
    }

    func stopAllServers() {
        for server in activeServers.values {
            server.stop()
        }
        activeServers.removeAll()
        InstallHeartbeat.shared.stop()
    }

    func plistData(for requestId: UUID) -> Data? {
        activeServers[requestId]?.generatePlistData()
    }
}

#if canImport(AVFoundation)
final class InstallHeartbeat {
    static let shared = InstallHeartbeat()
    private var player: AVAudioPlayer?
    private var stopWorkItem: DispatchWorkItem?

    private init() {}

    func start(for seconds: TimeInterval) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)

            if self.player == nil, let data = Self.silentWAV() {
                self.player = try? AVAudioPlayer(data: data)
                self.player?.numberOfLoops = -1
                self.player?.volume = 0
            }
            self.player?.play()

            self.stopWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.stop() }
            self.stopWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.stopWorkItem?.cancel()
            self.stopWorkItem = nil
            self.player?.stop()
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private static func silentWAV() -> Data? {
        let sampleRate: UInt32 = 8000
        let dataSize = Int(sampleRate) * 2
        var data = Data()

        func appendUInt32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func appendUInt16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        appendUInt32(16)
        appendUInt16(1)
        appendUInt16(1)
        appendUInt32(sampleRate)
        appendUInt32(sampleRate * 2)
        appendUInt16(2)
        appendUInt16(16)
        data.append(contentsOf: Array("data".utf8))
        appendUInt32(UInt32(dataSize))
        data.append(Data(count: dataSize))
        return data
    }
}
#endif

struct ModernCard<Content: SwiftUI.View>: SwiftUI.View {
    let content: Content
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    private var shadowColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.5) : Color.black.opacity(0.1)
    }

    private var shadowRadius: CGFloat {
        colorScheme == .dark ? 12 : 8
    }

    var body: some SwiftUI.View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .shadow(
                        color: shadowColor,
                        radius: shadowRadius,
                        x: 0,
                        y: 4
                    )
            )
    }
}

#if canImport(UIKit)
private var SafariViewDismissDelegateAssociatedKey: UInt8 = 0

class SafariViewDismissDelegate: NSObject, SFSafariViewControllerDelegate {
    let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
        super.init()
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        onDismiss()
    }
}
#endif

#if canImport(UIKit)
struct SafariWebView: UIViewControllerRepresentable {
    let url: URL
    @Binding var isPresented: Bool
    let onDismiss: (() -> Void)?

    init(url: URL, isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil) {
        self.url = url
        self._isPresented = isPresented
        self.onDismiss = onDismiss
    }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        config.barCollapsingEnabled = true

        let safariVC = SFSafariViewController(url: url, configuration: config)
        safariVC.delegate = context.coordinator

        return safariVC
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {

    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let parent: SafariWebView

        init(_ parent: SafariWebView) {
            self.parent = parent
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            parent.isPresented = false
            parent.onDismiss?()
        }

        func safariViewController(_ controller: SFSafariViewController, didCompleteInitialLoad didLoadSuccessfully: Bool) {
            if didLoadSuccessfully {
            } else {
            }
        }
    }
}
#endif

public enum PackageInstallationError: Error, LocalizedError {
    case invalidIPAFile
    case installationFailed(String)
    case networkError
    case timeoutError

    public var errorDescription: String? {
        switch self {
        case .invalidIPAFile:
            return "invalid_ipa_file".localized
        case .installationFailed(let reason):
            return String(format: "install_failed_with_reason".localized, reason)
        case .networkError:
            return "network_error".localized
        case .timeoutError:
            return "install_timeout".localized
        }
    }
}

#if canImport(Vapor)
struct CORSMiddleware: Middleware {
    func respond(to request: Request, chainingTo next: Responder) -> EventLoopFuture<Response> {
        return next.respond(to: request).map { response in
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
            response.headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Authorization")
            return response
        }
    }
}
#endif

#if canImport(Vapor)
class SimpleHTTPServer: NSObject, @unchecked Sendable {
    public let port: Int
    private let host: String
    private let ipaPath: String
    private let appInfo: AppInfo
    private var app: Application?
    private var isRunning = false
    private let serverQueue = DispatchQueue(label: "simple.server.queue", qos: .userInitiated)
    private var plistData: Data?
    private var plistFileName: String?

    static func randomPort(excluding used: Set<Int> = []) -> Int {
        for _ in 0..<64 {
            let candidate = Int.random(in: 4000...8000)
            if !used.contains(candidate) { return candidate }
        }
        return Int.random(in: 4000...8000)
    }

    init(port: Int, host: String, ipaPath: String, appInfo: AppInfo) {
        self.port = port
        self.host = host
        self.ipaPath = ipaPath
        self.appInfo = appInfo
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        serverQueue.async { [weak self] in
            Task { @MainActor in
                await self?.startSimpleServer()
            }
        }
    }

    private func startSimpleServer() async {
        do {

            let config = Environment(name: "development", arguments: ["serve"])
            app = try await Application.make(config)

            app?.http.server.configuration.port = port
            app?.http.server.configuration.hostname = "0.0.0.0"
            app?.http.server.configuration.address = .hostname("0.0.0.0", port: port)
            app?.http.server.configuration.tcpNoDelay = true
            app?.http.server.configuration.requestDecompression = .enabled
            app?.http.server.configuration.responseCompression = .enabled
            app?.threadPool = .init(numberOfThreads: 2)
            app?.middleware.use(CORSMiddleware())

            guard let resourceURL = Bundle.main.resourceURL else {
                InstallLog.shared.add("install server failed: resource directory missing")
                isRunning = false
                return
            }
            let installDirectory = resourceURL.appendingPathComponent("InstallServer", isDirectory: true)
            let certPath = Bundle.main.path(forResource: "server", ofType: "pem")
                ?? installDirectory.appendingPathComponent("server.pem").path
            let keyPath = Bundle.main.path(forResource: "server", ofType: "key")
                ?? installDirectory.appendingPathComponent("server.key").path
            guard FileManager.default.fileExists(atPath: certPath),
                  FileManager.default.fileExists(atPath: keyPath),
                  let chain = try? NIOSSLCertificate.fromPEMFile(certPath),
                  !chain.isEmpty,
                  let privateKey = try? NIOSSLPrivateKey(file: keyPath, format: .pem)
            else {
                InstallLog.shared.add("install server failed: TLS certificate missing")
                isRunning = false
                return
            }
            app?.http.server.configuration.tlsConfiguration = TLSConfiguration.makeServerConfiguration(
                certificateChain: chain.map { .certificate($0) },
                privateKey: .privateKey(privateKey)
            )

            setupSimpleRoutes()

            isRunning = true
            InstallLog.shared.add("install server listening 0.0.0.0:\(port)")
            try await app?.execute()
            isRunning = false

        } catch {
            InstallLog.shared.add("install server failed: \(error.localizedDescription)")
            isRunning = false
        }
    }

    private func setupSimpleRoutes() {
        guard let app = app else { return }

        app.get("health") { req -> String in
            return "OK"
        }

        app.get("ipa", ":filename") { [weak self] req async throws -> Response in
            guard let self = self,
                  let filename = req.parameters.get("filename"),
                  filename == self.appInfo.bundleIdentifier else {
                return Response(status: .notFound)
            }
            guard FileManager.default.fileExists(atPath: self.ipaPath) else {
                return Response(status: .notFound)
            }

            return try await req.fileio.asyncStreamFile(at: self.ipaPath)
        }

        app.get(":filename") { [weak self] req async throws -> Response in
            guard let self = self,
                  let filename = req.parameters.get("filename"),
                  filename == "\(self.appInfo.bundleIdentifier).ipa" else {
                return Response(status: .notFound)
            }

            let shouldSign = req.query["sign"] == "1"

            let path: String
            if shouldSign {
                path = (try? self.signIPAIfNeeded()) ?? self.ipaPath
            } else {
                path = self.ipaPath
            }

            guard FileManager.default.fileExists(atPath: path) else {
                return Response(status: .notFound)
            }

            return try await req.fileio.asyncStreamFile(at: path)
        }

        app.get("plist", ":filename") { [weak self] req -> Response in
            guard let self = self,
                  let filename = req.parameters.get("filename"),
                  filename == self.appInfo.bundleIdentifier else {
                return Response(status: .notFound)
            }

            let plistData = self.generatePlistData()
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/xml")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: plistData)

            return response
        }

        app.get("i", ":encodedPath") { [weak self] req -> Response in
            guard let self = self,
                  let encodedPath = req.parameters.get("encodedPath") else {
                return Response(status: .notFound)
            }

            guard let decodedData = Data(base64Encoded: encodedPath.replacingOccurrences(of: ".plist", with: "")),
                  String(data: decodedData, encoding: .utf8) != nil else {
                return Response(status: .notFound)
            }

            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/xml")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: self.generatePlistData())

            return response
        }

        app.get("install") { [weak self] req -> Response in
            guard let self = self else {
                return Response(status: .internalServerError)
            }

            let localManifestURL = "https://\(installServerHost):\(self.port)/plist/\(self.appInfo.bundleIdentifier)"
            let localInstallURL = "itms-services://?action=download-manifest&url=\(queryEncoded(localManifestURL))"

            let installPage = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>\(htmlEscaped(String(format: "installing_app".localized, self.appInfo.name)))</title>
                <style>
                    * {
                        box-sizing: border-box;
                    }
                    body {
                        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                        margin: 0;
                        padding: 20px;
                        background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
                        color: white;
                        text-align: center;
                        min-height: 100vh;
                        display: flex;
                        flex-direction: column;
                        justify-content: center;
                        align-items: center;
                    }
                    .container {
                        background: rgba(255, 255, 255, 0.1);
                        padding: 30px;
                        border-radius: 20px;
                        backdrop-filter: blur(10px);
                        max-width: 400px;
                        width: 100%;
                        box-shadow: 0 8px 32px rgba(0, 0, 0, 0.1);
                    }
                    .app-icon {
                        width: 80px;
                        height: 80px;
                        background: #007AFF;
                        border-radius: 16px;
                        margin: 0 auto 20px;
                        display: flex;
                        align-items: center;
                        justify-content: center;
                        font-size: 40px;
                        box-shadow: 0 4px 16px rgba(0, 122, 255, 0.3);
                    }
                    .app-info {
                        margin-bottom: 20px;
                    }
                    .app-name {
                        font-size: 24px;
                        font-weight: 600;
                        margin: 0 0 8px 0;
                    }
                    .app-version {
                        font-size: 16px;
                        opacity: 0.8;
                        margin: 0 0 4px 0;
                    }
                    .app-bundle {
                        font-size: 12px;
                        opacity: 0.6;
                        margin: 0;
                    }
                    .status {
                        margin-top: 20px;
                        font-size: 16px;
                        opacity: 0.9;
                        min-height: 24px;
                    }
                    .loading {
                        display: inline-block;
                        width: 20px;
                        height: 20px;
                        border: 3px solid rgba(255,255,255,.3);
                        border-radius: 50%;
                        border-top-color: #fff;
                        animation: spin 1s ease-in-out infinite;
                        margin-right: 10px;
                    }
                    .success {
                        color: #4CAF50;
                    }
                    .error {
                        color: #f44336;
                    }
                    .manual-install {
                        margin-top: 20px;
                        padding: 15px;
                        background: rgba(255, 255, 255, 0.1);
                        border-radius: 10px;
                        font-size: 14px;
                    }
                    .install-button {
                        background: #007AFF;
                        color: white;
                        border: none;
                        padding: 12px 24px;
                        border-radius: 8px;
                        font-size: 16px;
                        font-weight: 600;
                        cursor: pointer;
                        margin-top: 10px;
                        transition: background 0.3s;
                    }
                    .install-button:hover {
                        background: #0056CC;
                    }
                    .install-button:disabled {
                        background: #666;
                        cursor: not-allowed;
                    }
                    @keyframes spin {
                        to { transform: rotate(360deg); }
                    }
                    @keyframes fadeIn {
                        from { opacity: 0; transform: translateY(20px); }
                        to { opacity: 1; transform: translateY(0); }
                    }
                    .fade-in {
                        animation: fadeIn 0.5s ease-out;
                    }
                </style>
            </head>
            <body>
                <div class="container fade-in">
                    <div class="app-icon">📱</div>
                    <div class="app-info">
                        <h1 class="app-name">\(htmlEscaped(self.appInfo.name))</h1>
                        <p class="app-version">\(htmlEscaped(String(format: "version_x".localized, self.appInfo.version)))</p>
                        <p class="app-bundle">\(htmlEscaped(self.appInfo.bundleIdentifier))</p>
                    </div>

                    <div class="status" id="status">
                        <span class="loading"></span>\("install_starting".localized)
                    </div>

                    <div class="manual-install" id="manualInstall" style="display: none;">
                        <p>\("install_manual_hint".localized)</p>
                        <button class="install-button" id="manualButton" onclick="manualInstall()">
                            \("manual_install".localized)
                        </button>
                    </div>
                </div>

                <script>
                    let manifestURL = '';
                    let itmsURL = '';
                    let isInstalling = false;
                    let installSuccess = false;

                    window.onload = function() {
                        console.log('页面加载完成，开始自动安装...');
                        initializeInstallation();
                    };

                    function initializeInstallation() {
                        manifestURL = '\(localManifestURL)';
                        itmsURL = '\(localInstallURL)';

                        console.log('Manifest URL:', manifestURL);
                        console.log('ITMS URL:', itmsURL);

                        setTimeout(function() {
                            autoInstall();
                        }, 1000);
                    }

                    function autoInstall() {
                        if (isInstalling || installSuccess) {
                            console.log('安装正在进行中或已成功，跳过重复调用');
                            return;
                        }

                        const status = document.getElementById('status');
                        const manualInstall = document.getElementById('manualInstall');

                        isInstalling = true;
                        status.innerHTML = '<span class="loading"></span>\("install_starting".localized)';

                        console.log('开始安装尝试');

                        try {
                            window.location.href = itmsURL;
                            status.innerHTML = '<span class="success">\("install_auto_started".localized)</span>';
                            installSuccess = true;

                            console.log('安装程序启动成功');

                            setTimeout(function() {
                                if (installSuccess) {
                                    status.innerHTML = '<span class="success">✅ \("install_success_desc".localized)</span>';
                                    document.body.innerHTML = '<div class="container fade-in" style="text-align: center; padding: 50px; color: white;"><div class="app-icon">✅</div><h1>\("install_success".localized)</h1><p>\("install_success_desc".localized)</p><p style="font-size: 12px; opacity: 0.6;">\("install_contact_author".localized)</p></div>';
                                }
                            }, 3000);

                        } catch (error) {
                            console.error('安装失败:', error);
                            status.innerHTML = '<span class="error">❌ \("install_start_failed".localized)</span>';
                            manualInstall.style.display = 'block';
                            isInstalling = false;
                        }
                    }

                    function manualInstall() {
                        if (isInstalling || installSuccess) {
                            console.log('安装正在进行中或已成功，忽略手动安装');
                            return;
                        }

                        const button = document.getElementById('manualButton');
                        const status = document.getElementById('status');

                        button.disabled = true;
                        button.textContent = '\("installing".localized)';
                        status.innerHTML = '<span class="loading"></span>\("install_manual_triggering".localized)';
                        isInstalling = true;

                        try {
                            window.location.href = itmsURL;
                            status.innerHTML = '<span class="success">\("install_manual_started".localized)</span>';
                            installSuccess = true;
                        } catch (error) {
                            status.innerHTML = '<span class="error">\("install_manual_failed".localized)' + error.message + '</span>';
                            button.disabled = false;
                            button.textContent = '\("retry_install".localized)';
                            isInstalling = false;
                        }
                    }
                </script>
            </body>
            </html>
            """

            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "text/html")
            response.body = .init(string: installPage)

            return response
        }

        app.get("icon", "display") { [weak self] req -> Response in
            guard let self = self else {
                return Response(status: .internalServerError)
            }

            let iconData = self.getDefaultIconData()
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "image/png")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: iconData)

            return response
        }

        app.get("icon", "fullsize") { [weak self] req -> Response in
            guard let self = self else {
                return Response(status: .internalServerError)
            }

            let iconData = self.getDefaultIconData()
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "image/png")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: iconData)

            return response
        }

    }

    func stop() {

        serverQueue.async { [weak self] in
            self?.app?.shutdown()
            DispatchQueue.main.async { self?.isRunning = false }
        }
    }

    func setPlistData(_ data: Data, fileName: String) {
        self.plistData = data
        self.plistFileName = fileName
    }

    func generatePlistData() -> Data {
        let ipaURL = "https://\(installServerHost):\(port)/\(appInfo.bundleIdentifier).ipa?sign=1"

        let plistContent: [String: Any] = [
            "items": [[
                "assets": [
                    [
                        "kind": "software-package",
                        "url": ipaURL
                    ]
                ],
                "metadata": [
                    "bundle-identifier": appInfo.bundleIdentifier,
                    "bundle-version": appInfo.version,
                    "kind": "software",
                    "title": appInfo.name
                ]
            ]]
        ]

        guard let plistData = try? PropertyListSerialization.data(
            fromPropertyList: plistContent,
            format: .xml,
            options: .zero
        ) else {
            return Data()
        }

        return plistData
    }

    private func signIPAIfNeeded() throws -> String {

        return ipaPath
    }

    private func getDisplayImageURL() -> String {

        return "https://\(installServerHost):\(port)/icon/display"
    }

    private func getFullSizeImageURL() -> String {

        return "https://\(installServerHost):\(port)/icon/fullsize"
    }

    private func getDefaultIconData() -> Data {

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 57, height: 57))
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 57, height: 57))
        }
        return image.pngData() ?? Data()
        #else

        let pngData = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
            0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0x0F, 0x00, 0x00,
            0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
            0x42, 0x60, 0x82
        ])
        return pngData
        #endif
    }
}
#endif

enum DownloadSheet: Identifiable {
    case details(DownloadRequest)
    case decryptedFiles

    var id: String {
        switch self {
        case .details(let request):
            return "details-\(request.id.uuidString)"
        case .decryptedFiles:
            return "decrypted-files"
        }
    }
}

struct DownloadView: SwiftUI.View {
    @StateObject private var vm: UnifiedDownloadManager = UnifiedDownloadManager.shared
    @State private var animateCards = true
    @State private var showSafariWebView = false
    @State private var safariURL: URL? = nil
    @State private var showThemeSelector = false
    @StateObject private var scrollTracker = ScrollVelocityTracker()
    @State private var decryptedCount = 0
    @State private var activeSheet: DownloadSheet?
    @State private var pendingShare: URL?
    @State private var pendingDelete: DownloadRequest?
    @State private var expandedRequestIDs: Set<UUID> = []

    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject private var globalInstallManager: GlobalInstallationManager
    @EnvironmentObject private var tabBarStyleManager: TabBarStyleManager

    @StateObject private var decryptCoordinator = DecryptCoordinator.shared

    var body: some SwiftUI.View {
        ZStack {
            LiquidGlassBackdrop()
                .environmentObject(themeManager)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                downloadManagementSegmentView
            }
        }

        .navigationTitle("download_title".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {
                    let impactMed = UIImpactFeedbackGenerator(style: .light)
                    impactMed.impactOccurred()
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showThemeSelector.toggle()
                    }
                }) {
                    Image(systemName: themeManager.selectedTheme == .light ? "sun.max.fill" : "moon.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(themeManager.selectedTheme == .light ? .orange : .blue)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(
            FloatingThemeSelector(isPresented: $showThemeSelector)
        )

        .onAppear {
            vm.syncDownloadStatus()
            refreshDecryptedCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            handleAppEnteredBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            handleAppBecameActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("DecryptedFilesChanged"))) { _ in
            refreshDecryptedCount()
        }
        .environmentObject(GlobalInstallationManager.shared)
        .overlay(alignment: .bottomTrailing) {
            decryptedFilesButton
        }
        .sheet(item: $activeSheet, onDismiss: { handleSheetDismissed() }) { sheet in
            sheetContent(sheet)
        }
        .confirmationDialog(
            "delete".localized,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { request in
            Button("delete_all".localized, role: .destructive) {
                deleteDownload(request)
                pendingDelete = nil
            }
            Button("cancel".localized, role: .cancel) {
                pendingDelete = nil
            }
        } message: { _ in
            Text("delete_decrypted_hint".localized)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: DownloadSheet) -> some SwiftUI.View {
        switch sheet {
        case .details(let request):
            if let path = request.localFilePath {
                IPADetailsView(
                    ipaURL: URL(fileURLWithPath: path),
                    appName: request.package.name
                )
                .environmentObject(themeManager)
            }
        case .decryptedFiles:
            DecryptedFilesView()
                .environmentObject(themeManager)
        }
    }

    private func handleSheetDismissed() {
        refreshDecryptedCount()

        guard let url = pendingShare else { return }
        pendingShare = nil
        showThemeSelector = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            Self.presentShareSheet(for: url)
        }
    }

    private func presentShare(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        showThemeSelector = false

        if activeSheet != nil {
            pendingShare = url
            activeSheet = nil
            return
        }

        guard pendingDelete == nil else { return }

        Self.presentShareSheet(for: url)
    }

    private func openDetails(for request: DownloadRequest) {
        guard request.localFilePath != nil else { return }
        activeSheet = .details(request)
    }

    private func requestDelete(_ request: DownloadRequest) {
        if Self.decryptedOutputURLs(for: request).isEmpty {
            deleteDownload(request)
        } else {
            pendingDelete = request
        }
    }

    private static func presentShareSheet(for url: URL) {
        #if canImport(UIKit)
        guard let presenter = topMostViewController() else { return }
        SoundEffects.play(.tap)

        let controller = UIActivityViewController(
            activityItems: [url],
            applicationActivities: nil
        )
        controller.setValue("share_ipa".localized, forKey: "subject")

        if let popover = controller.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }

        presenter.present(controller, animated: true)
        #endif
    }

    private static func topMostViewController() -> UIViewController? {
        #if canImport(UIKit)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first,
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
                ?? scene.windows.first?.rootViewController else {
            return nil
        }

        var current = root
        while let presented = current.presentedViewController, !presented.isBeingDismissed {
            current = presented
        }
        return current
        #else
        return nil
        #endif
    }

    private var decryptedFilesButton: some SwiftUI.View {
        Button {
            activeSheet = .decryptedFiles
        } label: {
            ZStack(alignment: .topTrailing) {
                Image("XcodeIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 52, height: 52)
                    .shadow(color: Color.black.opacity(0.28), radius: 10, y: 4)

                if decryptedCount > 0 {
                    Text(decryptedCount > 99 ? "99+" : "\(decryptedCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(
                            Circle()
                                .fill(Color.red)
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.white, lineWidth: 1.5)
                                )
                                .shadow(color: Color.black.opacity(0.2), radius: 3, y: 1)
                        )
                        .offset(x: 4, y: -4)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.trailing, 18)
        .padding(.bottom, tabBarStyleManager.currentStyle == .floatingCard ? 96 : 24)
    }

    private func refreshDecryptedCount() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: DecryptedFilesView.folderURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let count = urls.filter { $0.pathExtension.lowercased() == "ipa" }.count
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            decryptedCount = count
        }
    }

    private func handleAppEnteredBackground() {

        vm.saveDownloadTasks()

        if !vm.activeDownloads.isEmpty {
        }
    }

    private func handleAppBecameActive() {
        vm.syncDownloadStatus()
    }

    var downloadManagementSegmentView: some SwiftUI.View {
        List {
            Group {
                if vm.downloadRequests.isEmpty {
                    emptyStateView
                        .scaleEffect(animateCards ? 1 : 0.9)
                        .opacity(animateCards ? 1 : 0)
                        .animation(.spring().delay(0.1), value: animateCards)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .padding(.top, 40)
                } else {
                    ForEach(Array(vm.sortedDownloadRequests.enumerated()), id: \.element.id) { index, request in
                        DownloadCardView(
                            request: request,
                            isPreview: scrollTracker.isFast,
                            expandedRequestIDs: $expandedRequestIDs,
                            onOpenDetails: { openDetails(for: request) },
                            onShare: { presentShare($0) }
                        )
                        .scaleEffect(animateCards ? 1 : 0.9)
                        .opacity(animateCards ? 1 : 0)
                        .animation(Animation.spring().delay(Double(index) * 0.1), value: animateCards)
                        .animation(nil, value: scrollTracker.isFast)
                        .id(request.id)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !expandedRequestIDs.contains(request.id) {
                                if request.runtime.status == .completed,
                                   let localFilePath = request.localFilePath,
                                   FileManager.default.fileExists(atPath: localFilePath) {
                                    Button {
                                        presentShare(URL(fileURLWithPath: localFilePath))
                                    } label: {
                                        Label("share".localized, systemImage: "square.and.arrow.up")
                                    }
                                    .tint(.blue)
                                }

                                Button(role: .destructive) {
                                    requestDelete(request)
                                } label: {
                                    Label("delete".localized, systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .preference(key: DownloadScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("downloadScroll")).origin.y)
                }
            )
            .onPreferenceChange(DownloadScrollOffsetPreferenceKey.self) { value in
                scrollTracker.update(offset: value)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .scrollEdgeFade()
        .coordinateSpace(name: "downloadScroll")
        .refreshable {
            vm.syncDownloadStatus()
        }
    }

    private var emptyStateView: some SwiftUI.View {
        VStack(spacing: 32) {

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .cornerRadius(24)
                .scaleEffect(animateCards ? 1.1 : 1)
                .opacity(animateCards ? 1 : 0.7)
                .animation(
                    Animation.easeInOut(duration: 2).repeatForever(autoreverses: true),
                    value: animateCards
                )

            Button(action: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                guard let url = URL(string: "https://github.com/pxx917144686"),
                    UIApplication.shared.canOpenURL(url) else {
                    return
                }
                UIApplication.shared.open(url)
            }) {
                HStack(spacing: 16) {
                    Text("view_source_code".localized)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.75)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .shadow(color: themeManager.accentColor.opacity(colorScheme == .dark ? 0.5 : 0.3), radius: colorScheme == .dark ? 12 : 8, x: 0, y: 4)
            }
            .buttonStyle(ScaleButtonStyle())

            .frame(maxWidth: 200)
            .padding(.horizontal, 8)

            VStack(spacing: 8) {
                Text("no_downloads".localized)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.primary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 32)
    }

    private static func decryptedOutputURLs(for request: DownloadRequest) -> [URL] {
        guard let path = request.localFilePath else { return [] }
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = documents.appendingPathComponent("Decrypted", isDirectory: true)
        return ["-decrypted.ipa", "-PARTIAL.ipa"].compactMap { suffix in
            let url = folder.appendingPathComponent(stem + suffix)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func deleteDownload(_ request: DownloadRequest) {
        SoundEffects.play(.dismiss)
        expandedRequestIDs.remove(request.id)

        if case .details(let current)? = activeSheet, current.id == request.id {
            activeSheet = nil
        }

        UnifiedDownloadManager.shared.deleteDownload(request: request)
        UnifiedDownloadManager.shared.saveDownloadTasks()

        let manager = FileManager.default
        if let localFilePath = request.localFilePath {
            try? manager.removeItem(atPath: localFilePath)
        }
        for url in Self.decryptedOutputURLs(for: request) {
            try? manager.removeItem(at: url)
        }

        refreshDecryptedCount()
        NotificationCenter.default.post(name: NSNotification.Name("ForceRefreshUI"), object: nil)
    }

}

struct DownloadScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}


struct DownloadCardView: SwiftUI.View {
    @ObservedObject var request: DownloadRequest
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var themeManager: ThemeManager
    var isPreview: Bool = false
    @Binding var expandedRequestIDs: Set<UUID>
    var onOpenDetails: () -> Void = {}
    var onShare: (URL) -> Void = { _ in }

    @State private var isInstalling = false
    @State private var installationProgress: Double = 0.0
    @State private var installationMessage: String = ""

    @State private var isDecrypting = false
    @State private var decryptMessage: String?
    @State private var decryptedURL: URL?
    @State private var decryptTask: Task<Void, Never>?
    @State private var fileSizeText: String?
    @State private var decryptOutcome: DecryptConsoleOutcome = .idle
    @State private var isConsoleCollapsed = false
    @StateObject private var decryptLog = DecryptLog()

    private var progress: Double {
        request.runtime.progressValue
    }

    private var status: DownloadStatus {
        request.runtime.status
    }

    private var showsConsole: Bool {
        isDecrypting || !decryptLog.lines.isEmpty
    }

    private var isRowExpanded: Bool {
        showsConsole && !isConsoleCollapsed
    }

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            topSection

            if shouldShowProgress {
                WindowsTransferProgressView(
                    progress: progress,
                    status: status,
                    error: request.runtime.error,
                    accentColor: themeManager.accentColor,
                    speed: request.runtime.speed.isEmpty ? nil : request.runtime.speed,
                    completedBytes: request.runtime.completedBytes,
                    totalBytes: request.runtime.totalBytes,
                    remainingTime: request.runtime.remainingTime,
                    isPreview: isPreview
                )
            }

            if status == DownloadStatus.completed {
                completedStatusView

                if !installationMessage.isEmpty && !isDecrypting {
                    installStatusView
                }

                if showsConsole {
                    if isConsoleCollapsed {
                        collapsedConsoleBar
                            .transition(.opacity)
                    } else {
                        DecryptConsoleView(
                            log: decryptLog,
                            outcome: decryptOutcome,
                            appName: request.package.name,
                            bundleIdentifier: request.package.bundleIdentifier,
                            message: decryptMessage,
                            decryptedURL: decryptedURL,
                            accentColor: themeManager.accentColor,
                            onCancel: {
                                DecryptCoordinator.shared.cancel()
                            },
                            onShare: {
                                if let url = decryptedURL {
                                    onShare(url)
                                }
                            },
                            onCollapse: {
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                                    isConsoleCollapsed = true
                                }
                            }
                        )
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .move(edge: .top)).combined(with: .scale(scale: 0.98, anchor: .top)),
                                removal: .opacity
                            )
                        )
                    }
                } else if let decryptMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Text(decryptMessage)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 4)

                        if let url = decryptedURL {
                            Button {
                                onShare(url)
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(themeManager.accentColor)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("dc_share_decrypted".localized)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(
                    color: colorScheme == .dark ? Color.black.opacity(0.4) : Color.black.opacity(0.08),
                    radius: colorScheme == .dark ? 10 : 6,
                    x: 0,
                    y: 2
                )
        )
        .onAppear {
            loadExistingDecrypted()
            fileSizeText = request.localFilePath.flatMap { getFileSize(path: $0) }
            syncExpansionState()
        }
        .onChange(of: request.localFilePath) { _, _ in
            fileSizeText = request.localFilePath.flatMap { getFileSize(path: $0) }
        }
        .onChange(of: isRowExpanded) { _, _ in
            syncExpansionState()
        }
        .onDisappear {
            expandedRequestIDs.remove(request.id)
        }
        .id(request.id)
    }

    private func syncExpansionState() {
        if isRowExpanded {
            expandedRequestIDs.insert(request.id)
        } else {
            expandedRequestIDs.remove(request.id)
        }
    }

    private var collapsedConsoleBar: some SwiftUI.View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                isConsoleCollapsed = false
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: decryptOutcome == .completed ? "checkmark.shield.fill" : "lock.open.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(decryptOutcome == .completed ? Color.green : themeManager.accentColor)

                Text("dc_console_title".localized)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(collapsedConsoleStatus)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("dc_expand_log".localized)
    }

    private var collapsedConsoleStatus: String {
        switch decryptOutcome {
        case .idle: return "dc_phase_prepare".localized
        case .running: return "dc_status_running".localized
        case .completed: return "dc_status_completed".localized
        case .failed: return "dc_status_failed".localized
        case .cancelled: return "dc_status_cancelled".localized
        }
    }

    private var shouldShowProgress: Bool {
        request.runtime.status == DownloadStatus.downloading ||
        request.runtime.status == DownloadStatus.waiting ||
        request.runtime.status == DownloadStatus.paused ||
        request.runtime.progressValue >= 0
    }

    private var topSection: some SwiftUI.View {
        HStack(alignment: .top, spacing: 10) {
            appIconView
            appInfoView
            Spacer(minLength: 6)
            actionButtonView
        }
        .contentShape(Rectangle())
        .onTapGesture {
            handleCardTap()
        }
    }

    private var appIconView: some SwiftUI.View {
        Group {
            if let iconURL = request.package.iconURL, let url = URL(string: iconURL) {
                ResourceImage(
                    url: url,
                    pointSize: CGSize(width: 52, height: 52),
                    contentMode: .fill,
                    cornerRadius: 12,
                    showsBorder: true
                )
                .frame(width: 52, height: 52)
            } else {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .overlay(
                        Image(systemName: "app.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.secondary)
                    )
                    .frame(width: 52, height: 52)
            }
        }
    }

    private var appInfoView: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 2) {
            Text(request.package.name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Text(request.package.bundleIdentifier)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(String(format: "version_x".localized, request.version))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let fileSizeText {
                Text(String(format: "file_size_x".localized, fileSizeText))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtonView: some SwiftUI.View {
        HStack(spacing: 6) {
            if status == DownloadStatus.completed, request.localFilePath != nil {
                decryptButton
            }
            primaryActionButton
        }
    }

    private var decryptGradient: [Color] {
        if isDecrypting {
            return [Color(red: 0.95, green: 0.31, blue: 0.28),
                    Color(red: 0.82, green: 0.18, blue: 0.20)]
        }
        return [themeManager.accentColor, themeManager.accentColor.opacity(0.85)]
    }

    private var decryptButton: some SwiftUI.View {
        Button {
            if isDecrypting {
                DecryptCoordinator.shared.cancel()
                return
            }
            startDecrypt()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: isDecrypting
                      ? "xmark.circle.fill"
                      : (decryptedURL != nil ? "checkmark.circle.fill" : "lock.open.fill"))
                    .font(.system(size: 12, weight: .bold))

                Text(isDecrypting ? "dc_cancel".localized : "dc_action".localized)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundColor(.white)
            .frame(width: 88, height: 34)
            .background(
                LinearGradient(colors: decryptGradient,
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Capsule())
            .shadow(color: decryptGradient[1].opacity(0.35), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(DecryptCoordinator.shared.isBusy
                  && DecryptCoordinator.shared.activeRequestID != request.id)
    }

    private func startDecrypt() {
        guard let path = request.localFilePath else { return }
        guard FairPlayDecryptor.isAvailable else {
            let report = AppGroupDiagnostics.inspect()
            decryptMessage = report.headline + "\n" + report.facts
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                decryptOutcome = .failed
            }
            decryptLog.reset(title: "NOGROUP")
            for line in report.facts.split(separator: "\n") {
                decryptLog.append(String(line), level: .failure)
            }
            decryptLog.finish()
            return
        }
        if DecryptCoordinator.shared.isBusy {
            if DecryptCoordinator.shared.activeRequestID == request.id { return }
            decryptMessage = "dc_err_busy".localized
            return
        }

        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            isConsoleCollapsed = false
            isDecrypting = true
            decryptOutcome = .running
        }
        decryptMessage = nil
        decryptLog.reset(title: "INIT")
        decryptLog.append("target  \(URL(fileURLWithPath: path).lastPathComponent)", level: .info)

        let log = decryptLog
        let token = DecryptCoordinator.shared.begin(requestID: request.id)

        var backgroundTask: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier.invalid
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "decrypt") {
            if backgroundTask != UIBackgroundTaskIdentifier.invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = UIBackgroundTaskIdentifier.invalid
            }
        }

        let task = Task {
            let record = await DecryptService.decryptFull(ipaPath: path, cancelToken: token) { event in
                log.consume(event)
            }
            await MainActor.run {
                if backgroundTask != UIBackgroundTaskIdentifier.invalid {
                    UIApplication.shared.endBackgroundTask(backgroundTask)
                }
                let finalOutcome: DecryptConsoleOutcome
                if record.status == .completed {
                    finalOutcome = .completed
                } else if record.message == "dc_err_cancelled".localized {
                    finalOutcome = .cancelled
                } else {
                    finalOutcome = .failed
                }
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    isDecrypting = false
                    decryptOutcome = finalOutcome
                }
                log.finish()
                DecryptCoordinator.shared.finish(requestID: request.id)

                if record.status == .completed, let output = record.outputPath {
                    decryptedURL = URL(fileURLWithPath: output)
                    decryptMessage = record.message
                    NotificationCenter.default.post(name: NSNotification.Name("DecryptedFilesChanged"), object: nil)
                    let outputURL = URL(fileURLWithPath: output)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        onShare(outputURL)
                    }
                } else {
                    decryptMessage = record.message ?? "dc_status_failed".localized
                }
            }
        }
        decryptTask = task
    }

    private func loadExistingDecrypted() {
        guard decryptedURL == nil, let path = request.localFilePath else { return }
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent

        Task.detached(priority: .utility) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let folder = documents.appendingPathComponent("Decrypted", isDirectory: true)
            var found: URL?
            for suffix in ["-decrypted.ipa", "-PARTIAL.ipa"] {
                let candidate = folder.appendingPathComponent(stem + suffix)
                if FileManager.default.fileExists(atPath: candidate.path) {
                    found = candidate
                    break
                }
            }
            guard let found else { return }
            await MainActor.run { decryptedURL = found }
        }
    }

    @ViewBuilder
    private var primaryActionButton: some SwiftUI.View {
        switch request.runtime.status {
        case .downloading:
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                UnifiedDownloadManager.shared.pauseDownload(request: request)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("download_pause".localized)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(themeManager.accentColor)
                .frame(width: 76, height: 32)
                .background(
                    Capsule()
                        .fill(themeManager.accentColor.opacity(0.12))
                )
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("download_pause".localized)

        case .paused:
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                UnifiedDownloadManager.shared.resumeDownload(request: request)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .bold))
                    Text("download_resume".localized)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(themeManager.accentColor)
                .frame(width: 76, height: 32)
                .background(
                    Capsule()
                        .fill(themeManager.accentColor.opacity(0.12))
                )
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("download_resume".localized)

        case .waiting:
            EmptyView()

        case .failed, .cancelled:
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                retryDownload()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .bold))
                    Text("retry".localized)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.orange)
                .frame(width: 76, height: 32)
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.12))
                )
            }
            .buttonStyle(ScaleButtonStyle())
            .accessibilityLabel("retry".localized)

        case .completed:
            if request.localFilePath != nil {
                Button {
                    guard !isInstalling else { return }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    startInstallation(for: request)
                } label: {
                    HStack(spacing: 4) {
                        if isInstalling {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.down.forward.app.fill")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text(isInstalling ? "installing".localized : "install".localized)
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .frame(width: 84, height: 34)
                    .background(
                        LinearGradient(
                            colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(Capsule())
                    .shadow(color: themeManager.accentColor.opacity(0.4), radius: 6, x: 0, y: 3)
                    .opacity(isInstalling ? 0.85 : 1.0)
                }
                .buttonStyle(ScaleButtonStyle())
                .disabled(isInstalling)
                .accessibilityLabel(isInstalling ? "installing".localized : "install".localized)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.green)
                    .accessibilityLabel("download_completed".localized)
            }
        }
    }

    private var completedStatusView: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)

                Text("file_saved_to".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            HStack(alignment: .top, spacing: 6) {
                Text(request.localFilePath ?? "unknown_path".localized)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                Spacer(minLength: 4)

                Button {
                    onOpenDetails()
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(themeManager.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(request.localFilePath == nil)
                .opacity(request.localFilePath == nil ? 0 : 1)
                .accessibilityLabel("detail_action".localized)
            }
        }
    }

    private var installStatusView: some SwiftUI.View {
        HStack(alignment: .top, spacing: 6) {
            if isInstalling {
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
            }

            Text(installationMessage)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)
        }
        .padding(.top, 2)
    }

    private func handleCardTap() {
        if isRowExpanded { return }
        if request.runtime.status == .completed, request.localFilePath != nil {
            onOpenDetails()
        }
    }

    private func getFileSize(path: String) -> String? {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            if let fileSize = attributes[.size] as? Int64 {
                let formatter = ByteCountFormatter()
                formatter.allowedUnits = [.useMB, .useGB]
                formatter.countStyle = .file
                return formatter.string(fromByteCount: fileSize)
            }
        } catch {
        }
        return nil
    }

    private func retryDownload() {
        UnifiedDownloadManager.shared.resumeDownload(request: request)
    }

    private func startInstallation(for request: DownloadRequest) {
        guard let localFilePath = request.localFilePath, FileManager.default.fileExists(atPath: localFilePath) else {
            installationMessage = "ipa_not_found".localized
            return
        }
        guard GlobalInstallationManager.shared.startInstallation(for: request.id, title: request.name) else {
            installationMessage = "dc_err_busy".localized
            return
        }

        SoundEffects.play(.press)
        isInstalling = true
        installationProgress = 0.0
        installationMessage = "preparing_install".localized

        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask {
            DispatchQueue.main.async {
                guard backgroundTaskID != .invalid else { return }
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
                backgroundTaskID = .invalid
                installationMessage = "install_bg_expired".localized
                isInstalling = false
            }
        }

        Task {
            do {
                let ipaMetadata = readIPAInfo(at: localFilePath)
                var bundleIdentifier = ipaMetadata?.bundleIdentifier ?? request.bundleIdentifier
                var version = ipaMetadata?.version ?? request.version
                var displayName = ipaMetadata?.name ?? request.name

                if bundleIdentifier.isEmpty, request.package.identifier > 0 {
                    bundleIdentifier = await delistedBundleIdentifier(trackId: request.package.identifier)
                }
                guard !bundleIdentifier.isEmpty else {
                    throw PackageInstallationError.invalidIPAFile
                }
                if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { displayName = bundleIdentifier }
                if version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { version = "1.0" }

                let appInfo = AppInfo(
                    name: displayName,
                    version: version,
                    bundleIdentifier: bundleIdentifier,
                    path: localFilePath,
                    localPath: localFilePath
                )

                await MainActor.run {
                    installationProgress = 0.2
                    installationMessage = "verifying_package".localized
                }

                let fileAttributes = try FileManager.default.attributesOfItem(atPath: localFilePath)
                guard let fileSize = fileAttributes[.size] as? Int64, fileSize > 0,
                      localFilePath.hasSuffix(".ipa") else {
                    throw PackageInstallationError.invalidIPAFile
                }

                await MainActor.run {
                    installationProgress = 0.4
                    installationMessage = "starting_install_service".localized
                }

                let port = HTTPServerManager.shared.allocatePort()
                let host = currentLocalIPv4() ?? "127.0.0.1"

                HTTPServerManager.shared.startServer(
                    for: request.id,
                    port: port,
                    host: host,
                    ipaPath: localFilePath,
                    appInfo: appInfo
                )

                await MainActor.run {
                    installationProgress = 0.6
                    installationMessage = "preparing_install_link".localized
                }

                let installSession = URLSession(configuration: {
                    let configuration = URLSessionConfiguration.ephemeral
                    configuration.timeoutIntervalForRequest = 6
                    configuration.timeoutIntervalForResource = 15
                    configuration.connectionProxyDictionary = [:]
                    return configuration
                }())

                let healthURL = "https://\(installServerHost):\(port)/health"
                var serverReady = false
                var lastProbeError: Error?
                for _ in 1...20 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    guard let url = URL(string: healthURL) else { break }
                    do {
                        let (_, response) = try await installSession.data(from: url)
                        if let httpResponse = response as? HTTPURLResponse,
                           httpResponse.statusCode == 200 {
                            serverReady = true
                            break
                        }
                    } catch {
                        lastProbeError = error
                    }
                }

                guard serverReady else {
                    SoundEffects.play(.error)
                    let resolvedAddress = resolveIPv4(installServerHost)
                    let detail = lastProbeError?.localizedDescription ?? resolvedAddress ?? "unavailable"
                    await MainActor.run {
                        installationMessage = "install_failed_title".localized
                        if let resolvedAddress, resolvedAddress != "127.0.0.1" {
                            presentInstallAlert(
                                String(format: "install_dns_failed".localized, resolvedAddress),
                                title: "install_dns_failed_title".localized
                            )
                        } else {
                            presentInstallAlert(
                                String(format: "install_tls_failed".localized, detail),
                                title: "install_tls_failed_title".localized
                            )
                        }
                        cleanupInstallation(request.id, failureReason: installationMessage)
                    }
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                    }
                    return
                }

                let manifestURL = "https://\(installServerHost):\(port)/plist/\(bundleIdentifier)"
                var manifestReady = false
                var manifestError: Error?
                if let url = URL(string: manifestURL) {
                    do {
                        let (data, response) = try await installSession.data(from: url)
                        if let httpResponse = response as? HTTPURLResponse,
                           httpResponse.statusCode == 200,
                           String(data: data, encoding: .utf8)?.contains("<plist") == true {
                            manifestReady = true
                        }
                    } catch {
                        manifestError = error
                    }
                }

                guard manifestReady else {
                    SoundEffects.play(.error)
                    let detail = manifestError?.localizedDescription ?? "unavailable"
                    await MainActor.run {
                        installationMessage = "install_manifest_failed".localized
                        presentInstallAlert(
                            String(format: "install_manifest_failed_detail".localized, detail),
                            title: "install_failed_title".localized
                        )
                        cleanupInstallation(request.id, failureReason: installationMessage)
                    }
                    if backgroundTaskID != .invalid {
                        UIApplication.shared.endBackgroundTask(backgroundTaskID)
                        backgroundTaskID = .invalid
                    }
                    return
                }

                await MainActor.run {
                    installationProgress = 0.8
                    installationMessage = "opening_install_page".localized
                    GlobalInstallationManager.shared.updateInstallationStep(
                        for: request.id,
                        step: "install_stage_opening_system".localized
                    )

                    let itmsURLString = "itms-services://?action=download-manifest&url=" + queryEncoded(manifestURL)

                    guard let itmsURL = URL(string: itmsURLString) else {
                        SoundEffects.play(.error)
                        installationMessage = "install_start_failed".localized
                        cleanupInstallation(request.id, failureReason: installationMessage)
                        return
                    }

                    guard UIApplication.shared.canOpenURL(itmsURL) else {
                        SoundEffects.play(.error)
                        installationMessage = "install_start_failed".localized
                        presentInstallAlert("install_open_rejected".localized)
                        cleanupInstallation(request.id, failureReason: installationMessage)
                        return
                    }

                    UIApplication.shared.open(itmsURL, options: [:]) { success in
                        DispatchQueue.main.async {
                            if success {
                                SoundEffects.play(.attention)
                                installationMessage = "install_handed_off".localized
                                isInstalling = false
                                cleanupInstallation(request.id, keepServer: true)
                            } else {
                                SoundEffects.play(.error)
                                installationMessage = "install_start_failed".localized
                                presentInstallAlert("install_open_failed".localized)
                                cleanupInstallation(request.id, failureReason: installationMessage)
                            }
                        }
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                }

            } catch {
                await MainActor.run {
                    installationMessage = error.localizedDescription
                    isInstalling = false
                    installationProgress = 0.0

                    HTTPServerManager.shared.stopServer(for: request.id)
                    GlobalInstallationManager.shared.failInstallation(
                        for: request.id,
                        reason: error.localizedDescription
                    )
                }
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
    }

    private func cleanupInstallation(
        _ requestId: UUID,
        keepServer: Bool = false,
        failureReason: String? = nil
    ) {

        Task {
            await MainActor.run {
                isInstalling = false
                installationProgress = 0.0
                if let failureReason {
                    GlobalInstallationManager.shared.failInstallation(for: requestId, reason: failureReason)
                } else {
                    GlobalInstallationManager.shared.finishInstallation(for: requestId)
                }

                if !keepServer {
                    HTTPServerManager.shared.stopServer(for: requestId)
                } else {

                    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 600) {

                        Task {
                            await MainActor.run {
                                HTTPServerManager.shared.stopServer(for: requestId)
                            }
                        }
                    }
                }
            }
        }
    }
}

private func queryEncoded(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func delistedBundleIdentifier(trackId: Int) async -> String {
    if let url = URL(string: "https://itunes.apple.com/lookup?id=\(trackId)") {
        if let (data, _) = try? await URLSession.shared.data(from: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let results = json["results"] as? [[String: Any]],
           let bundle = results.first?["bundleId"] as? String,
           !bundle.isEmpty {
            return bundle
        }
    }

    let manager = FileManager.default
    let documents = manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let searchDirectories = [
        documents.appendingPathComponent("Downloads", isDirectory: true),
        documents
    ]

    for directory in searchDirectories {
        let ipaFiles = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []

        for ipa in ipaFiles where ipa.pathExtension.lowercased() == "ipa" {
            guard let mapped = try? Data(contentsOf: ipa, options: .alwaysMapped),
                  let eocd = FastZipArchive.findEndOfCentralDirectory(in: mapped),
                  let entries = try? FastZipArchive.readCentralDirectory(from: mapped, eocd: eocd)
            else { continue }

            guard let metadataEntry = entries.first(where: { $0.filename == "iTunesMetadata.plist" }),
                  let metadataData = try? FastZipArchive.extractSingleEntry(from: mapped, entry: metadataEntry),
                  let metadata = try? PropertyListSerialization.propertyList(
                      from: metadataData, format: nil
                  ) as? [String: Any],
                  (metadata["trackId"] as? Int) == trackId ||
                      (metadata["adamId"] as? Int) == trackId ||
                      ((metadata["trackId"] as? String) == String(trackId))
            else { continue }

            guard let infoEntry = entries.first(where: {
                $0.filename.hasPrefix("Payload/") && $0.filename.hasSuffix(".app/Info.plist")
            }),
                  let infoData = try? FastZipArchive.extractSingleEntry(from: mapped, entry: infoEntry),
                  let info = try? PropertyListSerialization.propertyList(
                      from: infoData, format: nil
                  ) as? [String: Any],
                  let bundle = info["CFBundleIdentifier"] as? String,
                  !bundle.isEmpty
            else { continue }

            return bundle
        }
    }

    return ""
}

private struct IPAInstallMetadata {
    let bundleIdentifier: String
    let version: String
    let name: String
}

private func readIPAInfo(at path: String) -> IPAInstallMetadata? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped),
          let eocd = FastZipArchive.findEndOfCentralDirectory(in: data),
          let entries = try? FastZipArchive.readCentralDirectory(from: data, eocd: eocd),
          let infoEntry = entries.first(where: {
              $0.filename.hasPrefix("Payload/") && $0.filename.hasSuffix(".app/Info.plist")
          }),
          let infoData = try? FastZipArchive.extractSingleEntry(from: data, entry: infoEntry),
          let info = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let bundleIdentifier = info["CFBundleIdentifier"] as? String,
          !bundleIdentifier.isEmpty
    else { return nil }

    let version = (info["CFBundleShortVersionString"] as? String)
        ?? (info["CFBundleVersion"] as? String)
        ?? "1.0"
    let name = (info["CFBundleDisplayName"] as? String)
        ?? (info["CFBundleName"] as? String)
        ?? bundleIdentifier
    return IPAInstallMetadata(bundleIdentifier: bundleIdentifier, version: version, name: name)
}

private func resolveIPv4(_ host: String) -> String? {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var info: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return nil }
    defer { freeaddrinfo(first) }

    var pointer: UnsafeMutablePointer<addrinfo>? = first
    while let item = pointer {
        defer { pointer = item.pointee.ai_next }
        guard let address = item.pointee.ai_addr else { continue }
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(address, item.pointee.ai_addrlen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
            let value = String(cString: hostBuffer)
            if !value.isEmpty { return value }
        }
    }
    return nil
}

private func htmlEscaped(_ text: String) -> String {
    var result = text
    result = result.replacingOccurrences(of: "&", with: "&amp;")
    result = result.replacingOccurrences(of: "<", with: "&lt;")
    result = result.replacingOccurrences(of: ">", with: "&gt;")
    result = result.replacingOccurrences(of: "\"", with: "&quot;")
    result = result.replacingOccurrences(of: "'", with: "&#39;")
    return result
}

func currentLocalIPv4() -> String? {
    var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else { return nil }
    defer { freeifaddrs(ifaddrPointer) }

    var preferred: String?
    var fallback: String?
    var pointer = first
    while true {
        let interface = pointer.pointee
        if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            let lowerName = name.lowercased()
            let isVirtual = lowerName.hasPrefix("utun") || lowerName.hasPrefix("tap") ||
                lowerName.hasPrefix("tun") || lowerName.hasPrefix("ipsec") ||
                lowerName.hasPrefix("wg") || lowerName.hasPrefix("ppp") ||
                lowerName.hasPrefix("awdl") || lowerName.hasPrefix("llw")
            var address = interface.ifa_addr.pointee
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                &address,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let ip = String(cString: hostBuffer)
                if !isVirtual && !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") {
                    if name == "en0" {
                        preferred = ip
                    } else if fallback == nil {
                        fallback = ip
                    }
                }
            }
        }
        guard let next = interface.ifa_next else { break }
        pointer = next
    }
    return preferred ?? fallback
}

#if canImport(UIKit)
func presentInstallAlert(_ message: String, title: String = "install_failed_title".localized) {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first,
          let root = window.rootViewController else { return }

    var top = root
    while let presented = top.presentedViewController {
        top = presented
    }

    let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "ok".localized, style: .default))
    top.present(alert, animated: true)
}
#endif
