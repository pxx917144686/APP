import SwiftUI
import UIKit

struct SwipeAction {
    let title: String
    let systemImage: String
    let backgroundColor: Color
    let action: () -> Void
}

struct SwipeActionsModifier: ViewModifier {
    var actions: [SwipeAction]
    @State private var offset: CGFloat = 0

    private var totalButtonWidth: CGFloat {
        CGFloat(actions.count) * 80
    }
    private let maxSwipeDistance: CGFloat = 200

    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            actionButtons

            content
                .offset(x: offset)
                .background(
                    SwipeGestureView(
                        onSwipeChange: { translation in
                            if translation < 0 {
                                let dragAmount = -translation
                                let resistance: CGFloat = dragAmount > totalButtonWidth ? 0.3 : 1.0
                                offset = -min(dragAmount * resistance, maxSwipeDistance)
                            } else {
                                offset = min(translation * 0.5, 0)
                            }
                        },
                        onSwipeEnd: { translation, velocity in
                            let dragAmount = -translation

                            if dragAmount > totalButtonWidth * 0.4 || velocity < -200 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    offset = -totalButtonWidth
                                }
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    offset = 0
                                }
                            }
                        }
                    )
                )
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 0) {
            Spacer()
            ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        offset = 0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        action.action()
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: action.systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                        Text(action.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .frame(width: 80)
                .background(action.backgroundColor)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct SwipeGestureView: UIViewRepresentable {
    var onSwipeChange: (CGFloat) -> Void
    var onSwipeEnd: (CGFloat, CGFloat) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear

        let panGesture = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        panGesture.delegate = context.coordinator
        panGesture.minimumNumberOfTouches = 1
        view.addGestureRecognizer(panGesture)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSwipeChange: onSwipeChange, onSwipeEnd: onSwipeEnd)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSwipeChange: (CGFloat) -> Void
        var onSwipeEnd: (CGFloat, CGFloat) -> Void
        private var initialTranslation: CGPoint = .zero
        private var didBeginHorizontal = false

        init(onSwipeChange: @escaping (CGFloat) -> Void, onSwipeEnd: @escaping (CGFloat, CGFloat) -> Void) {
            self.onSwipeChange = onSwipeChange
            self.onSwipeEnd = onSwipeEnd
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let translation = gesture.translation(in: gesture.view)

            switch gesture.state {
            case .began:
                initialTranslation = translation
                didBeginHorizontal = false
            case .changed:
                let deltaX = translation.x - initialTranslation.x
                let deltaY = translation.y - initialTranslation.y

                if !didBeginHorizontal {
                    if abs(deltaX) > abs(deltaY) && abs(deltaX) > 12 {
                        didBeginHorizontal = true
                        initialTranslation = translation
                    }
                    return
                }

                let currentTranslation = translation.x - initialTranslation.x
                onSwipeChange(currentTranslation)

            case .ended, .cancelled, .failed:
                if didBeginHorizontal {
                    let velocity = gesture.velocity(in: gesture.view).x
                    let finalTranslation = translation.x - initialTranslation.x
                    onSwipeEnd(finalTranslation, velocity)
                }
                didBeginHorizontal = false

            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else {
                return false
            }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) && abs(velocity.x) > 50
        }
    }
}

extension View {
    func swipeActions(_ actions: [SwipeAction]) -> some View {
        modifier(SwipeActionsModifier(actions: actions))
    }
}
