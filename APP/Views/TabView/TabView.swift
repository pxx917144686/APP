import SwiftUI
import UIKit

enum TabEnum: String, CaseIterable, Hashable {
    case settings
    case tfapps
    case downloads
    case search

    var title: String {
        switch self {
        case .settings:  return "tab_settings".localized
        case .tfapps:     return "tab_tfapps".localized
        case .downloads:  return "tab_downloads".localized
        case .search:     return "tab_search".localized
        }
    }

    var icon: String {
        switch self {
        case .settings:  return "gearshape.fill"
        case .downloads:  return "arrow.down.circle.fill"
        case .tfapps:     return "square.stack.3d.up.fill"
        case .search:     return "magnifyingglass.circle.fill"
        }
    }

    var emojiIcon: String {
        switch self {
        case .settings:  return "⚙️"
        case .downloads:  return "📥"
        case .tfapps:     return "TF"
        case .search:     return "🔍"
        }
    }

    @ViewBuilder
    static func view(for tab: TabEnum, themeManager: ThemeManager, tabBarStyleManager: TabBarStyleManager) -> some View {
        switch tab {
        case .settings:
            SettingsView()
                .environmentObject(themeManager)
                .environmentObject(tabBarStyleManager)
        case .downloads:
            NavigationView {
                DownloadView()
                    .environmentObject(themeManager)
                    .environmentObject(tabBarStyleManager)
            }
        case .tfapps:
            NavigationView {
                TFAppsView()
                    .environmentObject(themeManager)
                    .environmentObject(tabBarStyleManager)
            }
        case .search:
            SearchView()
                .environmentObject(themeManager)
                .environmentObject(tabBarStyleManager)
        }
    }

    @ViewBuilder
    static func tabIcon(for tab: TabEnum, size: CGFloat = 24) -> some View {
        Text(tab.emojiIcon)
            .font(.system(size: size))
    }
}

struct TabbarView: View {
    @State private var selectedTab: TabEnum = .settings
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabBarStyleManager: TabBarStyleManager

