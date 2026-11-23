import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine
import ZsignSwift

struct SignView: SwiftUI.View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabBarStyleManager: TabBarStyleManager
    @StateObject private var store = SigningStore.shared
    @StateObject private var session = SigningSession()
    @StateObject private var downloads = UnifiedDownloadManager.shared
    @ObservedObject private var historyStore = SigningHistoryStore.shared

    @ObservedObject private var handoff = SigningHandoff.shared
    @State private var selectedIPA: SigningIPAInfo?
    @State private var bundleID = ""
    @State private var displayName = ""
    @State private var version = ""
    @State private var removeProvision = false
    @State private var removeAllExtensions = false
    @State private var removeWatchApp = false
    @State private var removeUncoveredExtensions = true
    @State private var useTargetProfiles = true
    @State private var autoInstallAfterSign = false
    @State private var showSelfInstallAlert = false
    @State private var didAutoInstall = false
    @State private var didSeedDefaultInjection = false
    @State private var isLoadingIPA = false
    @State private var selectedEntitlementKeys: Set<String> = []
    @State private var entitlementsReady = false
    @State private var entitlementsMode: SigningEntitlementsMode = .profile
    @State private var isolateKeychain = false
    @State private var dropUnsignableEntitlements = false
    @State private var removeICloudEntitlements = false
    @State private var keepGetTaskAllow = false
    @State private var increasedMemoryLimit = false
    @State private var showCertificateDetail = false
    @State private var showEntitlements = false
    @State private var injections: [SigningInjection] = []
    @State private var showDylibImporter = false
    @State private var showFrameworkImporter = false
    @State private var showInjectionMenu = false
    @State private var showIdentityImportMenu = false
    @State private var ocspChecking = false
    @State private var targets: [SigningTarget] = []
    @State private var targetEditingInjectionID: UUID?
    @State private var showTargetSheet = false
    @State private var showHistory = false
    @State private var showDeviceSheet = false
    @State private var pendingSigningMetadata: PendingSigningMetadata?
    @State private var pendingRefreshRecord: SigningHistoryRecord?
    @AppStorage("signingDeviceUDID") private var deviceUDID = ""
    @AppStorage("signingUDIDServiceURL") private var udidServiceURL = "https://udid.my/"

    @State private var showCertificateImporter = false
    @State private var showProfileImporter = false
    @State private var pendingCertificateQueue: [URL] = []
    @State private var showIPAImporter = false
    @State private var showIPAPicker = false
    @State private var showCertificateSheet = false
    @State private var pendingCertificateData: Data?
    @State private var pendingCertificateName = ""

    @State private var showAlert = false
    @State private var alertTitle = "sign_error_title".localized
    @State private var alertMessage = ""
    @State private var shareFile: ShareFile?
    @State private var isInstalling = false
    @State private var installPhase: SigningInstallPhase = .idle

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color { themeManager.accentColor }
    private var certificate: SigningCertificate? { store.selectedCertificate }
    private var profile: SigningProfile? { store.selectedProfile }
    private var certificatePassword: String? {
        guard let certificate else { return nil }
        return store.password(for: certificate)
    }

    private var trimmedBundleID: String { bundleID.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var signingEntitlementsPlist: Data? {
        guard let profile,
              let data = profile.entitlementsData,
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let requiredKeys = selectedIPA?.requiredEntitlementKeys ?? []
        let baseKeys: Set<String>
        switch entitlementsMode {
        case .profile:
            baseKeys = Set(dictionary.keys)
        case .appDeclared:
            guard !requiredKeys.isEmpty else { return nil }
            baseKeys = requiredKeys.intersection(dictionary.keys)
        case .custom:
            guard entitlementsReady else { return nil }
            baseKeys = selectedEntitlementKeys.intersection(dictionary.keys)
        }

        if entitlementsMode == .profile
            && !isolateKeychain
            && !dropUnsignableEntitlements
            && !removeICloudEntitlements
            && !keepGetTaskAllow
            && !increasedMemoryLimit {
            return nil
        }

        var filtered = dictionary.filter { baseKeys.contains($0.key) }

        if isolateKeychain,
           filtered["keychain-access-groups"] != nil,
           let keychain = dictionary["keychain-access-groups"] as? [String],
           !keychain.isEmpty {
            let team = profile.teamID
            let bundle = trimmedBundleID.isEmpty ? (selectedIPA?.bundleIdentifier ?? "") : trimmedBundleID
            if !team.isEmpty, !bundle.isEmpty {
                filtered["keychain-access-groups"] = ["\(team).\(bundle)"]
            }
        }

        if dropUnsignableEntitlements {
            filtered.removeValue(forKey: "com.apple.token")
            filtered.removeValue(forKey: "beta-reports-active")
        }

        if removeICloudEntitlements {
            filtered = filtered.filter { key, _ in
                !key.hasPrefix("com.apple.developer.icloud") &&
                !key.hasPrefix("com.apple.developer.ubiquity")
            }
        }

        if keepGetTaskAllow,
           let allowed = dictionary["get-task-allow"] as? Bool,
           allowed {
            filtered["get-task-allow"] = true
        }

        if increasedMemoryLimit {
            filtered["com.apple.developer.kernel.increased-memory-limit"] = true
        }

        for key in ["com.apple.developer.icloud-container-identifiers",
                    "com.apple.developer.icloud-container-development-container-identifiers",
                    "com.apple.developer.ubiquity-container-identifiers"] where (filtered[key] as? [Any])?.isEmpty == true {
            filtered.removeValue(forKey: key)
        }

        if filtered.isEmpty {
            if entitlementsMode == .custom {
                return try? PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
            }
            return nil
        }
        return try? PropertyListSerialization.data(fromPropertyList: filtered, format: .xml, options: 0)
    }

    private func resetEntitlementSelection() {
        selectedEntitlementKeys = Set(profile?.entitlementKeys ?? [])
        entitlementsReady = profile != nil
    }
    private var trimmedDisplayName: String { displayName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedVersion: String { version.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validationIssues: [SigningIssue] {
        guard certificate != nil, profile != nil else { return [] }
        var issues: [SigningIssue] = []
        if trimmedBundleID.isEmpty {
            issues.append(SigningIssue(text: "sign_bundle_id_required".localized, isError: true))
        }
        if let selectedIPA, selectedIPA.isEncrypted {
            issues.append(SigningIssue(text: "sign_ipa_encrypted".localized, isError: true))
        }
        if trimmedBundleID == Bundle.main.bundleIdentifier,
           injections.contains(where: { $0.name == "内购破解.dylib" }) {
            issues.append(SigningIssue(text: "sign_self_injection_warning".localized, isError: false))
        }
        if !trimmedBundleID.isEmpty, trimmedBundleID == Bundle.main.bundleIdentifier {
            issues.append(SigningIssue(text: "sign_self_bundle_warning".localized, isError: false))
        }
        if let certificate {
            if let expiresAt = certificate.expiresAt, expiresAt < Date() {
                issues.append(SigningIssue(text: "sign_cert_expired".localized, isError: true))
            }
            if certificatePassword == nil {
                issues.append(SigningIssue(text: "sign_cert_password_missing".localized, isError: true))
            }
        }
        if let profile {
            if let expiresAt = profile.expiresAt, expiresAt < Date() {
                issues.append(SigningIssue(text: "sign_profile_expired".localized, isError: true))
            }
            if !profile.bundleIDPattern.isEmpty, profile.bundleIDPattern != "*", profile.bundleIDPattern != trimmedBundleID {
                issues.append(SigningIssue(text: String(format: "sign_profile_fallback_warning".localized, profile.bundleIDPattern), isError: false))
            }
            if let certificate,
               !certificate.teamID.isEmpty,
               !profile.teamID.isEmpty,
               certificate.teamID != profile.teamID {
                issues.append(SigningIssue(text: "sign_team_mismatch_warning".localized, isError: false))
            }
            let needsICloud = selectedIPA?.requiredEntitlementKeys.contains {
                $0.hasPrefix("com.apple.developer.icloud") || $0.hasPrefix("com.apple.developer.ubiquity")
            } ?? false
            if needsICloud,
               let data = profile.entitlementsData,
               let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               (dict["com.apple.developer.icloud-container-identifiers"] as? [Any])?.isEmpty != false {
                issues.append(SigningIssue(text: "sign_icloud_container_missing_warning".localized, isError: false))
            }
            if !uncoveredExtensionTargets.isEmpty {
                let names = uncoveredExtensionTargets.map(\.displayName).joined(separator: ", ")
                issues.append(SigningIssue(text: String(format: "sign_target_profile_warning".localized, names), isError: false))
            }
            if provisioningAuditGapCount > 0 {
                issues.append(SigningIssue(text: String(format: "sign_audit_warning".localized, provisioningAuditGapCount), isError: false))
            }
            let trimmedUDID = deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
            let profileDevices = profile.provisionedDevices ?? []
            let allDevices = profile.provisionsAllDevices == true || profile.isEnterprise
            if !trimmedUDID.isEmpty,
               !allDevices,
               !profileDevices.isEmpty,
               !profileDevices.contains(where: { $0.caseInsensitiveCompare(trimmedUDID) == .orderedSame }) {
                issues.append(SigningIssue(text: "sign_device_not_in_profile".localized, isError: true))
            } else if trimmedUDID.isEmpty, !allDevices, !profileDevices.isEmpty {
                issues.append(SigningIssue(text: "sign_device_unknown".localized, isError: false))
            }
        }
        if removeProvision {
            issues.append(SigningIssue(text: "sign_remove_provision_warning".localized, isError: false))
        }
        if entitlementsMode == .appDeclared,
           selectedIPA?.requiredEntitlementKeys.isEmpty ?? true {
            issues.append(SigningIssue(text: "sign_ent_app_required_unknown".localized, isError: false))
        }
        if entitlementsMode == .custom && selectedEntitlementKeys.isEmpty {
            issues.append(SigningIssue(text: "sign_ent_custom_empty".localized, isError: false))
        }
        if isolateKeychain,
           let profile,
           (profile.entitlementKeys ?? []).contains("keychain-access-groups") == false {
            issues.append(SigningIssue(text: "sign_ent_no_keychain".localized, isError: false))
        }
        if increasedMemoryLimit,
           let profile,
           (profile.entitlementKeys ?? []).contains("com.apple.developer.kernel.increased-memory-limit") == false {
            issues.append(SigningIssue(text: "sign_ent_increased_memory_unauthorized".localized, isError: false))
        }
        return issues
    }

    private var hasBlockingIssues: Bool {
        validationIssues.contains { $0.isError }
    }

    private var canSign: Bool {
        certificate != nil && profile != nil && selectedIPA != nil && certificatePassword != nil && !hasBlockingIssues && !session.isRunning
    }

    var body: some SwiftUI.View {
        ZStack {
            LiquidGlassBackdrop()
                .environmentObject(themeManager)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 14) {
                    heroCard
                    identityCard
                    ipaCard
                    if selectedIPA != nil {
                        ipaPreflightCard
                    }
                    if selectedIPA != nil, profile != nil {
                        provisioningAuditCard
                    }
                    optionsCard
                    injectionCard
                    if !canSign && !session.isRunning {
                        signingPreflight
                    }
                    signAction

                    if session.isActive {
                        SigningConsoleView(
                            session: session,
                            certificateName: certificate?.commonName ?? "—",
                            profileName: profile?.displayName ?? "—",
                            onCancel: { session.cancel() },
                            onShare: { shareOutput() },
                            onInstall: { installOutput() }
                        )
                        .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
                    }

                    if session.outcome == .completed, let output = session.outputURL {
                        signResultCard(output)
                    }

                    if installPhase != .idle {
                        installPhaseCard
                    }

                    historyCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, tabBarStyleManager.currentStyle == .floatingCard ? 110 : 28)
            }
        }
        .navigationTitle("tab_sign".localized)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCertificateImporter) {
            DocumentPicker(types: [.item], allowsMultipleSelection: true) { urls in
                showCertificateImporter = false
                handleIdentityImport(urls)
            }
        }
        .sheet(isPresented: $showProfileImporter) {
            DocumentPicker(types: [.item], allowsMultipleSelection: true) { urls in
                showProfileImporter = false
                handleIdentityImport(urls)
            }
        }
        .onAppear { consumeSigningHandoff() }
        .onChange(of: handoff.pendingIPA) { _, _ in consumeSigningHandoff() }
        .sheet(isPresented: $showIPAImporter) {
            DocumentPicker(types: [.item]) { urls in
                showIPAImporter = false
                if let url = urls.first { handlePickedIPA(url) }
            }
        }
        .sheet(isPresented: $showDylibImporter) {
            DocumentPicker(types: [.item], allowsMultipleSelection: true) { urls in
                showDylibImporter = false
                handleDylibImport(.success(urls))
            }
        }
        .fileImporter(isPresented: $showFrameworkImporter, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            handleFrameworkImport(result)
        }
        .sheet(isPresented: $showCertificateSheet, onDismiss: {
            pendingCertificateData = nil
            pendingCertificateName = ""
            advanceCertificateQueue()
        }) {
            if let data = pendingCertificateData {
                CertificateImportSheet(fileName: pendingCertificateName) { password, name in
                    _ = try store.importCertificate(
                        data: data,
                        originalFileName: pendingCertificateName,
                        password: password,
                        displayName: name
                    )
                    SoundEffects.play(.rise)
                }
                .environmentObject(themeManager)
            }
        }
        .sheet(isPresented: $showIPAPicker) {
            SigningIPAPickerSheet(
                downloads: downloads,
                onPick: { url in applyIPA(url) },
                onImportFile: {
                    showIPAPicker = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        showIPAImporter = true
                    }
                }
            )
            .environmentObject(themeManager)
        }
        .sheet(item: $shareFile) { file in
            ActivityView(items: [file.url])
        }
        .sheet(isPresented: $showCertificateDetail) {
            if let certificate {
                CertificateDetailSheet(
                    certificate: certificate,
                    profile: profile,
                    onShowEntitlements: {
                        showCertificateDetail = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showEntitlements = true
                        }
                    }
                )
                .environmentObject(themeManager)
            }
        }
        .sheet(isPresented: $showEntitlements) {
            if let profile {
                EntitlementSelectionSheet(
                    profile: profile,
                    selectedKeys: $selectedEntitlementKeys,
                    requiredKeys: selectedIPA?.requiredEntitlementKeys ?? [],
                    requiredKeysKnown: selectedIPA?.hasOriginalProfile ?? false,
                    mode: $entitlementsMode
                )
                .environmentObject(themeManager)
            }
        }
        .sheet(isPresented: $showTargetSheet) {
            SigningTargetSelectionSheet(
                targets: availableTargets,
                selected: targetBinding,
                profiles: store.profiles,
                mainProfile: profile
            )
                .environmentObject(themeManager)
        }
        .sheet(isPresented: $showHistory) {
            SigningHistoryView(onRefresh: { record in
                showHistory = false
                refreshFromHistory(record)
            })
            .environmentObject(themeManager)
        }
        .sheet(isPresented: $showDeviceSheet) {
            SigningDeviceUDIDSheet(
                deviceUDID: $deviceUDID,
                serviceURL: $udidServiceURL,
                profile: profile
            )
            .environmentObject(themeManager)
        }

        .onAppear {
            resetEntitlementSelection()
            seedDefaultInjectionIfNeeded()
        }
        .onChange(of: removeAllExtensions) { _, _ in
            normalizeInjectionTargets()
        }
        .onChange(of: removeWatchApp) { _, _ in
            normalizeInjectionTargets()
        }
        .onChange(of: session.outcome) { _, newValue in
            guard newValue == .completed else { return }
            recordSigningResult()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                attemptAutoInstall()
            }
        }
        .onChange(of: profile?.id) { _, _ in
            resetEntitlementSelection()
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("ok".localized, role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .alert("sign_install_self_title".localized, isPresented: $showSelfInstallAlert) {
            Button("sign_share".localized) {
                shareOutput()
            }
            Button("cancel".localized, role: .cancel) { }
        } message: {
            Text("sign_install_self_warning".localized)
        }
        .overlay {
            if showInjectionMenu {
                CenteredChoicePopup(
                    title: "sign_injection_add".localized,
                    subtitle: "sign_injection_add_hint".localized,
                    onDismiss: { showInjectionMenu = false }
                ) {
                    CenteredChoiceRow(
                        icon: "link",
                        title: "sign_injection_dylib".localized,
                        subtitle: "sign_injection_dylib_hint".localized,
                        tint: accent
                    ) {
                        showInjectionMenu = false
                        showDylibImporter = true
                    }
                    CenteredChoiceRow(
                        icon: "shippingbox.fill",
                        title: "sign_injection_framework".localized,
                        subtitle: "sign_injection_framework_hint".localized,
                        tint: .cyan
                    ) {
                        showInjectionMenu = false
                        showFrameworkImporter = true
                    }
                }
                .zIndex(20)
            }
            if showIdentityImportMenu {
                CenteredChoicePopup(
                    title: "sign_identity_import".localized,
                    subtitle: "sign_identity_import_hint".localized,
                    onDismiss: { showIdentityImportMenu = false }
                ) {
                    CenteredChoiceRow(
                        icon: "key.horizontal.fill",
                        title: "sign_import_cert".localized,
                        subtitle: "sign_identity_import_cert_hint".localized,
                        tint: accent
                    ) {
                        showIdentityImportMenu = false
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            showCertificateImporter = true
                        }
                    }
                    CenteredChoiceRow(
                        icon: "doc.badge.gearshape",
                        title: "sign_import_profile".localized,
                        subtitle: "sign_identity_import_profile_hint".localized,
                        tint: .cyan
                    ) {
                        showIdentityImportMenu = false
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            showProfileImporter = true
                        }
                    }
                }
                .zIndex(20)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showInjectionMenu)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showIdentityImportMenu)
    }

    private var heroCard: some SwiftUI.View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(LinearGradient(colors: [accent, accent.opacity(0.60)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 46, height: 46)
                    .shadow(color: accent.opacity(0.40), radius: 8, y: 3)
                Image(systemName: "signature")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("sign_title".localized)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                Text("sign_subtitle".localized)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                countPill(value: store.certificates.count, title: "sign_cert_section".localized)
                countPill(value: store.profiles.count, title: "sign_profile_section".localized)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func countPill(value: Int, title: String) -> some SwiftUI.View {
        HStack(spacing: 4) {
            Text("\(value)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
            Text(title)
                .font(.system(size: 8.5))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(colorScheme == .dark ? 0.08 : 0.05)))
    }

    private var identityCard: some SwiftUI.View {
        sectionCard(
            title: "sign_identity_section".localized,
            icon: "person.badge.key.fill",
            count: nil,
            action: { showIdentityImportMenu = true }
        ) {
            if certificate != nil || profile != nil {
                identitySummaryRow
            } else {
                emptyRow(
                    icon: "person.badge.key",
                    title: "sign_identity_empty".localized,
                    hint: "sign_identity_empty_hint".localized,
                    actionTitle: "sign_identity_import".localized
                ) {
                    showIdentityImportMenu = true
                }
            }
        }
    }

    private var identitySummaryRow: some SwiftUI.View {
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
                    Text(identityCertificateName)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    pairingBadge
                }

                Text(identitySubtitle)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    if let expiresAt = identityCertificateExpiry {
                        meta("sign_cert_section".localized, dateText(expiresAt), warning: expiresAt < Date())
                    }
                    if let profile, let expiresAt = profile.expiresAt {
                        meta("sign_profile_section".localized, dateText(expiresAt), warning: expiresAt < Date())
                    }
                    if let profile {
                        meta("sign_profile_devices".localized, profile.isEnterprise ? "sign_profile_enterprise".localized : "\(profile.deviceCount)")
                    }
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 7) {
                Button {
                    showCertificateDetail = true
                } label: {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("detail_action".localized)

                Button {
                    showEntitlements = true
                } label: {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("sign_entitlements_title".localized)

                Menu {
                    identityMenu
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

    private var identityCertificateName: String {
        if let certificate {
            if certificate.teamID.isEmpty, let profileCertificate = profile?.certificates?.first {
                return profileCertificate.commonName
            }
            return certificate.commonName
        }
        return profile?.displayName ?? "—"
    }

    private var identityCertificateExpiry: Date? {
        certificate?.expiresAt ?? profile?.certificates?.first?.notAfter
    }

    private func checkRevocation() {
        guard let certificate, let profile, let password = certificatePassword else {
            alertTitle = "sign_ocsp_missing".localized
            alertMessage = "sign_ocsp_missing_message".localized
            showAlert = true
            return
        }
        let certificateURL = store.certificateURL(for: certificate)
        let profileURL = store.profileURL(for: profile)
        ocspChecking = true
        Task {
            let result: (Int32, Date?, String?) = await withCheckedContinuation { continuation in
                Zsign.checkRevokage(
                    provisionPath: profileURL.path,
                    p12Path: certificateURL.path,
                    p12Password: password
                ) { status, date, error in
                    continuation.resume(returning: (status, date, error))
                }
            }
            await MainActor.run {
                ocspChecking = false
                let dateTextValue = result.1.map { dateText($0) } ?? "—"
                switch result.0 {
                case 0:
                    alertTitle = "sign_ocsp_good_title".localized
                    alertMessage = String(format: "sign_ocsp_good_message".localized, dateTextValue)
                case 1:
                    alertTitle = "sign_ocsp_revoked_title".localized
                    alertMessage = "sign_ocsp_revoked_message".localized
                default:
                    alertTitle = "sign_ocsp_unknown_title".localized
                    alertMessage = result.2 ?? "sign_ocsp_unknown_message".localized
                }
                showAlert = true
            }
        }
    }

    private var identitySubtitle: String {
        let team = certificate?.teamID.isEmpty == false ? certificate!.teamID : (profile?.teamID ?? "—")
        let appID = profile?.bundleIDPattern ?? "—"
        return "\(team)  ·  \(appID)"
    }

    @ViewBuilder
    private var identityMenu: some SwiftUI.View {
        Section("sign_select_certificate".localized) {
            ForEach(store.certificates) { item in
                Button {
                    store.selectCertificate(item.id)
                    autoSelectProfileForCurrentIPA(preferredCertificate: item)
                } label: {
                    Label(item.displayName, systemImage: item.id == certificate?.id ? "checkmark" : "key")
                }
            }
        }
        Section("sign_select_profile".localized) {
            ForEach(store.profiles) { item in
                Button {
                    store.selectProfile(item.id)
                } label: {
                    Label(item.displayName, systemImage: item.id == profile?.id ? "checkmark" : "doc")
                }
            }
        }
        Divider()
        Button {
            showCertificateDetail = true
        } label: {
            Label("sign_cert_detail_title".localized, systemImage: "info.circle")
        }
        Button {
            showEntitlements = true
        } label: {
            Label("sign_entitlements_title".localized, systemImage: "checkmark.shield")
        }
        Button {
            checkRevocation()
        } label: {
            Label("sign_ocsp_check".localized, systemImage: "checkmark.seal")
        }
        .disabled(ocspChecking)
        Divider()
        Button {
            showCertificateImporter = true
        } label: {
            Label("sign_import_cert".localized, systemImage: "plus")
        }
        Button {
            showProfileImporter = true
        } label: {
            Label("sign_import_profile".localized, systemImage: "plus")
        }
        if let certificate {
            Divider()
            Button(role: .destructive) {
                store.deleteCertificate(certificate)
            } label: {
                Label("sign_delete_cert".localized, systemImage: "trash")
            }
        }
        if let profile {
            Button(role: .destructive) {
                store.deleteProfile(profile)
            } label: {
                Label("sign_delete_profile".localized, systemImage: "trash")
            }
        }
    }

    private enum IdentityPairing {
        case waiting
        case paired(String)
        case mismatch(String)
    }

    private var identityPairing: IdentityPairing {
        guard let certificate else { return .waiting }
        guard let profile else { return .waiting }
        let certTeam = certificate.teamID
        if certTeam.isEmpty || profile.teamID.isEmpty || certTeam == profile.teamID {
            return .paired(profile.teamID.isEmpty ? "—" : profile.teamID)
        }
        return .mismatch("\(certTeam) / \(profile.teamID)")
    }

    private var pairingBadge: some SwiftUI.View {
        let pairing = identityPairing
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

    private struct ProvisioningAuditEntry: Identifiable {
        let target: SigningTarget
        let covered: Bool
        let missingKeys: [String]
        let missingAppGroups: [String]
        let missingKeychainGroups: [String]
        let unknown: Bool
        let profileExpired: Bool
        let teamMismatch: Bool
        let deviceMismatch: Bool
        let profileName: String
        let usesIndependent: Bool

        var id: String { target.id }

        var gapCount: Int {
            missingKeys.count + missingAppGroups.count + missingKeychainGroups.count
                + (covered ? 0 : 1)
                + (profileExpired ? 1 : 0)
                + (teamMismatch ? 1 : 0)
                + (deviceMismatch ? 1 : 0)
        }

        var hasGap: Bool { gapCount > 0 }
    }

    private func matchedProfileForTarget(_ target: SigningTarget) -> SigningProfile? {
        guard let profile else { return nil }
        if target.kind == .main { return profile }
        let team = profile.teamID
        let candidates = store.profiles.filter { team.isEmpty || $0.teamID == team }
        if let exact = candidates.first(where: { $0.bundleIDPattern == target.bundleIdentifier }) {
            return exact
        }
        return candidates.first(where: { $0.bundleIDPattern == "*" })
    }

    private func isTargetProfileUsable(_ candidate: SigningProfile) -> Bool {
        guard let profile, candidate.id != profile.id else { return false }
        if let expiry = candidate.expiresAt, expiry < Date() { return false }
        if let certTeam = certificate?.teamID,
           !certTeam.isEmpty,
           !candidate.teamID.isEmpty,
           certTeam != candidate.teamID {
            return false
        }
        let udid = deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !udid.isEmpty,
           candidate.provisionsAllDevices != true,
           !candidate.isEnterprise {
            let devices = candidate.provisionedDevices ?? []
            if !devices.isEmpty, !devices.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }) {
                return false
            }
        }
        if let fingerprint = certificate?.fingerprint,
           !fingerprint.isEmpty,
           let certificates = candidate.certificates,
           !certificates.isEmpty,
           !certificates.contains(where: { $0.fingerprint?.caseInsensitiveCompare(fingerprint) == .orderedSame }) {
            return false
        }
        return true
    }

    private func independentProfile(for target: SigningTarget) -> SigningProfile? {
        guard useTargetProfiles, target.kind != .main else { return nil }
        guard let candidate = matchedProfileForTarget(target), isTargetProfileUsable(candidate) else { return nil }
        return candidate
    }

    private var targetSigningCredentials: [SigningTargetCredentials] {
        guard useTargetProfiles, profile != nil else { return [] }
        let removedPaths = Set(targetsToRemove.map(\.bundlePath))
        return targets.compactMap { target in
            guard target.kind != .main else { return nil }
            if removeAllExtensions { return nil }
            if removeWatchApp && target.kind == .watchApp { return nil }
            if removedPaths.contains(target.bundlePath) { return nil }
            guard let matched = independentProfile(for: target) else { return nil }
            return SigningTargetCredentials(
                targetID: target.id,
                bundlePath: target.bundlePath,
                profile: matched,
                profileURL: store.profileURL(for: matched),
                entitlementsPlist: matched.entitlementsData
            )
        }
    }

    private var provisioningAuditEntries: [ProvisioningAuditEntry] {
        guard let profile else { return [] }
        let skipKeys: Set<String> = [
            "application-identifier",
            "com.apple.developer.team-identifier",
            "keychain-access-groups",
            "com.apple.security.application-groups",
            "get-task-allow"
        ]
        let visibleTargets = targets.filter { target in
            if removeAllExtensions && target.kind != .main { return false }
            if removeWatchApp && target.kind == .watchApp { return false }
            return true
        }
        let trimmedUDID = deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)

        return visibleTargets.map { target in
            let effectiveProfile = independentProfile(for: target) ?? profile
            let usesIndependent = effectiveProfile.id != profile.id
            let dictionary: [String: Any]
            if let data = effectiveProfile.entitlementsData,
               let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                dictionary = parsed
            } else {
                dictionary = [:]
            }
            let profileKeys = Set(effectiveProfile.entitlementKeys ?? [])
            let profileAppGroups = Set(dictionary["com.apple.security.application-groups"] as? [String] ?? [])
            let profileKeychain = dictionary["keychain-access-groups"] as? [String] ?? []
            let profileExpired = effectiveProfile.expiresAt.map { $0 < Date() } ?? false
            let teamMismatch: Bool = {
                guard let certificate,
                      !certificate.teamID.isEmpty,
                      !effectiveProfile.teamID.isEmpty else { return false }
                return certificate.teamID != effectiveProfile.teamID
            }()
            let profileDevices = effectiveProfile.provisionedDevices ?? []
            let allDevices = effectiveProfile.provisionsAllDevices == true || effectiveProfile.isEnterprise
            let deviceMismatch = !trimmedUDID.isEmpty
                && !allDevices
                && !profileDevices.isEmpty
                && !profileDevices.contains(where: { $0.caseInsensitiveCompare(trimmedUDID) == .orderedSame })

            let resolvedID = target.kind == .main
                ? (trimmedBundleID.isEmpty ? target.bundleIdentifier : trimmedBundleID)
                : target.bundleIdentifier
            let covered = effectiveProfile.bundleIDPattern == "*" || effectiveProfile.bundleIDPattern == resolvedID

            guard target.hasOriginalProfile else {
                return ProvisioningAuditEntry(
                    target: target,
                    covered: covered,
                    missingKeys: [],
                    missingAppGroups: [],
                    missingKeychainGroups: [],
                    unknown: true,
                    profileExpired: profileExpired,
                    teamMismatch: teamMismatch,
                    deviceMismatch: deviceMismatch,
                    profileName: effectiveProfile.displayName,
                    usesIndependent: usesIndependent
                )
            }
            let missingKeys = target.requiredEntitlementKeys
                .subtracting(profileKeys)
                .subtracting(skipKeys)
                .sorted()
            let missingAppGroups = target.requiredAppGroups
                .filter { !profileAppGroups.contains($0) }
                .sorted()
            let missingKeychain = target.requiredKeychainGroups
                .filter { group in
                    !profileKeychain.contains(where: { granted in
                        granted == group || granted == effectiveProfile.teamID + ".*" || granted == "*"
                    })
                }
                .sorted()
            return ProvisioningAuditEntry(
                target: target,
                covered: covered,
                missingKeys: missingKeys,
                missingAppGroups: missingAppGroups,
                missingKeychainGroups: missingKeychain,
                unknown: false,
                profileExpired: profileExpired,
                teamMismatch: teamMismatch,
                deviceMismatch: deviceMismatch,
                profileName: effectiveProfile.displayName,
                usesIndependent: usesIndependent
            )
        }
    }

    private var provisioningAuditGapCount: Int {
        provisioningAuditEntries.reduce(0) { $0 + $1.gapCount }
    }

    private var provisioningAuditCard: some SwiftUI.View {
        sectionCard(
            title: "sign_audit_title".localized,
            icon: "checkmark.shield",
            count: provisioningAuditGapCount > 0 ? provisioningAuditGapCount : nil,
            action: nil
        ) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Text(String(format: "sign_audit_targets".localized, provisioningAuditEntries.count))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if provisioningAuditGapCount == 0 {
                        Label("sign_audit_all_good".localized, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.green)
                    } else {
                        Label(
                            String(format: "sign_audit_gaps".localized, provisioningAuditGapCount),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.orange)
                    }
                }

                if deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let profile,
                   (profile.provisionsAllDevices != true && !profile.isEnterprise),
                   !(profile.provisionedDevices ?? []).isEmpty {
                    Text("sign_audit_device_unknown".localized)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ForEach(provisioningAuditEntries) { entry in
                    auditRow(entry)
                }

                Text("sign_audit_note".localized)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("sign_audit_engine_note".localized)
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func auditRow(_ entry: ProvisioningAuditEntry) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: entry.target.kind.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(entry.target.kind == .main ? accent : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill((entry.target.kind == .main ? accent : Color.secondary).opacity(0.10))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(entry.target.displayName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                        if entry.usesIndependent {
                            Text("sign_audit_per_target".localized)
                                .font(.system(size: 6.5, weight: .bold))
                                .foregroundStyle(.cyan)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.cyan.opacity(0.12)))
                        }
                    }
                    Text(entry.target.bundleIdentifier.isEmpty ? entry.target.bundlePath : entry.target.bundleIdentifier)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 3) {
                        Image(systemName: entry.usesIndependent ? "doc.on.doc" : "doc")
                            .font(.system(size: 6.5))
                        Text(entry.usesIndependent
                             ? String(format: "sign_audit_using_independent".localized, entry.profileName)
                             : String(format: "sign_audit_using_main".localized, entry.profileName))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 7.5))
                    .foregroundStyle(entry.usesIndependent ? Color.cyan : Color.secondary)
                }

                Spacer(minLength: 4)

                if entry.teamMismatch {
                    Text("sign_audit_team_mismatch".localized)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.red)
                } else if entry.profileExpired {
                    Text("sign_audit_profile_expired".localized)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.red)
                } else if entry.deviceMismatch {
                    Text("sign_audit_device_mismatch".localized)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.red)
                } else if entry.unknown {
                    Text("sign_audit_unknown".localized)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else if !entry.covered {
                    Text("sign_audit_profile_not_covering".localized)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.red)
                } else if entry.hasGap {
                    Text(String(format: "sign_audit_missing_count".localized, entry.gapCount))
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.orange)
                } else {
                    Text("sign_audit_no_gap".localized)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.green)
                }
            }

            if !entry.unknown {
                if !entry.missingAppGroups.isEmpty {
                    auditGapLine("sign_audit_missing_app_groups".localized, entry.missingAppGroups)
                }
                if !entry.missingKeychainGroups.isEmpty {
                    auditGapLine("sign_audit_missing_keychain".localized, entry.missingKeychainGroups)
                }
                if !entry.missingKeys.isEmpty {
                    auditGapLine("sign_audit_missing_entitlements".localized, entry.missingKeys)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func auditGapLine(_ title: String, _ values: [String]) -> some SwiftUI.View {
        HStack(alignment: .top, spacing: 4) {
            Text(title)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 70, alignment: .leading)
            Text(values.joined(separator: ", "))
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var ipaPreflightCard: some SwiftUI.View {
        sectionCard(
            title: "sign_preflight_card_title".localized,
            icon: "checklist",
            count: nil,
            action: nil
        ) {
            if let ipa = selectedIPA {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        preflightChip("Bundle ID", ipa.bundleIdentifier, color: .secondary)
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 6) {
                        preflightChip("sign_preflight_extensions".localized, "\(extensionCount)", color: extensionCount > 0 ? .cyan : .secondary)
                        preflightChip("sign_preflight_encrypted".localized, ipa.isEncrypted ? "sign_preflight_yes".localized : "sign_preflight_no".localized, color: ipa.isEncrypted ? .red : .green)
                        preflightChip("sign_preflight_profile_coverage".localized, profileCoverageText, color: profileCoverageColor)
                    }

                    if !uncoveredExtensionTargets.isEmpty {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                            Text(String(format: "sign_preflight_extensions_missing".localized, uncoveredExtensionTargets.count))
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 1)
            }
        }
    }

    private var extensionCount: Int {
        targets.filter { $0.kind != .main }.count
    }

    private var profileCoverageText: String {
        guard let profile else { return "sign_preflight_missing".localized }
        if profile.isWildcard { return "sign_preflight_wildcard".localized }
        if uncoveredExtensionTargets.isEmpty { return "sign_preflight_matched".localized }
        return "sign_preflight_partial".localized
    }

    private var profileCoverageColor: Color {
        guard let profile else { return .red }
        if profile.isWildcard { return .green }
        if uncoveredExtensionTargets.isEmpty { return .green }
        return .orange
    }

    private func preflightChip(_ title: String, _ value: String, color: Color) -> some SwiftUI.View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
    }

    private var ipaCard: some SwiftUI.View {
        sectionCard(
            title: "sign_ipa_section".localized,
            icon: "shippingbox.fill",
            count: nil,
            action: { showIPAPicker = true }
        ) {
            if isLoadingIPA {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("sign_loading_ipa".localized)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
            } else if let selectedIPA {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedIPA.displayName)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Text(selectedIPA.bundleIdentifier)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 8) {
                                meta("sign_version".localized, selectedIPA.version)
                                meta("sign_ipa_size".localized, selectedIPA.sizeText)
                                if selectedIPA.isEncrypted {
                                    Label("sign_ipa_encrypted_tag".localized, systemImage: "lock.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button {
                                showIPAPicker = true
                            } label: {
                                Label("sign_from_downloads".localized, systemImage: "arrow.down.circle")
                            }
                            Button {
                                showIPAImporter = true
                            } label: {
                                Label("sign_from_files".localized, systemImage: "doc.badge.plus")
                            }
                            Divider()
                            Button(role: .destructive) {
                                self.selectedIPA = nil
                                bundleID = ""
                                displayName = ""
                                version = ""
                            } label: {
                                Label("sign_clear".localized, systemImage: "xmark.circle")
                            }
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
            } else {
                emptyRow(
                    icon: "shippingbox",
                    title: "sign_no_ipa".localized,
                    hint: "sign_no_ipa_hint".localized,
                    actionTitle: "sign_choose_ipa".localized
                ) {
                    showIPAPicker = true
                }
            }
        }
    }

    private var injectionCard: some SwiftUI.View {
        sectionCard(
            title: "sign_injection_section".localized,
            icon: "puzzlepiece.extension.fill",
            count: injections.count,
            action: { showInjectionMenu = true }
        ) {
            if injections.isEmpty {
                emptyRow(
                    icon: "puzzlepiece.extension",
                    title: "sign_injection_empty".localized,
                    hint: "sign_injection_empty_hint".localized,
                    actionTitle: "sign_injection_add".localized
                ) {
                    showInjectionMenu = true
                }
            } else {
                VStack(spacing: 7) {
                    ForEach(injections) { injection in
                        injectionRow(injection)
                    }
                    HStack(spacing: 5) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 8))
                        Text("sign_injection_weak_hint".localized)
                            .font(.system(size: 8.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
                }
            }
        }
    }

    private func injectionRow(_ injection: SigningInjection) -> some SwiftUI.View {
        HStack(spacing: 9) {
            Image(systemName: injection.isFramework ? "shippingbox.fill" : "link")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(accent.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(injection.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if injection.name == "内购破解.dylib" {
                        Text("sign_injection_builtin".localized)
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(.cyan)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.cyan.opacity(0.12)))
                    }
                }
                HStack(spacing: 5) {
                    Text(injection.isFramework ? "sign_injection_framework_type".localized : "sign_injection_dylib_type".localized)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button {
                        targetEditingInjectionID = injection.id
                        showTargetSheet = true
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "scope")
                                .font(.system(size: 7, weight: .bold))
                            Text(targetSummary(injection))
                                .font(.system(size: 8, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 6, weight: .bold))
                        }
                        .foregroundStyle(accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(accent.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 4)

            VStack(spacing: 1) {
                Toggle("", isOn: weakBinding(for: injection))
                    .labelsHidden()
                    .scaleEffect(0.75)
                    .tint(accent)
                Text("sign_injection_weak".localized)
                    .font(.system(size: 7.5))
                    .foregroundStyle(.secondary)
            }

            Button {
                injections.removeAll { $0.id == injection.id }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red.opacity(0.8))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.red.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("delete".localized)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
        )
    }

    private func weakBinding(for injection: SigningInjection) -> Binding<Bool> {
        Binding(
            get: { injections.first(where: { $0.id == injection.id })?.weak ?? true },
            set: { newValue in
                if let index = injections.firstIndex(where: { $0.id == injection.id }) {
                    injections[index].weak = newValue
                }
            }
        )
    }

    private var optionsCard: some SwiftUI.View {
        sectionCard(title: "sign_options_section".localized, icon: "slider.horizontal.3", count: nil, action: nil) {
            VStack(spacing: 10) {
                labeledField(title: "sign_bundle_id".localized, text: $bundleID, mono: true)
                labeledField(title: "sign_display_name".localized, text: $displayName, mono: false)
                labeledField(title: "sign_version".localized, text: $version, mono: true)

                Toggle(isOn: $removeProvision) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_remove_provision".localized)
                            .font(.system(size: 12, weight: .medium))
                        Text("sign_remove_provision_hint".localized)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Toggle(isOn: $removeAllExtensions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_remove_extensions".localized)
                            .font(.system(size: 12, weight: .medium))
                        Text("sign_remove_extensions_hint".localized)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Toggle(isOn: $removeWatchApp) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_remove_watch".localized)
                            .font(.system(size: 12, weight: .medium))
                        Text("sign_remove_watch_hint".localized)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Toggle(isOn: $removeUncoveredExtensions) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_remove_uncovered_extensions".localized)
                            .font(.system(size: 12, weight: .medium))
                        Text("sign_remove_uncovered_extensions_hint".localized)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Toggle(isOn: $useTargetProfiles) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_use_target_profiles".localized)
                            .font(.system(size: 12, weight: .medium))
                        Text(String(format: "sign_use_target_profiles_hint".localized, targetSigningCredentials.count))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Toggle(isOn: $autoInstallAfterSign) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_auto_install".localized)
                            .font(.system(size: 12, weight: .medium))
                        Text("sign_auto_install_hint".localized)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Button {
                    showDeviceSheet = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "iphone")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("sign_device_title".localized)
                                .font(.system(size: 12, weight: .medium))
                            Text(deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 ? "sign_device_not_set".localized
                                 : deviceUDID)
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)

                Button {
                    showEntitlements = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("sign_ent_mode".localized)
                                .font(.system(size: 12, weight: .medium))
                            Text(entitlementsMode.title + " · " + entitlementsMode.hint)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .buttonStyle(.plain)

                Toggle(isOn: $isolateKeychain) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_ent_isolate_keychain".localized)
                            .font(.system(size: 11, weight: .medium))
                        Text("sign_ent_isolate_keychain_hint".localized)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Toggle(isOn: $dropUnsignableEntitlements) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_ent_drop_unsignable".localized)
                            .font(.system(size: 11, weight: .medium))
                        Text("sign_ent_drop_unsignable_hint".localized)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Toggle(isOn: $removeICloudEntitlements) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_ent_remove_icloud".localized)
                            .font(.system(size: 11, weight: .medium))
                        Text("sign_ent_remove_icloud_hint".localized)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Toggle(isOn: $keepGetTaskAllow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_ent_keep_get_task_allow".localized)
                            .font(.system(size: 11, weight: .medium))
                        Text("sign_ent_keep_get_task_allow_hint".localized)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                Toggle(isOn: $increasedMemoryLimit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("sign_ent_increased_memory".localized)
                            .font(.system(size: 11, weight: .medium))
                        Text("sign_ent_increased_memory_hint".localized)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(accent)

                if !validationIssues.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(validationIssues) { issue in
                            HStack(alignment: .top, spacing: 5) {
                                Image(systemName: issue.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(issue.isError ? .red : .orange)
                                    .padding(.top, 1)
                                Text(issue.text)
                                    .font(.system(size: 10))
                                    .foregroundStyle(issue.isError ? .red : .orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.red.opacity(0.05))
                    )
                }

                if !uncoveredExtensionTargets.isEmpty {
                    Button {
                        removeAllExtensions = true
                        normalizeInjectionTargets()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "scissors")
                                .font(.system(size: 10, weight: .bold))
                            Text("sign_remove_extensions_action".localized)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var signingPreflight: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.orange)
                Text("sign_preflight_title".localized)
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Text("\(preflightOKCount)/5")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            preflightRow(ok: certificate != nil, text: "sign_preflight_cert".localized)
            preflightRow(ok: certificatePassword != nil, text: "sign_preflight_password".localized)
            preflightRow(ok: profile != nil, text: "sign_preflight_profile".localized)
            preflightRow(ok: selectedIPA != nil, text: "sign_preflight_ipa".localized)
            preflightRow(ok: !hasBlockingIssues && !trimmedBundleID.isEmpty, text: "sign_preflight_bundle".localized)

            if let fix = preflightFix {
                Button(action: fix.action) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 9, weight: .bold))
                        Text(fix.title)
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(accent)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(accent.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.08 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.20), lineWidth: 0.5)
        )
    }

    private var preflightOKCount: Int {
        var count = 0
        if certificate != nil { count += 1 }
        if certificatePassword != nil { count += 1 }
        if profile != nil { count += 1 }
        if selectedIPA != nil { count += 1 }
        if !hasBlockingIssues && !trimmedBundleID.isEmpty { count += 1 }
        return count
    }

    private func preflightRow(ok: Bool, text: String) -> some SwiftUI.View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(ok ? .green : .red)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(ok ? .secondary : .primary)
            Spacer(minLength: 0)
        }
    }

    private struct PreflightFix {
        let title: String
        let action: () -> Void
    }

    private func autoSelectProfileForCurrentIPA(preferredCertificate: SigningCertificate? = nil) {
        guard let ipa = selectedIPA else { return }
        let targetCertificate = preferredCertificate ?? certificate
        guard let best = store.bestProfile(for: ipa.bundleIdentifier, certificate: targetCertificate) else { return }
        if profile?.id != best.id {
            _ = store.selectBestProfile(for: ipa.bundleIdentifier, certificate: targetCertificate)
        }
    }

    private var preflightFix: PreflightFix? {
        if certificate == nil {
            return PreflightFix(title: "sign_preflight_import_cert".localized) {
                showCertificateImporter = true
            }
        }
        if certificatePassword == nil {
            return PreflightFix(title: "sign_preflight_reimport_cert".localized) {
                showCertificateImporter = true
            }
        }
        if profile == nil {
            return PreflightFix(title: "sign_preflight_import_profile".localized) {
                showProfileImporter = true
            }
        }
        if selectedIPA == nil {
            return PreflightFix(title: "sign_preflight_select_ipa".localized) {
                showIPAPicker = true
            }
        }
        return nil
    }

    private var signAction: some SwiftUI.View {
        VStack(spacing: 6) {
            Button {
                if canSign {
                    startSigning()
                } else {
                    presentError(message: hintText)
                }
            } label: {
                HStack(spacing: 8) {
                    if session.isRunning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "signature")
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text(session.isRunning ? "sign_running".localized : "sign_start".localized)
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: canSign || session.isRunning
                                    ? [accent, Color.cyan.opacity(0.85)]
                                    : [Color.gray.opacity(0.55), Color.gray.opacity(0.40)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: canSign ? accent.opacity(0.35) : .clear, radius: 10, y: 5)
                )
            }
            .buttonStyle(.plain)
            .disabled(session.isRunning)
            .opacity(session.isRunning ? 0.75 : 1)

            if !canSign && !session.isRunning {
                Text(hintText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hintText: String {
        if certificate == nil || profile == nil || selectedIPA == nil {
            return "sign_hint_select_all".localized
        }
        if certificatePassword == nil {
            return "sign_hint_password_missing".localized
        }
        if hasBlockingIssues {
            return "sign_hint_fix_issues".localized
        }
        return "sign_hint_ready".localized
    }

    private func sectionCard<Content: SwiftUI.View>(
        title: String,
        icon: String,
        count: Int?,
        action: (() -> Void)?,
        @ViewBuilder content: () -> Content
    ) -> AnyView {
        AnyView(VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.55)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
                if let action {
                    Button(action: action) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(accent)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(accent.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)

            content()
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        ))
    }

    private func emptyRow(icon: String, title: String, hint: String, actionTitle: String, action: @escaping () -> Void) -> some SwiftUI.View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accent.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(accent.opacity(0.10))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(hint)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(actionTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
            )
        }
        .buttonStyle(.plain)
    }

    private func labeledField(title: String, text: Binding<String>, mono: Bool) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
                )
        }
    }

    private func meta(_ title: String, _ value: String, warning: Bool = false) -> some SwiftUI.View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(warning ? .red : .secondary)
                .lineLimit(1)
        }
    }

    private func dateText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    private func selectionSection(certificates: [SigningCertificate], selectedID: UUID, onSelect: @escaping (UUID) -> Void) -> some SwiftUI.View {
        Section("sign_select".localized) {
            ForEach(certificates) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    Label(item.displayName, systemImage: item.id == selectedID ? "checkmark" : "key")
                }
            }
        }
    }

    private func selectionSection(profiles: [SigningProfile], selectedID: UUID, onSelect: @escaping (UUID) -> Void) -> some SwiftUI.View {
        Section("sign_select".localized) {
            ForEach(profiles) { item in
                Button {
                    onSelect(item.id)
                } label: {
                    Label(item.displayName, systemImage: item.id == selectedID ? "checkmark" : "doc")
                }
            }
        }
    }

    private func startSigning() {
        guard canSign,
              let certificate,
              let profile,
              let ipa = selectedIPA,
              let password = certificatePassword else {
            presentError(message: hintText)
            return
        }
        let finalBundleID = trimmedBundleID.isEmpty ? ipa.bundleIdentifier : trimmedBundleID
        let finalName = trimmedDisplayName.isEmpty ? ipa.displayName : trimmedDisplayName
        let finalVersion = trimmedVersion.isEmpty ? ipa.version : trimmedVersion
        let isSigningSelf = finalBundleID == Bundle.main.bundleIdentifier
        let effectiveInjections = injections.map { item in
            var copy = item
            if removeAllExtensions {
                copy.targets = ["."]
            } else if removeWatchApp {
                copy.targets = copy.targets.filter { !$0.hasPrefix("Watch/") }
                if copy.targets.isEmpty {
                    copy.targets = ["."]
                }
            }
            return copy
        }.filter { item in
            !(isSigningSelf && item.name == "内购破解.dylib")
        }

        let taskRequest = SigningIPTask(
            ipa: ipa,
            certificate: certificate,
            certificateURL: store.certificateURL(for: certificate),
            profile: profile,
            profileURL: store.profileURL(for: profile),
            password: password,
            bundleIdentifier: finalBundleID,
            displayName: finalName,
            version: finalVersion,
            removeProvision: removeProvision,
            entitlementsPlist: signingEntitlementsPlist,
            injections: effectiveInjections,
            removeExtensions: removeAllExtensions,
            removeWatchApp: removeWatchApp,
            removeTargetPaths: targetsToRemove.map(\.bundlePath),
            targetCredentials: targetSigningCredentials,
            outputDirectory: store.signedOutputDirectory
        )
        installPhase = .idle
        pendingSigningMetadata = PendingSigningMetadata(
            inputName: ipa.fileName,
            inputURL: ipa.url,
            bundleID: finalBundleID,
            version: finalVersion,
            displayName: finalName,
            certificateName: certificate.commonName,
            profileName: profile.displayName,
            profileExpiresAt: profile.expiresAt,
            injectionNames: effectiveInjections.map(\.name),
            removedExtensions: removeAllExtensions,
            certificateID: certificate.id,
            profileID: profile.id
        )
        didAutoInstall = false
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
            session.start(taskRequest)
        }
    }

    private func shareOutput() {
        guard let output = session.outputURL else { return }
        SoundEffects.play(.tap)
        shareFile = ShareFile(url: output)
    }

    private var installPhaseCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: installPhaseIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(installPhaseColor)
                Text("sign_install_phase_title".localized)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(installPhasePercent)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(installPhaseColor)
            }

            HStack(spacing: 4) {
                ForEach(Array(installPhaseSteps.enumerated()), id: \.offset) { index, title in
                    VStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .fill(index <= installPhaseStep ? installPhaseColor : Color.primary.opacity(0.08))
                                .frame(width: 18, height: 18)
                            if index < installPhaseStep {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(index == installPhaseStep ? .white : .secondary)
                            }
                        }
                        Text(title)
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(index <= installPhaseStep ? installPhaseColor : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    if index < installPhaseSteps.count - 1 {
                        Rectangle()
                            .fill(index < installPhaseStep ? installPhaseColor.opacity(0.5) : Color.primary.opacity(0.08))
                            .frame(height: 1)
                            .offset(y: -7)
                    }
                }
            }

            ProgressView(value: installPhaseProgress)
                .tint(installPhaseColor)
                .scaleEffect(y: 0.75)

            Text(installPhaseMessage)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(installPhaseColor.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var installPhaseSteps: [String] {
        [
            "sign_install_step_prepare".localized,
            "sign_install_step_connect".localized,
            "sign_install_step_transfer".localized,
            "sign_install_step_install".localized,
            "sign_install_step_deliver".localized
        ]
    }

    private var installPhaseStep: Int {
        switch installPhase {
        case .idle, .preparing: return 0
        case .connecting: return 1
        case .transferring: return 2
        case .awaitingSystem: return 3
        case .delivered: return 4
        case .failed: return 0
        }
    }

    private var installPhaseProgress: Double {
        switch installPhase {
        case .transferring(let fraction): return max(0.05, min(0.95, fraction))
        case .preparing: return 0.05
        case .connecting: return 0.2
        case .awaitingSystem: return 0.7
        case .delivered: return 1
        case .failed: return 0
        case .idle: return 0
        }
    }

    private var installPhasePercent: String {
        "\(Int(min(1, max(0, installPhaseProgress)) * 100))%"
    }

    private var installPhaseColor: Color {
        switch installPhase {
        case .failed: return .red
        case .delivered: return .green
        default: return accent
        }
    }

    private var installPhaseIcon: String {
        switch installPhase {
        case .failed: return "exclamationmark.triangle.fill"
        case .delivered: return "checkmark.seal.fill"
        default: return "iphone.arrow.down"
        }
    }

    private var installPhaseMessage: String {
        switch installPhase {
        case .idle: return ""
        case .preparing: return "sign_install_msg_preparing".localized
        case .connecting: return "sign_install_msg_connecting".localized
        case .transferring(let fraction): return String(format: "sign_install_msg_transferring".localized, Int(fraction * 100))
        case .awaitingSystem: return "sign_install_msg_awaiting".localized
        case .delivered: return "sign_install_msg_delivered".localized
        case .failed(let message): return message
        }
    }

    private func signResultCard(_ output: URL) -> some SwiftUI.View {
        let info = try? SigningIPAInfo.read(url: output)
        let isSelf = info?.bundleIdentifier == Bundle.main.bundleIdentifier
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.green)
                Text("sign_result_title".localized)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(info?.sizeText ?? "")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let info {
                HStack(spacing: 6) {
                    resultChip("sign_result_bundle_id".localized, info.bundleIdentifier, color: isSelf ? .red : .secondary)
                    resultChip("sign_version".localized, info.version, color: .secondary)
                }
            }

            if isSelf {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                    Text("sign_result_same_warning".localized)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Button {
                    shareOutput()
                } label: {
                    Label("sign_share".localized, systemImage: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.cyan.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button {
                    installOutput()
                } label: {
                    Label("sign_install".localized, systemImage: "arrow.down.app.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(LinearGradient(colors: [.cyan, .blue], startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isSelf ? Color.red.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private func resultChip(_ title: String, _ value: String, color: Color) -> some SwiftUI.View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 7.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.04)))
    }

    private struct PendingSigningMetadata {
        let inputName: String
        let inputURL: URL
        let bundleID: String
        let version: String
        let displayName: String
        let certificateName: String
        let profileName: String
        let profileExpiresAt: Date?
        let injectionNames: [String]
        let removedExtensions: Bool
        let certificateID: UUID
        let profileID: UUID
    }

    private var historyCard: some SwiftUI.View {
        sectionCard(
            title: "sign_history_title".localized,
            icon: "clock.arrow.circlepath",
            count: historyStore.records.count,
            action: { showHistory = true }
        ) {
            if historyStore.records.isEmpty {
                emptyRow(
                    icon: "clock",
                    title: "sign_history_empty".localized,
                    hint: "sign_history_empty_hint".localized,
                    actionTitle: "sign_history_open".localized
                ) {
                    showHistory = true
                }
            } else {
                VStack(spacing: 6) {
                    ForEach(historyStore.records.prefix(3)) { record in
                        Button {
                            showHistory = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(accent.opacity(0.10))
                                    )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.displayName)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .lineLimit(1)
                                    Text(record.bundleId.isEmpty ? record.outputName : record.bundleId)
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if historyStore.records.count > 3 {
                        Button {
                            showHistory = true
                        } label: {
                            Text("sign_history_view_all".localized)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func recordSigningResult() {
        guard let metadata = pendingSigningMetadata,
              let output = session.outputURL else { return }
        let record = historyStore.append(
            inputName: metadata.inputName,
            outputName: output.lastPathComponent,
            bundleId: metadata.bundleID,
            version: metadata.version,
            displayName: metadata.displayName,
            certificateName: metadata.certificateName,
            profileName: metadata.profileName,
            profileExpiresAt: metadata.profileExpiresAt,
            injectionNames: metadata.injectionNames,
            removedExtensions: metadata.removedExtensions,
            certificateID: metadata.certificateID,
            profileID: metadata.profileID
        )
        historyStore.retainSource(from: metadata.inputURL, for: record.id)
        pendingSigningMetadata = nil
    }

    private func refreshFromHistory(_ record: SigningHistoryRecord) {
        guard let source = historyStore.retainedSourceURL(for: record) else {
            alertTitle = "sign_error_title".localized
            alertMessage = "sign_history_refresh_source_missing".localized
            showAlert = true
            return
        }
        guard let certificateID = record.certificateID,
              store.certificates.contains(where: { $0.id == certificateID }),
              let profileID = record.profileID,
              store.profiles.contains(where: { $0.id == profileID }) else {
            alertTitle = "sign_error_title".localized
            alertMessage = "sign_history_refresh_identity_missing".localized
            showAlert = true
            return
        }
        store.selectCertificate(certificateID)
        store.selectProfile(profileID)
        pendingRefreshRecord = record
        applyIPA(source)
    }

    private func attemptAutoInstall() {
        guard autoInstallAfterSign, !didAutoInstall, !isInstalling else { return }
        guard session.outcome == .completed, let output = session.outputURL else { return }
        guard let info = try? SigningIPAInfo.read(url: output) else { return }
        guard info.bundleIdentifier != Bundle.main.bundleIdentifier else {
            didAutoInstall = true
            return
        }
        didAutoInstall = true
        installIPA(output)
    }

    private func installOutput() {
        guard let output = session.outputURL else { return }
        installIPA(output)
    }

    private func installIPA(_ output: URL) {
        guard !isInstalling else { return }
        guard let info = try? SigningIPAInfo.read(url: output) else {
            presentError(message: "sign_err_invalid_ipa".localized)
            return
        }
        guard info.bundleIdentifier != Bundle.main.bundleIdentifier else {
            showSelfInstallAlert = true
            return
        }
        isInstalling = true
        installPhase = .preparing
        Task {
            do {
                try await SigningInstaller.install(ipaURL: output, onPhase: { phase in
                    installPhase = phase
                })
                await MainActor.run {
                    isInstalling = false
                    alertTitle = "sign_install_title".localized
                    alertMessage = "sign_install_handed_off".localized
                    showAlert = true
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    installPhase = .failed(error.localizedDescription)
                    alertTitle = "sign_error_title".localized
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func applyIPA(_ url: URL) {
        isLoadingIPA = true
        Task {
            do {
                let info = try await Task.detached { try SigningIPAInfo.read(url: url) }.value
                let scanned = (try? await Task.detached { try SigningTargetScanner.scan(ipaURL: url) }.value) ?? []
                await MainActor.run {
                    SoundEffects.play(.rise)
                    selectedIPA = info
                    bundleID = info.bundleIdentifier
                    if pendingRefreshRecord == nil {
                        autoSelectProfileForCurrentIPA()
                    }
                    displayName = info.displayName
                    version = info.version
                    targets = scanned.isEmpty ? [SigningTarget.mainFallback(info: info)] : scanned
                    normalizeInjectionTargets()
                    isLoadingIPA = false
                    if let record = pendingRefreshRecord {
                        bundleID = record.bundleId
                        displayName = record.displayName
                        version = record.version
                        removeAllExtensions = record.removedExtensions
                        pendingRefreshRecord = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            startSigning()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isLoadingIPA = false
                    presentError(error)
                }
            }
        }
    }

    /// 证书和描述文件可以一次多选，一起导入：
    /// 描述文件当场入库，证书按顺序弹密码框。
    private func handleIdentityImport(_ urls: [URL]) {
        var certificates: [URL] = []
        var profiles: [URL] = []

        CertImportLog.add("picked \(urls.count) file(s): " + urls.map { "\($0.lastPathComponent)[\($0.pathExtension)]" }.joined(separator: ", "))

        for url in urls {
            switch url.pathExtension.lowercased() {
            case "p12", "pfx": certificates.append(url)
            case "mobileprovision": profiles.append(url)
            default: break
            }
        }

        guard !certificates.isEmpty || !profiles.isEmpty else {
            presentError(message: "sign_import_wrong_cert".localized)
            return
        }

        var importedProfiles = 0
        for profile in profiles where importProfileFile(profile) {
            importedProfiles += 1
        }
        if importedProfiles > 0 {
            SoundEffects.play(.rise)
        }

        if !certificates.isEmpty {
            pendingCertificateQueue.append(contentsOf: certificates)
            advanceCertificateQueue()
        }
    }

    private func advanceCertificateQueue() {
        guard !showCertificateSheet, !pendingCertificateQueue.isEmpty else { return }
        let next = pendingCertificateQueue.removeFirst()
        loadCertificateFile(next)
    }

    private func loadCertificateFile(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            pendingCertificateData = data
            pendingCertificateName = url.lastPathComponent
            showCertificateSheet = true
        } catch {
            presentError(error)
            advanceCertificateQueue()
        }
    }

    @discardableResult
    private func importProfileFile(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            _ = try store.importProfile(data: data, originalFileName: url.lastPathComponent)
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private func handlePickedIPA(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard ext == "ipa" || ext == "zip" else {
            presentError(message: "sign_import_wrong_type".localized)
            return
        }
        isLoadingIPA = true
        Task {
            do {
                let destination = try await store.importIPABackground(from: url)
                await MainActor.run {
                    applyIPA(destination)
                }
            } catch {
                await MainActor.run {
                    isLoadingIPA = false
                    presentError(error)
                }
            }
        }
    }

    private func consumeSigningHandoff() {
        guard let url = handoff.pendingIPA else { return }
        handoff.pendingIPA = nil
        handlePickedIPA(url)
    }

    private var availableTargets: [SigningTarget] {
        let base: [SigningTarget]
        if targets.isEmpty {
            base = [
                SigningTarget(
                    id: ".",
                    bundlePath: ".",
                    displayName: "sign_target_main".localized,
                    bundleIdentifier: "",
                    executableName: "",
                    kind: .main,
                    extensionPoint: nil,
                    requiredEntitlementKeys: [],
                    requiredAppGroups: [],
                    requiredKeychainGroups: [],
                    hasOriginalProfile: false
                )
            ]
        } else {
            base = targets
        }
        var available = base
        if removeAllExtensions {
            available = available.filter { $0.kind == .main }
        }
        if removeWatchApp {
            available = available.filter { $0.kind != .watchApp }
        }
        return available
    }

    private var targetsToRemove: [SigningTarget] {
        guard removeUncoveredExtensions, !removeAllExtensions else { return [] }
        return uncoveredExtensionTargets
    }

    private var uncoveredExtensionTargets: [SigningTarget] {
        guard let profile, !removeAllExtensions else { return [] }
        return targets.filter { target in
            guard target.kind != .main,
                  !(removeWatchApp && target.kind == .watchApp),
                  !target.bundleIdentifier.isEmpty else { return false }
            if independentProfile(for: target) != nil { return false }
            return profile.bundleIDPattern != "*" &&
                profile.bundleIDPattern != target.bundleIdentifier
        }
    }

    private var targetBinding: Binding<Set<String>> {
        Binding(
            get: {
                guard let id = targetEditingInjectionID,
                      let item = injections.first(where: { $0.id == id }) else { return ["."] }
                return item.targets
            },
            set: { newValue in
                guard let id = targetEditingInjectionID,
                      let index = injections.firstIndex(where: { $0.id == id }) else { return }
                var value = newValue
                if value.isEmpty { value = ["."] }
                injections[index].targets = value
            }
        )
    }

    private func targetSummary(_ injection: SigningInjection) -> String {
        let extensionCount = injection.targets.filter { $0 != "." }.count
        let mainSelected = injection.targets.contains(".")
        if extensionCount == 0 {
            return mainSelected ? "sign_target_main".localized : "sign_target_none".localized
        }
        if mainSelected {
            return String(format: "sign_target_summary".localized, extensionCount)
        }
        return String(format: "sign_target_summary_extensions".localized, extensionCount)
    }

    private func normalizeInjectionTargets() {
        let valid = Set(availableTargets.map(\.id))
        for index in injections.indices {
            var item = injections[index]
            item.targets = item.targets.intersection(valid)
            if item.targets.isEmpty {
                item.targets = ["."]
            }
            injections[index] = item
        }
    }

    private func seedDefaultInjectionIfNeeded() {
        guard !didSeedDefaultInjection else { return }
        guard injections.isEmpty else {
            didSeedDefaultInjection = true
            return
        }
        guard let url = builtInInjectionURL() else { return }
        didSeedDefaultInjection = true
        injections.append(
            SigningInjection(
                url: url,
                name: "内购破解.dylib",
                isFramework: false,
                targets: ["."],
                weak: true
            )
        )
    }

    private func builtInInjectionURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        let candidates = [
            bundleURL.appendingPathComponent("InAppPurchase.dylib"),
            bundleURL.appendingPathComponent("内购破解.dylib")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = Bundle.main.url(forResource: "InAppPurchase", withExtension: "dylib") {
            return url
        }
        return Bundle.main.url(forResource: "内购破解", withExtension: "dylib")
    }

    private func handleDylibImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                do {
                    let destination = try store.importInjection(from: url, isFramework: false)
                    injections.append(SigningInjection(url: destination, name: url.lastPathComponent, isFramework: false))
                } catch {
                    presentError(error)
                }
            }
        case .failure(let error):
            presentError(error)
        }
    }

    private func handleFrameworkImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                guard url.pathExtension.lowercased() == "framework" else {
                    presentError(message: "sign_injection_framework_invalid".localized)
                    continue
                }
                do {
                    let destination = try store.importInjection(from: url, isFramework: true)
                    injections.append(SigningInjection(url: destination, name: url.lastPathComponent, isFramework: true))
                } catch {
                    presentError(error)
                }
            }
        case .failure(let error):
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        presentError(message: error.localizedDescription)
    }

    private func presentError(message: String) {
        SoundEffects.play(.error)
        alertTitle = "sign_error_title".localized
        alertMessage = message
        showAlert = true
    }

    private var p12Type: UTType {
        UTType(filenameExtension: "p12") ?? .data
    }

    private var profileType: UTType {
        UTType(filenameExtension: "mobileprovision") ?? .data
    }

    private var ipaTypes: [UTType] {
        var types: [UTType] = [.data, .archive]
        if let ipa = UTType(filenameExtension: "ipa") {
            types.append(ipa)
        }
        if let apple = UTType("com.apple.itunes.ipa") {
            types.append(apple)
        }
        var seen = Set<String>()
        return types.filter { seen.insert($0.identifier).inserted }
    }

    private var dylibType: UTType {
        UTType(filenameExtension: "dylib") ?? .data
    }
}

private struct SigningIssue: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}
