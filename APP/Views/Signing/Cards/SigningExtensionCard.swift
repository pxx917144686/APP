import SwiftUI

struct SigningExtensionCard: SwiftUI.View {
    let injections: [SigningInjection]
    let accent: Color
    let colorScheme: ColorScheme
    let onAdd: () -> Void
    let onEditTargets: (SigningInjection) -> Void
    let onRemove: (UUID) -> Void
    let onToggleWeak: (UUID, Bool) -> Void

    var body: some SwiftUI.View {
        SigningSectionCard(
            title: "sign_injection_section".localized,
            icon: "puzzlepiece.extension.fill",
            count: injections.count,
            accent: accent,
            action: onAdd
        ) {
            if injections.isEmpty {
                SigningEmptyRow(
                    icon: "puzzlepiece.extension",
                    title: "sign_injection_empty".localized,
                    hint: "sign_injection_empty_hint".localized,
                    actionTitle: "sign_injection_add".localized,
                    accent: accent,
                    colorScheme: colorScheme,
                    action: onAdd
                )
            } else {
                VStack(spacing: 7) {
                    ForEach(injections) { injection in
                        row(for: injection)
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

    private func row(for injection: SigningInjection) -> some SwiftUI.View {
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
                        onEditTargets(injection)
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
                Toggle("", isOn: Binding(
                    get: { injection.weak },
                    set: { onToggleWeak(injection.id, $0) }
                ))
                .labelsHidden()
                .scaleEffect(0.75)
                .tint(accent)
                Text("sign_injection_weak".localized)
                    .font(.system(size: 7.5))
                    .foregroundStyle(.secondary)
            }

            Button {
                onRemove(injection.id)
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
}
