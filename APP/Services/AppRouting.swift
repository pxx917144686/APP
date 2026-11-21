import Foundation
import SwiftUI

@MainActor
final class TabRouter: ObservableObject {
    static let shared = TabRouter()

    @Published var requested: TabEnum?

    func select(_ tab: TabEnum) {
        requested = tab
    }
}

@MainActor
final class SigningHandoff: ObservableObject {
    static let shared = SigningHandoff()

    @Published var pendingIPA: URL?

    func send(_ url: URL) {
        pendingIPA = url
    }
}
