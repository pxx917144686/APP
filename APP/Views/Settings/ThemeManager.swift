import SwiftUI
import UIKit

struct Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 64
}

enum AppTheme: Int, CaseIterable {
    case light = 1
    case dark = 2
    case system = 0

    var displayName: String {
        switch self {
        case .system: return "follow_system".localized
        case .light: return "light_mode".localized
        case .dark: return "dark_mode".localized
        }
    }
}
@MainActor
class ThemeManager: ObservableObject, @unchecked Sendable {
    static let shared = ThemeManager()

    @Published var selectedTheme: AppTheme = .system {
        didSet {
            UserDefaults.standard.set(selectedTheme.rawValue, forKey: "Feather.userInterfaceStyle")

            DispatchQueue.main.async { [weak self] in
                self?.updateUserInterfaceStyle()
            }
        }
    }

    @Published var accentColor: Color = Color(hex: "#007AFF") {
        didSet {
            updateWindowTintColor()
            saveAccentColor()
        }
    }

    private var notificationObserver: Any?

    private init() {

        let savedTheme = UserDefaults.standard.integer(forKey: "Feather.userInterfaceStyle")

        let initialTheme: AppTheme
        if let theme = AppTheme(rawValue: savedTheme) {
            initialTheme = theme
        } else {
            initialTheme = .system
        }

        _selectedTheme = Published(initialValue: initialTheme)

        updateAccentColor()

        notificationObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in

            DispatchQueue.main.async {
                self?.updateAccentColor()
            }
        }
    }

    deinit {

        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func updateAccentColor() {

        let savedColorHex = UserDefaults.standard.string(forKey: "APP.userTintColor") ?? "#007AFF"
        accentColor = Color(hex: savedColorHex)
    }

    private func saveAccentColor() {
        let hex = accentColor.toHex()
        UserDefaults.standard.set(hex, forKey: "APP.userTintColor")
    }

    private func updateWindowTintColor() {
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            for window in windowScene.windows {
                window.tintColor = UIColor(accentColor)
            }
        }
    }

    var isDarkMode: Bool {
        switch selectedTheme {
        case .light:
            return false
        case .dark:
            return true
        case .system:
            return UITraitCollection.current.userInterfaceStyle == .dark
        }
    }

    var backgroundColor: Color {
        switch selectedTheme {
        case .light:
            return .white
        case .dark:
            return ModernDarkColors.backgroundPrimary
        case .system:

            if UITraitCollection.current.userInterfaceStyle == .dark {
                return ModernDarkColors.backgroundPrimary
            } else {
                return .white
            }
        }
    }

    var backgroundPrimary: Color {
        adaptiveColor(light: Color(.systemBackground), dark: ModernDarkColors.backgroundPrimary)
    }

    var backgroundSecondary: Color {
        adaptiveColor(light: Color(.secondarySystemBackground), dark: ModernDarkColors.backgroundSecondary)
    }

    var backgroundTertiary: Color {
        adaptiveColor(light: Color(.tertiarySystemBackground), dark: ModernDarkColors.backgroundTertiary)
    }

    var surfacePrimary: Color {
        adaptiveColor(light: Color(.systemBackground), dark: ModernDarkColors.surfacePrimary)
    }

    var surfaceSecondary: Color {
        adaptiveColor(light: Color(.secondarySystemBackground), dark: ModernDarkColors.surfaceSecondary)
    }

    var borderPrimary: Color {
        adaptiveColor(light: Color(.opaqueSeparator), dark: ModernDarkColors.borderPrimary)
    }

    var borderSecondary: Color {
        adaptiveColor(light: Color(.separator), dark: ModernDarkColors.borderSecondary)
    }

    var textPrimary: Color {
        adaptiveColor(light: Color(.label), dark: ModernDarkColors.textPrimary)
    }

    var textSecondary: Color {
        adaptiveColor(light: Color(.secondaryLabel), dark: ModernDarkColors.textSecondary)
    }

    var textTertiary: Color {
        adaptiveColor(light: Color(.tertiaryLabel), dark: ModernDarkColors.textTertiary)
    }

    var fillPrimary: Color {
        adaptiveColor(light: Color(.systemFill), dark: ModernDarkColors.fillPrimary)
    }

    var fillSecondary: Color {
        adaptiveColor(light: Color(.secondarySystemFill), dark: ModernDarkColors.fillSecondary)
    }

    var fillTertiary: Color {
        adaptiveColor(light: Color(.tertiarySystemFill), dark: ModernDarkColors.fillTertiary)
    }

    private func adaptiveColor(light: Color, dark: Color) -> Color {
        isDarkMode ? dark : light
    }

    func updateUserInterfaceStyle() {

        let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in windowScenes {
            for window in scene.windows {
                switch selectedTheme {
                case .light:
                    window.overrideUserInterfaceStyle = .light
                case .dark:
                    window.overrideUserInterfaceStyle = .dark
                case .system:
                    window.overrideUserInterfaceStyle = .unspecified
                }
            }
        }

        UserDefaults.standard.set(selectedTheme.rawValue, forKey: "Feather.userInterfaceStyle")

    }

    func syncFromSettings() {
        let settingsTheme = UserDefaults.standard.integer(forKey: "Feather.userInterfaceStyle")

        if let appTheme = AppTheme(rawValue: settingsTheme), appTheme != selectedTheme {
            selectedTheme = appTheme
        }
    }
}

