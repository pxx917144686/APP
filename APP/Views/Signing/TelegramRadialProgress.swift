import SwiftUI

struct TelegramRadialProgress: View {
    let progress: Double
    let outcome: SigningOutcome
    let tint: Color
    var size: CGFloat = 44
    var lineWidth: CGFloat = 3.5

    @State private var spin = false
    @State private var reveal = false
    @State private var burst = false

    private var clamped: CGFloat {
        CGFloat(min(max(progress, 0), 1))
    }

    private var ringColor: Color {
        switch outcome {
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        default: return tint
        }
    }

    private var shownProgress: CGFloat {
        switch outcome {
        case .completed, .failed: return 1
        default: return max(0.02, clamped)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(ringColor.opacity(outcome == .running ? 0.10 : 0.16))

            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: shownProgress)
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: outcome == .running
                            ? [ringColor, .blue, .purple, ringColor]
                            : [ringColor, ringColor.opacity(0.55), ringColor]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: ringColor.opacity(0.5), radius: 5)
                .animation(.linear(duration: 0.22), value: shownProgress)

            if outcome == .running {
                Circle()
                    .trim(from: 0, to: 0.22)
                    .stroke(
                        LinearGradient(
                            colors: [.clear, ringColor.opacity(0.95), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .allowsHitTesting(false)
            }

            if outcome == .completed {
                Circle()
                    .stroke(ringColor.opacity(0.45), lineWidth: 1)
                    .scaleEffect(burst ? 1.38 : 0.9)
                    .opacity(burst ? 0 : 0.85)
                    .animation(.easeOut(duration: 0.65), value: burst)
            }

            icon
        }
        .frame(width: size, height: size)
        .onAppear {
            if outcome == .running {
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    spin = true
                }
            }
            if outcome == .completed {
                withAnimation(.easeOut(duration: 0.25)) {
                    reveal = true
                }
                withAnimation(.easeOut(duration: 0.65)) {
                    burst = true
                }
            }
        }
        .onChange(of: outcome) { _, newValue in
            switch newValue {
            case .running:
                reveal = false
                burst = false
                spin = false
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                    spin = true
                }
            case .completed:
                withAnimation(.easeOut(duration: 0.25)) {
                    reveal = true
                }
                withAnimation(.easeOut(duration: 0.65)) {
                    burst = true
                }
            default:
                reveal = false
                burst = false
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        switch outcome {
        case .completed:
            TelegramCheckmark(
                size: size * 0.42,
                color: .white,
                lineWidth: max(1.6, size * 0.05),
                progress: reveal ? 1 : 0
            )
            .animation(.easeOut(duration: 0.21), value: reveal)
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: size * 0.30, weight: .black))
                .foregroundStyle(.white)
        case .cancelled:
            Image(systemName: "pause.fill")
                .font(.system(size: size * 0.28, weight: .black))
                .foregroundStyle(.white)
        default:
            Image(systemName: "signature")
                .font(.system(size: size * 0.32, weight: .bold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating, isActive: outcome == .running)
        }
    }
}
