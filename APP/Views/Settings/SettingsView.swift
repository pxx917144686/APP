import SwiftUI
import UIKit
import Foundation

struct SettingsView: View {
    @State private var currentIcon = AppIconManager.shared.currentAlternateIconName
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var tabBarStyleManager: TabBarStyleManager

    @AppStorage("APP.userTintColor") private var selectedColorHex: String = "#007AFF"
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @State private var selectedColor = Color(hex: "#007AFF")
    @State private var showingIconSuccess = false
    @State private var isIconLoading = false
    @State private var showingIconError = false
    @State private var iconErrorMessage = ""
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

    @AppStorage(SoundEffects.enabledKey) private var soundEffects = true
    @ObservedObject private var islandSettings = IslandSettings.shared

    var body: some View {
        NavigationStack {
            ZStack {
                LiquidGlassBackdrop()
                    .environmentObject(themeManager)
                    .ignoresSafeArea()

                ScrollView {
                VStack(spacing: 20) {
                    accountHeaderSection

                    VStack(spacing: 0) {
                        appearanceRow
                    }
                    .liquidGlassSurface(cornerRadius: 16)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    VStack(spacing: 0) {
                        colorRow
                    }
                    .liquidGlassSurface(cornerRadius: 16)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    VStack(spacing: 0) {
                        languageRow

                        Divider()
                            .padding(.leading, 56)

                        tabOrderRow
                    }
                    .liquidGlassSurface(cornerRadius: 16)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    VStack(spacing: 0) {
                        tabBarRowContent
                    }
                    .liquidGlassSurface(cornerRadius: 16)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    if tabBarStyleManager.currentStyle == .floatingCard {
                        VStack(spacing: 0) {
                            floatingTabBarSettingsContent
                        }
                        .liquidGlassSurface(cornerRadius: 16)
                        .cornerRadius(16)
                        .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
                    }

                    VStack(spacing: 0) {
                        soundRow
                    }
                    .liquidGlassSurface(cornerRadius: 16)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    VStack(spacing: 0) {
                        islandSettingsContent
                    }
                    .liquidGlassSurface(cornerRadius: 16)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    VStack(spacing: 0) {
                        iconGridContent
                    }
                    .liquidGlassSurface(cornerRadius: 16)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    VStack(spacing: 0) {
                        updateRow
                    }
                    .liquidGlassSurface(cornerRadius: 16)
                    .cornerRadius(16)
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)

                    versionFooter
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
                }
                .background(Color.clear)
            }
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
            .alert("icon_set_failed".localized, isPresented: $showingIconError) {
                Button("ok".localized, role: .cancel) { }
            } message: {
                Text(iconErrorMessage)
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
        .liquidGlassSurface(cornerRadius: 16)
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
    private var availableTabStyles: [TabBarStyle] {
        if #available(iOS 18.0, *) {
            return TabBarStyle.allCases
        }
        return TabBarStyle.allCases.filter { $0 != .floatingCard }
    }

    @ViewBuilder
    private var tabBarRowContent: some View {
        VStack(spacing: 0) {
            ForEach(Array(availableTabStyles.enumerated()), id: \.element.id) { index, style in
                tabBarStyleItem(style: style)
                if index < availableTabStyles.count - 1 {
                    Divider()
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 0)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var updateRow: some View {
        Button {
            switch updateChecker.state {
            case .available(_, let url):
                UIApplication.shared.open(url)
            default:
                Task { await updateChecker.check() }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(themeManager.accentColor))

                Text("check_updates".localized)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)

                Spacer()

                updateStatusView
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain, sound: .tap)
        .disabled(updateChecker.state == .checking)
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateChecker.state {
        case .idle:
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        case .checking:
            ProgressView()
                .scaleEffect(0.75)
        case .upToDate:
            Text("update_latest".localized)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        case .available(let version, _):
            HStack(spacing: 4) {
                Text("v\(version)")
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(themeManager.accentColor)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150, alignment: .trailing)
        }
    }

    private var versionFooter: some View {
        VStack(spacing: 3) {
            Text("APP")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("v\(appVersion)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private var soundRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(themeManager.accentColor))

            Text("sound_effects".localized)
                .font(.system(size: 16))
                .foregroundColor(.primary)

            Spacer()

            Toggle("", isOn: $soundEffects)
                .labelsHidden()
                .toggleStyle(SoundingToggleStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var islandSettingsContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(themeManager.accentColor))

                VStack(alignment: .leading, spacing: 2) {
                    Text("live_island".localized)
                        .font(.system(size: 16))
                        .foregroundColor(.primary)
                    Text("live_island_desc".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Toggle("", isOn: $islandSettings.isEnabled)
                    .labelsHidden()
                    .toggleStyle(SoundingToggleStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(spacing: 0) {
                Divider().padding(.leading, 56)
                islandToggleRow(
                    icon: "arrow.down.to.line",
                    title: "live_island_download".localized,
                    isOn: $islandSettings.showsDownload
                )
                Divider().padding(.leading, 56)
                islandToggleRow(
                    icon: "signature",
                    title: "live_island_sign".localized,
                    isOn: $islandSettings.showsSign
                )
                Divider().padding(.leading, 56)
                islandToggleRow(
                    icon: "lock.open",
                    title: "live_island_decrypt".localized,
                    isOn: $islandSettings.showsDecrypt
                )
                Divider().padding(.leading, 56)
                islandToggleRow(
                    icon: "shippingbox",
                    title: "live_island_install".localized,
                    isOn: $islandSettings.showsInstall
                )
            }
            .disabled(!islandSettings.isEnabled)
            .opacity(islandSettings.isEnabled ? 1 : 0.45)
        }
    }

    private func islandToggleRow(icon: String, title: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(themeManager.accentColor)
                .frame(width: 28, height: 28)

            Text(title)
                .font(.system(size: 15))
                .foregroundColor(.primary)

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SoundingToggleStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
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
                    .buttonStyle(PlainButtonStyle(), sound: .tick)
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
            .buttonStyle(PlainButtonStyle(), sound: .tick)
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
                    ForEach(Array(presetColorHexes.enumerated()), id: \.offset) { index, hex in
                        let color = Color(hex: hex)
                        let isSelected = selectedColorHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == hex.lowercased()
                        Circle()
                            .fill(color)
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        isSelected ? Color.primary : Color.clear,
                                        lineWidth: 2.5
                                    )
                            )
                            .overlay {
                                if isSelected {
                                    Circle()
                                        .fill(.black.opacity(0.25))
                                        .frame(width: 18, height: 18)
                                        .overlay(
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 9, weight: .bold))
                                                .foregroundStyle(.white)
                                        )
                                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                                }
                            }
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    selectedColor = color
                                    selectedColorHex = hex
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
        .buttonStyle(PlainButtonStyle(), sound: .tick)
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

            switch style {
            case .systemDefault:
                VStack(spacing: 0) {
                    Spacer()
                    HStack(spacing: 0) {
                        ForEach(TabEnum.allCases, id: \.self) { tab in
                            VStack(spacing: 3) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 13))
                                    .foregroundStyle(tab == .settings ? themeManager.accentColor : .secondary.opacity(0.6))
                                Text(tab.title)
                                    .font(.system(size: 7.5, weight: .regular))
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
                    HStack(spacing: 6) {
                        HStack(spacing: 0) {
                            ForEach([TabEnum.settings, .downloads, .decrypt, .sign], id: \.self) { tab in
                                VStack(spacing: 1) {
                                    Image(systemName: tab.icon)
                                        .font(.system(size: 10))
                                        .foregroundStyle(tab == .settings ? themeManager.accentColor : .secondary.opacity(0.6))
                                    Text(tab.title)
                                        .font(.system(size: 6, weight: .regular))
                                        .foregroundStyle(tab == .settings ? themeManager.accentColor : .secondary.opacity(0.6))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.5)
                                }
                                .frame(width: 23)
                            }
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 2)
                        )

                        Circle()
                            .fill(themeManager.accentColor)
                            .frame(width: 28, height: 28)
                            .overlay(
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                            )
                            .shadow(color: Color.black.opacity(0.15), radius: 5, x: 0, y: 2)
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
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

    private var tabOrderRow: some View {
        NavigationLink(destination: TabOrderSettingsView().environmentObject(themeManager)) {
            HStack(spacing: 12) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(themeManager.accentColor)
                    .frame(width: 28, height: 28)

                Text("tab_order_title".localized)
                    .font(.system(size: 16))
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle(), sound: .tick)
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
        .buttonStyle(PlainButtonStyle(), sound: .tick)
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
                    } else {
                        iconErrorMessage = error?.localizedDescription ?? "icon_set_failed_desc".localized
                        showingIconError = true
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
        .disabled(isIconLoading)
        .opacity(isIconLoading ? 0.5 : 1)
    }
}
