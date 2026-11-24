import SwiftUI

struct SigningHistoryRow: View {
    let options: SigningHistoryRowOptions

    var body: some View {
        Button(action: options.onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(options.accentColor)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(options.accentColor.opacity(0.10))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(options.record.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(options.record.bundleId.isEmpty ? options.record.outputName : options.record.bundleId)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    if options.hasRetainedSource {
                        Text("sign_history_source_ready".localized)
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    if options.isAvailable {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("sign_history_file_missing".localized)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }

                HStack(spacing: 8) {
                    if !options.record.version.isEmpty {
                        meta("v\(options.record.version)")
                    }
                    meta(options.record.date.formatted(date: .abbreviated, time: .shortened))
                    if let profile = options.record.profileName {
                        meta(profile, limit: 18)
                    }
                }

                if let certificate = options.record.certificateName, !certificate.isEmpty {
                    Text(certificate)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(action: options.onToggleHidden) {
                Label(
                    options.record.isHidden == true ? "sign_history_unhide".localized : "sign_history_hide".localized,
                    systemImage: options.record.isHidden == true ? "eye" : "eye.slash"
                )
            }
            Button(role: .destructive, action: options.onDelete) {
                Label("sign_delete".localized, systemImage: "trash")
            }
        }
    }

    private func meta(_ text: String, limit: Int = 40) -> some View {
        Text(text)
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: CGFloat(limit) * 5, alignment: .leading)
    }
}
