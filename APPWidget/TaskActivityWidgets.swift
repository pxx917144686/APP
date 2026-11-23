import ActivityKit
import SwiftUI
import WidgetKit

struct DecryptActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DecryptActivityAttributes.self) { context in
            DecryptLockCard(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            let keyEncoded = context.attributes.taskKey
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        DecryptBadge(status: state.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(state.step)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.status == "done" ? "✓" : "\(state.entryCount)")
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(decryptTint(status: state.status))
                        Text("项")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Link(destination: URL(string: "appisland://tab?name=decrypt")!) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(decryptTint(status: state.status))

                        if state.status == "running" {
                            Link(destination: URL(string: "appisland://cancel?key=\(keyEncoded)")!) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 15, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 30)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "lock.open.laptopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(decryptTint(status: state.status))
            } compactTrailing: {
                Text(state.status == "done" ? "✓" : "\(state.entryCount)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(decryptTint(status: state.status))
            } minimal: {
                Image(systemName: state.status == "done" ? "checkmark" : "lock.open")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(decryptTint(status: state.status))
            }
            .widgetURL(URL(string: "appisland://tab?name=decrypt"))
            .keylineTint(decryptTint(status: state.status))
        }
    }
}

struct InstallActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InstallActivityAttributes.self) { context in
            InstallLockCard(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        InstallBadge(status: state.status)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(state.step)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: installSymbol(status: state.status))
                        .font(.title3)
                        .foregroundStyle(installTint(status: state.status))
                }

                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Link(destination: URL(string: "appisland://tab?name=downloads")!) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(installTint(status: state.status))
                    }
                }
            } compactLeading: {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(installTint(status: state.status))
            } compactTrailing: {
                Image(systemName: installSymbol(status: state.status))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(installTint(status: state.status))
            } minimal: {
                Image(systemName: installSymbol(status: state.status))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(installTint(status: state.status))
            }
            .widgetURL(URL(string: "appisland://tab?name=downloads"))
            .keylineTint(installTint(status: state.status))
        }
    }
}

struct QuickLaunchWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "QuickLaunchWidget", provider: QuickLaunchProvider()) { _ in
            QuickLaunchView()
                .modifier(WidgetSurface())
        }
        .configurationDisplayName("快捷启动")
        .description("一键进入下载、签名、解密、搜索")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct QuickLaunchEntry: TimelineEntry {
    let date: Date
}

private struct QuickLaunchProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickLaunchEntry {
        QuickLaunchEntry(date: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (QuickLaunchEntry) -> Void) {
        completion(QuickLaunchEntry(date: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickLaunchEntry>) -> Void) {
        completion(Timeline(entries: [QuickLaunchEntry(date: Date())], policy: .never))
    }
}

private struct QuickLaunchView: View {
    @Environment(\.widgetFamily) private var family

    private let actions: [(String, String, String)] = [
        ("arrow.down.to.line", "下载", "downloads"),
        ("signature", "签名", "sign"),
        ("lock.open", "解密", "decrypt"),
        ("magnifyingglass", "搜索", "search")
    ]

    var body: some View {
        if family == .systemSmall {
            VStack(spacing: 8) {
                ForEach(actions.prefix(2), id: \.2) { icon, title, tab in
                    tile(icon: icon, title: title, tab: tab)
                }
            }
            .padding(12)
        } else {
            HStack(spacing: 10) {
                ForEach(actions, id: \.2) { icon, title, tab in
                    tile(icon: icon, title: title, tab: tab)
                }
            }
            .padding(12)
        }
    }

    private func tile(icon: String, title: String, tab: String) -> some View {
        Link(destination: URL(string: "appisland://tab?name=\(tab)")!) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(.primary)
        }
    }
}

private struct WidgetSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOSApplicationExtension 17.0, *) {
            content.containerBackground(for: .widget) {
                Color(uiColor: .secondarySystemBackground)
            }
        } else {
            content.background(Color(uiColor: .secondarySystemBackground))
        }
    }
}

private struct DecryptBadge: View {
    let status: String

    var body: some View {
        ZStack {
            Circle()
                .fill(decryptTint(status: status).opacity(0.22))
                .frame(width: 20, height: 20)
            Image(systemName: "lock.open.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(decryptTint(status: status))
        }
    }
}

private struct InstallBadge: View {
    let status: String

    var body: some View {
        ZStack {
            Circle()
                .fill(installTint(status: status).opacity(0.22))
                .frame(width: 20, height: 20)
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(installTint(status: status))
        }
    }
}

private struct DecryptLockCard: View {
    let state: DecryptActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                DecryptBadge(status: state.status)
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(state.status == "done" ? "✓" : "\(state.entryCount)")
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            ProgressView()
                .progressViewStyle(.linear)
                .tint(decryptTint(status: state.status))
            HStack(spacing: 4) {
                Image(systemName: "gearshape.2")
                    .font(.caption2)
                Text(state.step)
                Spacer()
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private struct InstallLockCard: View {
    let state: InstallActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                InstallBadge(status: state.status)
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Image(systemName: installSymbol(status: state.status))
                    .font(.title3)
                    .foregroundStyle(installTint(status: state.status))
            }
            HStack(spacing: 4) {
                Text(state.step)
                Spacer()
                if !state.detail.isEmpty {
                    Text(state.detail)
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private func decryptTint(status: String) -> Color {
    switch status {
    case "done": return .green
    case "failed": return .red
    case "cancelled": return .gray
    default: return .teal
    }
}

private func installTint(status: String) -> Color {
    switch status {
    case "done": return .green
    case "failed": return .red
    default: return .indigo
    }
}

private func installSymbol(status: String) -> String {
    switch status {
    case "done": return "checkmark.circle.fill"
    case "failed": return "exclamationmark.circle.fill"
    default: return "arrow.up.forward.app"
    }
}
