
import SwiftUI
import Combine
import Foundation
import Network

#if canImport(UIKit)
import UIKit
import SafariServices
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

    func startInstallation(for requestId: UUID) -> Bool {
        guard !isAnyInstalling else { return false }
        isAnyInstalling = true
        currentInstallingRequestId = requestId
        return true
    }

    func finishInstallation() {
        isAnyInstalling = false
        currentInstallingRequestId = nil
    }

    func finishInstallation(for requestId: UUID) {

        if currentInstallingRequestId == requestId || currentInstallingRequestId == nil {
            isAnyInstalling = false
            currentInstallingRequestId = nil
        }
    }
}

@MainActor
class HTTPServerManager: ObservableObject, @unchecked Sendable {
    static let shared = HTTPServerManager()
    private var activeServers: [UUID: SimpleHTTPServer] = [:]

    private init() {}

    func startServer(for requestId: UUID, port: Int, ipaPath: String, appInfo: AppInfo) {
        let server = SimpleHTTPServer(port: port, ipaPath: ipaPath, appInfo: appInfo)
        server.start()
        activeServers[requestId] = server
    }

    func stopServer(for requestId: UUID) {
        if let server = activeServers[requestId] {
            server.stop()
            activeServers.removeValue(forKey: requestId)
        }
    }

