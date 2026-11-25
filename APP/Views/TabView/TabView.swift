import SwiftUI
import UIKit

enum TabEnum: String, CaseIterable, Hashable {
    case settings
    case downloads
    case testflight
    case sign
    case search

    var title: String {
        switch self {
        case .settings:  return "tab_settings".localized
        case .downloads:  return "tab_downloads".localized
        case .testflight: return "tab_testflight_short".localized
        case .sign:       return "tab_sign".localized
        case .search:     return "tab_search".localized
        }
    }

    var icon: String {
        switch self {
        case .settings:  return "gearshape.fill"
        case .downloads:  return "arrow.down.circle.fill"
        case .testflight: return "paperplane.fill"
        case .sign:       return "signature"
        case .search:     return "magnifyingglass.circle.fill"
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
            NavigationStack {
                DownloadView()
                    .environmentObject(themeManager)
                    .environmentObject(tabBarStyleManager)
            }
        case .testflight:
            NavigationStack {
                TestFlightDownloadView(showsCloseButton: false, showsNavigationStack: false)
                    .environmentObject(themeManager)
            }
        case .sign:
            NavigationStack {
                SignView()
                    .environmentObject(themeManager)
                    .environmentObject(tabBarStyleManager)
            }
        case .search:
            SearchView()
                .environmentObject(themeManager)
                .environmentObject(tabBarStyleManager)
        }
    }
}

struct TabbarView: View {
    @State private var selectedTab: TabEnum = {
        if let raw = UserDefaults.standard.string(forKey: "initialTab"),
           let tab = TabEnum(rawValue: raw) {
            return tab
        }
        return .settings
    }()
    @ObservedObject private var tabOrder = TabOrderStore.shared
    @ObservedObject private var router = TabRouter.shared
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabBarStyleManager: TabBarStyleManager

    private static let floatingTabMinWidth: CGFloat = 44

    private var usesFloatingTabBar: Bool {
        tabBarStyleManager.currentStyle == .floatingCard
    }

