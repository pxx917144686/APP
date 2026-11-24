import SwiftUI

private struct AppPresentationHost: ViewModifier {
    @ObservedObject private var presenter = AppPresenter.shared

    func body(content: Content) -> some View {
        content
            .topBannerHost()
            .sheet(item: presenter.sheetItem) { sheet in
                sheet.content()
            }
            .alert(
                presenter.activeAlert?.title ?? "",
                isPresented: presenter.alertPresented,
                presenting: presenter.activeAlert
            ) { alert in
                if let secondaryTitle = alert.secondaryTitle {
                    Button(secondaryTitle, role: alert.secondaryRole) {
                        alert.onSecondary?()
                    }
                }
                Button(alert.primaryTitle, role: alert.primaryRole) {
                    alert.onPrimary?()
                }
            } message: { alert in
                if let message = alert.message {
                    Text(message)
                }
            }
    }
}

extension View {
    func appPresentationHost() -> some View {
        modifier(AppPresentationHost())
    }
}
