import SwiftUI

struct LiquidGlassBackground: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                LinearGradient(
                    colors: backgroundColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(themeManager.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.22))
                    .frame(width: size.width * 0.8, height: size.width * 0.8)
                    .blur(radius: 90)
                    .offset(x: -size.width * 0.28, y: -size.height * 0.22)

                Circle()
                    .fill(Color.cyan.opacity(colorScheme == .dark ? 0.22 : 0.16))
                    .frame(width: size.width * 0.7, height: size.width * 0.7)
                    .blur(radius: 80)
                    .offset(x: size.width * 0.36, y: size.height * 0.10)

                Circle()
                    .fill(Color.purple.opacity(colorScheme == .dark ? 0.20 : 0.10))
                    .frame(width: size.width * 0.55, height: size.width * 0.55)
                    .blur(radius: 70)
                    .offset(x: size.width * 0.05, y: size.height * 0.42)

                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(colorScheme == .dark ? 0.055 : 0.35), .clear],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )

                if themeManager.waterEffectEnabled {
                    LiquidWaterLayer()
                        .environmentObject(themeManager)
                }
            }
            .ignoresSafeArea()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var backgroundColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.035, green: 0.045, blue: 0.075),
                Color(red: 0.055, green: 0.065, blue: 0.115),
                Color(red: 0.025, green: 0.035, blue: 0.06)
            ]
        }
        return [
            Color(red: 0.94, green: 0.96, blue: 1.0),
            Color(red: 0.90, green: 0.94, blue: 0.99),
            Color(red: 0.96, green: 0.97, blue: 1.0)
        ]
    }
}

struct LiquidGlassBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        solid
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// 纯色静态背景：不做渐变、不跑 TimelineView、没有水波，避免持续重绘。
    private var solid: Color {
        colorScheme == .dark
            ? Color(red: 0.086, green: 0.094, blue: 0.118)
            : Color(red: 0.960, green: 0.968, blue: 0.984)
    }
}

extension View {
    @ViewBuilder
    func liquidGlassSurface(cornerRadius: CGFloat = 16) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.28), Color.white.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                )
                .shadow(color: Color.black.opacity(0.14), radius: 18, x: 0, y: 8)
        }
    }

    @ViewBuilder
    func liquidGlassCircle() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}


struct LiquidWaterLayer: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                guard size.width > 1, size.height > 1 else { return }
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                drawCaustics(context: context, size: size, time: time)
                drawRipples(context: context, size: size, time: time)
            }
            .blendMode(.plusLighter)
            .opacity(0.62)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func drawCaustics(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        var blurred = context
        blurred.addFilter(.blur(radius: 13))

        for index in 0..<5 {
            let base = size.height * (0.14 + CGFloat(index) * 0.17)
            let amplitude = 10 + CGFloat(index) * 4
            let speed = 0.30 + Double(index) * 0.045
            var path = Path()
            var started = false
            var x = -24.0
            while x <= Double(size.width) + 24 {
                let u = x / Double(max(size.width, 1))
                let y = Double(base)
                    + sin(u * 6.1 + time * speed + Double(index) * 1.7) * Double(amplitude)
                    + sin(u * 2.2 - time * speed * 0.7 + Double(index) * 0.9) * Double(amplitude) * 0.55
                let point = CGPoint(x: x, y: y)
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
                x += 9
            }

            let gradient = Gradient(colors: [
                themeManager.accentColor.opacity(0.0),
                themeManager.accentColor.opacity(0.28),
                Color.white.opacity(0.24),
                Color.cyan.opacity(0.16),
                themeManager.accentColor.opacity(0.0)
            ])
            blurred.stroke(
                path,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: base),
                    endPoint: CGPoint(x: size.width, y: base)
                ),
                lineWidth: 1.4 + CGFloat(index) * 0.45
            )
        }
    }

    private func drawRipples(context: GraphicsContext, size: CGSize, time: TimeInterval) {
        let center = CGPoint(x: size.width * 0.52, y: size.height * 0.36)
        for index in 0..<3 {
            let progress = (time * 0.10 + Double(index) / 3.0).truncatingRemainder(dividingBy: 1.0)
            let radius = size.width * (0.10 + progress * 0.46)
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius * 0.62,
                width: radius * 2,
                height: radius * 1.24
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(0.10 * (1.0 - progress))),
                lineWidth: 0.8
            )
        }
    }
}
