import SwiftUI

struct SigningOptionsCard: SwiftUI.View {
    @Binding var bundleID: String
    @Binding var displayName: String
    @Binding var version: String
    @Binding var removeProvision: Bool
    @Binding var removeWatchApp: Bool
    @Binding var removeUncoveredExtensions: Bool
    @Binding var useTargetProfiles: Bool
    @Binding var autoInstallAfterSign: Bool
    @Binding var isolateKeychain: Bool
    @Binding var dropUnsignableEntitlements: Bool
    @Binding var removeICloudEntitlements: Bool
    @Binding var keepGetTaskAllow: Bool
    @Binding var increasedMemoryLimit: Bool
    let targets: [SigningTarget]
    let hasProfile: Bool
    let extensionIDOverrideActive: Bool
    let hasExtensionTargets: Bool
    let autoMatchedTargetCount: Int
    let extensionChoicesCount: Int
    let entitlementsMode: SigningEntitlementsMode
    let validationIssues: [SigningIssue]
    let deviceUDID: String
    let accent: Color
    let colorScheme: ColorScheme
    let effectiveExtensionID: (SigningTarget) -> String
    let onFillCertificateID: () -> Void
    let onShowExtensionCredentials: () -> Void
    let onShowDeviceSheet: () -> Void
    let onShowEntitlements: () -> Void

    var body: some SwiftUI.View {
        SigningSectionCard(title: "sign_options_section".localized, icon: "slider.horizontal.3", accent: accent) {
            VStack(spacing: 10) {
                SigningLabeledField(title: "sign_bundle_id".localized, text: $bundleID, mono: true, colorScheme: colorScheme)
                SigningLabeledField(title: "sign_certificate_id".localized, text: $bundleID, mono: true, colorScheme: colorScheme)

                HStack(spacing: 6) {
                    Text("sign_certificate_id_hint".localized)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 4)

                    Button(action: onFillCertificateID) {
                        Text("sign_fill_from_profile".localized)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(!hasProfile)
                    .opacity(hasProfile ? 1 : 0.45)
                }

                if extensionIDOverrideActive {
                    extensionIDOverride
                }

                Button(action: onShowExtensionCredentials) {
                    HStack(spacing: 10) {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("sign_extension_credentials".localized)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.primary)
                            Text("sign_extension_credentials_hint".localized)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        if extensionChoicesCount > 0 {
                            Text("\(extensionChoicesCount)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(accent.opacity(0.12)))
                        }

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(9)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!hasExtensionTargets)

                SigningLabeledField(title: "sign_display_name".localized, text: $displayName, mono: false, colorScheme: colorScheme)
                SigningLabeledField(title: "sign_version".localized, text: $version, mono: true, colorScheme: colorScheme)

                optionToggle("sign_remove_provision".localized, "sign_remove_provision_hint".localized, isOn: $removeProvision)
                optionToggle("sign_remove_watch".localized, "sign_remove_watch_hint".localized, isOn: $removeWatchApp)
                optionToggle("sign_remove_uncovered_extensions".localized, "sign_remove_uncovered_extensions_hint".localized, isOn: $removeUncoveredExtensions)
                    .disabled(!hasProfile)
                optionToggle(
                    "sign_use_target_profiles".localized,
                    String(format: "sign_use_target_profiles_hint".localized, autoMatchedTargetCount),
                    isOn: $useTargetProfiles
                )
                .disabled(!hasProfile || !hasExtensionTargets)
                optionToggle("sign_auto_install".localized, "sign_auto_install_hint".localized, isOn: $autoInstallAfterSign)

                Button(action: onShowDeviceSheet) {
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

                Button(action: onShowEntitlements) {
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

                optionToggle("sign_ent_isolate_keychain".localized, "sign_ent_isolate_keychain_hint".localized, isOn: $isolateKeychain, compact: true)
                optionToggle("sign_ent_drop_unsignable".localized, "sign_ent_drop_unsignable_hint".localized, isOn: $dropUnsignableEntitlements, compact: true)
                optionToggle("sign_ent_remove_icloud".localized, "sign_ent_remove_icloud_hint".localized, isOn: $removeICloudEntitlements, compact: true)
                optionToggle("sign_ent_keep_get_task_allow".localized, "sign_ent_keep_get_task_allow_hint".localized, isOn: $keepGetTaskAllow, compact: true)
                optionToggle("sign_ent_increased_memory".localized, "sign_ent_increased_memory_hint".localized, isOn: $increasedMemoryLimit, compact: true)

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
            }
        }
    }

    private var extensionIDOverride: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 5) {
            Text("sign_extension_follow_hint".localized)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("sign_extension_ids".localized)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(targets.filter { target in
                target.kind != .main
                    && !(removeWatchApp && target.kind == .watchApp)
            }.prefix(4)) { target in
                HStack(spacing: 6) {
                    Image(systemName: target.kind.icon)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(target.kind.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(effectiveExtensionID(target))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
        )
    }

    private func optionToggle(_ title: String, _ hint: String? = nil, isOn: Binding<Bool>, compact: Bool = false) -> some SwiftUI.View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                if let hint {
                    Text(hint)
                        .font(.system(size: compact ? 8.5 : 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(accent)
    }
}
