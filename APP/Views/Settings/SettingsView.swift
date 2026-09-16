import SwiftUI
import UIKit
import Foundation

struct SettingsView: View {
    @State private var currentIcon = AppIconManager.shared.currentAlternateIconName
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var tabBarStyleManager: TabBarStyleManager

    @AppStorage("APP.userTintColor") private var selectedColorHex: String = "#007AFF"
    @State private var selectedColor = Color(hex: "#007AFF")
    @State private var showingIconSuccess = false
    @State private var isIconLoading = false
    @State private var showAccountSheet = false
    @State private var showingColorPicker = false

    var allIcons: [AltIcon] {
        let allIcons = AppIconView.getAllIconsFromFolder()

        if !allIcons.isEmpty {
            return allIcons.sorted { icon1, icon2 in
                if icon1.key == "app" { return true }
                if icon2.key == "app" { return false }
                return icon1.key ?? "" < icon2.key ?? ""
            }
        }

        return [
            AltIcon(
                displayName: "icon_default".localized,
                author: "icon_author".localized,
                key: "app"
            ),
            AltIcon(
                displayName: "icon_love".localized,
                author: "icon_author".localized,
                key: "kana_love"
            ),
            AltIcon(
                displayName: "icon_peek".localized,
                author: "icon_author".localized,
                key: "kana_peek"
            )
        ]
    }

    private let presetColorHexes: [String] = [
        "#B496DC", "#848ef9", "#ff7a83", "#4161F1", "#FF00FF",
        "#4CD964", "#FF2D55", "#FF9500", "#4860e8", "#5394F7",
        "#e18aab", "#00CED1", "#228B22", "#FF6347", "#191970",
        "#FFB6C1", "#98FB98", "#E6E6FA", "#FF7F50", "#50C878"
    ]

