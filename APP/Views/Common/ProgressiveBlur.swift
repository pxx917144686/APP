import SwiftUI
import UIKit

struct ProgressiveBlur: UIViewRepresentable {
    enum Edge {
        case top
        case bottom
        case leading
        case trailing
    }

    var edge: Edge = .top
    var maxRadius: CGFloat = 4

    func makeUIView(context: Context) -> ProgressiveBlurUIView {
        ProgressiveBlurUIView(edge: edge, maxRadius: maxRadius)
    }

    func updateUIView(_ uiView: ProgressiveBlurUIView, context: Context) {
        uiView.apply(edge: edge, maxRadius: maxRadius)
    }
}

final class ProgressiveBlurUIView: UIVisualEffectView {
    private var edge: ProgressiveBlur.Edge
    private var maxRadius: CGFloat
    private var filter: NSObject?
    private var cachedMask: UIImage?
    private var cachedMaskSize: CGSize = .zero

    private static let filterSelector = NSSelectorFromString("filterWithType:")

    private static var supportsVariableBlur: Bool {
        guard let cls = NSClassFromString("CAFilter"), let meta = object_getClass(cls) else { return false }
        return class_respondsToSelector(meta, filterSelector)
    }

    init(edge: ProgressiveBlur.Edge, maxRadius: CGFloat) {
        self.edge = edge
        self.maxRadius = maxRadius
        super.init(effect: Self.supportsVariableBlur ? UIBlurEffect(style: .regular) : nil)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(edge: ProgressiveBlur.Edge, maxRadius: CGFloat) {
        guard self.edge != edge || self.maxRadius != maxRadius else { return }
        self.edge = edge
        self.maxRadius = maxRadius
        cachedMask = nil
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }

        if filter == nil {
            filter = Self.makeVariableBlurFilter(radius: maxRadius)
        }
        guard let filter else { return }

        if cachedMask == nil || cachedMaskSize != bounds.size {
            cachedMask = Self.maskImage(edge: edge, size: bounds.size)
            cachedMaskSize = bounds.size
            filter.setValue(cachedMask?.cgImage, forKey: "inputMaskImage")
        }

        let backdrop = subviews.first { String(describing: type(of: $0)).contains("Backdrop") } ?? subviews.first
        backdrop?.layer.setValue([filter], forKey: "filters")

        for subview in subviews where String(describing: type(of: subview)).contains("ContentView") {
            subview.alpha = 0
        }
    }

    private static func makeVariableBlurFilter(radius: CGFloat) -> NSObject? {
        guard let cls = NSClassFromString("CAFilter"),
              let meta = object_getClass(cls),
              class_respondsToSelector(meta, filterSelector) else {
            return nil
        }
        typealias FilterWithType = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
        let imp = class_getMethodImplementation(meta, filterSelector)
        let function = unsafeBitCast(imp, to: FilterWithType.self)
        guard let filter = function(cls, filterSelector, "variableBlur" as NSString)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }

    private static func maskImage(edge: ProgressiveBlur.Edge, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let colors = [
                UIColor.white.withAlphaComponent(1).cgColor,
                UIColor.white.withAlphaComponent(0).cgColor
            ] as CFArray
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            ) else { return }

            let start: CGPoint
            let end: CGPoint
            switch edge {
            case .top:
                start = CGPoint(x: 0, y: 0)
                end = CGPoint(x: 0, y: size.height)
            case .bottom:
                start = CGPoint(x: 0, y: size.height)
                end = CGPoint(x: 0, y: 0)
            case .leading:
                start = CGPoint(x: 0, y: 0)
                end = CGPoint(x: size.width, y: 0)
            case .trailing:
                start = CGPoint(x: size.width, y: 0)
                end = CGPoint(x: 0, y: 0)
            }
            context.cgContext.drawLinearGradient(
                gradient,
                start: start,
                end: end,
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }
}
