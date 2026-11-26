import SwiftUI
import UIKit

struct GlassSurface<Content: View>: View {
    var cornerRadius: CGFloat = 16
    var blur: CGFloat = 24
    var saturation: CGFloat = 1.8
    var tintOpacity: Double = 0.10
    var showsHighlight: Bool = true

    let content: Content

    init(
        cornerRadius: CGFloat = 16,
        blur: CGFloat = 24,
        saturation: CGFloat = 1.8,
        tintOpacity: Double = 0.10,
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
        content
            .background {
                GlassBackdropViewRepresentable(blur: blur, saturation: saturation)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .overlay {
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
            .overlay {
                if showsHighlight {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.38),
                                    Color.white.opacity(0.06),
                                    Color.white.opacity(0.18)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.6
                        )
                        .allowsHitTesting(false)
                }
            }
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
