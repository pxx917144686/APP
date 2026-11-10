import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct AccountView: View {
    @State private var addSheet = false
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showDeleteAlert = false
    @State private var accountToDelete: Account?
    @State private var selectedAccountForDetail: Account?

    var body: some View {
        NavigationView {
            List {

                Section {
                    if let account = appStore.selectedAccount {
                        accountHeaderCard(account: account)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                            .onTapGesture {
                                selectedAccountForDetail = account
                            }
                    } else {
                        emptyAccountCard
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    }
                }

                if appStore.hasMultipleAccounts {
                    Section {
                        ForEach(Array(appStore.savedAccounts.enumerated()), id: \.element.id) { index, account in
                            Button(action: {
                                appStore.switchToAccount(at: index)
                            }) {
                                accountRow(account: account, isSelected: index == appStore.selectedAccountIndex)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    accountToDelete = account
                                    showDeleteAlert = true
                                } label: {
                                    Label("delete".localized, systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("all_accounts".localized)
                    }
                }

                Section {
                    Button(action: {
                        addSheet.toggle()
                    }) {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .foregroundColor(.green)
                            Text("add_account".localized)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                    }

                    if appStore.selectedAccount != nil {
                        Button(role: .destructive, action: {
                            if let account = appStore.selectedAccount {
                                accountToDelete = account
                                showDeleteAlert = true
                            }
                        }) {
                            HStack(spacing: 12) {
                                Image(systemName: "rectangle.portrait.and.arrow.right.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.red)
                                Text("logout".localized)
                                    .font(.system(size: 15))
                                    .foregroundColor(.red)
                                Spacer()
                            }
                        }
                    }
                }

                if let account = appStore.selectedAccount {
                    Section {
                        NavigationLink(destination: AccountDetailView(account: account)) {
                            HStack {
                                Text("region".localized)
                                    .font(.system(size: 15))
                                    .foregroundColor(.primary)
                                Spacer()
                                Text("\(flag(country: account.countryCode)) \(countryName(account.countryCode))")
                                    .font(.system(size: 15))
                                    .foregroundColor(.secondary)
                            }
                        }

                        HStack {
                            Text("dsid".localized)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                            Spacer()
                            Text(account.directoryServicesIdentifier)
                                .font(.system(size: 14, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } header: {
                        Text("account_info".localized)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("apple_id".localized)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if appStore.selectedAccount != nil {
                        Button(action: { addSheet.toggle() }) {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(themeManager.accentColor)
                        }
                    }
                }
            }
            .sheet(isPresented: $addSheet) {
                AddAccountView()
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
            .sheet(item: $selectedAccountForDetail) { account in
                NavigationView {
                    AccountDetailView(account: account)
                }
                .environmentObject(appStore)
                .environmentObject(themeManager)
            }
            .alert("confirm_delete".localized, isPresented: $showDeleteAlert) {
                Button("cancel".localized, role: .cancel) {
                    accountToDelete = nil
                }
                Button("delete".localized, role: .destructive) {
                    if let account = accountToDelete {
                        if appStore.savedAccounts.count == 1 {
                            appStore.logoutAccount()
                        } else if let index = appStore.savedAccounts.firstIndex(where: { $0.id == account.id }) {
                            appStore.deleteAccount(account)
                            if index <= appStore.selectedAccountIndex && appStore.selectedAccountIndex > 0 {
                                appStore.selectedAccountIndex -= 1
                            }
                        }
                        accountToDelete = nil
                    }
                }
            } message: {
                if let account = accountToDelete {
                    Text(String(format: "delete_account_message".localized, account.email))
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyAccountCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))

            VStack(spacing: 6) {
                Text("login_apple_id".localized)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)

                Text("login_apple_id_desc".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: {
                addSheet.toggle()
            }) {
                Text("login_apple_id_btn".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(themeManager.accentColor)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, 16)
    }

    private func accountHeaderCard(account: Account) -> some View {
        HStack(spacing: 16) {
            AccountAvatarButton(size: 72)

            VStack(alignment: .leading, spacing: 6) {
                Text(account.name.isEmpty ? account.email : account.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if !account.name.isEmpty {
                    Text(account.email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Text(flag(country: account.countryCode))
                            .font(.caption)
                        Text(countryName(account.countryCode))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !account.dsPersonId.isEmpty {
                        Text("DS: \(account.dsPersonId)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.gray.opacity(0.15))
                            )
                    }
                }
                .padding(.top, 2)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
    }

    private func accountRow(account: Account, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(themeManager.accentColor.opacity(0.15))
                .frame(width: 36, height: 36)
                .overlay(
                    Text(String(account.email.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(themeManager.accentColor)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(account.email)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(flag(country: account.countryCode) + " " + countryName(account.countryCode))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(themeManager.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    private func flag(country: String) -> String {
        let base: UInt32 = 127397
        var s = ""
        for v in country.uppercased().unicodeScalars {
            if let scalar = UnicodeScalar(base + v.value) {
                s.unicodeScalars.append(scalar)
            }
        }
        return s
    }

    private func countryName(_ code: String) -> String {
        let locale = LanguageManager.shared.locale
        return locale.localizedString(forRegionCode: code) ?? code.uppercased()
    }
}

#Preview {
    AccountView()
        .environmentObject(AppStore.this)
        .environmentObject(ThemeManager.shared)
}