public struct ModernDarkColors {
    static let backgroundPrimary = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let backgroundSecondary = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let backgroundTertiary = Color(red: 0.15, green: 0.15, blue: 0.17)

    static let surfacePrimary = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let surfaceSecondary = Color(red: 0.18, green: 0.18, blue: 0.20)

    static let borderPrimary = Color(red: 0.24, green: 0.24, blue: 0.26)
    static let borderSecondary = Color(red: 0.32, green: 0.32, blue: 0.34)

    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.65, green: 0.65, blue: 0.67)
    static let textTertiary = Color(red: 0.45, green: 0.45, blue: 0.47)

    static let fillPrimary = Color(red: 0.25, green: 0.25, blue: 0.27)
    static let fillSecondary = Color(red: 0.20, green: 0.20, blue: 0.22)
    static let fillTertiary = Color(red: 0.15, green: 0.15, blue: 0.17)
}

enum ThemeMode: String, CaseIterable {
    case light
    case dark

    var displayName: String {
        switch self {
        case .light:
            return "light_mode".localized
        case .dark:
            return "dark_mode".localized
        }
    }
}

struct ThemePreviewCard: View {
    let mode: ThemeMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(themeBackgroundColor)
                        .frame(width: 130, height: 220)
                        .overlay(
                            RoundedRectangle(cornerRadius: 28)
                                .stroke(isSelected ? themeManager.accentColor : borderColor, lineWidth: isSelected ? 3 : 1.5)
                        )
                        .shadow(color: isSelected ? themeManager.accentColor.opacity(0.35) : Color.black.opacity(0.15), radius: isSelected ? 16 : 8, x: 0, y: isSelected ? 8 : 4)