    func stopAllServers() {
        for server in activeServers.values {
            server.stop()
        }
        activeServers.removeAll()
    }
}

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
                    .fill(Color(.secondarySystemBackground))
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
    private let ipaPath: String
    private let appInfo: AppInfo
    private var app: Application?
    private var isRunning = false
    private let serverQueue = DispatchQueue(label: "simple.server.queue", qos: .userInitiated)
    private var plistData: Data?
    private var plistFileName: String?

    static func randomPort() -> Int {
        return Int.random(in: 4000...8000)
    }

    init(port: Int, ipaPath: String, appInfo: AppInfo) {
        self.port = port
        self.ipaPath = ipaPath
        self.appInfo = appInfo
        super.init()
    }

    static let userDefaultsKey = "SimpleHTTPServer"

    static func getSavedPort() -> Int? {
        return UserDefaults.standard.integer(forKey: "\(userDefaultsKey).port")
    }

    static func savePort(_ port: Int) {
        UserDefaults.standard.set(port, forKey: "\(userDefaultsKey).port")
    }

    func start() {

        requestLocalNetworkPermission { [weak self] granted in
            if granted {
                self?.serverQueue.async { [weak self] in
                    Task { @MainActor in
                        await self?.startSimpleServer()
                    }
                }
            }
        }
    }

    private func requestLocalNetworkPermission(completion: @escaping @Sendable (Bool) -> Void) {

        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "NetworkPermission")

        monitor.pathUpdateHandler = { path in

            let hasPermission = path.status == .satisfied || path.status == .requiresConnection
            DispatchQueue.main.async {
                completion(hasPermission)
            }
            monitor.cancel()
        }

        monitor.start(queue: queue)

        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            monitor.cancel()
            completion(true)
        }
    }

    private func startSimpleServer() async {
        do {

            let config = Environment(name: "development", arguments: ["serve"])
            app = try await Application.make(config)

            app?.http.server.configuration.port = port
            app?.http.server.configuration.address = .hostname("0.0.0.0", port: port)
            app?.http.server.configuration.tcpNoDelay = true
            app?.http.server.configuration.requestDecompression = .enabled
            app?.http.server.configuration.responseCompression = .enabled
            app?.threadPool = .init(numberOfThreads: 2)
            app?.http.server.configuration.tlsConfiguration = nil

            app?.middleware.use(CORSMiddleware())

            setupSimpleRoutes()

            try await app?.execute()
            isRunning = true

        } catch {
            isRunning = false
        }
    }

    private func setupSimpleRoutes() {
        guard let app = app else { return }

        app.get("health") { req -> String in
            return "OK"
        }

        app.get("ipa", ":filename") { [weak self] req -> Response in
            guard let self = self,
                  let filename = req.parameters.get("filename"),
                  filename == self.appInfo.bundleIdentifier else {
                return Response(status: .notFound)
            }

            guard let ipaData = try? Data(contentsOf: URL(fileURLWithPath: self.ipaPath)) else {
                return Response(status: .notFound)
            }

            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/octet-stream")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: ipaData)

            return response
        }

        app.get(":filename") { [weak self] req -> Response in
            guard let self = self,
                  let filename = req.parameters.get("filename"),
                  filename == "\(self.appInfo.bundleIdentifier).ipa" else {
                return Response(status: .notFound)
            }

            let shouldSign = req.parameters.get("sign") == "1"

            var ipaData: Data
            if shouldSign {

                do {
                    let signedIPAPath = try self.signIPAIfNeeded()
                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: signedIPAPath)) else {
                        return Response(status: .internalServerError)
                    }
                    ipaData = data
                } catch {

                    guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.ipaPath)) else {
                        return Response(status: .notFound)
                    }
                    ipaData = data
                }
            } else {

                guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.ipaPath)) else {
                    return Response(status: .notFound)
                }
                ipaData = data
            }

            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/octet-stream")
            response.headers.add(name: "Access-Control-Allow-Origin", value: "*")
            response.headers.add(name: "Cache-Control", value: "no-cache")
            response.body = .init(data: ipaData)

            return response
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

            let externalManifestURL = self.generateExternalManifestURL()

            let installPage = """
            <!DOCTYPE html>
            <html>
            <head>
                <meta charset="utf-8">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>\(String(format: "installing_app".localized, self.appInfo.name))</title>
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
                        <h1 class="app-name">\(self.appInfo.name)</h1>
                        <p class="app-version">\(String(format: "version_x".localized, self.appInfo.version))</p>
                        <p class="app-bundle">\(self.appInfo.bundleIdentifier)</p>
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
                        manifestURL = '\(externalManifestURL)';
                        itmsURL = 'itms-services:

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
                            status.innerHTML = '<span class="success">✅ 已启动安装程序...</span>';
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
                        status.innerHTML = '<span class="loading"></span>手动触发安装...';
                        isInstalling = true;

                        try {
                            window.location.href = itmsURL;
                            status.innerHTML = '<span class="success">✅ 手动安装已启动</span>';
                            installSuccess = true;
                        } catch (error) {
                            status.innerHTML = '<span class="error">❌ 手动安装失败: ' + error.message + '</span>';
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

        app.get("health") { req -> Response in
            let response = Response(status: .ok)
            response.headers.add(name: "Content-Type", value: "application/json")
            response.body = .init(string: "{\"status\":\"healthy\",\"timestamp\":\"\(Date().timeIntervalSince1970)\"}")
            return response
        }
    }

    func stop() {

        serverQueue.async { [weak self] in
            self?.app?.shutdown()
            self?.isRunning = false
        }
    }

    func setPlistData(_ data: Data, fileName: String) {
        self.plistData = data
        self.plistFileName = fileName
    }

    private func generateExternalManifestURL() -> String {

        let localIP = "127.0.0.1"
        let ipaURL = "http://\(localIP):\(port)/\(appInfo.bundleIdentifier).ipa"

        let fullIPAURL = "\(ipaURL)?sign=1"

        let proxyURL = "https://api.palera.in/genPlist?bundleid=\(appInfo.bundleIdentifier)&name=\(appInfo.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? appInfo.name)&version=\(appInfo.version)&fetchurl=\(fullIPAURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fullIPAURL)"

        return proxyURL
    }

    private func generatePlistData() -> Data {
        let ipaURL = "http://127.0.0.1:\(port)/\(appInfo.bundleIdentifier).ipa"

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

        return "http://127.0.0.1:\(port)/icon/display"
    }

    private func getFullSizeImageURL() -> String {

        return "http://127.0.0.1:\(port)/icon/fullsize"
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

struct DownloadView: SwiftUI.View {
    @StateObject private var vm: UnifiedDownloadManager = UnifiedDownloadManager.shared
    @State private var animateCards = true
    @State private var showSafariWebView = false
    @State private var safariURL: URL? = nil
    @State private var showIPAFilesView = false
    @State private var showThemeSelector = false
    @State private var isScrollingFast = false
    @State private var scrollVelocity: CGFloat = 0

    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject private var globalInstallManager: GlobalInstallationManager
    @EnvironmentObject private var tabBarStyleManager: TabBarStyleManager

    @State private var lastScrollOffset: CGFloat = 0
    @State private var lastScrollTime: Date = Date()

    var body: some SwiftUI.View {
        ZStack {
            themeManager.backgroundColor
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

        .overlay(alignment: .bottomTrailing) {
            Button(action: {
                showIPAFilesView.toggle()
            }) {
                Text("📁")
                    .font(.system(size: 24))
                    .padding()
                    .background(LinearGradient(colors: [Color.blue, Color.purple], startPoint: .leading, endPoint: .trailing))
                    .clipShape(Circle())
                    .shadow(color: colorScheme == .dark ? Color.black.opacity(0.6) : Color.black.opacity(0.3), radius: colorScheme == .dark ? 12 : 8, x: 0, y: 4)
            }
            .padding(.trailing, 16)
            .padding(.bottom, tabBarStyleManager.currentStyle == .floatingCard ? 88 : 16)
            .offset(y: animateCards ? 0 : 30)
            .opacity(animateCards ? 1 : 0)
            .animation(.spring(response: 0.5, dampingFraction: 0.7).delay(0.2), value: animateCards)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: tabBarStyleManager.currentStyle)
        }

        .sheet(isPresented: $showIPAFilesView) {
            IPAListView(isPresented: $showIPAFilesView).environmentObject(themeManager)
        }
        .onAppear {
            vm.syncDownloadStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            handleAppEnteredBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            handleAppBecameActive()
        }
        .environmentObject(GlobalInstallationManager.shared)
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
                    ForEach(vm.sortedDownloadRequests.indices, id: \.self) { index in
                        let request = vm.sortedDownloadRequests[index]
                        DownloadCardView(
                            request: request,
                            isPreview: isScrollingFast
                        )
                        .scaleEffect(animateCards ? 1 : 0.9)
                        .opacity(animateCards ? 1 : 0)
                        .animation(Animation.spring().delay(Double(index) * 0.1), value: animateCards)
                        .animation(nil, value: isScrollingFast)
                        .id(request.id)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if request.runtime.status == .completed,
                               let localFilePath = request.localFilePath,
                               FileManager.default.fileExists(atPath: localFilePath) {
                                Button {
                                    shareIPAFile(path: localFilePath, name: request.package.name)
                                } label: {
                                    Label("share".localized, systemImage: "square.and.arrow.up")
                                }
                                .tint(.blue)
                            }

                            Button(role: .destructive) {
                                UnifiedDownloadManager.shared.deleteDownload(request: request)
                                UnifiedDownloadManager.shared.saveDownloadTasks()

                                if let localFilePath = request.localFilePath, FileManager.default.fileExists(atPath: localFilePath) {
                                    do {
                                        try FileManager.default.removeItem(atPath: localFilePath)
                                    } catch {
                                    }
                                }

                                NotificationCenter.default.post(name: NSNotification.Name("ForceRefreshUI"), object: nil)
                            } label: {
                                Label("delete".localized, systemImage: "trash")
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
                detectScrollVelocity(offset: value)
            }
        }
        .listStyle(.plain)
        .background(Color.clear)
        .onAppear {
            UITableView.appearance().backgroundColor = .clear
        }
        .coordinateSpace(name: "downloadScroll")
        .refreshable {
            vm.syncDownloadStatus()
        }
    }

    private func detectScrollVelocity(offset: CGFloat) {
        let now = Date()
        let timeDiff = now.timeIntervalSince(lastScrollTime)

        if timeDiff > 0 {
            let offsetDiff = abs(offset - lastScrollOffset)
            let velocity = offsetDiff / timeDiff
            scrollVelocity = velocity

            let fastThreshold: CGFloat = 800
            let isFast = velocity > fastThreshold

            if isFast != isScrollingFast {
                withAnimation(.easeInOut(duration: 0.1)) {
                    isScrollingFast = isFast
                }
            }
        }

        lastScrollOffset = offset
        lastScrollTime = now
    }

    private func shareIPAFile(path: String, name: String) {

        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        let fileURL = URL(fileURLWithPath: path)

        #if canImport(UIKit)
        guard let topViewController = getTopViewController() else {
            return
        }

        let activityViewController = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )

        activityViewController.title = name

        if UIDevice.current.userInterfaceIdiom == .pad {
            activityViewController.popoverPresentationController?.sourceView = topViewController.view
            activityViewController.popoverPresentationController?.sourceRect = CGRect(
                x: topViewController.view.bounds.midX,
                y: topViewController.view.bounds.midY,
                width: 0,
                height: 0
            )
            activityViewController.popoverPresentationController?.permittedArrowDirections = []
        }

        topViewController.present(activityViewController, animated: true)
        #endif
    }

    private func getTopViewController() -> UIViewController? {
        #if canImport(UIKit)
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }

        var topController = keyWindow.rootViewController
        while let presentedViewController = topController?.presentedViewController {
            topController = presentedViewController
        }
        return topController
        #else
        return nil
        #endif
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
                                colors: [Color.blue, Color.purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                )
                .shadow(color: colorScheme == .dark ? Color.blue.opacity(0.5) : Color.blue.opacity(0.3), radius: colorScheme == .dark ? 12 : 8, x: 0, y: 4)
            }
            .buttonStyle(PlainButtonStyle())

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

    private func deleteDownload() {

    }

    private func retryDownload() {

    }

    private func isUnpurchasedAppError() -> Bool {

        return false
    }

    private func openAppStore() {

        let appStoreURL = "https://apps.apple.com/"

        guard let url = URL(string: appStoreURL) else {
            return
        }

        #if canImport(UIKit)
        if UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url) { success in
                if success {
                } else {
                }
            }
        } else {
        }
        #endif
    }

}

struct DownloadScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct CustomProgressView: SwiftUI.View {
    let progress: Double
    var height: CGFloat = 4
    var cornerRadius: CGFloat = 2
    var color: Color = .blue

    var body: some SwiftUI.View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color(.systemGray5))
                    .frame(height: height)

                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(max(0, min(1, progress))), height: height)
            }
        }
        .frame(height: height)
    }
}

struct DownloadProgressView: SwiftUI.View {
    let progress: Double
    let status: DownloadStatus
    let error: String?
    let accentColor: Color

    private var progressLabel: String {
        switch status {
        case .waiting:
            return "download_waiting".localized
        case .downloading:
            return "downloading".localized
        case .paused:
            return "download_paused".localized
        case .completed:
            return "download_completed".localized
        case .failed:
            return "download_failed".localized
        case .cancelled:
            return "download_cancelled".localized
        }
    }

    private var progressColor: Color {
        switch status {
        case .waiting, .paused:
            return .orange
        case .downloading, .completed:
            return accentColor
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }

    var body: some SwiftUI.View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(progressLabel)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                Spacer()

                if status != .failed && status != .cancelled {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(accentColor)
                }
            }

            CustomProgressView(
                progress: progress,
                height: 4,
                cornerRadius: 2,
                color: progressColor
            )

            if let error = error, !error.isEmpty {
                HStack {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .lineLimit(2)

                    Spacer()
                }
            }
        }
    }
}

struct DownloadCardView: SwiftUI.View {
    @ObservedObject var request: DownloadRequest
    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject var themeManager: ThemeManager
    var isPreview: Bool = false

    @State private var showDetailView = false
    @State private var showInstallView = false

    @State private var isInstalling = false
    @State private var installationProgress: Double = 0.0
    @State private var installationMessage: String = ""

    private var progress: Double {
        request.runtime.progressValue
    }

    private var status: DownloadStatus {
        request.runtime.status
    }

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            topSection

            if shouldShowProgress {
                ECGDownloadProgressView(
                    progress: progress,
                    status: status,
                    error: request.runtime.error,
                    accentColor: themeManager.accentColor
                )
            }

            if status == DownloadStatus.completed {
                completedStatusView
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(
                    color: colorScheme == .dark ? Color.black.opacity(0.4) : Color.black.opacity(0.08),
                    radius: colorScheme == .dark ? 10 : 6,
                    x: 0,
                    y: 2
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            handleCardTap()
        }
        .id(request.id)
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
    }

    private var appIconView: some SwiftUI.View {
        Group {
            if let iconURL = request.package.iconURL, let url = URL(string: iconURL) {
                ArtworkView(
                    url: url,
                    aspectRatio: 1,
                    contentMode: .fill,
                    cornerRadius: 12,
                    showsBorder: true,
                    loadingAnimation: !isPreview,
                    isPreview: isPreview
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

            if let localFilePath = request.localFilePath {
                if let fileSize = getFileSize(path: localFilePath) {
                    Text(String(format: "file_size_x".localized, fileSize))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionButtonView: some SwiftUI.View {
        primaryActionButton
    }

    @ViewBuilder
    private var primaryActionButton: some SwiftUI.View {
        switch request.runtime.status {
        case .downloading, .waiting, .paused:
            EmptyView()

        case .failed, .cancelled:
            HStack(spacing: 3) {
                Text("🔄")
                    .font(.system(size: 13))
                Text("retry".localized)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundColor(.orange)
            .frame(width: 76, height: 32)
            .background(
                Capsule()
                    .fill(Color.orange.opacity(0.12))
            )
            .contentShape(Rectangle())
            .onTapGesture {
                retryDownload()
            }

        case .completed:
            if request.localFilePath != nil {
                HStack(spacing: 4) {
                    if isInstalling {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.7)
                    } else {
                        Text("📦")
                            .font(.system(size: 14))
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
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isInstalling else { return }
                    startInstallation(for: request)
                }
            } else {
                Text("✅")
                    .font(.system(size: 20))
            }
        }
    }

    private var completedStatusView: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("✅")
                    .font(.caption)

                Text("file_saved_to".localized)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text(request.localFilePath ?? "unknown_path".localized)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func handleCardTap() {
        switch request.runtime.status {
        case DownloadStatus.completed:

            if request.localFilePath != nil {
                showInstallView = true
            } else {

                showDetailView = true
            }
        case DownloadStatus.failed:

            showDetailView = true
        case DownloadStatus.cancelled:

            showDetailView = true
        default:

            showDetailView = true
        }
    }

    private func shareIPAFile(path: String) {
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        let fileURL = URL(fileURLWithPath: path)

        #if os(iOS)

        let activityViewController = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )

        activityViewController.setValue("share_ipa".localized, forKey: "subject")

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first,
           let rootViewController = window.rootViewController {

            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = rootViewController.view
                popover.sourceRect = CGRect(x: rootViewController.view.bounds.midX,
                                          y: rootViewController.view.bounds.midY,
                                          width: 0, height: 0)
                popover.permittedArrowDirections = []
            }

            rootViewController.present(activityViewController, animated: true) {
            }
        }
        #else
        #endif
    }

    private var statusIndicator: some SwiftUI.View {
        Group {
            switch request.runtime.status {
            case DownloadStatus.waiting:
                Text("⏳")
            case DownloadStatus.downloading:
                Text("⬇️")
            case DownloadStatus.paused:
                Text("⏸️")
            case DownloadStatus.completed:
                Text("✅")
            case DownloadStatus.failed:
                Text("❌")
            case DownloadStatus.cancelled:
                Text("❌")
            }
        }
        .font(.title2)
    }

    private var progressView: some SwiftUI.View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(getProgressLabel())
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)

                Spacer()

                if request.runtime.status != .failed && request.runtime.status != .cancelled {
                    Text("\(Int(request.runtime.progressValue * 100))%")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(themeManager.accentColor)
                }
            }

            CustomProgressView(
                progress: request.runtime.progressValue,
                height: 4,
                cornerRadius: 2,
                color: themeManager.accentColor
            )

            if let error = request.runtime.error, !error.isEmpty {
                HStack {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .lineLimit(2)

                    Spacer()
                }
            }
        }
    }

    private func getProgressLabel() -> String {
        switch request.runtime.status {
        case DownloadStatus.waiting:
            return "download_waiting".localized
        case DownloadStatus.downloading:
            return "downloading".localized
        case DownloadStatus.paused:
            return "download_paused".localized
        case DownloadStatus.completed:
            return "download_completed".localized
        case DownloadStatus.failed:
            return "download_failed".localized
        case DownloadStatus.cancelled:
            return "download_cancelled".localized
        }
    }

    private func getProgressIcon() -> String {
        switch request.runtime.status {
        case DownloadStatus.waiting:
            return "clock"
        case DownloadStatus.downloading:
            return "arrow.down.circle"
        case DownloadStatus.paused:
            return "pause.circle"
        case DownloadStatus.completed:
            return "checkmark.circle"
        case DownloadStatus.failed:
            return "xmark.circle"
        case DownloadStatus.cancelled:
            return "xmark.circle"
        }
    }

    private func getProgressColor() -> Color {
        switch request.runtime.status {
        case DownloadStatus.waiting:
            return .orange
        case DownloadStatus.downloading:
            return themeManager.accentColor
        case DownloadStatus.paused:
            return .orange
        case DownloadStatus.completed:
            return .green
        case DownloadStatus.failed:
            return .red
        case DownloadStatus.cancelled:
            return .gray
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

    private func isUnpurchasedAppError() -> Bool {

        return false
    }

    private func openAppStore() {

        if let appStoreURL = URL(string: "https://apps.apple.com/") {
            UIApplication.shared.open(appStoreURL)
        }
    }

    private func retryDownload() {

        UnifiedDownloadManager.shared.resumeDownload(request: request)

    }

    private func deleteDownload() {

        UnifiedDownloadManager.shared.deleteDownload(request: request)

        UnifiedDownloadManager.shared.saveDownloadTasks()

        if let localFilePath = request.localFilePath, FileManager.default.fileExists(atPath: localFilePath) {
            do {
                try FileManager.default.removeItem(atPath: localFilePath)
            } catch {
            }
        }

        NotificationCenter.default.post(name: NSNotification.Name("ForceRefreshUI"), object: nil)
    }

    private func cancelDownload() {

        UnifiedDownloadManager.shared.cancelDownload(request: request)

    }

    private func pauseDownload() {
        UnifiedDownloadManager.shared.pauseDownload(request: request)
    }

    private func resumeDownload() {
        UnifiedDownloadManager.shared.resumeDownload(request: request)
    }

    private func startInstallation(for request: DownloadRequest) {
        guard let localFilePath = request.localFilePath, FileManager.default.fileExists(atPath: localFilePath) else {
            installationMessage = "ipa_not_found".localized
            return
        }

        isInstalling = true
        installationProgress = 0.0
        installationMessage = "preparing_install".localized

        let backgroundTaskID = UIApplication.shared.beginBackgroundTask {
        }

        Task {
            do {
                let appInfo = AppInfo(
                    name: request.name,
                    version: request.version,
                    bundleIdentifier: request.bundleIdentifier,
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

                let port = SimpleHTTPServer.randomPort()

                HTTPServerManager.shared.startServer(
                    for: request.id,
                    port: port,
                    ipaPath: localFilePath,
                    appInfo: appInfo
                )

                SimpleHTTPServer.savePort(port)

                await MainActor.run {
                    installationProgress = 0.6
                    installationMessage = "准备安装链接..."
                }

                let healthURL = "http://127.0.0.1:\(port)/health"
                var serverReady = false
                for _ in 1...20 {
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if let url = URL(string: healthURL) {
                        do {
                            let (_, response) = try await URLSession.shared.data(from: url)
                            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                                serverReady = true
                                break
                            }
                        } catch {
                        }
                    }
                }

                guard serverReady else {
                    await MainActor.run {
                        installationMessage = "install_service_timeout".localized
                        cleanupInstallation(request.id)
                    }
                    UIApplication.shared.endBackgroundTask(backgroundTaskID)
                    return
                }

                await MainActor.run {
                    installationProgress = 0.8
                    installationMessage = "opening_install_page".localized

                    let localIP = "127.0.0.1"
                    let ipaURL = "http://\(localIP):\(port)/\(request.bundleIdentifier).ipa?sign=1"

                    var manifestComponents = URLComponents(string: "https://api.palera.in/genPlist")
                    manifestComponents?.queryItems = [
                        URLQueryItem(name: "bundleid", value: request.bundleIdentifier),
                        URLQueryItem(name: "name", value: request.name),
                        URLQueryItem(name: "version", value: request.version),
                        URLQueryItem(name: "fetchurl", value: ipaURL)
                    ]

                    guard let manifestURL = manifestComponents?.url?.absoluteString else {
                        installationMessage = "install_start_failed".localized
                        cleanupInstallation(request.id)
                        return
                    }

                    let actionItem = URLQueryItem(name: "action", value: "download-manifest")
                    let urlItem = URLQueryItem(name: "url", value: manifestURL)

                    var comps = URLComponents()
                    comps.queryItems = [actionItem, urlItem]

                    guard let percentEncodedQuery = comps.percentEncodedQuery else {
                        installationMessage = "install_start_failed".localized
                        cleanupInstallation(request.id)
                        return
                    }

                    let itmsURLString = "itms-services://?" + percentEncodedQuery

                    guard let itmsURL = URL(string: itmsURLString) else {
                        installationMessage = "install_start_failed".localized
                        cleanupInstallation(request.id)
                        return
                    }

                    guard UIApplication.shared.canOpenURL(itmsURL) else {
                        installationMessage = "install_start_failed".localized
                        cleanupInstallation(request.id)
                        return
                    }

                    UIApplication.shared.open(itmsURL, options: [:]) { success in
                        DispatchQueue.main.async {
                            if success {
                                isInstalling = false
                            } else {
                                installationMessage = "install_start_failed".localized
                                cleanupInstallation(request.id)
                            }
                        }
                    }
                }

                UIApplication.shared.endBackgroundTask(backgroundTaskID)

            } catch {
                await MainActor.run {
                    installationMessage = error.localizedDescription
                    isInstalling = false
                    installationProgress = 0.0

                    HTTPServerManager.shared.stopServer(for: request.id)
                }
                UIApplication.shared.endBackgroundTask(backgroundTaskID)
            }
        }
    }

    private func cleanupInstallation(_ requestId: UUID, keepServer: Bool = false) {

        Task {
            await MainActor.run {
                isInstalling = false
                installationProgress = 0.0
                installationMessage = ""

                if !keepServer {
                    HTTPServerManager.shared.stopServer(for: requestId)
                } else {

                    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 300) {

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

struct IPAListView: SwiftUI.View {
    @EnvironmentObject var themeManager: ThemeManager
    @Binding var isPresented: Bool
    @State private var ipaFiles: [(name: String, path: String, size: String, date: Date)] = []
    @State private var isLoading = false
    @State private var selectedFileIndex: Int? = nil
    @State private var showDeleteAlert = false
    @State private var deleteFilePath: String? = nil
    @State private var deleteFileName: String? = nil
    @State private var lastDeleteSuccess = false

    var body: some SwiftUI.View {
        NavigationView {
            ZStack {
                themeManager.backgroundColor
                    .ignoresSafeArea()

                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: themeManager.accentColor))
                        .scaleEffect(2)
                } else {
                    if ipaFiles.isEmpty {
                        emptyStateView
                    } else {
                        fileListView
                    }
                }
            }
            .navigationTitle("download_record_file".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        loadIPAFiles()
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .confirmationDialog("delete_file".localized, isPresented: $showDeleteAlert, titleVisibility: .visible) {
                Button("delete".localized, role: .destructive, action: confirmDelete)
                Button("cancel".localized, role: .cancel) { }
            } message: {
                Text(String(format: "delete_file_confirm".localized, deleteFileName ?? ""))
            }
        }
        .onAppear {
            loadIPAFiles()
        }
    }

    private var emptyStateView: some SwiftUI.View {
        VStack(spacing: 16) {
            Text("📭")
                .font(.system(size: 64))
            Text("no_ipa_found".localized)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.primary)
            Text("no_ipa_found_desc".localized)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fileListView: some SwiftUI.View {
        List(ipaFiles.indices, id: \.self) { index in
            let file = ipaFiles[index]
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    HStack {
                        Text(file.size)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("·")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(file.date.formatted())
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button(action: {
                        shareIPAFile(path: file.path, name: file.name)
                    }) {
                        Label {
                            Text("share".localized)
                        } icon: {
                            Text("📤")
                        }
                    }
                    Button(action: {
                        showDeleteConfirmation(for: file.path, name: file.name)
                    }) {
                        Label {
                            Text("delete".localized)
                        } icon: {
                            Text("🗑️")
                        }
                        .foregroundColor(.red)
                    }
                } label: {
                    Text("⋯")
                        .font(.title2)
                        .foregroundColor(themeManager.accentColor)
                }
            }
            .padding(.vertical, 8)
        }
        .listStyle(.plain)
        .padding(.top, 8)
    }

    private func loadIPAFiles() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {

            let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let libraryDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let downloadsDirectory = applicationSupportDirectory.appendingPathComponent("Downloads")

            let directoriesToScan = [documentDirectory, libraryDirectory, cachesDirectory, downloadsDirectory]

            var files: [(name: String, path: String, size: String, date: Date)] = []
            let fileManager = FileManager.default

            func scanDirectory(_ directory: URL) {
                guard let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.fileSizeKey, .creationDateKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { return }

                for case let url as URL in enumerator {
                    guard url.pathExtension.lowercased() == "ipa" else { continue }

                    let filePath = url.path
                    guard !files.contains(where: { $0.path == filePath }) else { continue }

                    do {
                        let attributes = try fileManager.attributesOfItem(atPath: filePath)
                        let fileSize = attributes[.size] as? Int64 ?? 0
                        let formatter = ByteCountFormatter()
                        formatter.allowedUnits = [.useMB, .useGB]
                        formatter.countStyle = .file
                        let sizeString = formatter.string(fromByteCount: fileSize)

                        let creationDate = attributes[.creationDate] as? Date ?? Date()

                        files.append((name: url.lastPathComponent, path: filePath, size: sizeString, date: creationDate))
                    } catch {
                        continue
                    }
                }
            }

            for directory in directoriesToScan {
                scanDirectory(directory)
            }

            files.sort { $0.date > $1.date }

            DispatchQueue.main.async {
                ipaFiles = files
                isLoading = false
            }
        }
    }

    private func shareIPAFile(path: String, name: String) {

        guard FileManager.default.fileExists(atPath: path) else {
            return
        }

        let fileURL = URL(fileURLWithPath: path)

        #if canImport(UIKit)

        guard let topViewController = getTopViewController() else {
            return
        }

        let activityViewController = UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )

        activityViewController.title = name

        if UIDevice.current.userInterfaceIdiom == .pad {
            if let popover = activityViewController.popoverPresentationController {
                popover.sourceView = topViewController.view
                popover.sourceRect = CGRect(
                    x: topViewController.view.bounds.midX,
                    y: topViewController.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }
        }

        topViewController.present(activityViewController, animated: true) {
        }
        #else

        #endif
    }

    private func getTopViewController() -> UIViewController? {
        #if canImport(UIKit)
        guard let windowScene = UIApplication.shared.connectedScenes
            .filter({ $0.activationState == .foregroundActive })
            .first as? UIWindowScene,
              let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }),
              var topVC = keyWindow.rootViewController else {
            return nil
        }

        while let presentedVC = topVC.presentedViewController {
            topVC = presentedVC
        }

        return topVC
        #else
        return nil
        #endif
    }

    private func showDeleteConfirmation(for path: String, name: String) {
        deleteFilePath = path
        deleteFileName = name
        showDeleteAlert = true
    }

    private func confirmDelete() {
        guard let filePath = deleteFilePath else {
            return
        }

        do {

            guard FileManager.default.fileExists(atPath: filePath) else {
                return
            }

            try FileManager.default.removeItem(atPath: filePath)

            if let index = ipaFiles.firstIndex(where: { $0.path == filePath }) {
                ipaFiles.remove(at: index)
            }

            deleteFilePath = nil
            deleteFileName = nil

        } catch {

        }
    }
}

struct DownloadView_Previews: PreviewProvider {
    static var previews: some SwiftUI.View {
        NavigationView {
            DownloadView()
        }
        .environmentObject(ThemeManager.shared)
        .environmentObject(TabBarStyleManager.shared)
    }
}
