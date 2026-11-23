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
                        .accessibilityLabel(isPasswordVisible ? "hide_password".localized : "show_password".localized)
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
                .fill(.ultraThinMaterial)
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

    private func flag(country code: String) -> String {
        guard code.count == 2 else { return "🌐" }
        let base: UInt32 = 0x1F1E6
        var scalars = String.UnicodeScalarView()
        for scalar in code.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { return "🌐" }
            if let flagScalar = Unicode.Scalar(base + (scalar.value - 65)) {
                scalars.append(flagScalar)
            } else {
                return "🌐"
            }
        }
        return scalars.count == 2 ? String(scalars) : "🌐"
    }

    private func countryName(_ code: String) -> String {
        RegionNames.localizedName(for: code)
    }

    private func deleteAccount() {
        SoundEffects.play(.dismiss)
        AppStore.this.deleteAccount(account)
        dismiss()
    }

}