                    VStack(spacing: 0) {
                        statusBar
                        contentArea
                        Spacer(minLength: 0)
                        dockArea
                        homeIndicator
                    }
                    .frame(width: 130, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 28))

                    dynamicIsland
                }

                Text(mode.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)

                ZStack {
                    Circle()
                        .stroke(isSelected ? themeManager.accentColor : Color.gray.opacity(0.4), lineWidth: 2)
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Circle()
                            .fill(themeManager.accentColor)
                            .frame(width: 24, height: 24)

                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isSelected)
    }

    private var statusBar: some View {
        HStack {
            Text("9:41")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(themeTextColor)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "cellularbars")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeTextColor)
                Image(systemName: "wifi")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeTextColor)
                Image(systemName: "battery.100")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(themeTextColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var dynamicIsland: some View {
        VStack {
            HStack {
                Spacer()
                Capsule()
                    .fill(themeTextColor.opacity(0.9))
                    .frame(width: 36, height: 7)
                Spacer()
            }
            .padding(.top, 14)
            Spacer()
        }
    }

    private var contentArea: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                widgetView
                VStack(spacing: 6) {
                    iconRow1
                    iconRow2
                }
            }
            .padding(.top, 6)

            HStack(spacing: 8) {
                iconRow3
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
    }

    private var widgetView: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(widgetGradient)
            .frame(width: 50, height: 50)
            .overlay(
                VStack(alignment: .leading, spacing: 3) {
                    Text("天气")
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                    Spacer()
                    Text("24°")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                    Text("晴")
                        .font(.system(size: 6))
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading),
                alignment: .topLeading
            )
    }

    private var iconRow1: some View {
        HStack(spacing: 6) {
            appIcon(color: Color.blue, icon: "envelope.fill")
            appIcon(color: Color.green, icon: "message.fill")
            appIcon(color: Color.orange, icon: "photo.fill")
        }
    }

    private var iconRow2: some View {
        HStack(spacing: 6) {
            appIcon(color: Color.purple, icon: "music.note")
            appIcon(color: Color.red, icon: "heart.fill")
            appIcon(color: Color.teal, icon: "cloud.fill")
        }
    }

    private var iconRow3: some View {
        HStack(spacing: 6) {
            appIcon(color: Color.indigo, icon: "gearshape.fill")
            appIcon(color: Color.pink, icon: "heart.text.square.fill")
            appIcon(color: Color.brown, icon: "book.fill")
            appIcon(color: Color.mint, icon: "cart.fill")
        }
    }

    private var dockArea: some View {
        HStack(spacing: 8) {
            appIcon(color: Color.green, icon: "phone.fill")
            appIcon(color: Color.blue, icon: "safari.fill")
            appIcon(color: Color.green, icon: "message.fill")
            appIcon(color: Color.orange, icon: "music.note")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(dockBackgroundColor)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var homeIndicator: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(themeTextColor.opacity(0.4))
            .frame(width: 50, height: 4)
            .padding(.bottom, 6)
    }

    private func appIcon(color: Color, icon: String) -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(color)
            .frame(width: 16, height: 16)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white)
            )
    }

    private var widgetGradient: LinearGradient {
        LinearGradient(
            colors: mode == .light
                ? [Color(red: 0.4, green: 0.7, blue: 1.0), Color(red: 0.2, green: 0.5, blue: 0.9)]
                : [Color(red: 0.2, green: 0.3, blue: 0.5), Color(red: 0.1, green: 0.2, blue: 0.4)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @EnvironmentObject private var themeManager: ThemeManager

    private var borderColor: Color {
        mode == .light ? Color.gray.opacity(0.25) : Color.gray.opacity(0.35)
    }

    private var themeBackgroundColor: Color {
        switch mode {
        case .light:
            return Color(red: 0.96, green: 0.96, blue: 0.98)
        case .dark:
            return ModernDarkColors.surfacePrimary
        }
    }

    private var themeTextColor: Color {
        switch mode {
        case .light:
            return Color.black
        case .dark:
            return ModernDarkColors.textPrimary
        }
    }

    private var dockBackgroundColor: Color {
        switch mode {
        case .light:
            return Color.white.opacity(0.7)
        case .dark:
            return ModernDarkColors.surfaceSecondary.opacity(0.8)
        }
    }
}

struct FloatingThemeSelector: View {
    @EnvironmentObject var themeManager: ThemeManager
    @Binding var isPresented: Bool

    var body: some View {
        if isPresented {
            ZStack {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            isPresented = false
                        }
                    }

                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: Spacing.lg) {

                        HStack(spacing: Spacing.xl) {

                            FloatingThemeOption(
                                mode: .light,
                                isSelected: themeManager.selectedTheme == .light,
                                action: {
                                    themeManager.selectedTheme = .light
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        isPresented = false
                                    }
                                }
                            )

                            FloatingThemeOption(
                                mode: .dark,
                                isSelected: themeManager.selectedTheme == .dark,
                                action: {
                                    themeManager.selectedTheme = .dark
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        isPresented = false
                                    }
                                }
                            )
                        }
                        .padding(.horizontal, Spacing.lg)
                    }
                    .padding(.bottom, 80)
                }
            }
            .transition(.opacity)
        }
    }
}

