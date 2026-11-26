import SwiftUI

struct UpdateProgressRing: View {
    var progress: Double
    var tint: Color
    var size: CGFloat = 72
    var lineWidth: CGFloat = 6

    private var clamped: Double {
        min(max(progress, 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.15), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0.001, clamped))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.2), value: clamped)

            Text("\(Int(clamped * 100))%")
                .font(.system(size: size * 0.21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText(value: clamped))
        }
        .frame(width: size, height: size)
        .accessibilityLabel("\(Int(clamped * 100))%")
    }
}
