import Foundation
import SwiftUI

enum TabBarStyle: String, CaseIterable, Identifiable {
    case systemDefault
    case floatingCard

    var id: String { rawValue }

    var name: String {
        switch self {
        case .systemDefault: return "tab_style_default".localized
        case .floatingCard: return "tab_style_floating".localized
        }
    }

    var icon: String {
        switch self {
        case .systemDefault: return "square"
        case .floatingCard: return "square.stack.3d.up"
        }
    }
}

struct FloatingTabBarConfig: Equatable {
    var horizontalPadding: CGFloat
    var bottomOffset: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat

    static let `default` = FloatingTabBarConfig(
        horizontalPadding: 36,
        bottomOffset: 14,
        height: 60,
        cornerRadius: 24
    )

    static let minHorizontalPadding: CGFloat = 0
    static let maxHorizontalPadding: CGFloat = 100
    static let minBottomOffset: CGFloat = -50
    static let maxBottomOffset: CGFloat = 80
    static let minHeight: CGFloat = 36
    static let maxHeight: CGFloat = 120
    static let minCornerRadius: CGFloat = 0
    static let maxCornerRadius: CGFloat = 60
}

final class TabBarStyleManager: ObservableObject {
    static let shared = TabBarStyleManager()

    @Published var currentStyle: TabBarStyle {
        didSet {
            UserDefaults.standard.set(currentStyle.rawValue, forKey: "TabBarStyle")
        }
    }

    @Published var floatingConfig: FloatingTabBarConfig {
        didSet {
            saveFloatingConfig()
        }
    }

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "TabBarStyle"),
           let style = TabBarStyle(rawValue: saved) {
            self.currentStyle = style
        } else {
            self.currentStyle = .systemDefault
        }

        self.floatingConfig = .default
        self.loadFloatingConfig()
    }

    private func saveFloatingConfig() {
        UserDefaults.standard.set(Float(floatingConfig.horizontalPadding), forKey: "FloatingTabBar_horizontalPadding")
        UserDefaults.standard.set(Float(floatingConfig.bottomOffset), forKey: "FloatingTabBar_bottomOffset")
        UserDefaults.standard.set(Float(floatingConfig.height), forKey: "FloatingTabBar_height")
        UserDefaults.standard.set(Float(floatingConfig.cornerRadius), forKey: "FloatingTabBar_cornerRadius")
    }

    private func loadFloatingConfig() {
        var config = FloatingTabBarConfig.default

        if UserDefaults.standard.object(forKey: "FloatingTabBar_horizontalPadding") != nil {
            config.horizontalPadding = CGFloat(UserDefaults.standard.float(forKey: "FloatingTabBar_horizontalPadding"))
        }
        if UserDefaults.standard.object(forKey: "FloatingTabBar_bottomOffset") != nil {
            config.bottomOffset = CGFloat(UserDefaults.standard.float(forKey: "FloatingTabBar_bottomOffset"))
        }
        if UserDefaults.standard.object(forKey: "FloatingTabBar_height") != nil {
            config.height = CGFloat(UserDefaults.standard.float(forKey: "FloatingTabBar_height"))
        }
        if UserDefaults.standard.object(forKey: "FloatingTabBar_cornerRadius") != nil {
            config.cornerRadius = CGFloat(UserDefaults.standard.float(forKey: "FloatingTabBar_cornerRadius"))
        }

        self.floatingConfig = config
    }

    func resetFloatingConfig() {
        floatingConfig = .default
    }
}
