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
            .frame(height: 112)

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

    private let maxPoints = 480
    private let leftInset: CGFloat = 30
    private let rightInset: CGFloat = 6
    private let topInset: CGFloat = 23
    private let bottomInset: CGFloat = 15

    private struct Stats {
        var current: Double
        var average: Double
        var peak: Double
        var peakFraction: Double
        var elapsed: Double
        var remainingBytes: Int64
    }

    private var denominator: Double {
        if totalBytes > 0 { return Double(totalBytes) }
        return Double(max(completedBytes, samples.last?.bytes ?? 0, 1))
    }

    private var lastFraction: Double {
        guard let last = samples.last else { return 0 }
        return max(0, min(1, Double(last.bytes) / denominator))
    }

    private var stats: Stats {
        let speeds = samples.map { max(0, $0.speed) }
        let peakSample = samples.max { $0.speed < $1.speed }
        let peakFraction = peakSample.map { max(0, min(1, Double($0.bytes) / denominator)) } ?? 0
        let elapsed = max(0, (samples.last?.time ?? 0) - (samples.first?.time ?? 0))
        let remaining: Int64
        if totalBytes > 0 {
            remaining = max(0, totalBytes - max(0, completedBytes))
        } else {
            remaining = 0
        }
        guard !speeds.isEmpty else {
            return Stats(current: 0, average: 0, peak: 0, peakFraction: peakFraction,
                         elapsed: 0, remainingBytes: remaining)
        }
        let average = speeds.reduce(0, +) / Double(speeds.count)
        return Stats(current: speeds.last ?? 0, average: average, peak: speeds.max() ?? 0,
                     peakFraction: peakFraction, elapsed: elapsed, remainingBytes: remaining)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isLive)) { timeline in
            Canvas { context, size in
                let plot = CGRect(x: leftInset, y: topInset,
                                  width: max(1, size.width - leftInset - rightInset),
                                  height: max(1, size.height - topInset - bottomInset))
                let range = axisRange()
                let stats = stats

                let points = makePoints(plot: plot, range: range)
                drawHUD(&context, plot: plot, stats: stats, hasData: points.count >= 2)

                guard points.count >= 2 else {
                    drawAxes(&context, plot: plot, range: range, hasCurve: false)
                    drawIdle(&context, plot: plot)
                    return
                }

                drawAxes(&context, plot: plot, range: range, hasCurve: true)
                drawAverageLine(&context, plot: plot, range: range, stats: stats)
                drawArea(&context, plot: plot, points: points)
                drawTrace(&context, points: points)
                drawNodes(&context, points: points)
                drawPeak(&context, plot: plot, range: range, stats: stats)
                drawHead(&context, plot: plot, points: points,
                         pulse: Self.pulsePhase(at: timeline.date))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private static func pulsePhase(at date: Date) -> Double {
        let seconds = date.timeIntervalSinceReferenceDate
        return seconds.truncatingRemainder(dividingBy: 1.1) / 1.1
    }

    private func axisRange() -> (lower: Double, upper: Double, step: Double) {
        let speeds = samples.map { max(0, $0.speed) }
        guard let maxSpeed = speeds.max(), let minSpeed = speeds.min() else {
            return (0, 1_048_576, 262_144)
        }
        let rawSpan = max(maxSpeed - minSpeed, maxSpeed * 0.12, 1)
        let step = niceStep(rawSpan / 4)
        let lower = floor(max(0, minSpeed - rawSpan * 0.15) / step) * step
        let upper = max(ceil((maxSpeed + rawSpan * 0.15) / step) * step, lower + step * 4)
        return (lower, upper, step)
    }

    private func niceStep(_ value: Double) -> Double {
        let exponent = floor(log10(max(value, 1)))
        let base = pow(10, exponent)
        let normalized = value / base
        let nice: Double
        if normalized <= 1 {
            nice = 1
        } else if normalized <= 2 {
            nice = 2
        } else if normalized <= 5 {
            nice = 5
        } else {
            nice = 10
        }
        return nice * base
    }

    private func makePoints(plot: CGRect, range: (lower: Double, upper: Double, step: Double)) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
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

        return picked.map { sample in
            let fraction = max(0, min(1, Double(sample.bytes) / denominator))
            let x = plot.minX + plot.width * CGFloat(fraction)
            let ratio = CGFloat(max(0, min(1, (max(0, sample.speed) - range.lower) / (range.upper - range.lower))))
            let y = plot.maxY - plot.height * ratio
            return CGPoint(x: x, y: y)
        }
    }

    private func drawHUD(_ context: inout GraphicsContext, plot: CGRect,
                         stats: Stats, hasData: Bool) {
        let title: Text
        if hasData {
            title = Text("现 \(speedText(stats.current))  均 \(speedText(stats.average))  峰 \(speedText(stats.peak))")
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        } else {
            title = Text("download_waiting_sample".localized)
                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
        }
        context.draw(title, at: CGPoint(x: plot.minX, y: 2), anchor: .topLeading)

        let detail: Text
        if hasData {
            let remaining = DownloadByteFormatter.file.string(fromByteCount: max(0, stats.remainingBytes))
            detail = Text(String(format: "chart_hud_detail".localized, remaining, elapsedText(stats.elapsed)))
                .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.75))
        } else {
            detail = Text(" ")
                .font(.system(size: 6.5))
        }
        context.draw(detail, at: CGPoint(x: plot.minX, y: 12), anchor: .topLeading)

        let arrow = stats.current >= stats.average ? "↑" : "↓"
        let arrowText = Text(arrow)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(stats.current >= stats.average
                             ? Color(red: 0.20, green: 0.72, blue: 0.45)
                             : Color(red: 0.92, green: 0.35, blue: 0.35))
        context.draw(arrowText, at: CGPoint(x: plot.maxX, y: 1), anchor: .topTrailing)
    }

    private func drawAxes(_ context: inout GraphicsContext, plot: CGRect,
                          range: (lower: Double, upper: Double, step: Double), hasCurve: Bool) {
        var axes = Path()
        axes.move(to: CGPoint(x: plot.minX, y: plot.minY))
        axes.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        axes.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        context.stroke(axes, with: .color(Color.primary.opacity(0.20)), lineWidth: 0.7)

        var grid = Path()
        var value = range.lower
        var count = 0
        while value <= range.upper + range.step * 0.001 && count < 7 {
            let ratio = CGFloat(max(0, min(1, (value - range.lower) / (range.upper - range.lower))))
            let y = plot.maxY - plot.height * ratio
            grid.move(to: CGPoint(x: plot.minX, y: y))
            grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            let label = Text(axisSpeedText(value))
                .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            context.draw(label, at: CGPoint(x: plot.minX - 3, y: y), anchor: .trailing)
            value += range.step
            count += 1
        }
        context.stroke(grid, with: .color(Color.primary.opacity(0.07)),
                       style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))

        guard hasCurve else { return }

        let fractions: [Double] = plot.width < 280 ? [0, 1.0 / 3.0, 2.0 / 3.0, 1] : [0, 0.25, 0.5, 0.75, 1]
        var vertical = Path()
        for fraction in fractions {
            let x = plot.minX + plot.width * CGFloat(lastFraction * fraction)
            vertical.move(to: CGPoint(x: x, y: plot.minY))
            vertical.addLine(to: CGPoint(x: x, y: plot.maxY))

            let anchor: UnitPoint = fraction == 0 ? .topLeading : (fraction == 1 ? .topTrailing : .top)
            let label = Text(elapsedLabel(at: fraction))
                .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
            context.draw(label, at: CGPoint(x: x, y: plot.maxY + 3), anchor: anchor)
        }
        context.stroke(vertical, with: .color(Color.primary.opacity(0.06)),
                       style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
    }

    private func drawAverageLine(_ context: inout GraphicsContext, plot: CGRect,
                                 range: (lower: Double, upper: Double, step: Double), stats: Stats) {
        guard stats.average > 0 else { return }
        let ratio = CGFloat(max(0, min(1, (stats.average - range.lower) / (range.upper - range.lower))))
        let y = plot.maxY - plot.height * ratio
        var line = Path()
        line.move(to: CGPoint(x: plot.minX, y: y))
        line.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(line, with: .color(color.opacity(0.30)),
                       style: StrokeStyle(lineWidth: 0.7, dash: [4, 3]))

        let label = Text("均 \(axisSpeedText(stats.average))")
            .font(.system(size: 6.5, weight: .medium, design: .monospaced))
            .foregroundColor(color.opacity(0.75))
        context.draw(label, at: CGPoint(x: plot.maxX - 1, y: y - 1), anchor: .bottomTrailing)
    }

    private func drawIdle(_ context: inout GraphicsContext, plot: CGRect) {
        var path = Path()
        let y = plot.midY
        path.move(to: CGPoint(x: plot.minX, y: y))
        path.addLine(to: CGPoint(x: plot.maxX, y: y))
        context.stroke(path, with: .color(color.opacity(0.30)),
                       style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [3, 3]))
    }

    private func drawArea(_ context: inout GraphicsContext, plot: CGRect, points: [CGPoint]) {
        var area = tracePath(points)
        guard let first = points.first, let last = points.last else { return }
        area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
        area.addLine(to: CGPoint(x: first.x, y: plot.maxY))
        area.closeSubpath()
        context.fill(
            area,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.22), color.opacity(0.0)]),
                startPoint: CGPoint(x: 0, y: plot.minY),
                endPoint: CGPoint(x: 0, y: plot.maxY)
            )
        )
    }

    private func drawTrace(_ context: inout GraphicsContext, points: [CGPoint]) {
        let path = tracePath(points)
        var glow = context
        glow.addFilter(.shadow(color: color.opacity(0.55), radius: 3))
        glow.stroke(path, with: .color(color.opacity(0.30)),
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        glow.stroke(path, with: .color(color),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private func drawNodes(_ context: inout GraphicsContext, points: [CGPoint]) {
        let radius: CGFloat = points.count > 240 ? 1.0 : 1.2
        for point in points {
            let dot = CGRect(x: point.x - radius, y: point.y - radius,
                             width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.95)))
        }
    }

    private func drawPeak(_ context: inout GraphicsContext, plot: CGRect,
                          range: (lower: Double, upper: Double, step: Double), stats: Stats) {
        guard stats.peak > 0 else { return }
        let x = plot.minX + plot.width * CGFloat(stats.peakFraction)
        let ratio = CGFloat(max(0, min(1, (stats.peak - range.lower) / (range.upper - range.lower))))
        let y = plot.maxY - plot.height * ratio
        let ring = CGRect(x: x - 2.6, y: y - 2.6, width: 5.2, height: 5.2)
        context.stroke(Path(ellipseIn: ring), with: .color(color.opacity(0.85)), lineWidth: 1)
        let label = Text(axisSpeedText(stats.peak))
            .font(.system(size: 6, weight: .semibold, design: .monospaced))
            .foregroundColor(color.opacity(0.85))
        context.draw(label, at: CGPoint(x: x, y: max(plot.minY + 6, y - 4)), anchor: .bottom)
    }

    private func drawHead(_ context: inout GraphicsContext, plot: CGRect,
                          points: [CGPoint], pulse: Double) {
        guard let last = points.last else { return }

        var dashed = Path()
        dashed.move(to: CGPoint(x: last.x, y: plot.minY))
        dashed.addLine(to: CGPoint(x: last.x, y: plot.maxY))
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

    private func elapsedLabel(at fraction: Double) -> String {
        guard let first = samples.first, let last = samples.last, fraction > 0 else { return "0:00" }
        let target = first.bytes + Int64(Double(last.bytes - first.bytes) * fraction)
        let nearest = samples.min { abs($0.bytes - target) < abs($1.bytes - target) }
        return elapsedText(max(0, (nearest?.time ?? first.time) - first.time))
    }

    private func elapsedText(_ seconds: Double) -> String {
        let value = Int(max(0, seconds).rounded())
        if value >= 3600 {
            return String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
        }
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    private func speedText(_ value: Double) -> String {
        axisSpeedText(value) + "/s"
    }

    private func axisSpeedText(_ value: Double) -> String {
        if value >= 1_048_576 {
            return String(format: "%.1fM", value / 1_048_576)
        }
        if value >= 1024 {
            return String(format: "%.0fK", value / 1024)
        }
        return String(format: "%.0fB", value)
    }
}
