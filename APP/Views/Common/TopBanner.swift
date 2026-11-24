import SwiftUI

struct TopBanner: Identifiable, Equatable {
    let id: UUID
    var message: String
    var systemImage: String?
    var tint: Color

    init(id: UUID = UUID(), message: String, systemImage: String? = nil, tint: Color = .black) {
        self.id = id
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
    }
}

@MainActor
final class TopBannerPresenter: ObservableObject {
    static let shared = TopBannerPresenter()

    @Published private(set) var banners: [TopBanner] = []

    private var dismissTasks: [UUID: Task<Void, Never>] = [:]

    func show(_ banner: TopBanner, duration: TimeInterval = 2.6) {
        banners.append(banner)
        dismissTasks[banner.id]?.cancel()
        dismissTasks[banner.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(duration, 0.6) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss(banner.id)
        }
        while banners.count > 3 {
            dismiss(banners[0].id)
        }
    }

    func dismiss(_ id: UUID) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
        banners.removeAll { $0.id == id }
    }

    func dismissAll() {
        for task in dismissTasks.values {
            task.cancel()
        }
        dismissTasks.removeAll()
        banners.removeAll()
    }
}

private struct TopBannerHost: ViewModifier {
    @ObservedObject private var presenter = TopBannerPresenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            VStack(spacing: 6) {
                ForEach(presenter.banners) { banner in
                    HStack(spacing: 7) {
                        if let systemImage = banner.systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(banner.message)
                            .font(.system(size: 13, weight: .semibold))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(banner.tint.opacity(0.92)))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { presenter.dismiss(banner.id) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: presenter.banners)
        }
    }
}

extension View {
    func topBannerHost() -> some View {
        modifier(TopBannerHost())
    }
}
