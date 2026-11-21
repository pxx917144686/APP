import SwiftUI

struct CertificateDetailSheet: View {
    let certificate: SigningCertificate
    let profile: SigningProfile?
    let onShowEntitlements: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager

    private var profileCertificate: ProfileCertificate? {
        let certs = profile?.certificates ?? []
        if let match = certs.first(where: { !certificate.teamID.isEmpty && $0.teamID == certificate.teamID }) {
            return match
        }
        return certs.first
    }

    private var usesProfileCertificate: Bool {
        certificate.fingerprint == nil && certificate.serialNumber == nil && profileCertificate != nil
    }

    private var commonName: String {
        usesProfileCertificate ? (profileCertificate?.commonName ?? certificate.commonName) : certificate.commonName
    }

    private var teamID: String {
        let value = usesProfileCertificate ? (profileCertificate?.teamID ?? "") : certificate.teamID
        return value.isEmpty ? "—" : value
    }

    private var serialNumber: String {
        let value = usesProfileCertificate ? (profileCertificate?.serialNumber ?? "") : (certificate.serialNumber ?? "")
        return value.isEmpty ? "—" : value
    }

    private var fingerprint: String {
        let value = usesProfileCertificate ? (profileCertificate?.fingerprint ?? "") : (certificate.fingerprint ?? "")
        return value.isEmpty ? "—" : value
    }

    private var issuer: String {
        let value = usesProfileCertificate ? (profileCertificate?.issuer ?? "") : (certificate.issuer ?? "")
        return value.isEmpty ? "—" : value
    }

    private var subject: String {
        let value = usesProfileCertificate ? (profileCertificate?.subject ?? "") : (certificate.subject ?? "")
        return value.isEmpty ? "—" : value
    }

    private var notBefore: Date? {
        usesProfileCertificate ? profileCertificate?.notBefore : certificate.notBefore
    }

    private var notAfter: Date? {
        usesProfileCertificate ? profileCertificate?.notAfter : certificate.expiresAt
    }

    private var entitlementCount: Int {
        profile?.entitlementKeys?.count ?? 0
    }

    private static var parsedValuesCache: [String: [String: Any]] = [:]

    private var profileEntitlements: [String: Any] {
        guard let profile, let data = profile.entitlementsData else { return [:] }
        let cacheKey = "\(profile.id)-\(data.count)"
        if let cached = Self.parsedValuesCache[cacheKey] { return cached }
        let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
        Self.parsedValuesCache[cacheKey] = dictionary
        return dictionary
    }

    private var appGroups: [String] {
        profileEntitlements["com.apple.security.application-groups"] as? [String] ?? []
    }

    private var keychainGroups: [String] {
        profileEntitlements["keychain-access-groups"] as? [String] ?? []
    }

    private var applicationIdentifier: String {
        (profileEntitlements["application-identifier"] as? String) ?? profile?.applicationIdentifier ?? "—"
    }

    private var getTaskAllow: String {
        guard let value = profileEntitlements["get-task-allow"] as? Bool else { return "—" }
        return value ? "true" : "false"
    }

    private var apsEnvironment: String {
        (profileEntitlements["aps-environment"] as? String) ?? "—"
    }

    private var certificateStatus: String {
        guard let notAfter else { return "sign_cert_detail_unknown".localized }
        return notAfter < Date() ? "sign_cert_detail_expired".localized : "sign_cert_detail_valid".localized
    }

    private var statusColor: Color {
        guard let notAfter else { return .gray }
        return notAfter < Date() ? .red : .green
    }

    private var daysRemaining: Int? {
        guard let notAfter else { return nil }
        return Calendar.current.dateComponents([.day], from: Date(), to: notAfter).day
    }

    private var validityText: String {
        guard let daysRemaining else { return "—" }
        if daysRemaining < 0 {
            return String(format: "sign_cert_detail_days_expired".localized, abs(daysRemaining))
        }
        return String(format: "sign_cert_detail_days_left".localized, daysRemaining)
    }

    private var purposeText: String {
        let lowered = commonName.lowercased()
        if lowered.contains("distribution") {
            return "sign_cert_detail_purpose_distribution".localized
        }
        if lowered.contains("development") || lowered.contains("developer") {
            return "sign_cert_detail_purpose_development".localized
        }
        return "sign_cert_detail_purpose_unknown".localized
    }

