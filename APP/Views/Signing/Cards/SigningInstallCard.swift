import SwiftUI

struct SigningInstallCard: SwiftUI.View {
    let phase: SigningInstallPhase
    let accent: Color

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(color)
                Text("sign_install_phase_title".localized)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text(percent)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }

            HStack(spacing: 4) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                    VStack(spacing: 3) {
                        ZStack {
                            Circle()
                                .fill(index <= step ? color : Color.primary.opacity(0.08))
                                .frame(width: 18, height: 18)
                            if index < step {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                                    .foregroundStyle(index == step ? .white : .secondary)
                            }
                        }
                        Text(title)
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(index <= step ? color : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(index < step ? color.opacity(0.5) : Color.primary.opacity(0.08))
                            .frame(height: 1)
                            .offset(y: -7)
                    }
                }
            }

            ProgressView(value: progress)
                .tint(color)
                .scaleEffect(y: 0.75)

            Text(message)
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
                .strokeBorder(color.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var steps: [String] {
        [
            "sign_install_step_prepare".localized,
            "sign_install_step_connect".localized,
            "sign_install_step_transfer".localized,
            "sign_install_step_install".localized,
            "sign_install_step_deliver".localized
        ]
    }

    private var step: Int {
        switch phase {
        case .idle, .preparing: return 0
        case .connecting: return 1
        case .transferring: return 2
        case .awaitingSystem: return 3
        case .delivered: return 4
        case .failed: return 0
        }
    }

    private var progress: Double {
        switch phase {
        case .transferring(let fraction): return max(0.05, min(0.95, fraction))
        case .preparing: return 0.05
        case .connecting: return 0.2
        case .awaitingSystem: return 0.7
        case .delivered: return 1
        case .failed: return 0
        case .idle: return 0
        }
    }

    private var percent: String {
        "\(Int(min(1, max(0, progress)) * 100))%"
    }

    private var color: Color {
        switch phase {
        case .failed: return .red
        case .delivered: return .green
        default: return accent
        }
    }

    private var icon: String {
        switch phase {
        case .failed: return "exclamationmark.triangle.fill"
        case .delivered: return "checkmark.seal.fill"
        default: return "iphone.arrow.down"
        }
    }

    private var message: String {
        switch phase {
        case .idle: return ""
        case .preparing: return "sign_install_msg_preparing".localized
        case .connecting: return "sign_install_msg_connecting".localized
        case .transferring(let fraction): return String(format: "sign_install_msg_transferring".localized, Int(fraction * 100))
        case .awaitingSystem: return "sign_install_msg_awaiting".localized
        case .delivered: return "sign_install_msg_delivered".localized
        case .failed(let message): return message
        }
    }
}
