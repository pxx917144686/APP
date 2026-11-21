import Foundation
import UIKit

@MainActor
enum SigningOTAInstaller {
    private static var activeServer: LocalInstallServer?
    private static var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private static var cleanupTask: Task<Void, Never>?

    static func install(
        ipaURL: URL,
        info: SigningIPAInfo,
        onPhase: (@MainActor (SigningInstallPhase) -> Void)? = nil
    ) async throws {
        stop()
        onPhase?(.preparing)

        let server = LocalInstallServer()
        let port = try await server.start(
            ipa: ipaURL,
            bundleId: info.bundleIdentifier,
            bundleVersion: info.version,
            title: info.displayName.isEmpty ? info.name : info.displayName
        )
        activeServer = server
        print("[SignInstall] ForgeSign local server ready on 127.0.0.1:\(port)")
        onPhase?(.connecting)
        server.onIPAProgress = { fraction in
            Task { @MainActor in
                onPhase?(.transferring(fraction))
            }
        }
        InstallKeepAlive.shared.start()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "signing.ota.install") {
            DispatchQueue.main.async {
                guard backgroundTask != .invalid else { return }
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
                stop()
            }
        }

        do {
            guard let healthURL = URL(string: "\(server.installBaseURL)/health") else {
                throw SigningInstallerError.serverUnavailable
            }
            var healthRequest = URLRequest(url: healthURL)
            healthRequest.timeoutInterval = 8
            let (_, healthResponse) = try await URLSession.shared.data(for: healthRequest)
            guard (healthResponse as? HTTPURLResponse)?.statusCode == 200 else {
                throw SigningInstallerError.serverUnavailable
            }
            onPhase?(.connecting)

            guard let manifestURL = URL(string: server.remoteManifestURL) else {
                throw SigningInstallerError.manifestUnavailable
            }
            var manifestRequest = URLRequest(url: manifestURL)
            manifestRequest.timeoutInterval = 20
            let (manifestData, manifestResponse) = try await URLSession.shared.data(for: manifestRequest)
            guard (manifestResponse as? HTTPURLResponse)?.statusCode == 200,
                  String(data: manifestData, encoding: .utf8)?.contains("<plist") == true else {
                throw SigningInstallerError.manifestUnavailable
            }
            print("[SignInstall] remote manifest ready: \(manifestURL.absoluteString)")

            guard let itmsURL = URL(string: server.itmsServicesURL),
                  UIApplication.shared.canOpenURL(itmsURL) else {
                server.onIPADelivered = {
                    Task { @MainActor in
                        onPhase?(.delivered)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        stop()
                    }
                }
                cleanupTask = Task {
                    try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    stop()
                }
                openInstallPage(server: server)
                return
            }

            let opened = await withCheckedContinuation { continuation in
                UIApplication.shared.open(itmsURL, options: [:]) { success in
                    continuation.resume(returning: success)
                }
            }
            print("[SignInstall] itms-services opened: \(opened)")
            if !opened {
                onPhase?(.awaitingSystem)
                server.onIPADelivered = {
                    Task { @MainActor in
                        onPhase?(.delivered)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        stop()
                    }
                }
                cleanupTask = Task {
                    try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    stop()
                }
                openInstallPage(server: server)
                return
            }
            onPhase?(.awaitingSystem)

            server.onIPADelivered = {
                print("[SignInstall] IPA delivered to iOS")
                Task { @MainActor in
                    onPhase?(.delivered)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    stop()
                }
            }

            cleanupTask = Task {
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                stop()
            }
            _ = port
        } catch {
            print("[SignInstall] ForgeSign install failed: \(error.localizedDescription)")
            onPhase?(.failed(error.localizedDescription))
            stop()
            throw error
        }
    }

    private static func openInstallPage(server: LocalInstallServer) {
        guard let pageURL = URL(string: "\(server.installBaseURL)/\(server.installToken)/install") else {
            return
        }
        UIApplication.shared.open(pageURL, options: [:]) { _ in }
    }

    static func stop() {
        cleanupTask?.cancel()
        cleanupTask = nil
        activeServer?.stop()
        activeServer = nil
        InstallKeepAlive.shared.stop()
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
