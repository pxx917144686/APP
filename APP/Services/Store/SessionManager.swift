import Foundation
import Combine
import SwiftUI

@MainActor
class SessionManager: ObservableObject, @unchecked Sendable {
    static let shared = SessionManager()

    @Published var isSessionValid = true
    @Published var isReconnecting = false
    @Published var lastSessionCheck = Date()
    @Published var sessionError: String?

    private var sessionTimer: Timer?
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3
    private let sessionCheckInterval: TimeInterval = 30
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        AppStore.this.$selectedAccount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] account in
                Task { @MainActor in
                    self?.handleAccountChange(account)
                }
            }
            .store(in: &cancellables)
    }

    nonisolated deinit {
        Task { @MainActor [cancellables, sessionTimer] in
            var c = cancellables
            c.removeAll()
            sessionTimer?.invalidate()
        }
    }

    private func handleAccountChange(_ account: Account?) {
        if account != nil {
            resetSessionState()
            startSessionMonitoring()
            Task { await checkSessionValidity() }
        } else {
            stopSessionMonitoring()
            resetSessionState()
        }
    }

    func startSessionMonitoring() {
        stopSessionMonitoring()
        sessionTimer = Timer.scheduledTimer(withTimeInterval: sessionCheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkSessionValidity()
            }
        }
    }

    @MainActor
    func stopSessionMonitoring() {
        sessionTimer?.invalidate()
        sessionTimer = nil
    }

    func checkSessionValidity() async {
        guard let account = AppStore.this.selectedAccount else {
            return
        }
        let isValid = await validateSessionWithAPI(account: account)
        if isValid {
            isSessionValid = true
            sessionError = nil
            reconnectAttempts = 0
            lastSessionCheck = Date()
        } else {
            await handleSessionInvalid()
        }
    }

    private func validateSessionWithAPI(account: Account) async -> Bool {
        return await AuthenticationManager.shared.validateAccount(account)
    }

    private func handleSessionInvalid() async {
        isSessionValid = false
        if reconnectAttempts < maxReconnectAttempts {
            await attemptReconnection()
        } else {
            sessionError = "Apple ID会话已过期，请重新登录"
        }
    }

    private func attemptReconnection() async {
        guard let account = AppStore.this.selectedAccount else {
            return
        }
        reconnectAttempts += 1
        isReconnecting = true
        sessionError = "正在重新连接... (\(reconnectAttempts)/\(maxReconnectAttempts))"
        let refreshedAccount = AuthenticationManager.shared.refreshCookies(for: account)
        let isValid = await validateSessionWithAPI(account: refreshedAccount)
        if isValid {
            isSessionValid = true
            isReconnecting = false
            sessionError = nil
            reconnectAttempts = 0
            lastSessionCheck = Date()
            await notifySessionRestored()
        } else {
            isReconnecting = false
            sessionError = "重连失败，请检查网络连接"
        }
    }

    private func notifySessionRestored() async {
        NotificationCenter.default.post(name: .sessionRestored, object: nil)
        AppStore.this.refreshAccount()
    }

    func manualSessionCheck() async {
        await checkSessionValidity()
    }

    func forceReauthentication() async {
        isSessionValid = false
        isReconnecting = false
        sessionError = "需要重新登录"
        reconnectAttempts = maxReconnectAttempts
    }

    func resetSessionState() {
        isSessionValid = true
        isReconnecting = false
        sessionError = nil
        reconnectAttempts = 0
        lastSessionCheck = Date()
    }

    func resumeFailedDownloads() async {
        let downloadManager = UnifiedDownloadManager.shared
        for request in downloadManager.downloadRequests {
            if request.runtime.status == .failed &&
               request.runtime.error?.contains("认证") == true {
                request.runtime.status = .waiting
                request.runtime.error = nil
                request.runtime.progressValue = 0
                downloadManager.startDownload(for: request)
            }
        }
    }
}

extension Notification.Name {
    static let sessionRestored = Notification.Name("sessionRestored")
    static let sessionInvalid = Notification.Name("sessionInvalid")
    static let accountStoreTokensRefreshed = Notification.Name("accountStoreTokensRefreshed")
}
