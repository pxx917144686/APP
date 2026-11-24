import SwiftUI
import UIKit
import ZsignSwift

@main
struct App: SwiftUI.App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var themeManager = ThemeManager.shared
    @StateObject private var tabBarStyleManager = TabBarStyleManager.shared
    @StateObject private var languageManager = LanguageManager.shared
    @State private var languageToggle = false
    @State private var isAppInitialized = false

    init() {
        CrashLogger.install()
        SoundEffects.prepare()
        #if DEBUG
        Self.runP12SelfTestIfNeeded()
        #endif
    }

    #if DEBUG
    private static func runP12SelfTestIfNeeded() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let probe = docs.appendingPathComponent("debug-cert.p12")
        guard let data = try? Data(contentsOf: probe) else { return }
        let result = Zsign.certificateDERWithError(p12Data: data, password: "1")
        CertImportLog.add("SELFTEST \(data.count) bytes -> " +
                          (result.data == nil ? "nil (\(result.error))" : "\(result.data!.count) bytes"))
    }
    #endif

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
                        .appPresentationHost()
                } else {
                    LaunchScreenView()
                        .environmentObject(themeManager)
                }
            }
            .preferredColorScheme(colorScheme)
            .onOpenURL { url in
                IslandDeepLink.handle(url)
            }
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Task { @MainActor in
                AppPrewarmer.warm()
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
        AppCache.configure()
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
