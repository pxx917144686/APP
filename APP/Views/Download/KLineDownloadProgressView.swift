import SwiftUI

struct KLineDownloadProgressView: View {
    let progress: Double
    let status: DownloadStatus
    let error: String?
    let accentColor: Color
    let speed: String?
    let completedBytes: Int64
    let totalBytes: Int64
    let remainingTime: TimeInterval
    let samples: [DownloadRuntime.SpeedSample]

    private var color: Color {
        switch status {
        case .waiting, .paused: return .orange
        case .downloading, .completed: return accentColor
        case .failed: return .red
        case .cancelled: return .gray
        }
    }

    private var statusText: String {
        switch status {
        case .waiting: return "download_waiting".localized
        case .downloading: return "downloading".localized
        case .paused: return "download_paused".localized
        case .completed: return "download_completed".localized
        case .failed: return "download_failed".localized
        case .cancelled: return "download_cancelled".localized
        }
    }

    private var statusIcon: String {
        switch status {
        case .waiting: return "clock.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .paused: return "pause.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle.fill"
        }
    }

    private var sizeText: String {
        let formatter = DownloadByteFormatter.file
        let completed = formatter.string(fromByteCount: max(0, completedBytes))
        let total = formatter.string(fromByteCount: max(0, totalBytes))
        if totalBytes <= 0 { return completed }
        return "\(completed) / \(total)"
    }

    private var remainingText: String {
        guard status == .downloading, remainingTime > 0 else { return "--:--" }
        let value = Int(remainingTime.rounded())
        let hours = value / 3600
        let minutes = (value % 3600) / 60
        let seconds = value % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                Text(statusText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int(max(0, min(1, progress)) * 100))%")
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }

            HeartbeatTracePanel(
                samples: samples,
                progress: max(0, min(1, progress)),
                completedBytes: completedBytes,
                totalBytes: totalBytes,
                color: color,
                isLive: status == .downloading
            )
            .frame(height: 88)