struct FloatingThemeOption: View {
    let mode: ThemeMode
    let isSelected: Bool
    let action: () -> Void

    let isCompactDevice = false

    private var cardSize: CGSize {

        return CGSize(width: 100, height: 120)
    }

    private var fontSize: CGFloat {

        return 12
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.md) {

                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(themeBackgroundColor)
                        .frame(width: cardSize.width, height: cardSize.height)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(isSelected ? ThemeManager.shared.accentColor : Color.clear, lineWidth: 4)
                        )
                        .shadow(color: isSelected ? ThemeManager.shared.accentColor.opacity(0.4) : Color.black.opacity(0.15), radius: isSelected ? 12 : 6, x: 0, y: 4)

                    VStack(spacing: 8) {

                        HStack {
                            Text("9:41")
                                .font(.system(size: fontSize - 2, weight: .medium))
                                .foregroundColor(themeTextColor)
                            Spacer()
                            HStack(spacing: 3) {
                                Image(systemName: "wifi")
                                    .font(.system(size: fontSize - 2))
                                    .foregroundColor(themeTextColor)
                                Image(systemName: "battery.100")
                                    .font(.system(size: fontSize - 2))
                                    .foregroundColor(themeTextColor)
                            }
                        }
                        .frame(width: cardSize.width * 0.75)
                        .padding(.top, 6)

                        RoundedRectangle(cornerRadius: 10)
                            .fill(themeSearchBarColor)
                            .frame(width: cardSize.width * 0.75, height: fontSize + 6)
                            .overlay(
                                HStack(spacing: 4) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: fontSize - 3))
                                        .foregroundColor(themeSecondaryColor)
                                    Text("search".localized)
                                        .font(.system(size: fontSize - 3))
                                        .foregroundColor(themeSecondaryColor)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                            )

                        VStack(spacing: 4) {
                            HStack(spacing: 4) {

                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.blue)
                                    .frame(width: fontSize + 3, height: fontSize + 3)

                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.green)
                                    .frame(width: fontSize + 3, height: fontSize + 3)

                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.orange)
                                    .frame(width: fontSize + 3, height: fontSize + 3)
                            }
                            HStack(spacing: 4) {

                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.purple)
                                    .frame(width: fontSize + 3, height: fontSize + 3)

                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.red)
                                    .frame(width: fontSize + 3, height: fontSize + 3)

                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.teal)
                                    .frame(width: fontSize + 3, height: fontSize + 3)
                            }
                        }
                        .padding(.top, 4)
                    }
                }

                Text(mode.displayName)
                    .font(.system(size: fontSize + 2, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? ThemeManager.shared.accentColor : .primary)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(ThemeManager.shared.accentColor)
                        .font(.system(size: fontSize + 6))
                        .scaleEffect(1.2)
                }
            }
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var themeBackgroundColor: Color {
        switch mode {
        case .light:
            return Color.white
        case .dark:
            return ModernDarkColors.surfacePrimary
        }
    }

    private var themeTextColor: Color {
        switch mode {
        case .light:
            return Color.black
        case .dark:
            return ModernDarkColors.textPrimary
        }
    }

    private var themeSecondaryColor: Color {
        switch mode {
        case .light:
            return Color.gray
        case .dark:
            return ModernDarkColors.textSecondary
        }
    }

    private var themeSearchBarColor: Color {
        switch mode {
        case .light:
            return Color.gray.opacity(0.1)
        case .dark:
            return ModernDarkColors.surfaceSecondary
        }
    }
}
