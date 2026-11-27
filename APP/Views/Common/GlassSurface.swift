import SwiftUI
import UIKit

struct GlassSurface<Content: View>: View {
    var cornerRadius: CGFloat = 16
    var blur: CGFloat = 24
    var saturation: CGFloat = 1.8
    var tintOpacity: Double = 0.07
    var showsHighlight: Bool = true

    let content: Content

    /// iOS 26+ 使用原生液态玻璃(比系统材质 + 白色 tint 更透亮);
    /// `blur` / `saturation` 仅作用于 iOS 26 以下的 UIVisualEffectView 回退路径。
    init(
        cornerRadius: CGFloat = 16,
        blur: CGFloat = 24,
        saturation: CGFloat = 1.8,
        tintOpacity: Double = 0.07,
        showsHighlight: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.blur = blur
        self.saturation = saturation
        self.tintOpacity = tintOpacity
        self.showsHighlight = showsHighlight
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay { tint }
                .overlay { gloss }
        } else {
            content
                .background {
                    GlassBackdropViewRepresentable(blur: blur, saturation: saturation)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                .overlay { tint }
                .overlay { gloss }
        }
    }

    private var tint: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(tintOpacity),
                        Color.white.opacity(tintOpacity * 0.3),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var gloss: some View {
        if showsHighlight {
            GlassGlossOverlay(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}

/// 玻璃亮面装饰:顶部镜面高光带 + 底部厚度阴影 + 边缘轮廓光,随深浅色模式自适应。
struct GlassGlossOverlay<Shape: InsettableShape>: View {
    var shape: Shape
    var intensity: Double = 1
    var showsRim: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            // 顶部镜面高光:光掠过玻璃上沿形成的亮面
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity((dark ? 0.30 : 0.50) * intensity),
                        Color.white.opacity((dark ? 0.10 : 0.16) * intensity),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.36)
                )
            )
            // 底部沉降阴影:玻璃厚度的折射感
            shape.fill(
                LinearGradient(
                    colors: [
                        .clear,
                        Color.black.opacity((dark ? 0.22 : 0.07) * intensity)
                    ],
                    startPoint: UnitPoint(x: 0.5, y: 0.64),
                    endPoint: .bottom
                )
            )
            if showsRim {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity((dark ? 0.42 : 0.55) * intensity),
                            Color.white.opacity((dark ? 0.08 : 0.14) * intensity),
                            Color.white.opacity((dark ? 0.20 : 0.30) * intensity)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.6
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct GlassBackdropViewRepresentable: UIViewRepresentable {
    var blur: CGFloat
    var saturation: CGFloat

    func makeUIView(context: Context) -> GlassBackdropUIView {
        GlassBackdropUIView(blur: blur, saturation: saturation)
    }

    func updateUIView(_ uiView: GlassBackdropUIView, context: Context) {
        uiView.apply(blur: blur, saturation: saturation)
    }
}

final class GlassBackdropUIView: UIVisualEffectView {
    private var blur: CGFloat
    private var saturation: CGFloat

    init(blur: CGFloat, saturation: CGFloat) {
        self.blur = blur
        self.saturation = saturation
        super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(blur: CGFloat, saturation: CGFloat) {
        guard self.blur != blur || self.saturation != saturation else { return }
        self.blur = blur
        self.saturation = saturation
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        let backdrop = subviews.first { String(describing: type(of: $0)).contains("Backdrop") } ?? subviews.first
        guard let layer = backdrop?.layer,
              let filters = layer.value(forKey: "filters") as? [NSObject] else {
            return
        }

        for filter in filters {
            let name = (filter.value(forKey: "name") as? String) ?? String(describing: type(of: filter))
            if name.localizedCaseInsensitiveContains("gaussian") {
                filter.setValue(blur, forKey: "inputRadius")
            } else if name.localizedCaseInsensitiveContains("saturate") {
                filter.setValue(saturation, forKey: "inputAmount")
            }
        }
    }
}
