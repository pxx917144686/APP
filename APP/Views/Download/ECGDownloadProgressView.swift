import SwiftUI

struct ECGDownloadProgressView: View {
    let progress: Double
    let status: DownloadStatus
    let error: String?
    let accentColor: Color

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
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(waveformColor)
                        .monospacedDigit()
                }
            }

            ECGMonitorPanel(
                progress: progress,
                color: waveformColor,
                isActive: isActive
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
    }
}

private struct ECGMonitorPanel: View {
    let progress: Double
    let color: Color
    let isActive: Bool

    var body: some View {
        ZStack {
            ECGGridView(lineColor: color.opacity(0.10), majorLineColor: color.opacity(0.20))

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isActive)) { context in
                Canvas { ctx, size in
                    drawTrace(&ctx, size: size, time: context.date.timeIntervalSinceReferenceDate)
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

    private func drawTrace(_ ctx: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        guard size.width > 2, size.height > 2 else { return }

        let midY = size.height * 0.5
        let amplitude = size.height * 0.30
        let step: CGFloat = 0.5
        let scrollSpeed: Double = 46
        let beatsPerSecond: Double = 1.05

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

        let clamped = max(0, min(1, progress))
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
        let dot = CGRect(x: headX - 3.5, y: headY - 3.5, width: 7, height: 7)
        ctx.fill(Path(ellipseIn: dot.insetBy(dx: -4, dy: -4)), with: .color(color.opacity(0.20)))
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

struct ECGGridView: View {
    let lineColor: Color
    let majorLineColor: Color
    let smallGridSize: CGFloat = 10

    var body: some View {
        Canvas { ctx, size in
            var minor = Path()
            var major = Path()

            var x: CGFloat = 0
            var index = 0
            while x <= size.width {
                let target: Bool = index % 5 == 0
                if target {
                    major.move(to: CGPoint(x: x, y: 0))
                    major.addLine(to: CGPoint(x: x, y: size.height))
                } else {
                    minor.move(to: CGPoint(x: x, y: 0))
                    minor.addLine(to: CGPoint(x: x, y: size.height))
                }
                x += smallGridSize
                index += 1
            }

            var y: CGFloat = 0
            index = 0
            while y <= size.height {
                let target: Bool = index % 5 == 0
                if target {
                    major.move(to: CGPoint(x: 0, y: y))
                    major.addLine(to: CGPoint(x: size.width, y: y))
                } else {
                    minor.move(to: CGPoint(x: 0, y: y))
                    minor.addLine(to: CGPoint(x: size.width, y: y))
                }
                y += smallGridSize
                index += 1
            }

            ctx.stroke(minor, with: .color(lineColor), lineWidth: 0.5)
            ctx.stroke(major, with: .color(majorLineColor), lineWidth: 1)
        }
    }
}
