import SwiftUI

struct DoubleHelixIndicator: View {
    var color: Color = .primary
    var dotSize: CGFloat = 2
    var spacing: CGFloat = 1
    var amplitude: CGFloat = 8
    var count: Int = 10
    var duration: Double = 2.3

    @State private var animating = false

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(0..<count, id: \.self) { index in
                ZStack {
                    Circle()
                        .fill(color.opacity(0.8))
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: animating ? -amplitude : amplitude)

                    Circle()
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
                        .offset(y: animating ? amplitude : -amplitude)
                }
                .frame(height: amplitude * 2 + dotSize)
                .animation(
                    .easeInOut(duration: duration)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1),
                    value: animating
                )
            }
        }
        .onAppear { animating = true }
        .accessibilityLabel("loading")
    }
}
