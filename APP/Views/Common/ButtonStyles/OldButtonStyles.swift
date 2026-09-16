import SwiftUI

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .shadow(
                color: Color.black.opacity(configuration.isPressed ? 0.15 : 0.25),
                radius: configuration.isPressed ? 4 : 8,
                x: 0,
                y: configuration.isPressed ? 2 : 4
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct CardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12
    var backgroundColor: Color = Color(.systemBackground)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(backgroundColor)
                    .shadow(
                        color: Color.black.opacity(configuration.isPressed ? 0.08 : 0.15),
                        radius: configuration.isPressed ? 4 : 10,
                        x: 0,
                        y: configuration.isPressed ? 2 : 6
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

struct PressableScaleModifier: ViewModifier {
    var isPressed: Bool
    var scale: CGFloat = 0.96

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? scale : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
    }
}

extension View {
    func pressableScale(_ isPressed: Bool, scale: CGFloat = 0.96) -> some View {
        modifier(PressableScaleModifier(isPressed: isPressed, scale: scale))
    }
}
