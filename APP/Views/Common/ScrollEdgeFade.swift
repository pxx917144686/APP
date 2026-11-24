import SwiftUI

struct ScrollEdgeFadeModifier: ViewModifier {
    var top: CGFloat
    var bottom: CGFloat

    func body(content: Content) -> some View {
        content.mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: bottom)
            }
        }
    }
}

extension View {
    func scrollEdgeFade(top: CGFloat = 18, bottom: CGFloat = 18) -> some View {
        modifier(ScrollEdgeFadeModifier(top: top, bottom: bottom))
    }
}
