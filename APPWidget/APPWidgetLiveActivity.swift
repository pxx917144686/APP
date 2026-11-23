import ActivityKit
import SwiftUI
import WidgetKit

struct APPWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: IslandAttributes.self) { context in
            Group {
                if context.attributes.kind == "sign" {
                    LockScreenCard(state: context.state, kind: context.attributes.kind)
                } else {
                    PlayerCard(state: context.state, startedAt: context.attributes.startedAt)
                }
            }
            .activityBackgroundTint(Color.black.opacity(0.82))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let kind = context.attributes.kind
            let taskKey = context.attributes.taskKey
            let keyEncoded = taskKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let isPlayer = kind != "sign"

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        if isPlayer {
                            Artwork(size: 34, paused: state.status == "paused")
                        } else {
                            KindBadge(kind: kind, status: state.status)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.title)
                                .font(.headline)
                                .lineLimit(1)
                            HStack(spacing: 4) {
                                StatusIcon(status: state.status)
                                Text(state.detail.isEmpty ? state.phase : state.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if state.status == "done" {
                            TelegramCheckmark(size: 18, color: tint(for: state.status, kind: kind))
                        } else {
                            Text(progressLabel(for: state))
                                .font(.title3.weight(.semibold))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: state.progress))
                                .foregroundStyle(tint(for: state.status, kind: kind))
                        }
                        if !state.remaining.isEmpty {
                            Text(state.remaining)
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.center) {
                    if isPlayer {
                        PlayerProgress(state: state, startedAt: context.attributes.startedAt)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: state.progress)
                        .progressViewStyle(.linear)
                        .tint(tint(for: state.status, kind: kind))
                        .frame(maxWidth: .infinity)
                }

            } compactLeading: {
                if isPlayer {
                    Artwork(size: 18, paused: state.status == "paused")
                } else {
                    HStack(spacing: 4) {
                        KindBadge(kind: kind, status: state.status)
                        Image(systemName: kindSymbol(kind))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            } compactTrailing: {
                if state.status == "done" {
                    TelegramCheckmark(size: 12, color: tint(for: state.status, kind: kind))
                } else {
                    Text(progressLabel(for: state))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: state.progress))
                        .foregroundStyle(tint(for: state.status, kind: kind))
                }
            } minimal: {
                ZStack {
                    ProgressRing(value: state.progress, color: tint(for: state.status, kind: kind))
                    if state.status == "done" {
                        TelegramCheckmark(
                            size: 10,
                            color: tint(for: state.status, kind: kind),
                            lineWidth: 1.5
                        )
                    } else {
                        Image(systemName: kindSymbol(kind))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint(for: state.status, kind: kind))
                    }
                }
            }
            .widgetURL(URL(string: "appisland://detail?key=\(keyEncoded)"))
            .keylineTint(tint(for: state.status, kind: kind))
        }
    }

    private func tint(for status: String, kind: String) -> Color {
        switch status {
        case "done": return .green
        case "failed": return .red
        case "cancelled": return .gray
        case "paused": return .orange
        default: return kind == "sign" ? .purple : .blue
        }
    }

    private func kindSymbol(_ kind: String) -> String {
        kind == "sign" ? "signature" : "arrow.down.to.line"
    }
}

private func progressLabel(for state: IslandAttributes.ContentState) -> String {
    switch state.status {
    case "done": return "✓"
    case "failed": return "!"
    case "cancelled": return "×"
    default: return state.progress <= 0 ? "…" : "\(Int(state.progress * 100))%"
    }
}

private struct Artwork: View {
    var size: CGFloat
    var paused: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.blue, Color.cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: paused ? "pause.fill" : "arrow.down")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

private struct PlayerProgress: View {
    let state: IslandAttributes.ContentState
    let startedAt: Date

    var body: some View {
        HStack {
            Text(startedAt, style: .timer)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Text(state.remaining.isEmpty ? state.phase : state.remaining)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct PlayerCard: View {
    let state: IslandAttributes.ContentState
    let startedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Artwork(size: 52, paused: state.status == "paused")
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(state.detail.isEmpty ? state.phase : state.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if state.status == "done" {
                    TelegramCheckmark(size: 20, color: .green)
                } else {
                    Text(progressLabel(for: state))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: state.progress))
                        .foregroundStyle(state.status == "paused" ? .orange : .blue)
                }
            }
            IslandProgressBar(
                progress: state.progress,
                tint: state.status == "paused" ? .orange : .blue,
                height: 8,
                track: .white.opacity(0.22)
            )
            HStack {
                Text(startedAt, style: .timer)
                    .monospacedDigit()
                Spacer()
                Text(state.remaining.isEmpty ? state.phase : state.remaining)
                    .monospacedDigit()
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private struct StatusIcon: View {
    let status: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
    }

    private var symbol: String {
        switch status {
        case "done": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.circle.fill"
        case "cancelled": return "xmark.circle.fill"
        case "paused": return "pause.circle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var color: Color {
        switch status {
        case "done": return .green
        case "failed": return .red
        case "cancelled": return .gray
        case "paused": return .orange
        default: return .blue
        }
    }
}

private struct KindBadge: View {
    let kind: String
    let status: String

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: 20, height: 20)
            Image(systemName: kind == "sign" ? "signature" : "arrow.down.to.line")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        switch status {
        case "done": return .green
        case "failed": return .red
        case "paused": return .orange
        default: return kind == "sign" ? .purple : .blue
        }
    }
}

private struct ProgressRing: View {
    let value: Double
    let color: Color

    private let lineWidth: CGFloat = 2

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(value, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 24, height: 24)
        .animation(.linear(duration: 0.2), value: value)
    }
}

private struct LockScreenCard: View {
    let state: IslandAttributes.ContentState
    let kind: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                KindBadge(kind: kind, status: state.status)
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if state.status == "done" {
                    TelegramCheckmark(size: 20, color: .green)
                } else {
                    Text(progressLabel(for: state))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: state.progress))
                }
            }
            IslandProgressBar(progress: state.progress, tint: tint, height: 8, track: .white.opacity(0.22))
            HStack(spacing: 4) {
                StatusIcon(status: state.status)
                Text(state.detail)
                Spacer()
                if !state.remaining.isEmpty {
                    Text(state.remaining)
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(14)
    }

    private var tint: Color {
        switch state.status {
        case "done": return .green
        case "failed": return .red
        case "cancelled": return .gray
        case "paused": return .orange
        default: return kind == "sign" ? .purple : .blue
        }
    }
}
