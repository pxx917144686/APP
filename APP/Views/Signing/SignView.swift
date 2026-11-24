import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine
import ZsignSwift

struct ExtensionCredentialChoice: Hashable {
    var certificateID: UUID?
    var profileID: UUID?
}

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
    @State private var removeWatchApp = false
    @State private var removeUncoveredExtensions = false
    @State private var useTargetProfiles = false
    @State private var extensionChoices: [String: ExtensionCredentialChoice] = [:]
    @State private var showExtensionCredentials = false
    @State private var autoInstallAfterSign = true
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

    @State private var shareFile: ShareFile?
    @State private var isInstalling = false
    @State private var installPhase: SigningInstallPhase = .idle
    @State private var tasks = TaskBag()

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
            if !profile.bundleIDPattern.isEmpty, !profile.covers(bundleID: targetAppBundleID) {
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
                    identityCardView
                    SigningIPACard(
                        selectedIPA: selectedIPA,
                        isLoading: isLoadingIPA,
                        accent: accent,
                        colorScheme: colorScheme,
                        onPick: { showIPAPicker = true },
                        onImportFiles: { showIPAImporter = true },
                        onClear: {
                            selectedIPA = nil
                            bundleID = ""
                            extensionChoices = [:]
                            displayName = ""
                            version = ""
                        }
                    )
                    if selectedIPA != nil {
                        ipaPreflightCard
                    }
                    if selectedIPA != nil, profile != nil {
                        provisioningAuditCard
                    }
                    optionsCardView
                    extensionCardView
                    if !canSign && !session.isRunning {
                        signingPreflight
                    }
                    signActionView

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
                        SigningResultCard(
                            output: output,
                            onShare: { shareOutput() },
                            onInstall: { installOutput() }
                        )
                    }

                    if installPhase != .idle {
                        SigningInstallCard(phase: installPhase, accent: accent)
                    }

                    historyCardView
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
        .sheet(isPresented: $showExtensionCredentials) {
            ExtensionCredentialsSheet(
                targets: availableTargets.filter { $0.kind != .main },
                certificates: store.certificates,
                profiles: store.profiles,
                mainCertificate: certificate,
                mainProfile: profile,
                oldMainID: originalAppBundleID,
                newMainID: targetAppBundleID,
                usesCustomMainID: extensionIDOverrideActive,
                hasPassword: { store.password(for: $0) != nil },
                choices: $extensionChoices
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

    private var identityCardView: some SwiftUI.View {
        SigningIdentityCard(
            certificate: certificate,
            profile: profile,
            certificates: store.certificates,
            profiles: store.profiles,
            accent: accent,
            colorScheme: colorScheme,
            isCheckingRevocation: ocspChecking,
            onAdd: { showIdentityImportMenu = true },
            onShowDetail: { showCertificateDetail = true },
            onShowEntitlements: { showEntitlements = true },
            onCheckRevocation: { checkRevocation() },
            onSelectCertificate: { item in
                store.selectCertificate(item.id)
                autoSelectProfileForCurrentIPA(preferredCertificate: item)
            },
            onSelectProfile: { id in store.selectProfile(id) },
            onImportCertificate: { showCertificateImporter = true },
            onImportProfile: { showProfileImporter = true },
            onDeleteCertificate: { if let certificate { store.deleteCertificate(certificate) } },
            onDeleteProfile: { if let profile { store.deleteProfile(profile) } }
        )
    }

    private func checkRevocation() {
        guard let certificate, let profile, let password = certificatePassword else {
            AppPresenter.shared.present(alert: AppAlert(
                title: "sign_ocsp_missing".localized,
                message: "sign_ocsp_missing_message".localized
            ))
            return
        }
        let certificateURL = store.certificateURL(for: certificate)
        let profileURL = store.profileURL(for: profile)
        ocspChecking = true
        tasks.replace(key: "ocsp") { token in
            let result: (Int32, Date?, String?) = await withCheckedContinuation { continuation in
                Zsign.checkRevokage(
                    provisionPath: profileURL.path,
                    p12Path: certificateURL.path,
                    p12Password: password
                ) { status, date, error in
                    continuation.resume(returning: (status, date, error))
                }
            }
            guard self.tasks.isCurrent(token, for: "ocsp") else { return }
            self.ocspChecking = false
            let dateTextValue = result.1.map { self.dateText($0) } ?? "—"
            switch result.0 {
            case 0:
                AppPresenter.shared.present(alert: AppAlert(
                    title: "sign_ocsp_good_title".localized,
                    message: String(format: "sign_ocsp_good_message".localized, dateTextValue)
                ))
            case 1:
                AppPresenter.shared.present(alert: AppAlert(
                    title: "sign_ocsp_revoked_title".localized,
                    message: "sign_ocsp_revoked_message".localized
                ))
            default:
                AppPresenter.shared.present(alert: AppAlert(
                    title: "sign_ocsp_unknown_title".localized,
                    message: result.2 ?? "sign_ocsp_unknown_message".localized
                ))
            }
        }
    }

    private var originalAppBundleID: String {
        selectedIPA?.bundleIdentifier ?? ""
    }

    private var targetAppBundleID: String {
        let trimmed = trimmedBundleID
        let raw = trimmed.isEmpty ? originalAppBundleID : trimmed
        let normalized = normalizedCertificateID(raw)
        return normalized.isEmpty ? raw : normalized
    }

    private var extensionIDOverrideActive: Bool {
        !originalAppBundleID.isEmpty
            && targetAppBundleID != originalAppBundleID
    }

    private func derivedExtensionID(for target: SigningTarget) -> String {
        guard target.kind != .main else { return targetAppBundleID }
        let original = target.bundleIdentifier
        guard !original.isEmpty else { return targetAppBundleID }
        guard extensionIDOverrideActive else { return original }
        if original == targetAppBundleID || original.hasPrefix(targetAppBundleID + ".") {
            return original
        }
        if original == originalAppBundleID {
            return targetAppBundleID
        }
        if original.hasPrefix(originalAppBundleID + ".") {
            return targetAppBundleID + String(original.dropFirst(originalAppBundleID.count))
        }
        let suffix = original.split(separator: ".").suffix(2).joined(separator: ".")
        return suffix.isEmpty ? targetAppBundleID : targetAppBundleID + "." + suffix
    }

    private func separateProfile(for target: SigningTarget, bundleID: String) -> SigningProfile? {
        guard useTargetProfiles, target.kind != .main, let profile else { return nil }
        let team = profile.teamID
        let candidates = store.profiles.filter { candidate in
            guard candidate.id != profile.id else { return false }
            guard team.isEmpty || candidate.teamID == team else { return false }
            guard candidate.covers(bundleID: bundleID) else { return false }
            return isTargetProfileUsable(candidate)
        }
        return candidates.sorted { lhs, rhs in
            let lhsExact = lhs.bundleIDPattern == bundleID
            let rhsExact = rhs.bundleIDPattern == bundleID
            if lhsExact != rhsExact { return lhsExact }
            return lhs.bundleIDPattern.count > rhs.bundleIDPattern.count
        }.first
    }

    private func choice(for target: SigningTarget) -> ExtensionCredentialChoice {
        extensionChoices[target.bundlePath] ?? ExtensionCredentialChoice()
    }

    private func certificateForChoice(_ choice: ExtensionCredentialChoice) -> SigningCertificate? {
        if let id = choice.certificateID {
            return store.certificates.first { $0.id == id }
        }
        return certificate
    }

    private func profileMatchesCertificate(_ candidate: SigningProfile, certificate candidateCertificate: SigningCertificate?) -> Bool {
        guard let candidateCertificate else { return true }
        if let expiry = candidate.expiresAt, expiry < Date() { return false }
        if !candidateCertificate.teamID.isEmpty,
           !candidate.teamID.isEmpty,
           candidateCertificate.teamID != candidate.teamID {
            return false
        }
        if let fingerprint = candidateCertificate.fingerprint,
           !fingerprint.isEmpty,
           let certificates = candidate.certificates,
           !certificates.isEmpty,
           !certificates.contains(where: { $0.fingerprint?.caseInsensitiveCompare(fingerprint) == .orderedSame }) {
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
        return true
    }

    private func bestProfile(for target: SigningTarget, certificate candidateCertificate: SigningCertificate?) -> SigningProfile? {
        let derived = derivedExtensionID(for: target)
        let original = target.bundleIdentifier
        let candidates = store.profiles.filter { candidate in
            guard profileMatchesCertificate(candidate, certificate: candidateCertificate) else { return false }
            return candidate.covers(bundleID: derived) || candidate.covers(bundleID: original)
        }
        return candidates.sorted { lhs, rhs in
            let lhsID = lhs.covers(bundleID: original) ? original : derived
            let rhsID = rhs.covers(bundleID: original) ? original : derived
            let lhsExact = lhs.bundleIDPattern == lhsID
            let rhsExact = rhs.bundleIDPattern == rhsID
            if lhsExact != rhsExact { return lhsExact }
            return lhs.bundleIDPattern.count > rhs.bundleIDPattern.count
        }.first
    }

    private func chosenProfile(for target: SigningTarget) -> SigningProfile? {
        guard target.kind != .main else { return nil }
        let current = choice(for: target)
        guard current.certificateID != nil || current.profileID != nil else { return nil }
        let selectedCertificate = certificateForChoice(current)
        if let profileID = current.profileID {
            return store.profiles.first { $0.id == profileID }
        }
        return bestProfile(for: target, certificate: selectedCertificate)
    }

    private func extensionID(for target: SigningTarget, profile candidate: SigningProfile) -> String {
        guard extensionIDOverrideActive else { return target.bundleIdentifier }
        let original = target.bundleIdentifier
        let derived = derivedExtensionID(for: target)
        if let mainProfile = profile, candidate.id == mainProfile.id {
            return derived
        }
        if candidate.covers(bundleID: derived) { return derived }
        if candidate.covers(bundleID: original) { return original }
        return derived
    }

    private func effectiveExtensionID(for target: SigningTarget) -> String {
        guard target.kind != .main else { return targetAppBundleID }
        let original = target.bundleIdentifier
        guard extensionIDOverrideActive else { return original }
        if let chosen = chosenProfile(for: target) {
            return extensionID(for: target, profile: chosen)
        }
        let derived = derivedExtensionID(for: target)
        guard useTargetProfiles else { return derived }
        if separateProfile(for: target, bundleID: derived) != nil {
            return derived
        }
        if separateProfile(for: target, bundleID: original) != nil {
            return original
        }
        return derived
    }

    private func matchedProfileForTarget(_ target: SigningTarget) -> SigningProfile? {
        guard let profile else { return nil }
        if target.kind == .main { return profile }
        if let chosen = chosenProfile(for: target) { return chosen }
        return separateProfile(for: target, bundleID: effectiveExtensionID(for: target))
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
        guard target.kind != .main else { return nil }
        return matchedProfileForTarget(target)
    }

    private var autoMatchedTargetCount: Int {
        guard useTargetProfiles, profile != nil else { return 0 }
        return targets.filter { target in
            guard target.kind != .main else { return false }
            if removeWatchApp && target.kind == .watchApp { return false }
            let selected = choice(for: target)
            guard selected.certificateID == nil, selected.profileID == nil else { return false }
            return independentProfile(for: target) != nil
        }.count
    }

    private var targetSigningCredentials: [SigningTargetCredentials] {
        guard let mainProfile = profile else { return [] }
        let removedPaths = Set(targetsToRemove.map(\.bundlePath))
        return targets.compactMap { target in
            guard target.kind != .main else { return nil }
            if removeWatchApp && target.kind == .watchApp { return nil }
            if removedPaths.contains(target.bundlePath) { return nil }
            let matched = independentProfile(for: target) ?? mainProfile
            let selectedCertificate = certificateForChoice(choice(for: target)) ?? certificate
            guard let selectedCertificate,
                  let password = store.password(for: selectedCertificate) else { return nil }
            let entitlements: Data?
            if matched.id == mainProfile.id {
                entitlements = extensionEntitlements(for: target, profile: mainProfile)
            } else {
                guard profileMatchesCertificate(matched, certificate: selectedCertificate) else { return nil }
                entitlements = matched.entitlementsData
            }
            return SigningTargetCredentials(
                targetID: target.id,
                bundlePath: target.bundlePath,
                originalBundleIdentifier: target.bundleIdentifier,
                bundleIdentifier: effectiveExtensionID(for: target),
                certificate: selectedCertificate,
                certificateURL: store.certificateURL(for: selectedCertificate),
                password: password,
                profile: matched,
                profileURL: store.profileURL(for: matched),
                entitlementsPlist: entitlements
            )
        }
    }

    private func extensionEntitlements(for target: SigningTarget, profile targetProfile: SigningProfile) -> Data? {
        var dictionary: [String: Any] = [:]
        if let data = signingEntitlementsPlist,
           let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            dictionary = parsed
        } else if let data = targetProfile.entitlementsData,
                  let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            dictionary = parsed
        } else {
            return targetProfile.entitlementsData
        }
        let team = targetProfile.teamID
        let bundleID = effectiveExtensionID(for: target)
        if !team.isEmpty, !bundleID.isEmpty {
            dictionary["application-identifier"] = "\(team).\(bundleID)"
            if dictionary["com.apple.application-identifier"] != nil {
                dictionary["com.apple.application-identifier"] = "\(team).\(bundleID)"
            }
        }
        return try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
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
                : effectiveExtensionID(for: target)
            let covered = effectiveProfile.covers(bundleID: resolvedID)

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

    private var signActionView: some SwiftUI.View {
        SigningActionCard(
            canSign: canSign,
            isRunning: session.isRunning,
            hint: hintText,
            accent: accent,
            onTap: {
                if canSign {
                    startSigning()
                } else {
                    presentError(message: hintText)
                }
            }
        )
    }

    private var historyCardView: some SwiftUI.View {
        SigningHistoryCard(
            records: historyStore.records,
            accent: accent,
            colorScheme: colorScheme,
            onOpen: { showHistory = true }
        )
    }

    private var extensionCardView: some SwiftUI.View {
        SigningExtensionCard(
            injections: injections,
            accent: accent,
            colorScheme: colorScheme,
            onAdd: { showInjectionMenu = true },
            onEditTargets: { injection in
                targetEditingInjectionID = injection.id
                showTargetSheet = true
            },
            onRemove: { id in injections.removeAll { $0.id == id } },
            onToggleWeak: { id, weak in
                if let index = injections.firstIndex(where: { $0.id == id }) {
                    injections[index].weak = weak
                }
            }
        )
    }

    private var optionsCardView: some SwiftUI.View {
        SigningOptionsCard(
            bundleID: $bundleID,
            displayName: $displayName,
            version: $version,
            removeProvision: $removeProvision,
            removeWatchApp: $removeWatchApp,
            removeUncoveredExtensions: $removeUncoveredExtensions,
            useTargetProfiles: $useTargetProfiles,
            autoInstallAfterSign: $autoInstallAfterSign,
            isolateKeychain: $isolateKeychain,
            dropUnsignableEntitlements: $dropUnsignableEntitlements,
            removeICloudEntitlements: $removeICloudEntitlements,
            keepGetTaskAllow: $keepGetTaskAllow,
            increasedMemoryLimit: $increasedMemoryLimit,
            targets: targets,
            hasProfile: profile != nil,
            extensionIDOverrideActive: extensionIDOverrideActive,
            hasExtensionTargets: !availableTargets.filter { $0.kind != .main }.isEmpty,
            autoMatchedTargetCount: autoMatchedTargetCount,
            extensionChoicesCount: extensionChoices.count,
            entitlementsMode: entitlementsMode,
            validationIssues: validationIssues,
            deviceUDID: deviceUDID,
            accent: accent,
            colorScheme: colorScheme,
            effectiveExtensionID: { effectiveExtensionID(for: $0) },
            onFillCertificateID: { fillCertificateIDFromProfile() },
            onShowExtensionCredentials: { showExtensionCredentials = true },
            onShowDeviceSheet: { showDeviceSheet = true },
            onShowEntitlements: { showEntitlements = true }
        )
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
            if removeWatchApp {
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
            certificateID: certificate.id,
            profileID: profile.id
        )
        didAutoInstall = false
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        MotionTransition.smooth.run {
            session.start(taskRequest)
        }
    }

    private func shareOutput() {
        guard let output = session.outputURL else { return }
        shareFile = ShareFile(url: output)
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
        let certificateID: UUID
        let profileID: UUID
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
            certificateID: metadata.certificateID,
            profileID: metadata.profileID
        )
        historyStore.retainSource(from: metadata.inputURL, for: record.id)
        pendingSigningMetadata = nil
    }

    private func refreshFromHistory(_ record: SigningHistoryRecord) {
        guard let source = historyStore.retainedSourceURL(for: record) else {
            presentError(message: "sign_history_refresh_source_missing".localized)
            return
        }
        guard let certificateID = record.certificateID,
              store.certificates.contains(where: { $0.id == certificateID }),
              let profileID = record.profileID,
              store.profiles.contains(where: { $0.id == profileID }) else {
            presentError(message: "sign_history_refresh_identity_missing".localized)
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
            AppPresenter.shared.present(alert: AppAlert(
                title: "sign_install_self_title".localized,
                message: "sign_install_self_warning".localized,
                primaryTitle: "sign_share".localized,
                onPrimary: { shareOutput() },
                secondaryTitle: "cancel".localized
            ))
            return
        }
        isInstalling = true
        installPhase = .preparing
        tasks.replace(key: "install") { token in
            do {
                try await SigningInstaller.install(ipaURL: output, onPhase: { phase in
                    self.installPhase = phase
                })
                guard self.tasks.isCurrent(token, for: "install") else { return }
                self.isInstalling = false
                TopBannerPresenter.shared.show(TopBanner(
                    message: "sign_install_handed_off".localized,
                    systemImage: "checkmark.seal.fill"
                ))
            } catch {
                guard self.tasks.isCurrent(token, for: "install") else { return }
                self.isInstalling = false
                self.installPhase = .failed(error.localizedDescription)
                AppPresenter.shared.present(alert: AppAlert(
                    title: "sign_error_title".localized,
                    message: error.localizedDescription
                ))
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

    private func handleCertificateImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                pendingCertificateData = data
                pendingCertificateName = url.lastPathComponent
                showCertificateSheet = true
            } catch {
                presentError(error)
            }
        case .failure(let error):
            presentError(error)
        }
    }

    private func handleProfileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                _ = try store.importProfile(data: data, originalFileName: url.lastPathComponent)
            } catch {
                presentError(error)
            }
        case .failure(let error):
            presentError(error)
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

    private func normalizedCertificateID(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }
        if let dot = value.firstIndex(of: ".") {
            let prefix = String(value[..<dot])
            if prefix.count == 10,
               prefix.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
                value = String(value[value.index(after: dot)...])
            }
        }
        return value
    }

    private func fillCertificateIDFromProfile() {
        guard let profile else {
            presentError(message: "sign_hint_select_all".localized)
            return
        }
        let raw = profile.applicationIdentifier.isEmpty ? profile.bundleIDPattern : profile.applicationIdentifier
        let normalized = normalizedCertificateID(raw)
        guard !normalized.isEmpty, !normalized.contains("*") else {
            presentError(message: "sign_certificate_id_wildcard".localized)
            return
        }
        bundleID = normalized
    }

    private func handleIdentityImport(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let certificateFiles = urls.filter { $0.pathExtension.lowercased() == "p12" }
        let profileFiles = urls.filter { $0.pathExtension.lowercased() == "mobileprovision" }
        for url in profileFiles {
            guard let data = try? Data(contentsOf: url) else { continue }
            _ = try? store.importProfile(data: data, originalFileName: url.lastPathComponent)
        }
        pendingCertificateQueue = certificateFiles
        advanceCertificateQueue()
    }

    private func advanceCertificateQueue() {
        guard pendingCertificateData == nil, !pendingCertificateQueue.isEmpty else { return }
        let url = pendingCertificateQueue.removeFirst()
        guard let data = try? Data(contentsOf: url) else {
            advanceCertificateQueue()
            return
        }
        pendingCertificateName = url.lastPathComponent
        pendingCertificateData = data
        showCertificateSheet = true
    }

    private func consumeSigningHandoff() {
        guard let url = handoff.pendingIPA else { return }
        handoff.pendingIPA = nil
        applyIPA(url)
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
        if removeWatchApp {
            available = available.filter { $0.kind != .watchApp }
        }
        return available
    }

    private var targetsToRemove: [SigningTarget] {
        guard removeUncoveredExtensions else { return [] }
        return uncoveredExtensionTargets
    }

    private var uncoveredExtensionTargets: [SigningTarget] {
        guard let profile else { return [] }
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
        AppPresenter.shared.present(alert: AppAlert(
            title: "sign_error_title".localized,
            message: message
        ))
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