            HStack(spacing: 8) {
                Text(sizeText)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let speed, !speed.isEmpty, status == .downloading {
                    Label(speed, systemImage: "arrow.down")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(String(format: "dl_transfer_left".localized, remainingText))
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let error, !error.isEmpty {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct HeartbeatTracePanel: View {
    let samples: [DownloadRuntime.SpeedSample]
    let progress: Double
    let completedBytes: Int64
    let totalBytes: Int64
    let color: Color
    let isLive: Bool

    private let maxPoints = 360
    private let horizontalInset: CGFloat = 8

    private var denominator: Double {
        if totalBytes > 0 { return Double(totalBytes) }
        return Double(max(completedBytes, samples.last?.bytes ?? 0, 1))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isLive)) { timeline in
            Canvas { context, size in
                drawFilledBackdrop(&context, size: size)
                drawGrid(&context, size: size)

                let points = makePoints(size: size)
                guard points.count >= 2 else {
                    drawIdle(&context, size: size)
                    return
                }
                drawArea(&context, size: size, points: points)
                drawTrace(&context, size: size, points: points)
                drawHead(&context, size: size, points: points,
                         pulse: Self.pulsePhase(at: timeline.date))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private static func pulsePhase(at date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        return seconds.truncatingRemainder(dividingBy: 1.1) / 1.1
    }

    private func makePoints(size: CGSize) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
        let usable = size.width - horizontalInset * 2
        let top: CGFloat = 7
        let bottom = size.height - 9

        let step = max(1, samples.count / maxPoints)
        var picked: [DownloadRuntime.SpeedSample] = []
        var index = 0
        while index < samples.count {
            picked.append(samples[index])
            index += step
        }
        if let last = samples.last, picked.last?.bytes != last.bytes {
            picked.append(last)
        }

        let speeds = picked.map { max(0, $0.speed) }
        let maxSpeed = speeds.max() ?? 0
        let minSpeed = speeds.min() ?? 0
        let span = max(maxSpeed - minSpeed, maxSpeed * 0.08, 1)
        let lower = max(0, minSpeed - span * 0.18)
        let upper = max(maxSpeed + span * 0.18, lower + 1)

        return picked.map { sample in
            let fraction = max(0, min(1, Double(sample.bytes) / denominator))
            let x = horizontalInset + usable * CGFloat(fraction)
            let ratio = CGFloat(max(0, min(1, (max(0, sample.speed) - lower) / (upper - lower))))
            let y = bottom - (bottom - top) * ratio
            return CGPoint(x: x, y: y)
        }
    }

    private func drawFilledBackdrop(_ context: inout GraphicsContext, size: CGSize) {
        let width = (size.width - horizontalInset * 2) * CGFloat(max(0, min(1, progress)))
        guard width > 0 else { return }
        let rect = CGRect(x: horizontalInset, y: 0, width: width, height: size.height)
        context.fill(Path(rect), with: .color(color.opacity(0.05)))
    }

    private func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        for step in 1..<4 {
            let y = size.height * CGFloat(step) / 4
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(Color.primary.opacity(0.07)), lineWidth: 0.5)
    }

    private func drawIdle(_ context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let y = size.height * 0.6
        path.move(to: CGPoint(x: horizontalInset, y: y))
        path.addLine(to: CGPoint(x: size.width - horizontalInset, y: y))
        context.stroke(path, with: .color(color.opacity(0.30)),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 3]))
    }

    private func drawArea(_ context: inout GraphicsContext, size: CGSize, points: [CGPoint]) {
        var area = tracePath(points)
        guard let first = points.first, let last = points.last else { return }
        area.addLine(to: CGPoint(x: last.x, y: size.height))
        area.addLine(to: CGPoint(x: first.x, y: size.height))
        area.closeSubpath()
        context.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.26), color.opacity(0.01)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)
            )
        )
    }

    private func drawTrace(_ context: inout GraphicsContext, size: CGSize, points: [CGPoint]) {
        let path = tracePath(points)
        var glow = context
        glow.addFilter(.shadow(color: color.opacity(0.55), radius: 3))
        glow.stroke(path, with: .color(color.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        glow.stroke(path, with: .color(color),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func drawHead(_ context: inout GraphicsContext, size: CGSize,
                          points: [CGPoint], pulse: Double) {
        guard let last = points.last else { return }

        var dashed = Path()
        dashed.move(to: CGPoint(x: last.x, y: 2))
        dashed.addLine(to: CGPoint(x: last.x, y: size.height - 2))
        context.stroke(dashed, with: .color(color.opacity(0.22)),
                       style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

        var glow = context
        glow.addFilter(.shadow(color: color.opacity(0.6), radius: 6))
        let dot = CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)
        glow.fill(Path(ellipseIn: dot), with: .color(color))
        let core = CGRect(x: last.x - 1.5, y: last.y - 1.5, width: 3, height: 3)
        glow.fill(Path(ellipseIn: core), with: .color(Color.white.opacity(0.95)))

        if isLive {
            let ringRadius = 3 + 8 * CGFloat(pulse)
            let ring = CGRect(x: last.x - ringRadius, y: last.y - ringRadius,
                              width: ringRadius * 2, height: ringRadius * 2)
            context.stroke(Path(ellipseIn: ring),
                           with: .color(color.opacity(0.45 * (1 - pulse))),
                           lineWidth: 1.4)
            let innerPulse = (pulse + 0.5).truncatingRemainder(dividingBy: 1)
            let innerRadius = 3 + 6 * CGFloat(innerPulse)
            let inner = CGRect(x: last.x - innerRadius, y: last.y - innerRadius,
                               width: innerRadius * 2, height: innerRadius * 2)
            context.stroke(Path(ellipseIn: inner),
                           with: .color(color.opacity(0.30 * (1 - innerPulse))),
                           lineWidth: 1)
        }
    }

    private func tracePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 1 else { return path }
        for index in 1..<points.count {
            path.addLine(to: points[index])
        }
        return path
    }
}
