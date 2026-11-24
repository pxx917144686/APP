import SwiftUI

struct SigningHistoryRowOptions {
    var record: SigningHistoryRecord
    var isAvailable: Bool
    var hasRetainedSource: Bool
    var accentColor: Color
    var onSelect: () -> Void
    var onToggleHidden: () -> Void
    var onDelete: () -> Void
}

struct AppViewFactory {
    var signingHistoryRow: (SigningHistoryRowOptions) -> AnyView

    static let `default` = AppViewFactory(
        signingHistoryRow: { options in
            AnyView(SigningHistoryRow(options: options))
        }
    )
}

private struct AppViewFactoryKey: EnvironmentKey {
    static let defaultValue = AppViewFactory.default
}

extension EnvironmentValues {
    var appViewFactory: AppViewFactory {
        get { self[AppViewFactoryKey.self] }
        set { self[AppViewFactoryKey.self] = newValue }
    }
}
