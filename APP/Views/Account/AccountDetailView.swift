import SwiftUI

struct AccountDetailView: View {
    let account: Account
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appStore: AppStore
    @EnvironmentObject var themeManager: ThemeManager
    @State private var showingDeleteAlert = false
    @State private var isPasswordVisible = false
    @State private var areSessionTokensVisible = false

    var body: some View {
        List {

            Section {
                accountHeader
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }

            Section {
                infoRow(title: "apple_id".localized, value: account.email, isEmail: true)
                infoRow(title: "name".localized, value: account.fullName)
            } header: {
                Text("basic_info".localized)
            }

            Section {
                infoRow(title: "DSID", value: account.dsPersonId, isMonospaced: true)
            } header: {
                Text("account_identifier".localized)
            }

            Section {
                HStack {
                    Text("country_region".localized)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(flag(country: account.countryCode)) \(countryName(account.countryCode))")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("region_title".localized)
            }

            Section {
                HStack {
                    Text("password_token".localized)
                        .font(.system(size: 15))
                        .foregroundColor(.primary)
                    Spacer()

                    if account.passwordToken.isEmpty {
                        Text("no_value".localized)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.5))
                    } else {
                        Text(isPasswordVisible ? account.passwordToken : String(repeating: "•", count: min(account.passwordToken.count, 16)))
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .trailing)

                        Button(action: {
                            isPasswordVisible.toggle()
                        }) {
                            Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(themeManager.accentColor)
                                .font(.system(size: 14))
                        }
                        .padding(.leading, 4)
                    }
                }
            } header: {
                Text("auth_info".localized)
            } footer: {
                Text("password_token_hint".localized)
            }



            Section {
                Button(role: .destructive, action: {
                    showingDeleteAlert = true
                }) {
                    HStack {
                        Spacer()
                        Text("delete_this_account".localized)
                            .font(.system(size: 16, weight: .medium))
                        Spacer()
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("account_detail".localized)
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
        .alert("delete_account".localized, isPresented: $showingDeleteAlert) {
            Button("cancel".localized, role: .cancel) {
                showingDeleteAlert = false
            }
            Button("delete".localized, role: .destructive) {
                deleteAccount()
            }
        } message: {
            Text(String(format: "delete_account_confirm_detail".localized, account.email))
        }
    }

    private var accountHeader: some View {
        VStack(spacing: 12) {
            AccountAvatarButton(size: 80)

            VStack(spacing: 4) {
                Text(account.fullName.isEmpty ? account.email : account.fullName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.primary)

                if !account.fullName.isEmpty {
                    Text(account.email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 6) {
                    Text(flag(country: account.countryCode))
                        .font(.caption)
                    Text(countryName(account.countryCode))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .padding(.horizontal, 16)
    }

    private func infoRow(title: String, value: String, isEmail: Bool = false, isMonospaced: Bool = false) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.primary)
            Spacer()
            if value.isEmpty {
                Text("no_value".localized)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary.opacity(0.5))
            } else {
                Text(value)
                    .font(isMonospaced ? .system(size: 14, design: .monospaced) : .system(size: 15))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private func tokenRow(title: String, value: String, visible: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .frame(minWidth: 96, alignment: .leading)

            Spacer()

            if value.isEmpty {
                Text("no_value".localized)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.5))
            } else if visible {
                Text(value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(6)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
            } else {
                Text(String(repeating: "•", count: min(value.count, 24)))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private func deleteAccount() {
        if appStore.savedAccounts.count == 1 {
            appStore.logoutAccount()
        } else {
            appStore.deleteAccount(account)
        }
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
