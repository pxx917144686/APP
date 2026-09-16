import SwiftUI

struct AccountSheetView: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var showAddAccount = false
    @State private var selectedAccountForDetail: Account?

    var body: some View {
        NavigationView {
            List {
                if let account = appStore.selectedAccount {
                    profileHeaderSection(account: account)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 20, leading: 0, bottom: 20, trailing: 0))

                    nameEmailSection(account: account)

                    accountIdentifierSection(account: account)

                    regionSection(account: account)

                } else {
                    emptyAccountSection
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 32, leading: 0, bottom: 32, trailing: 0))
                }

                if appStore.hasMultipleAccounts {
                    switchAccountSection
                }

                actionSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("apple_id".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("back".localized) {
                        dismiss()
                    }
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(themeManager.accentColor)
                }
            }
            .sheet(isPresented: $showAddAccount) {
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
        }
    }

    private var emptyAccountSection: some View {
        VStack(spacing: 20) {
            Text("👤")
                .font(.system(size: 64))

            VStack(spacing: 8) {
                Text("sign_in_apple_id".localized)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.primary)

                Text("sign_in_apple_id_desc".localized)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button(action: {
                showAddAccount = true
            }) {
                Text("login_apple_id_btn".localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(themeManager.accentColor)
                    .cornerRadius(14)
            }
            .padding(.horizontal, 32)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func profileHeaderSection(account: Account) -> some View {
        VStack(spacing: 16) {
            ZStack {
                AccountAvatarButton(size: 84)

                Circle()
                    .stroke(themeManager.accentColor.opacity(0.3), lineWidth: 3)
                    .frame(width: 94, height: 94)
            }

            VStack(spacing: 4) {
                Text(account.fullName.isEmpty ? account.email : account.fullName)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if !account.fullName.isEmpty {
                    Text(account.email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func nameEmailSection(account: Account) -> some View {
        Section {
            VStack(spacing: 0) {
                HStack {
                    Text("name".localized)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(account.fullName.isEmpty ? "-" : account.fullName)
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 10)

                Divider()
                    .padding(.leading, 16)

                HStack {
                    Text("apple_id_email".localized)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(account.email)
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.vertical, 10)
            }
        } header: {
            Text("name_email_header".localized)
        }
    }

    private func accountIdentifierSection(account: Account) -> some View {
        Section {
            VStack(spacing: 0) {
                HStack {
                    Text("DSID")
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(account.dsPersonId.isEmpty ? "-" : account.dsPersonId)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 10)
            }
        } header: {
            Text("account_identifier_header".localized)
        }
    }


    private func regionSection(account: Account) -> some View {
        Section {
            HStack {
                Text("country_region".localized)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                Spacer()
                HStack(spacing: 6) {
                    Text(flag(country: account.countryCode))
                        .font(.system(size: 15))
                    Text(countryName(account.countryCode))
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 10)
        } header: {
            Text("region_header".localized)
        }
    }

    private var switchAccountSection: some View {
        Section {
            ForEach(Array(appStore.savedAccounts.enumerated()), id: \.element.id) { index, account in
                Button(action: {
                    appStore.switchToAccount(at: index)
                }) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(themeManager.accentColor.opacity(0.15))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(String(account.email.prefix(1)).uppercased())
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(themeManager.accentColor)
                            )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email)
                                .font(.system(size: 15))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Text(flag(country: account.countryCode) + " " + countryName(account.countryCode))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if index == appStore.selectedAccountIndex {
                            Text("✅")
                                .font(.system(size: 20))
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("switch_account".localized)
        }
    }

    private var actionSection: some View {
        Section {
            Button(action: {
                showAddAccount = true
            }) {
                HStack(spacing: 12) {
                    Text("➕")
                        .font(.system(size: 22))
                    Text("add_account".localized)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                    Spacer()
                    Text("›")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }

            if appStore.selectedAccount != nil {
                Button(role: .destructive, action: {
                    logoutAccount()
                }) {
                    HStack(spacing: 12) {
                        Text("✖️")
                            .font(.system(size: 22))
                        Text("sign_out".localized)
                            .font(.system(size: 15))
                            .foregroundColor(.red)
                        Spacer()
                    }
                }
            }
        }
    }

    private func logoutAccount() {
        appStore.logoutAccount()
        dismiss()
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
    AccountSheetView()
        .environmentObject(AppStore.this)
        .environmentObject(ThemeManager.shared)
}
