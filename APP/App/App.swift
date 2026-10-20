import SwiftUI
import UIKit

@main
struct App: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var tabBarStyleManager = TabBarStyleManager.shared
    @StateObject private var languageManager = LanguageManager.shared
    @State private var languageToggle = false
    @State private var isAppInitialized = false

    var body: some SwiftUI.Scene {
        WindowGroup {
            Group {
                if isAppInitialized {
                    TabbarView()
                        .environmentObject(themeManager)
                        .environmentObject(tabBarStyleManager)
                        .environmentObject(AppStore.this)
                        .environmentObject(languageManager)
                        .id(languageToggle)
                        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AppLanguageChanged"))) { _ in
                            languageToggle.toggle()
                        }
                } else {
                    LaunchScreenView()
                        .environmentObject(themeManager)
                }
            }
            .preferredColorScheme(colorScheme)
            .onAppear {
                performDelayedInitialization()
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch themeManager.selectedTheme {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    private func performDelayedInitialization() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isAppInitialized = true
        }

        if ProcessInfo.processInfo.arguments.contains("-OwnedAppsTest") {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                Task { @MainActor in
                    guard let account = AppStore.this.selectedAccount else {
                        downloadDebugLog("OwnedAppsTest: 无已登录账号")
                        exit(0)
                    }
                    do {
                        let apps = try await OwnedAppsService.shared.fetchOwnedApps(account: account)
                        downloadDebugLog("OwnedAppsTest: 共 \(apps.count) 个")
                        for app in apps {
                            downloadDebugLog("OWNED \(app.id) | \(app.name) | \(app.bundleId) | v\(app.version)")
                        }
                    } catch {
                        downloadDebugLog("OwnedAppsTest: 失败 \(error.localizedDescription)")
                    }
                    exit(0)
                }
            }
        }

        if ProcessInfo.processInfo.arguments.contains("-DownloadSelfTest") {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                Task { @MainActor in
                    guard let account = AppStore.this.selectedAccount else {
                        downloadDebugLog("DownloadSelfTest: 无已登录账号")
                        exit(0)
                    }
                    let args = ProcessInfo.processInfo.arguments
                    let testId: String
                    if let idx = args.firstIndex(of: "-DownloadSelfTest"), idx + 1 < args.count, Int(args[idx + 1]) != nil {
                        testId = args[idx + 1]
                    } else {
                        testId = "1596063349"
                    }
                    downloadDebugLog("DownloadSelfTest: 账号=\(account.email) 区=\(account.countryCode) dsid=\(account.directoryServicesIdentifier) id=\(testId)")
                    do {
                        if Int(testId) != nil {
                            let purchaseRes = await PurchaseManager.shared.purchaseAppIfNeeded(
                                appIdentifier: testId,
                                account: account,
                                countryCode: account.countryCode,
                                isFree: true
                            )
                            switch purchaseRes {
                            case .success(let r): downloadDebugLog("DownloadSelfTest purchase: 成功 \(r.message)")
                            case .failure(let e): downloadDebugLog("DownloadSelfTest purchase: 失败 \(e.localizedDescription)")
                            }
                        }
                        let resp = try await StoreRequest.shared.download(appIdentifier: testId, account: account)
                        downloadDebugLog("DownloadSelfTest: 成功 songList=\(resp.songList.count) 首URL=\(resp.songList.first?.url.prefix(60) ?? "nil")")
                    } catch {
                        downloadDebugLog("DownloadSelfTest: 失败 \(error.localizedDescription)")
                    }
                    exit(0)
                }
            }
        }

        if ProcessInfo.processInfo.arguments.contains("-SAPSelfTest") {
            let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("sap_selftest_result.txt")
            try? "start\n".data(using: .utf8)?.write(to: logURL)
            WasmSAPSigner.progress = { line in
                let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("sap_selftest_result.txt")
                if let handle = try? FileHandle(forWritingTo: path) {
                    handle.seekToEndOfFile()
                    handle.write(Data("[\(Int(Date().timeIntervalSince1970))] \(line)\n".utf8))
                    try? handle.close()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
                Task {
                    do {
                        let sig = try await WasmSAPSigner.signOnce(guid: "0123456789AB", body: Data("test".utf8))
                        WasmSAPSigner.progress?("SAP_SELF_TEST 原子签名 OK len=\(sig.count)")
                        let session = try await WasmSAPSigner.openSession(guid: "0123456789AB")
                        let s1 = try await session.sign(Data("one".utf8))
                        let s2 = try await session.sign(Data("two".utf8))
                        await session.close()
                        WasmSAPSigner.progress?("SAP_SELF_TEST 会话签名 OK len1=\(s1.count) len2=\(s2.count)")
                        WasmSAPSigner.progress?("SAP_SELF_TEST OK")
                    } catch {
                        WasmSAPSigner.progress?("SAP_SELF_TEST FAIL \(error)")
                    }
                    exit(0)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task { @MainActor in
                _ = ImageLoader.shared
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in
                _ = UnifiedDownloadManager.shared
            }
        }

    }
}

struct LaunchScreenView: View {
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        ZStack {
            themeManager.backgroundColor
                .ignoresSafeArea()

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .cornerRadius(24)
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate {

    var backgroundSessionCompletionHandler: (() -> Void)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        DispatchQueue.global(qos: .utility).async {
            Task { @MainActor in
                AnalyticsManager.shared.addProvider(ConsoleAnalyticsProvider())
            }
        }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {

        self.backgroundSessionCompletionHandler = completionHandler

        let _ = AppStoreDownloadManager.shared
    }
}

struct App_Previews: SwiftUI.PreviewProvider {
    static var previews: some SwiftUI.View {
        let themeManager = ThemeManager.shared
        TabbarView()
            .environmentObject(themeManager)
            .environmentObject(AppStore.this)
    }
}
