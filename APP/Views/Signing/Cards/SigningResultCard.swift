import SwiftUI

struct SigningResultCard: SwiftUI.View {
    let output: URL
    let onShare: () -> Void
    let onInstall: () -> Void

    private var info: SigningIPAInfo? {
        try? SigningIPAInfo.read(url: output)
    }

    private var isSelf: Bool {
        info?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                TelegramRadialProgress(
                    progress: 1,
                    outcome: .completed,
                    tint: .green,
                    size: 26,
                    lineWidth: 2.2
                )
                Text("sign_result_title".localized)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(info?.sizeText ?? "")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let info {
                HStack(spacing: 6) {
                    chip("sign_result_bundle_id".localized, info.bundleIdentifier, color: isSelf ? .red : .secondary)
                    chip("sign_version".localized, info.version, color: .secondary)
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
                Button(action: onShare) {
                    Label("sign_share".localized, systemImage: "square.and.arrow.up")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.cyan.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button(action: onInstall) {
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

    private func chip(_ title: String, _ value: String, color: Color) -> some SwiftUI.View {
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
}
