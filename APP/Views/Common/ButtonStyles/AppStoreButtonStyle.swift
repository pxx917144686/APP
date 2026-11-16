import SwiftUI

struct AppStoreButtonStyle: ButtonStyle {
    @EnvironmentObject var themeManager: ThemeManager
    var width: CGFloat = 78

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(themeManager.accentColor)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: width, height: 32)
            .background(
                Capsule()
                    .fill(themeManager.accentColor.opacity(0.12))
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct AppStoreOrangeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.orange)
            .lineLimit(1)
            .frame(width: 78, height: 32)
            .background(
                Capsule()
                    .fill(Color.orange.opacity(0.12))
            )
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct AppStoreProgressButtonStyle: View {
    @EnvironmentObject var themeManager: ThemeManager
    var width: CGFloat = 78

    var body: some View {
        HStack(spacing: 5) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: themeManager.accentColor))
                .scaleEffect(0.6)
                .frame(width: 13, height: 13)

            Text("purchasing".localized)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(themeManager.accentColor)
                .lineLimit(1)
        }
        .frame(width: width, height: 32)
        .background(
            Capsule()
                .fill(themeManager.accentColor.opacity(0.12))
        )
    }
}

struct AppStoreOwnedButtonStyle: View {
    var width: CGFloat = 78

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
            Text("purchased".localized)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(.secondary)
        .frame(width: width, height: 32)
        .background(
            Capsule()
                .fill(Color.secondary.opacity(0.12))
        )
    }
}
