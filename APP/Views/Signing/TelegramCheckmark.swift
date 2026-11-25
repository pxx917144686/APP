import SwiftUI

struct TelegramCheckmark: View {
    var size: CGFloat
    var color: Color
    var lineWidth: CGFloat = 2
    var progress: CGFloat = 1

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: size * 0.16, y: size * 0.52))
            path.addLine(to: CGPoint(x: size * 0.40, y: size * 0.76))
            path.addLine(to: CGPoint(x: size * 0.84, y: size * 0.26))
        }
        .trim(from: 0, to: min(max(progress, 0), 1))
        .stroke(
            color,
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        )
        .frame(width: size, height: size)
    }
}
