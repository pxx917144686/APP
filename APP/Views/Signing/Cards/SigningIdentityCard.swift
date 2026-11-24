import SwiftUI

struct SigningIdentityCard: SwiftUI.View {
    let certificate: SigningCertificate?
    let profile: SigningProfile?
    let certificates: [SigningCertificate]
    let profiles: [SigningProfile]
    let accent: Color
    let colorScheme: ColorScheme
    let isCheckingRevocation: Bool
    let onAdd: () -> Void
    let onShowDetail: () -> Void
    let onShowEntitlements: () -> Void
    let onCheckRevocation: () -> Void
    let onSelectCertificate: (SigningCertificate) -> Void
    let onSelectProfile: (UUID) -> Void
    let onImportCertificate: () -> Void
    let onImportProfile: () -> Void
    let onDeleteCertificate: () -> Void
    let onDeleteProfile: () -> Void

    var body: some SwiftUI.View {
        SigningSectionCard(
            title: "sign_identity_section".localized,
            icon: "person.badge.key.fill",
            accent: accent,
            action: onAdd
        ) {
            if certificate != nil || profile != nil {
                summaryRow
            } else {
                SigningEmptyRow(
                    icon: "person.badge.key",
                    title: "sign_identity_empty".localized,
                    hint: "sign_identity_empty_hint".localized,
                    actionTitle: "sign_identity_import".localized,
                    accent: accent,
                    colorScheme: colorScheme,
                    action: onAdd
                )
            }
        }
    }

    private var summaryRow: some SwiftUI.View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(accent.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(certificateName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    pairingBadge
                }

                Text(subtitle)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    if let expiresAt = certificateExpiry {
                        SigningMetaText(title: "sign_cert_section".localized, value: dateText(expiresAt), warning: expiresAt < Date())
                    }
                    if let profile, let expiresAt = profile.expiresAt {
                        SigningMetaText(title: "sign_profile_section".localized, value: dateText(expiresAt), warning: expiresAt < Date())
                    }
                    if let profile {
                        SigningMetaText(title: "sign_profile_devices".localized, value: profile.isEnterprise ? "sign_profile_enterprise".localized : "\(profile.deviceCount)")
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 7) {
                Button(action: onShowDetail) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("detail_action".localized)

                Button(action: onShowEntitlements) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("sign_entitlements_title".localized)

                Menu {
                    menuContent
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
        )
    }

    private var certificateName: String {
        if let certificate {
            if certificate.teamID.isEmpty, let profileCertificate = profile?.certificates?.first {
                return profileCertificate.commonName
            }
            return certificate.commonName
        }
        return profile?.displayName ?? "—"
    }

    private var certificateExpiry: Date? {
        certificate?.expiresAt ?? profile?.certificates?.first?.notAfter
    }

    private var subtitle: String {
        let team = certificate?.teamID.isEmpty == false ? certificate!.teamID : (profile?.teamID ?? "—")
        let appID = profile?.bundleIDPattern ?? "—"
        return "\(team)  ·  \(appID)"
    }

    private enum Pairing {
        case waiting
        case paired(String)
        case mismatch(String)
    }

    private var pairing: Pairing {
        guard let certificate, let profile else { return .waiting }
        let certTeam = certificate.teamID
        if certTeam.isEmpty || profile.teamID.isEmpty || certTeam == profile.teamID {
            return .paired(profile.teamID.isEmpty ? "—" : profile.teamID)
        }
        return .mismatch("\(certTeam) / \(profile.teamID)")
    }

    private var pairingBadge: some SwiftUI.View {
        let color: Color
        let icon: String
        let text: String
        switch pairing {
        case .waiting:
            color = .orange
            icon = "link.badge.plus"
            text = "sign_identity_waiting".localized
        case .paired(let team):
            color = .green
            icon = "checkmark.circle.fill"
            text = String(format: "sign_identity_paired".localized, team)
        case .mismatch(let teams):
            color = .red
            icon = "exclamationmark.triangle.fill"
            text = String(format: "sign_identity_mismatch".localized, teams)
        }

        return HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(text)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.10)))
    }

    @SwiftUI.ViewBuilder
    private var menuContent: some SwiftUI.View {
        Section("sign_select_certificate".localized) {
            ForEach(certificates) { item in
                Button {
                    onSelectCertificate(item)
                } label: {
                    Label(item.displayName, systemImage: item.id == certificate?.id ? "checkmark" : "key")
                }
            }
        }
        Section("sign_select_profile".localized) {
            ForEach(profiles) { item in
                Button {
                    onSelectProfile(item.id)
                } label: {
                    Label(item.displayName, systemImage: item.id == profile?.id ? "checkmark" : "doc")
                }
            }
        }
        Divider()
        Button(action: onShowDetail) {
            Label("sign_cert_detail_title".localized, systemImage: "info.circle")
        }
        Button(action: onShowEntitlements) {
            Label("sign_entitlements_title".localized, systemImage: "checkmark.shield")
        }
        Button(action: onCheckRevocation) {
            Label("sign_ocsp_check".localized, systemImage: "checkmark.seal")
        }
        .disabled(isCheckingRevocation)
        Divider()
        Button(action: onImportCertificate) {
            Label("sign_import_cert".localized, systemImage: "plus")
        }
        Button(action: onImportProfile) {
            Label("sign_import_profile".localized, systemImage: "plus")
        }
        if certificate != nil {
            Divider()
            Button(role: .destructive, action: onDeleteCertificate) {
                Label("sign_delete_cert".localized, systemImage: "trash")
            }
        }
        if profile != nil {
            Button(role: .destructive, action: onDeleteProfile) {
                Label("sign_delete_profile".localized, systemImage: "trash")
            }
        }
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