    private var sourceText: String {
        usesProfileCertificate ? "sign_cert_detail_source_profile".localized : "sign_cert_detail_source_p12".localized
    }

    private var profileTypeText: String {
        guard let profile else { return "—" }
        if profile.isEnterprise { return "sign_cert_detail_profile_type_enterprise".localized }
        if profile.isWildcard { return "sign_cert_detail_profile_type_wildcard".localized }
        return "sign_cert_detail_profile_type_exact".localized
    }

    private var profileDevicesText: String {
        guard let profile else { return "—" }
        if profile.isEnterprise { return "sign_cert_detail_profile_devices_enterprise".localized }
        return String(format: "sign_cert_detail_profile_devices_value".localized, profile.deviceCount)
    }

    var body: some SwiftUI.View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    header
                    overviewCard
                    certificateFieldsCard
                    if profile != nil {
                        profileCard
                    }
                    appGroupCard
                    entitlementCard
                }
                .padding(16)
            }
            .background(themeManager.backgroundColor.ignoresSafeArea())
            .navigationTitle("sign_cert_detail_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some SwiftUI.View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [themeManager.accentColor.opacity(0.22), Color.cyan.opacity(0.08), Color.clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 44, height: 44)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(certificate.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                    Text(commonName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        tag(teamID == "—" ? "TEAM —" : "TEAM \(teamID)", color: themeManager.accentColor)
                        tag(certificateStatus, color: statusColor)
                        if let notAfter {
                            tag(dateText(notAfter), color: notAfter < Date() ? .red : .green)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(themeManager.accentColor.opacity(0.18), lineWidth: 0.5))
    }

    private var overviewCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(themeManager.accentColor)
                Text("sign_cert_detail_overview".localized)
                    .font(.system(size: 13, weight: .bold))
            }

            Text("sign_cert_detail_overview_hint".localized)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            detailRow("sign_cert_detail_status".localized, certificateStatus, mono: false, color: statusColor)
            divider
            detailRow("sign_cert_detail_validity".localized, validityText, mono: true, color: (daysRemaining ?? 0) < 0 ? .red : .secondary)
            divider
            detailRow("sign_cert_detail_purpose".localized, purposeText, mono: false)
            divider
            detailRow("sign_cert_detail_source".localized, sourceText, mono: false)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var certificateFieldsCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("sign_cert_detail_cert_fields".localized, icon: "key.horizontal.fill")

            if usesProfileCertificate {
                infoLine("sign_cert_detail_from_profile".localized, color: .secondary)
            } else if certificate.fingerprint == nil {
                infoLine("sign_cert_detail_unavailable".localized, color: .orange)
            }

            fieldRow("sign_cert_detail_common_name".localized, commonName, caption: "sign_cert_detail_caption_cn".localized, mono: false)
            divider
            fieldRow("sign_cert_detail_team".localized, teamID, caption: "sign_cert_detail_caption_team".localized, mono: true)
            divider
            fieldRow("sign_cert_detail_serial".localized, serialNumber, caption: "sign_cert_detail_caption_serial".localized, mono: true)
            divider
            fieldRow("sign_cert_detail_not_before".localized, notBefore.map(dateText) ?? "—", caption: "sign_cert_detail_caption_not_before".localized, mono: true)
            divider
            fieldRow("sign_cert_detail_not_after".localized, notAfter.map(dateText) ?? "—", caption: "sign_cert_detail_caption_not_after".localized, mono: true, highlight: (notAfter ?? .distantFuture) < Date())
            divider
            fieldRow("sign_cert_detail_issuer".localized, issuer, caption: "sign_cert_detail_caption_issuer".localized, mono: false)
            divider
            fieldRow("sign_cert_detail_subject".localized, subject, caption: "sign_cert_detail_caption_subject".localized, mono: false)
            divider
            fieldRow("sign_cert_detail_fingerprint".localized, fingerprint, caption: "sign_cert_detail_caption_fingerprint".localized, mono: true, multiline: true)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var profileCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader("sign_cert_detail_profile_title".localized, icon: "doc.badge.gearshape.fill")

            if let profile {
                fieldRow("sign_cert_detail_profile_name".localized, profile.displayName, caption: nil, mono: false)
                divider
                fieldRow("sign_cert_detail_profile_appid".localized, profile.applicationIdentifier.isEmpty ? "—" : profile.applicationIdentifier, caption: "sign_cert_detail_caption_appid".localized, mono: true)
                divider
                fieldRow("sign_cert_detail_profile_team".localized, profile.teamID.isEmpty ? "—" : "\(profile.teamName) (\(profile.teamID))", caption: nil, mono: false)
                divider
                fieldRow("sign_cert_detail_profile_expiry".localized, profile.expiresAt.map(dateText) ?? "—", caption: "sign_cert_detail_caption_profile_expiry".localized, mono: true, highlight: (profile.expiresAt ?? .distantFuture) < Date())
                divider
                fieldRow("sign_cert_detail_profile_devices".localized, profileDevicesText, caption: "sign_cert_detail_caption_devices".localized, mono: false)
                divider
                fieldRow("sign_cert_detail_profile_type".localized, profileTypeText, caption: nil, mono: false)
                if !profile.platforms.isEmpty {
                    divider
                    fieldRow("sign_cert_detail_profile_platforms".localized, profile.platforms.joined(separator: ", "), caption: nil, mono: true)
                }
                divider
                fieldRow("sign_cert_detail_profile_certs".localized, "\(profile.certificates?.count ?? 0)", caption: nil, mono: true)
                divider
                fieldRow("sign_cert_detail_profile_entitlements".localized, "\(entitlementCount)", caption: "sign_cert_detail_caption_entitlements".localized, mono: true)
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var appGroupCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("sign_cert_detail_app_groups".localized, icon: "square.stack.3d.up.fill")

            if appGroups.isEmpty {
                Text("sign_cert_detail_app_groups_empty".localized)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(appGroups, id: \.self) { group in
                        HStack(spacing: 5) {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.cyan)
                            Text(group)
                                .font(.system(size: 9.5, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.cyan.opacity(0.06))
                )
            }

            Text("sign_cert_detail_app_groups_hint".localized)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !keychainGroups.isEmpty {
                Text("sign_cert_detail_keychain_groups".localized)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(keychainGroups, id: \.self) { group in
                        Text(group)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack(spacing: 10) {
                miniMeta("sign_cert_detail_app_identifier".localized, applicationIdentifier)
                miniMeta("sign_cert_detail_get_task_allow".localized, getTaskAllow)
                miniMeta("sign_cert_detail_aps".localized, apsEnvironment)
            }
            .padding(.top, 2)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var entitlementCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(themeManager.accentColor)
                Text("sign_cert_detail_entitlements".localized)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(entitlementCount)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Text("sign_cert_detail_entitlements_source".localized)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if profile == nil {
                Text("sign_cert_detail_no_profile".localized)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if entitlementCount == 0 {
                Text("sign_entitlements_empty".localized)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text("sign_cert_detail_entitlements_hint".localized)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onShowEntitlements) {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .bold))
                        Text("sign_entitlements_open".localized)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(themeManager.accentColor)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(themeManager.accentColor.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func sectionHeader(_ title: String, icon: String) -> some SwiftUI.View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(themeManager.accentColor)
            Text(title)
                .font(.system(size: 12.5, weight: .bold))
            Spacer()
        }
        .padding(.bottom, 6)
    }

    private func infoLine(_ text: String, color: Color) -> some SwiftUI.View {
        HStack(spacing: 5) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 9))
        }
        .foregroundStyle(color)
        .padding(.bottom, 6)
    }

    private func fieldRow(_ title: String, _ value: String, caption: String?, mono: Bool, multiline: Bool = false, highlight: Bool = false) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: mono ? 10 : 11, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(highlight ? .red : .primary)
                .lineLimit(multiline ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let caption, !caption.isEmpty {
                Text(caption)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
    }

    private func detailRow(_ title: String, _ value: String, mono: Bool, color: Color = .primary) -> some SwiftUI.View {
        HStack(alignment: .top, spacing: 8) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(value)
                .font(.system(size: mono ? 9.5 : 10, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func miniMeta(_ title: String, _ value: String) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 7.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some SwiftUI.View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: 0.5)
    }

    private func tag(_ text: String, color: Color) -> some SwiftUI.View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }
}
