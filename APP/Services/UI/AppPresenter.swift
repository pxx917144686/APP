import SwiftUI

struct AppAlert: Identifiable {
    let id: UUID
    var title: String
    var message: String?
    var primaryTitle: String
    var primaryRole: ButtonRole?
    var onPrimary: (() -> Void)?
    var secondaryTitle: String?
    var secondaryRole: ButtonRole?
    var onSecondary: (() -> Void)?

    init(
        id: UUID = UUID(),
        title: String,
        message: String? = nil,
        primaryTitle: String = "ok".localized,
        primaryRole: ButtonRole? = nil,
        onPrimary: (() -> Void)? = nil,
        secondaryTitle: String? = nil,
        secondaryRole: ButtonRole? = .cancel,
        onSecondary: (() -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.primaryTitle = primaryTitle
        self.primaryRole = primaryRole
        self.onPrimary = onPrimary
        self.secondaryTitle = secondaryTitle
        self.secondaryRole = secondaryRole
        self.onSecondary = onSecondary
    }
}

struct AppSheet: Identifiable {
    let id = UUID()
    var content: @MainActor () -> AnyView
    var onDismiss: (() -> Void)?
}

@MainActor
final class AppPresenter: ObservableObject {
    static let shared = AppPresenter()

    @Published private(set) var activeAlert: AppAlert?
    @Published private(set) var activeSheet: AppSheet?

    private enum Pending {
        case alert(AppAlert)
        case sheet(AppSheet)
    }

    private var queue: [Pending] = []

    var alertPresented: Binding<Bool> {
        Binding(
            get: { self.activeAlert != nil },
            set: { if !$0 { self.finishAlert() } }
        )
    }

    var sheetItem: Binding<AppSheet?> {
        Binding(
            get: { self.activeSheet },
            set: { if $0 == nil { self.finishSheet() } }
        )
    }

    func present(alert: AppAlert) {
        queue.append(.alert(alert))
        advance()
    }

    func present(sheet: AppSheet) {
        queue.append(.sheet(sheet))
        advance()
    }

    func dismiss() {
        if activeAlert != nil {
            finishAlert()
            return
        }
        if activeSheet != nil {
            finishSheet()
            return
        }
        queue.removeAll()
    }

    private func finishAlert() {
        guard activeAlert != nil else { return }
        activeAlert = nil
        scheduleAdvance()
    }

    private func finishSheet() {
        guard let sheet = activeSheet else { return }
        activeSheet = nil
        sheet.onDismiss?()
        scheduleAdvance()
    }

    private func scheduleAdvance() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self?.advance()
        }
    }

    private func advance() {
        guard activeAlert == nil, activeSheet == nil else { return }
        guard !queue.isEmpty else { return }
        switch queue.removeFirst() {
        case .alert(let alert):
            activeAlert = alert
        case .sheet(let sheet):
            activeSheet = sheet
        }
    }
}
