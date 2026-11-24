import SwiftUI

struct ShimmerModifier: ViewModifier {
    var active: Bool

    @State private var phase: CGFloat = -1

    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content
                .overlay {
                    GeometryReader { proxy in
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0), location: 0),
                                .init(color: .white.opacity(0.32), location: 0.5),
                                .init(color: .white.opacity(0), location: 1)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .frame(width: max(proxy.size.width * 0.55, 1))
                        .offset(x: phase * proxy.size.width * 1.55)
                    }
                    .allowsHitTesting(false)
                }
                .mask(content)
                .onAppear {
                    phase = -1
                    withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                        phase = 1.2
                    }
                }
        } else {
            content
        }
    }
}

extension View {
    func shimmering(active: Bool = true) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}
