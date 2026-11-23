import SwiftUI

struct ExtensionCredentialsSheet: View {
    let targets: [SigningTarget]
    let certificates: [SigningCertificate]
    let profiles: [SigningProfile]
    let mainCertificate: SigningCertificate?
    let mainProfile: SigningProfile?
    let oldMainID: String
    let newMainID: String
    let usesCustomMainID: Bool
    let hasPassword: (SigningCertificate) -> Bool

    @Binding var choices: [String: ExtensionCredentialChoice]

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("sign_extension_credentials_hint".localized)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if targets.isEmpty {
                    Section {
                        Text("sign_extension_credentials_empty".localized)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(targets) { target in
                        targetSection(target)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("sign_extension_credentials".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("done".localized) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func targetSection(_ target: SigningTarget) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: target.kind.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(themeManager.accentColor)
                    Text(target.displayName.isEmpty ? target.kind.title : target.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if choice(for: target).certificateID != nil || choice(for: target).profileID != nil {
                        Text("sign_extension_custom_badge".localized)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(themeManager.accentColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(themeManager.accentColor.opacity(0.12)))
                    }
                }

                Text(target.bundleIdentifier)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Picker(selection: certificateBinding(for: target)) {
                    Text("sign_extension_follow_main_certificate".localized)
                        .tag(Optional<UUID>.none)
                    ForEach(certificates) { cert in
                        Text(cert.displayName.isEmpty ? cert.commonName : cert.displayName)
                            .tag(Optional(cert.id))
                    }
                } label: {
                    Text("sign_extension_certificate".localized)
                        .font(.system(size: 12))
                }
                .pickerStyle(.menu)
                .tint(themeManager.accentColor)

                Picker(selection: profileBinding(for: target)) {
                    Text("sign_extension_auto_profile".localized)
                        .tag(Optional<UUID>.none)
                    ForEach(profilesMatching(target)) { candidate in
                        Text(candidate.displayName)
                            .tag(Optional(candidate.id))
                    }
                } label: {
                    Text("sign_extension_profile".localized)
                        .font(.system(size: 12))
                }
                .pickerStyle(.menu)
                .tint(themeManager.accentColor)

                HStack(spacing: 4) {
                    Text("sign_extension_id".localized)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(effectiveID(for: target))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Spacer(minLength: 0)
                }

                if let profile = resolvedProfile(for: target) {
                    if !profile.covers(bundleID: target.bundleIdentifier),
                       !profile.covers(bundleID: derivedID(for: target)) {
                        Label("sign_extension_profile_missing".localized, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                } else {
                    Label("sign_extension_profile_missing".localized, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if let cert = selectedCertificate(for: target),
                   let profile = resolvedProfile(for: target),
                   !profileCovers(profile, certificate: cert) {
                    Label("sign_extension_cert_mismatch".localized, systemImage: "xmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if let cert = selectedCertificate(for: target), !hasPassword(cert) {
                    Label("sign_extension_password_missing".localized, systemImage: "key.slash.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }

                if choice(for: target).certificateID != nil || choice(for: target).profileID != nil {
                    Button {
                        choices.removeValue(forKey: target.bundlePath)
                    } label: {
                        Text("sign_extension_reset".localized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text(target.kind.title)
        }
    }

    private func choice(for target: SigningTarget) -> ExtensionCredentialChoice {
        choices[target.bundlePath] ?? ExtensionCredentialChoice()
    }

    private func certificateBinding(for target: SigningTarget) -> Binding<UUID?> {
        Binding(
            get: { choice(for: target).certificateID },
            set: { newValue in
                var value = choice(for: target)
                value.certificateID = newValue
                value.profileID = nil
                choices[target.bundlePath] = value
            }
        )
    }

    private func profileBinding(for target: SigningTarget) -> Binding<UUID?> {
        Binding(
            get: { choice(for: target).profileID },
            set: { newValue in
                var value = choice(for: target)
                value.profileID = newValue
                choices[target.bundlePath] = value
            }
        )
    }

    private func selectedCertificate(for target: SigningTarget) -> SigningCertificate? {
        if let id = choice(for: target).certificateID {
            return certificates.first { $0.id == id }
        }
        return mainCertificate
    }

    private func derivedID(for target: SigningTarget) -> String {
        guard usesCustomMainID else { return target.bundleIdentifier }
        if target.bundleIdentifier == oldMainID {
            return newMainID
        }
        if target.bundleIdentifier.hasPrefix(oldMainID + ".") {
            return newMainID + String(target.bundleIdentifier.dropFirst(oldMainID.count))
        }
        let suffix = target.bundleIdentifier.split(separator: ".").suffix(2).joined(separator: ".")
        return suffix.isEmpty ? newMainID : newMainID + "." + suffix
    }

    private func profileCovers(_ candidate: SigningProfile, certificate: SigningCertificate?) -> Bool {
        guard let certificate else { return true }
        if let expiry = candidate.expiresAt, expiry < Date() { return false }
        if !certificate.teamID.isEmpty,
           !candidate.teamID.isEmpty,
           certificate.teamID != candidate.teamID {
            return false
        }
        if let fingerprint = certificate.fingerprint,
           !fingerprint.isEmpty,
           let profileCertificates = candidate.certificates,
           !profileCertificates.isEmpty,
           !profileCertificates.contains(where: { $0.fingerprint?.caseInsensitiveCompare(fingerprint) == .orderedSame }) {
            return false
        }
        return true
    }

    private func profilesMatching(_ target: SigningTarget) -> [SigningProfile] {
        let certificate = selectedCertificate(for: target)
        let derived = derivedID(for: target)
        let original = target.bundleIdentifier
        var result = profiles.filter { candidate in
            profileCovers(candidate, certificate: certificate)
                && (candidate.covers(bundleID: original) || candidate.covers(bundleID: derived))
        }
        if let selectedID = choice(for: target).profileID,
           !result.contains(where: { $0.id == selectedID }),
           let selected = profiles.first(where: { $0.id == selectedID }) {
            result.append(selected)
        }
        return result.sorted { lhs, rhs in
            let lhsExact = lhs.bundleIDPattern == original || lhs.bundleIDPattern == derived
            let rhsExact = rhs.bundleIDPattern == original || rhs.bundleIDPattern == derived
            if lhsExact != rhsExact { return lhsExact }
            return lhs.bundleIDPattern.count > rhs.bundleIDPattern.count
        }
    }

    private func autoProfile(for target: SigningTarget) -> SigningProfile? {
        let derived = derivedID(for: target)
        let original = target.bundleIdentifier
        return profilesMatching(target).first { candidate in
            candidate.covers(bundleID: original) || candidate.covers(bundleID: derived)
        }
    }

    private func resolvedProfile(for target: SigningTarget) -> SigningProfile? {
        if let id = choice(for: target).profileID {
            return profiles.first { $0.id == id }
        }
        return autoProfile(for: target)
    }

    private func effectiveID(for target: SigningTarget) -> String {
        guard usesCustomMainID else { return target.bundleIdentifier }
        let derived = derivedID(for: target)
        guard let profile = resolvedProfile(for: target) else { return derived }
        if let mainProfile, profile.id == mainProfile.id {
            return derived
        }
        if profile.covers(bundleID: derived) {
            return derived
        }
        if profile.covers(bundleID: target.bundleIdentifier) {
            return target.bundleIdentifier
        }
        return derived
    }
}