    private var presetColors: [Color] {
        presetColorHexes.map { Color(hex: $0) }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    accountHeaderSection

                    VStack(spacing: 0) {
                        appearanceRow
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    VStack(spacing: 0) {
                        colorRow
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    VStack(spacing: 0) {
                        languageRow
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)


                    VStack(spacing: 0) {
                        tabBarRowContent
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    if tabBarStyleManager.currentStyle == .floatingCard {
                        VStack(spacing: 0) {
                            floatingTabBarSettingsContent
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(16)
                        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
                    }

                    VStack(spacing: 0) {
                        iconGridContent
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .onAppear {
                selectedColor = Color(hex: selectedColorHex)
                currentIcon = AppIconManager.shared.currentAlternateIconName
            }
            .onChange(of: selectedColorHex) { _, newValue in
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    for window in windowScene.windows {
                        window.tintColor = UIColor(Color(hex: newValue))
                    }
                }
                themeManager.objectWillChange.send()
            }
            .sheet(isPresented: $showAccountSheet) {
                AccountSheetView()
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
            .alert("icon_set_success".localized, isPresented: $showingIconSuccess) {
                Button("ok".localized, role: .cancel) { }
            }
        }
    }

    private var accountHeaderSection: some View {
        Button(action: {
            showAccountSheet = true
        }) {
            if let account = appStore.selectedAccount {
                HStack(spacing: 16) {
                    ZStack {
                        AccountAvatarButton(size: 64)

                        Circle()
                            .stroke(themeManager.accentColor.opacity(0.3), lineWidth: 2)
                            .frame(width: 72, height: 72)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.fullName.isEmpty ? account.email : account.fullName)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        if !account.fullName.isEmpty {
                            Text(account.email)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        HStack(spacing: 6) {
                            Text(flag(country: account.countryCode))
                                .font(.caption)
                            Text(countryName(account.countryCode))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 2)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            } else {
                HStack(spacing: 16) {
                    Text("👤")
                        .font(.system(size: 64))
                        .frame(width: 64, height: 64)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("sign_in_apple_id".localized)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.primary)

                        Text("sign_in_apple_id_desc".localized)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(ScaleButtonStyle())
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    private func flag(country: String) -> String {
        let base: UInt32 = 127397
        var s = ""
        for v in country.uppercased().unicodeScalars {
            if let scalar = UnicodeScalar(base + v.value) {
                s.unicodeScalars.append(scalar)
            }
        }
        return s
    }

    private func countryName(_ code: String) -> String {
        let locale = LanguageManager.shared.locale
        return locale.localizedString(forRegionCode: code) ?? code.uppercased()
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(ThemeManager.shared)
            .environmentObject(AppStore.this)
            .environmentObject(TabBarStyleManager.shared)
    }
}

extension SettingsView {
    @ViewBuilder
    private var tabBarRowContent: some View {
        VStack(spacing: 0) {
            ForEach(Array(TabBarStyle.allCases.enumerated()), id: \.element.id) { index, style in
                tabBarStyleItem(style: style)
                if index < TabBarStyle.allCases.count - 1 {
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 0)
    }

    private var appearanceRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "moon.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(themeManager.accentColor)
                    )

                Text("appearance".localized)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)

                Spacer()
            }

            HStack(spacing: 8) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Button(action: {
                        let impactMed = UIImpactFeedbackGenerator(style: .light)
                        impactMed.impactOccurred()
                        themeManager.selectedTheme = theme
                    }) {
                        Text(theme.displayName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(themeManager.selectedTheme == theme ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(themeManager.selectedTheme == theme ? themeManager.accentColor : Color(.systemGray5))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: {
                showingColorPicker = true
            }) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(selectedColor)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                            )

                        Text("🎨")
                            .font(.system(size: 14))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("color".localized)
                            .font(.system(size: 16))
                            .foregroundColor(.primary)

                        Text(selectedColorHex)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .sheet(isPresented: $showingColorPicker) {
                NavigationView {
                    ColorPickerView(selectedColor: $selectedColor)
                        .navigationTitle("color".localized)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button(action: {
                                    showingColorPicker = false
                                }) {
                                    Text("ok".localized)
                                        .fontWeight(.semibold)
                                }
                            }
                        }
                }
            }
            .onChange(of: selectedColor) { _, newColor in
                selectedColorHex = newColor.toHex()
                themeManager.accentColor = newColor
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presetColors, id: \.self) { color in
                        Circle()
                            .fill(color)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        selectedColor == color ? Color.primary : Color.clear,
                                        lineWidth: 2.5
                                    )
                            )
                            .overlay(
                                selectedColor == color ?
                                Text("✓")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .background(
                                        Circle()
                                            .fill(Color.primary.opacity(0.3))
                                            .frame(width: 18, height: 18)
                                    ) : nil
                            )
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedColor = color
                                    selectedColorHex = color.toHex()
                                    themeManager.accentColor = color
                                }
                                let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                                impactFeedback.impactOccurred()
                            }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func tabBarStyleItem(style: TabBarStyle) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                tabBarStyleManager.currentStyle = style
            }
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
        }) {
            HStack(alignment: .center, spacing: 16) {
                tabBarStylePreview(style: style)
                    .frame(width: 180, height: 80, alignment: .center)
                    .clipped()
                    .cornerRadius(10)

                VStack(alignment: .leading, spacing: 6) {
                    Text(style.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Text(styleDescription(for: style))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(themeManager.accentColor)
                    .opacity(tabBarStyleManager.currentStyle == style ? 1 : 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func styleDescription(for style: TabBarStyle) -> String {
        switch style {
        case .systemDefault:
            return "tab_style_default_desc".localized
        case .floatingCard:
            return "tab_style_floating_desc".localized
        }
    }

    @ViewBuilder
    private func tabBarStylePreview(style: TabBarStyle) -> some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            switch style {
            case .systemDefault:
                VStack(spacing: 0) {
                    Spacer()
                    Divider()
                    HStack(spacing: 0) {
                        ForEach(TabEnum.allCases, id: \.self) { tab in
                            VStack(spacing: 3) {
                                Text(tab.emojiIcon)
                                    .font(.system(size: 18))
                                Text(tab.title)
                                    .font(.system(size: 9, weight: .regular))
                                    .foregroundStyle(tab == .settings ? themeManager.accentColor : .secondary.opacity(0.6))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                    .background(Color(.systemBackground))
                }
            case .floatingCard:
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        HStack(spacing: 0) {
                            ForEach([TabEnum.settings, .tfapps, .downloads], id: \.self) { tab in
                                VStack(spacing: 2) {
                                    Text(tab.emojiIcon)
                                        .font(.system(size: 14))
                                    Text(tab.title)
                                        .font(.system(size: 7, weight: .regular))
                                        .foregroundStyle(tab == .settings ? themeManager.accentColor : .secondary.opacity(0.6))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                }
                                .frame(width: 36)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 3)
                        )

                        Circle()
                            .fill(themeManager.accentColor)
                            .frame(width: 36, height: 36)
                            .overlay(
                                Text(TabEnum.search.emojiIcon)
                                    .font(.system(size: 16))
                            )
                            .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
                    VStack(spacing: 0) {
                    Spacer()
                    Divider()
                    HStack(spacing: 0) {
                        ForEach([TabEnum.settings, .tfapps, .downloads], id: \.self) { tab in
                            VStack(spacing: 3) {
                                Text(tab.emojiIcon)
                                    .font(.system(size: 18))
                                Text(tab.title)
                                    .font(.system(size: 9, weight: .regular))
                                    .foregroundStyle(.secondary.opacity(0.6))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        VStack(spacing: 3) {
                            Text(TabEnum.search.emojiIcon)
                                .font(.system(size: 18))
                            Text(TabEnum.search.title)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(themeManager.accentColor)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                        }
                        .frame(width: 56)
                    }
                    .padding(.top, 6)
                    .padding(.bottom, 8)
                    .background(Color(.systemBackground))
                }
            }
        }
    }

    private var iconGridContent: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            ForEach(allIcons) { icon in
                iconItem(icon: icon)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    private var floatingTabBarSettingsContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("floating_tabbar_customize".localized)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer()

                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                        tabBarStyleManager.resetFloatingConfig()
                    }
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()
                }) {
                    Text("reset".localized)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(themeManager.accentColor)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(spacing: 16) {
                sliderRow(
                    title: "floating_tabbar_horizontal_padding".localized,
                    value: Binding(
                        get: { tabBarStyleManager.floatingConfig.horizontalPadding },
                        set: { tabBarStyleManager.floatingConfig.horizontalPadding = $0 }
                    ),
                    minValue: FloatingTabBarConfig.minHorizontalPadding,
                    maxValue: FloatingTabBarConfig.maxHorizontalPadding,
                    unit: "pt"
                )

                Divider()

                sliderRow(
                    title: "floating_tabbar_bottom_offset".localized,
                    value: Binding(
                        get: { tabBarStyleManager.floatingConfig.bottomOffset },
                        set: { tabBarStyleManager.floatingConfig.bottomOffset = $0 }
                    ),
                    minValue: FloatingTabBarConfig.minBottomOffset,
                    maxValue: FloatingTabBarConfig.maxBottomOffset,
                    unit: "pt"
                )

                Divider()

                sliderRow(
                    title: "floating_tabbar_height".localized,
                    value: Binding(
                        get: { tabBarStyleManager.floatingConfig.height },
                        set: { tabBarStyleManager.floatingConfig.height = $0 }
                    ),
                    minValue: FloatingTabBarConfig.minHeight,
                    maxValue: FloatingTabBarConfig.maxHeight,
                    unit: "pt"
                )

                Divider()

                sliderRow(
                    title: "floating_tabbar_corner_radius".localized,
                    value: Binding(
                        get: { tabBarStyleManager.floatingConfig.cornerRadius },
                        set: { tabBarStyleManager.floatingConfig.cornerRadius = $0 }
                    ),
                    minValue: FloatingTabBarConfig.minCornerRadius,
                    maxValue: FloatingTabBarConfig.maxCornerRadius,
                    unit: "pt"
                )
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<CGFloat>,
        minValue: CGFloat,
        maxValue: CGFloat,
        unit: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)

                Spacer()

                Text(String(format: "%.0f %@", value.wrappedValue, unit))
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(themeManager.accentColor)
            }

            Slider(value: value, in: minValue...maxValue, step: 1)
                .tint(themeManager.accentColor)
        }
    }

    private var languageRow: some View {
        NavigationLink(destination: LanguageSettingsView().environmentObject(themeManager)) {
            HStack(spacing: 12) {
                Text(LanguageManager.shared.currentLanguage.flag)
                    .font(.system(size: 18))
                    .frame(width: 28, height: 28)

                Text("language".localized)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)

                Spacer()

                Text(LanguageManager.shared.currentLanguage.nativeName)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func iconItem(icon: AltIcon) -> some View {
        Button {
            isIconLoading = true

            let iconNameToSet = icon.key == "app" ? nil : icon.key

            AppIconManager.shared.setAlternateIconName(iconNameToSet) { success, error in
                DispatchQueue.main.async {
                    isIconLoading = false
                    currentIcon = AppIconManager.shared.currentAlternateIconName
                    if success {
                        showingIconSuccess = true
                    }
                }
            }
        } label: {
            VStack(alignment: .center, spacing: 6) {
                ZStack {
                    Image(uiImage: icon.image)
                        .appIconStyle()
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