    var body: some View {
        Group {
            if #available(iOS 18.0, *) {
                if tabBarStyleManager.currentStyle == .floatingCard {
                    floatingCardTabView
                } else {
                    systemTabView
                }
            } else {
                standardTabView
            }
        }
        .tint(themeManager.accentColor)
        .background(themeManager.backgroundColor)
        .onAppear {
            AnalyticsManager.shared.trackScreen(selectedTab.rawValue)
            updateTabBarAppearance()
        }
        .onChange(of: selectedTab) { _, newValue in
            AnalyticsManager.shared.trackScreen(newValue.rawValue)
        }
        .onChange(of: themeManager.accentColor) { _, _ in
            updateTabBarAppearance()
        }
        .onChange(of: tabBarStyleManager.currentStyle) { _, _ in
            updateTabBarAppearance()
        }
    }

    private var systemTabView: some View {
        standardTabView
    }

    @ViewBuilder
    private var standardTabView: some View {
        TabView(selection: $selectedTab) {
            TabEnum.view(for: .settings, themeManager: themeManager, tabBarStyleManager: tabBarStyleManager)
                .tabItem {
                    Label {
                        Text(TabEnum.settings.title)
                    } icon: {
                        Image(systemName: TabEnum.settings.icon)
                    }
                }
                .tag(TabEnum.settings)

            TabEnum.view(for: .tfapps, themeManager: themeManager, tabBarStyleManager: tabBarStyleManager)
                .tabItem {
                    Label {
                        Text(TabEnum.tfapps.title)
                    } icon: {
                        Image(systemName: TabEnum.tfapps.icon)
                    }
                }
                .tag(TabEnum.tfapps)

            TabEnum.view(for: .downloads, themeManager: themeManager, tabBarStyleManager: tabBarStyleManager)
                .tabItem {
                    Label {
                        Text(TabEnum.downloads.title)
                    } icon: {
                        Image(systemName: TabEnum.downloads.icon)
                    }
                }
                .tag(TabEnum.downloads)

            TabEnum.view(for: .search, themeManager: themeManager, tabBarStyleManager: tabBarStyleManager)
                .tabItem {
                    Label {
                        Text(TabEnum.search.title)
                    } icon: {
                        Image(systemName: TabEnum.search.icon)
                    }
                }
                .tag(TabEnum.search)
        }
    }

    @available(iOS 18.0, *)

    private var floatingCardTabView: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                TabView(selection: $selectedTab) {
                    TabEnum.view(for: .settings, themeManager: themeManager, tabBarStyleManager: tabBarStyleManager)
                        .tag(TabEnum.settings)

                    TabEnum.view(for: .tfapps, themeManager: themeManager, tabBarStyleManager: tabBarStyleManager)
                        .tag(TabEnum.tfapps)

                    TabEnum.view(for: .downloads, themeManager: themeManager, tabBarStyleManager: tabBarStyleManager)
                        .tag(TabEnum.downloads)

                    TabEnum.view(for: .search, themeManager: themeManager, tabBarStyleManager: tabBarStyleManager)
                        .tag(TabEnum.search)
                }
                .safeAreaInset(edge: .bottom) {
                    Color.clear.frame(height: geo.safeAreaInsets.bottom + tabBarStyleManager.floatingConfig.height + tabBarStyleManager.floatingConfig.bottomOffset)
                }

                floatingTabBarContent
                    .padding(.horizontal, tabBarStyleManager.floatingConfig.horizontalPadding)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom + tabBarStyleManager.floatingConfig.bottomOffset - 16, 4))
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    private var floatingTabBarContent: some View {
        let config = tabBarStyleManager.floatingConfig
        let tabHeight = config.height

        return HStack(spacing: 16) {
            HStack(spacing: 0) {
                ForEach([TabEnum.settings, .tfapps, .downloads], id: \.self) { tab in
                    tabButton(for: tab, height: tabHeight)
                        .frame(minWidth: 60, maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(height: tabHeight)
            .background(
                RoundedRectangle(cornerRadius: config.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 8)
                    .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: config.cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
            )

            Button(action: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                    selectedTab = .search
                }
                let impactMed = UIImpactFeedbackGenerator(style: .light)
                impactMed.impactOccurred()
            }) {
                ZStack {
                    if selectedTab == .search {
                        Circle()
                            .fill(themeManager.accentColor)
                    } else {
                        Circle()
                            .fill(.ultraThinMaterial)
                    }

                    Text(TabEnum.search.emojiIcon)
                        .font(.system(size: 28))
                }
                .frame(width: tabHeight, height: tabHeight)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(selectedTab == .search ? 0 : 0.15), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 8)
                .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func tabButton(for tab: TabEnum, height: CGFloat) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                selectedTab = tab
            }
            let impactMed = UIImpactFeedbackGenerator(style: .light)
            impactMed.impactOccurred()
        }) {
            VStack(spacing: 4) {
                Text(tab.emojiIcon)
                    .font(.system(size: min(24, height * 0.45)))

                Text(tab.title)
                    .font(.system(size: min(11, height * 0.2), weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tab ? themeManager.accentColor : .secondary.opacity(0.7))
                    .offset(x: 1)
            }
            .contentShape(Rectangle())
            .frame(maxHeight: .infinity)
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func updateTabBarAppearance() {
        let appearance = UITabBarAppearance()
        let style = tabBarStyleManager.currentStyle

        switch style {
        case .systemDefault:
            appearance.configureWithDefaultBackground()
            UITabBar.appearance().isHidden = false
        case .floatingCard:
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = .clear
            appearance.shadowImage = UIImage()
            appearance.backgroundImage = UIImage()
            UITabBar.appearance().isHidden = true
        }

        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(themeManager.accentColor)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(themeManager.accentColor)]

        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}
