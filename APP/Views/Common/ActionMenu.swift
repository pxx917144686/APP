import SwiftUI

struct ActionMenuItem: Identifiable {
    let id = UUID()
    var title: String
    var icon: String
    var role: ButtonRole?
    var isEnabled: Bool
    var showsChevron: Bool
    var action: () -> Void

    init(
        title: String,
        icon: String,
        role: ButtonRole? = nil,
        isEnabled: Bool = true,
        showsChevron: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.role = role
        self.isEnabled = isEnabled
        self.showsChevron = showsChevron
        self.action = action
    }
}

struct ActionMenuRequest: Identifiable {
    let id = UUID()
    var items: [ActionMenuItem]
}

@MainActor
final class ActionMenuPresenter: ObservableObject {
    static let shared = ActionMenuPresenter()

    @Published private(set) var request: ActionMenuRequest?

    func present(_ request: ActionMenuRequest) {
        self.request = request
    }

    func dismiss() {
        request = nil
    }
}

struct ActionMenuOverlay: View {
    let request: ActionMenuRequest
    let onDismiss: () -> Void

    @State private var shown = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black
                .opacity(shown ? 0.32 : 0)
                .ignoresSafeArea()
                .onTapGesture { close() }

            panel
                .offset(y: shown ? 0 : 70)
                .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
                shown = true
            }
        }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            ForEach(request.items) { item in
                Button {
                    guard item.isEnabled else { return }
                    close(then: item.action)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .medium))
                            .frame(width: 22)

                        Text(item.title)
                            .font(.system(size: 15))

                        Spacer(minLength: 8)

                        if item.showsChevron {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(foreground(for: item))
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!item.isEnabled)

                if item.id != request.items.last?.id {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                        .padding(.leading, 48)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            GlassGlossOverlay(
                shape: RoundedRectangle(cornerRadius: 14, style: .continuous),
                intensity: 0.8
            )
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }

    private func foreground(for item: ActionMenuItem) -> Color {
        if !item.isEnabled { return .secondary.opacity(0.5) }
        if item.role == .destructive { return .red }
        return .primary
    }

    private func close(then action: (() -> Void)? = nil) {
        withAnimation(.easeOut(duration: 0.18)) {
            shown = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            onDismiss()
            action?()
        }
    }
}

private struct ActionMenuHost: ViewModifier {
    @ObservedObject private var presenter = ActionMenuPresenter.shared

    func body(content: Content) -> some View {
        content.overlay {
            if let request = presenter.request {
                ActionMenuOverlay(request: request) {
                    presenter.dismiss()
                }
            }
        }
    }
}

extension View {
    func actionMenuHost() -> some View {
        modifier(ActionMenuHost())
    }
}
