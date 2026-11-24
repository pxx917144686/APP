import SwiftUI

struct MotionTransition: Sendable {
    var duration: Double
    var delay: Double
    var spring: Spring?

    static let snappy = MotionTransition(duration: 0.28, delay: 0, spring: .init(response: 0.30, dampingFraction: 0.82))
    static let smooth = MotionTransition(duration: 0.45, delay: 0, spring: .init(response: 0.45, dampingFraction: 0.86))
    static let gentle = MotionTransition(duration: 0.60, delay: 0.05, spring: .init(response: 0.62, dampingFraction: 0.90))

    var animation: Animation {
        if let spring {
            return .spring(response: spring.response, dampingFraction: spring.dampingFraction).delay(delay)
        }
        return .easeInOut(duration: duration).delay(delay)
    }

    func run(_ body: () -> Void) {
        withAnimation(animation, body)
    }

    struct Spring: Sendable {
        var response: Double
        var dampingFraction: Double
    }
}
