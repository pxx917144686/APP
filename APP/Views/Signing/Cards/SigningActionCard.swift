import SwiftUI

struct SigningActionCard: SwiftUI.View {
    let canSign: Bool
    let isRunning: Bool
    let hint: String
    let accent: Color
    let onTap: () -> Void

    var body: some SwiftUI.View {
        VStack(spacing: 6) {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    if isRunning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                            .scaleEffect(0.85)
                    } else {
                        Image(systemName: "signature")
                            .font(.system(size: 15, weight: .bold))
                    }
                    Text(isRunning ? "sign_running".localized : "sign_start".localized)
                        .font(.system(size: 15, weight: .bold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: canSign || isRunning
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
            .disabled(isRunning)
            .opacity(isRunning ? 0.75 : 1)

            if !canSign && !isRunning {
                Text(hint)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
