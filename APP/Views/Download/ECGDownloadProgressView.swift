import SwiftUI

struct ECGDownloadProgressView: View {
    let progress: Double
    let status: DownloadStatus
    let error: String?
    let accentColor: Color

    @State private var phase: CGFloat = 0
    @State private var waveformOffset: CGFloat = 0
    @State private var heartbeatTimer: Timer?

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

                if status != .failed && status != .cancelled {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(waveformColor)
                        .monospacedDigit()
                }
            }

            ZStack {
                ECGGridView(lineColor: waveformColor.opacity(0.15), majorLineColor: waveformColor.opacity(0.3))

                ECGWaveformView(
                    progress: progress,
                    color: waveformColor,
                    isActive: isActive,
                    phase: phase
                )
                .mask(
                    GeometryReader { geometry in
                        Rectangle()
                            .size(width: geometry.size.width * CGFloat(max(0, min(1, progress))), height: geometry.size.height)
                    }
                )

                if progress > 0 && progress < 1 {
                    GeometryReader { geometry in
                        Circle()
                            .fill(waveformColor)
                            .frame(width: 8, height: 8)
                            .shadow(color: waveformColor.opacity(0.8), radius: 4, x: 0, y: 0)
                            .offset(x: geometry.size.width * CGFloat(progress) - 4, y: geometry.size.height / 2 - 4)
                    }
                }
            }
            .frame(height: 50)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(waveformColor.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(waveformColor.opacity(0.2), lineWidth: 1)
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
        .onAppear {
            if isActive {
                startHeartbeatAnimation()
            }
        }
        .onDisappear {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
        }
        .onChange(of: isActive) { _, newValue in
            if newValue {
                startHeartbeatAnimation()
            } else {
                stopHeartbeatAnimation()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: progress)
    }

    private func startHeartbeatAnimation() {
        guard heartbeatTimer == nil else { return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            withAnimation(.linear(duration: 0.05)) {
                phase += 0.15
            }
        }
    }

    private func stopHeartbeatAnimation() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
    }
}

struct ECGGridView: View {
    let lineColor: Color
    let majorLineColor: Color
    let smallGridSize: CGFloat = 10
    private var largeGridSize: CGFloat { smallGridSize * 5 }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            Path { path in
                for x in stride(from: 0, through: width, by: smallGridSize) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                }
                for y in stride(from: 0, through: height, by: smallGridSize) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(lineColor, lineWidth: 0.5)

            Path { path in
                for x in stride(from: 0, through: width, by: largeGridSize) {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))
                }
                for y in stride(from: 0, through: height, by: largeGridSize) {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(majorLineColor, lineWidth: 1)
        }
    }
}

struct ECGWaveformView: View {
    let progress: Double
    let color: Color
    let isActive: Bool
    let phase: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let width: CGFloat = geometry.size.width
            let height: CGFloat = geometry.size.height
            let midY: CGFloat = height / 2

            Path { path in
                let pointCount: Int = Int(width / 2)
                var points: [CGPoint] = []

                for i in 0...pointCount {
                    let x: CGFloat = CGFloat(i) * 2
                    let normalizedX: CGFloat = x / width

                    let baseWave: CGFloat = sin(normalizedX * .pi * 20 + phase) * 3

                    let heartbeatValue: CGFloat = generateHeartbeat(at: normalizedX, phase: phase)
                    let heartbeat: CGFloat = heartbeatValue * (isActive ? 15 : 5)

                    let extraWave: CGFloat = isActive ? sin(normalizedX * .pi * 8 + phase * 2) * 2 : 0

                    let y: CGFloat = midY + baseWave + heartbeat + extraWave
                    points.append(CGPoint(x: x, y: y))
                }

                if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

            Path { path in
                let pointCount: Int = Int(width / 2)
                var points: [CGPoint] = []

                for i in 0...pointCount {
                    let x: CGFloat = CGFloat(i) * 2
                    let normalizedX: CGFloat = x / width

                    let baseWave: CGFloat = sin(normalizedX * .pi * 20 + phase) * 3

                    let heartbeatValue: CGFloat = generateHeartbeat(at: normalizedX, phase: phase)
                    let heartbeat: CGFloat = heartbeatValue * (isActive ? 15 : 5)

                    let extraWave: CGFloat = isActive ? sin(normalizedX * .pi * 8 + phase * 2) * 2 : 0

                    let y: CGFloat = midY + baseWave + heartbeat + extraWave
                    points.append(CGPoint(x: x, y: y))
                }

                if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                    path.addLine(to: CGPoint(x: width, y: height))
                    path.addLine(to: CGPoint(x: 0, y: height))
                    path.closeSubpath()
                }
            }
            .fill(
                LinearGradient(
                    colors: [
                        color.opacity(0.3),
                        color.opacity(0.05)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private func generateHeartbeat(at position: CGFloat, phase: CGFloat) -> CGFloat {
        let cycleLength: CGFloat = 0.15
        let adjustedPhase: CGFloat = phase / 10
        let totalPos: CGFloat = position + adjustedPhase
        var relativePos: CGFloat = totalPos.truncatingRemainder(dividingBy: cycleLength)
        if relativePos < 0 {
            relativePos += cycleLength
        }
        relativePos = relativePos / cycleLength

        var pWave: CGFloat = 0
        let pDist: CGFloat = abs(relativePos - 0.1)
        if pDist < 0.05 {
            pWave = (1 - pDist / 0.05) * 0.3
        }

        var qWave: CGFloat = 0
        let qDist: CGFloat = abs(relativePos - 0.3)
        if qDist < 0.03 {
            qWave = -(1 - qDist / 0.03) * 0.2
        }

        var rWave: CGFloat = 0
        let rDist: CGFloat = abs(relativePos - 0.35)
        if rDist < 0.04 {
            rWave = (1 - rDist / 0.04) * 1.0
        }

        var sWave: CGFloat = 0
        let sDist: CGFloat = abs(relativePos - 0.42)
        if sDist < 0.03 {
            sWave = -(1 - sDist / 0.03) * 0.3
        }

        var tWave: CGFloat = 0
        let tDist: CGFloat = abs(relativePos - 0.6)
        if tDist < 0.08 {
            tWave = (1 - tDist / 0.08) * 0.4
        }

        let result: CGFloat = pWave + qWave + rWave + sWave + tWave
        return result
    }

    private func adjustedPosition(_ position: CGFloat) -> CGFloat {
        position
    }
}
