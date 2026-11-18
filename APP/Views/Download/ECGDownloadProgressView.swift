import SwiftUI

struct ECGDownloadProgressView: View {
    let progress: Double
    let status: DownloadStatus
    let error: String?
    let accentColor: Color
    var speed: String? = nil
    var isPreview: Bool = false

    private var progressLabel: String {
        switch status {
        case .waiting:
            return "download_waiting".localized
        case .downloading:
            return "downloading".localized
        case .paused:
            return "download_paused".localized
        case .completed:
            return "download_completed".localized
        case .failed:
            return "download_failed".localized
        case .cancelled:
            return "download_cancelled".localized
        }
    }

    private var waveformColor: Color {
        switch status {
        case .waiting, .paused:
            return .orange
        case .downloading, .completed:
            return accentColor
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }

    private var isActive: Bool {
        status == .downloading || status == .waiting
    }

    private var showsProgress: Bool {
        status != .failed && status != .cancelled
    }

    private var isFlatline: Bool {
        status == .failed || status == .cancelled
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(waveformColor)
                    Text(progressLabel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if showsProgress {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(waveformColor)
                            .monospacedDigit()
                        if let speed, !speed.isEmpty {
                            Text(speed)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                }
            }

            ECGMonitorPanel(
                progress: progress,
                color: waveformColor,
                isActive: isActive,
                isFlatline: isFlatline,
                isPaused: isPreview
            )

            if let error = error, !error.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                        .lineLimit(2)

                    Spacer()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(progressLabel) \(Int((progress * 100).rounded()))%")
    }
}

private struct ECGMonitorPanel: View {
    let progress: Double
    let color: Color
    let isActive: Bool
    let isFlatline: Bool
    let isPaused: Bool

    private let scrollSpeed: Double = 46
    private let smallGrid: CGFloat = 10

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || isPaused)) { context in
            Canvas { ctx, size in
                let time = context.date.timeIntervalSinceReferenceDate
                drawGrid(&ctx, size: size, time: time)
                if isFlatline {
                    drawFlatline(&ctx, size: size)
                } else {
                    drawTrace(&ctx, size: size, time: time)
                }
            }
        }
        .frame(height: 46)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func drawGrid(_ ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        var minor = Path()
        var major = Path()

        let offset = CGFloat((time * scrollSpeed).truncatingRemainder(dividingBy: Double(smallGrid)))

        var x = -offset
        var index = 0
        while x <= size.width {
            let target = index % 5 == 0
            if target {
                major.move(to: CGPoint(x: x, y: 0))
                major.addLine(to: CGPoint(x: x, y: size.height))
            } else {
                minor.move(to: CGPoint(x: x, y: 0))
                minor.addLine(to: CGPoint(x: x, y: size.height))
            }
            x += smallGrid
            index += 1
        }

        var y: CGFloat = 0
        index = 0
        while y <= size.height {
            let target = index % 5 == 0
            if target {
                major.move(to: CGPoint(x: 0, y: y))
                major.addLine(to: CGPoint(x: size.width, y: y))
            } else {
                minor.move(to: CGPoint(x: 0, y: y))
                minor.addLine(to: CGPoint(x: size.width, y: y))
            }
            y += smallGrid
            index += 1
        }

        ctx.stroke(minor, with: .color(color.opacity(0.10)), lineWidth: 0.5)
        ctx.stroke(major, with: .color(color.opacity(0.20)), lineWidth: 1)
    }

    private func drawFlatline(_ ctx: inout GraphicsContext, size: CGSize) {
        let midY = size.height * 0.5
        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY))
        path.addLine(to: CGPoint(x: size.width, y: midY))
        ctx.stroke(path, with: .color(color.opacity(0.35)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
    }

    private func drawTrace(_ ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 2, size.height > 2 else { return }

        let midY = size.height * 0.5
        let amplitude = size.height * 0.30
        let step: CGFloat = 0.5

        let clamped = max(0, min(1, progress))
        let beatsPerSecond: Double = 0.9 + 0.5 * clamped

        var path = Path()
        var x: CGFloat = 0
        var started = false

        while x <= size.width {
            let age = Double((size.width - x) / CGFloat(scrollSpeed))
            let phase = ((time - age) * beatsPerSecond).truncatingRemainder(dividingBy: 1)
            let y = midY - CGFloat(Self.waveValue(phase)) * amplitude
            let point = CGPoint(x: x, y: y)
            if started {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                started = true
            }
            x += step
        }

        ctx.stroke(
            path,
            with: .color(color.opacity(0.13)),
            style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
        )

        let headX = size.width * CGFloat(clamped)
        guard headX > 0.5 else { return }

        var revealed = ctx
        revealed.clip(to: Path(CGRect(x: 0, y: 0, width: headX, height: size.height)))
        revealed.stroke(
            path,
            with: .color(color.opacity(0.22)),
            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        )
        revealed.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
        )

        let headAge = Double((size.width - headX) / CGFloat(scrollSpeed))
        let headPhase = ((time - headAge) * beatsPerSecond).truncatingRemainder(dividingBy: 1)
        let headY = midY - CGFloat(Self.waveValue(headPhase)) * amplitude
        let center = CGPoint(x: headX, y: headY)

        let pulse = 0.5 + 0.5 * sin(time * .pi * 2 * 1.3)
        let haloRadius = 6 + 4 * pulse
        let halo = CGRect(x: center.x - haloRadius, y: center.y - haloRadius,
                          width: haloRadius * 2, height: haloRadius * 2)
        ctx.fill(Path(ellipseIn: halo), with: .color(color.opacity(0.10 + 0.12 * pulse)))

        let dot = CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
        ctx.fill(Path(ellipseIn: dot), with: .color(color))
    }

    private static func waveValue(_ phase: Double) -> Double {
        func bump(_ center: Double, _ sigma: Double, _ amplitude: Double) -> Double {
            let d = (phase - center) / sigma
            return amplitude * exp(-d * d)
        }

        var value = 0.0
        value += bump(0.150, 0.036, 0.18)
        value -= bump(0.300, 0.014, 0.12)
        value += bump(0.340, 0.019, 1.00)
        value -= bump(0.386, 0.015, 0.28)
        value += bump(0.580, 0.060, 0.30)
        value += sin(phase * .pi * 2) * 0.010
        return value
    }
}
