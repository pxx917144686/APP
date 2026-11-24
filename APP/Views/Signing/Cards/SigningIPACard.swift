import SwiftUI

struct SigningIPACard: SwiftUI.View {
    let selectedIPA: SigningIPAInfo?
    let isLoading: Bool
    let accent: Color
    let colorScheme: ColorScheme
    let onPick: () -> Void
    let onImportFiles: () -> Void
    let onClear: () -> Void

    var body: some SwiftUI.View {
        SigningSectionCard(
            title: "sign_ipa_section".localized,
            icon: "shippingbox.fill",
            accent: accent,
            action: onPick
        ) {
            if isLoading {
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
                                SigningMetaText(title: "sign_version".localized, value: selectedIPA.version)
                                SigningMetaText(title: "sign_ipa_size".localized, value: selectedIPA.sizeText)
                                if selectedIPA.isEncrypted {
                                    Label("sign_ipa_encrypted_tag".localized, systemImage: "lock.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button(action: onPick) {
                                Label("sign_from_downloads".localized, systemImage: "arrow.down.circle")
                            }
                            Button(action: onImportFiles) {
                                Label("sign_from_files".localized, systemImage: "doc.badge.plus")
                            }
                            Divider()
                            Button(role: .destructive, action: onClear) {
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
                SigningEmptyRow(
                    icon: "shippingbox",
                    title: "sign_no_ipa".localized,
                    hint: "sign_no_ipa_hint".localized,
                    actionTitle: "sign_choose_ipa".localized,
                    accent: accent,
                    colorScheme: colorScheme,
                    action: onPick
                )
            }
        }
    }
}