    var body: some View {
        ZStack {
            LiquidGlassBackdrop()
                .environmentObject(themeManager)
            Group {
                if #available(iOS 18.0, *) {
                    if usesFloatingTabBar {
                        floatingCardTabView
                    } else {
                        systemTabView
                    }
                } else {
                    standardTabView
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(themeManager.accentColor)
        .background(themeManager.backgroundColor)
        .onAppear {
            AnalyticsManager.shared.trackScreen(selectedTab.rawValue)
            updateTabBarAppearance()
            if let requested = router.requested {
                router.requested = nil
                selectedTab = requested
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            AnalyticsManager.shared.trackScreen(newValue.rawValue)
            SoundEffects.play(.tick)
            updateTabBarAppearance()
        }
        .onChange(of: router.requested) { _, newValue in
            guard let newValue else { return }
            router.requested = nil
            withAnimation(.spring(response: 0.35, dampingFraction: 0.65)) {
                selectedTab = newValue
            }
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
        if #available(iOS 18.0, *) {
            modernStandardTabView
        } else {
            legacyStandardTabView
        }
    }

    /// iOS 18+：搜索用 `role: .search` 单独成一个按钮，不占前五个位置，
    /// 这样六个标签也不会被系统塞进「更多」那个老式表格页。
    @available(iOS 18.0, *)
    private var modernStandardTabView: some View {
        TabView(selection: $selectedTab) {
            ForEach(tabOrder.order.filter { $0 != .search }, id: \.self) { tab in
                Tab(value: tab) {
                    tabContent(for: tab)
                } label: {
                    Label(tab.title, systemImage: tab.icon)
                }
            }

            Tab(value: TabEnum.search, role: .search) {
                tabContent(for: .search)
            } label: {
                Label(TabEnum.search.title, systemImage: TabEnum.search.icon)
            }
        }
    }

    @ViewBuilder
    private var legacyStandardTabView: some View {
        TabView(selection: $selectedTab) {
            ForEach(tabOrder.order, id: \.self) { tab in
                tabContent(for: tab)
                    .tabItem {
                        Label {
                            Text(tab.title)
                        } icon: {
                            Image(systemName: tab.icon)
                        }
                    }
                    .tag(tab)
            }
        }
    }

    @available(iOS 18.0, *)

    private var floatingCardTabView: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // 兜底：整屏再铺一层，TabView 没盖到的缝隙也不会露出黑底
                LiquidGlassBackdrop()
                    .environmentObject(themeManager)
                    .ignoresSafeArea()

                tabContent(for: selectedTab)
                    // 用 safeAreaInset 而不是 padding：只把内容顶起来，
                    // 页面背景仍然铺到屏幕最底，不会留黑带
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Color.clear
                            .frame(height: tabBarStyleManager.floatingConfig.height + tabBarStyleManager.floatingConfig.bottomOffset)
                    }
        
                floatingTabBarContent
                    .padding(.horizontal, floatingHorizontalPadding(for: geo.size.width))
                    .padding(.bottom, max(geo.safeAreaInsets.bottom + tabBarStyleManager.floatingConfig.bottomOffset - 16, 4))
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    /// 每个标签页自带一层液态玻璃背景：TabView 容器本身不透明，
    /// 放在最外层的背景会被它盖住。
    @ViewBuilder
    private func tabContent(for tab: TabEnum) -> some SwiftUI.View {
        TabEnum.view(for: tab, themeManager: themeManager, tabBarStyleManager: tabBarStyleManager)
            // 悬浮模式下系统自带的 tab bar 会留一条空白矩形，这里彻底藏掉
            .toolbar(
                usesFloatingTabBar ? .hidden : .visible,
                for: .tabBar
            )
            // iOS 26 的玻璃 tab bar 不吃 UITabBarAppearance，必须显式隐藏背景
            .toolbarBackground(.hidden, for: .tabBar)
    }

    private func floatingHorizontalPadding(for width: CGFloat) -> CGFloat {
        let config = tabBarStyleManager.floatingConfig
        let tabsMinWidth = CGFloat(TabOrderStore.reorderable.count - 1) * Self.floatingTabMinWidth + 16
        let contentMinWidth = tabsMinWidth + 16 + config.height
        let roomForPadding = max(0, width - contentMinWidth)
        return min(config.horizontalPadding, roomForPadding / 2)
    }

    private var floatingTabBarContent: some View {
        let config = tabBarStyleManager.floatingConfig
        let tabHeight = config.height

        return HStack(spacing: 16) {
            HStack(spacing: 0) {
                ForEach(tabOrder.order.filter { $0 != .search }, id: \.self) { tab in
                    tabButton(for: tab, height: tabHeight)
                        .frame(minWidth: Self.floatingTabMinWidth, maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(height: tabHeight)
            .liquidGlassSurface(cornerRadius: config.cornerRadius)
            .shadow(color: Color.black.opacity(0.18), radius: 20, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
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

                    Image(systemName: "magnifyingglass")
                        .font(.system(size: tabHeight * 0.42, weight: .semibold))
                        .foregroundStyle(selectedTab == .search ? Color.white : Color.primary.opacity(0.7))
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
                Image(systemName: tab.icon)
                    .font(.system(size: min(22, height * 0.42), weight: selectedTab == tab ? .semibold : .regular))
                    .foregroundStyle(selectedTab == tab ? themeManager.accentColor : .secondary.opacity(0.7))

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

        if usesFloatingTabBar {
            appearance.configureWithTransparentBackground()
            appearance.backgroundColor = .clear
            appearance.shadowImage = UIImage()
            appearance.backgroundImage = UIImage()
            UITabBar.appearance().isHidden = true
        } else {
            if themeManager.liquidGlassEnabled {
                appearance.configureWithTransparentBackground()
                appearance.backgroundColor = .clear
                appearance.shadowImage = UIImage()
                appearance.backgroundImage = UIImage()
            } else {
                appearance.configureWithOpaqueBackground()
            }
            UITabBar.appearance().isHidden = false
        }

        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(themeManager.accentColor)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(themeManager.accentColor)]

        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }

        let hidden = usesFloatingTabBar
        DispatchQueue.main.async {
            for bar in Self.liveTabBars() {
                bar.standardAppearance = appearance
                bar.scrollEdgeAppearance = appearance
                bar.isHidden = hidden
                bar.setNeedsLayout()
            }
        }
    }

    private static func liveTabBars() -> [UITabBar] {
        var bars: [UITabBar] = []
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                if let bar = findTabBar(in: window.rootViewController), !bars.contains(where: { $0 === bar }) {
                    bars.append(bar)
                }
            }
        }
        return bars
    }

    private static func findTabBar(in controller: UIViewController?) -> UITabBar? {
        guard let controller else { return nil }
        if let tab = controller as? UITabBarController { return tab.tabBar }
        for child in controller.children {
            if let found = findTabBar(in: child) { return found }
        }
        return findTabBar(in: controller.presentedViewController)
    }
}
