import Foundation
import SwiftUI
import Combine

@MainActor
class AppStore: ObservableObject {

    static let this = AppStore()

    private static let selectedIndexDefaultsKey = "ipatool.swift.selectedAccountIndex"

    @Published var savedAccounts: [Account] = []

    @Published var selectedAccount: Account? = nil

    @Published var selectedAccountIndex: Int = 0

    private init() {
        loadAccounts()
        Task { await restoreSessionIfNeeded() }
    }

    private func loadAccounts() {

        let allAccounts = AuthenticationManager.shared.loadAllSavedAccounts()
        savedAccounts = allAccounts

        if !allAccounts.isEmpty {
            let storedIndex = UserDefaults.standard.integer(forKey: Self.selectedIndexDefaultsKey)
            let safeIndex = (storedIndex >= 0 && storedIndex < allAccounts.count) ? storedIndex : 0
            selectedAccount = allAccounts[safeIndex]
            selectedAccountIndex = safeIndex
        } else {
            selectedAccount = nil
            selectedAccountIndex = 0
            UserDefaults.standard.removeObject(forKey: Self.selectedIndexDefaultsKey)
        }
    }

    private func persistSelectedIndex() {
        if savedAccounts.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.selectedIndexDefaultsKey)
        } else {
            UserDefaults.standard.set(selectedAccountIndex, forKey: Self.selectedIndexDefaultsKey)
        }
    }

    private func restoreSessionIfNeeded() async {
        guard let account = selectedAccount else { return }
        AuthenticationManager.shared.setCookies(account.cookies)
        let isValid = await AuthenticationManager.shared.validateAccount(account)
        if isValid {
            let refreshed = AuthenticationManager.shared.refreshCookies(for: account)
            selectedAccount = refreshed
            if let idx = savedAccounts.firstIndex(where: { $0.email == refreshed.email }) {
                savedAccounts[idx] = refreshed
            }
            try? AuthenticationManager.shared.saveAllAccounts(savedAccounts)
            _ = SessionManager.shared
        } else if savedAccounts.count > 1 {
            logoutAccount()
        }
    }

    func loginAccount(email: String, password: String, code: String?) async throws {
        let account: Account
        if let c = code, !c.isEmpty {

            account = try await AuthenticationManager.shared.authenticateWith2FA(
                email: email,
                password: password,
                code: c
            )
        } else {
            account = try await AuthenticationManager.shared.authenticate(
                email: email,
                password: password,
                mfa: nil
            )
        }

        if let existingIndex = savedAccounts.firstIndex(where: { $0.email == account.email }) {
            savedAccounts[existingIndex] = account
            selectedAccountIndex = existingIndex
        } else {
            savedAccounts.append(account)
            selectedAccountIndex = savedAccounts.count - 1
        }
        selectedAccount = account
        persistSelectedIndex()
        StoreRequest.shared.savePassword(password, for: account.email)
        try? AuthenticationManager.shared.saveAllAccounts(savedAccounts)
        Task.detached(priority: .utility) {
            await StoreRequest.shared.ensureITunesSession(account: account)
        }
    }

    func logoutAccount() {
        guard let currentAccount = selectedAccount else { return }
        deleteAccount(currentAccount)
    }

    func deleteAccount(_ account: Account) {
        if let index = savedAccounts.firstIndex(where: { $0.email == account.email }) {
            savedAccounts.remove(at: index)

            if savedAccounts.isEmpty {
                selectedAccount = nil
                selectedAccountIndex = 0
            } else {
                selectedAccountIndex = min(index, savedAccounts.count - 1)
                selectedAccount = savedAccounts[selectedAccountIndex]
            }
        }
        for c in HTTPCookieStorage.shared.cookies ?? [] where c.domain.lowercased().contains("apple.com") {
            HTTPCookieStorage.shared.deleteCookie(c)
        }
        try? AuthenticationManager.shared.saveAllAccounts(savedAccounts)
        persistSelectedIndex()
    }

    func refreshAccount() {
        loadAccounts()
        objectWillChange.send()
    }

    func switchToAccount(at index: Int) {
        guard index >= 0 && index < savedAccounts.count else { return }
        selectedAccountIndex = index
        selectedAccount = savedAccounts[index]
        persistSelectedIndex()
        Task { await restoreSessionIfNeeded() }
    }

    func switchToAccount(_ account: Account) {
        if let index = savedAccounts.firstIndex(where: { $0.email == account.email }) {
            switchToAccount(at: index)
        }
    }

    func updateAccount(_ account: Account) {
        selectedAccount = account
        if let index = savedAccounts.firstIndex(where: { $0.email == account.email }) {
            savedAccounts[index] = account
        }
        try? AuthenticationManager.shared.saveAllAccounts(savedAccounts)
        persistSelectedIndex()
    }

    func refreshCurrentAccount() async throws {
        guard let account = selectedAccount else {
            return
        }

        AuthenticationManager.shared.setCookies(account.cookies)

        if await AuthenticationManager.shared.validateAccount(account) {
            let updatedAccount = AuthenticationManager.shared.refreshCookies(for: account)
            selectedAccount = updatedAccount
            if let idx = savedAccounts.firstIndex(where: { $0.email == updatedAccount.email }) {
                savedAccounts[idx] = updatedAccount
            }
            try? AuthenticationManager.shared.saveAllAccounts(savedAccounts)
            persistSelectedIndex()
        } else {
            logoutAccount()
        }
    }

    func setCurrentAccountCookies() {
        guard let account = selectedAccount else {
            return
        }
        AuthenticationManager.shared.setCookies(account.cookies)
    }

    var currentAccountRegion: String {
        return selectedAccount?.countryCode ?? ""
    }

    var allAccountRegions: [String] {
        return savedAccounts.map { $0.countryCode }
    }

    var hasMultipleAccounts: Bool {
        return savedAccounts.count > 1
    }
}
