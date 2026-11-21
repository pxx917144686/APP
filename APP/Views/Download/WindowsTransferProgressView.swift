import SwiftUI

struct WindowsTransferProgressView: View {
    let progress: Double
    let status: DownloadStatus
    let error: String?
    let accentColor: Color
    let speed: String?
    let completedBytes: Int64
    let totalBytes: Int64
    let remainingTime: TimeInterval
    var isPreview: Bool = false

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

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.75), color],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * CGFloat(max(0, min(1, progress))))
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.white.opacity(0.20))
                                .frame(height: 2)
                                .padding(.horizontal, 2)
                                .padding(.top, 1)
                        }
                        .animation(.linear(duration: 0.25), value: progress)
                }
            }
            .frame(height: 8)

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
}
