import SwiftUI
import WidgetKit

struct TaskStatsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TaskStatsWidget", provider: TaskSnapshotProvider()) { entry in
            TaskStatsView(items: entry.items)
                .modifier(WidgetSurface())
        }
        .configurationDisplayName("任务统计")
        .description("正在运行、已完成、失败的下载与签名任务数量")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryInline])
    }
}

struct RecentTasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "RecentTasksWidget", provider: TaskSnapshotProvider()) { entry in
            RecentTasksView(items: entry.items)
                .modifier(WidgetSurface())
        }
        .configurationDisplayName("最近任务")
        .description("最近处理的下载、签名、解密任务")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}

struct TaskBoardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TaskBoardWidget", provider: TaskSnapshotProvider()) { entry in
            TaskBoardView(items: entry.items)
                .modifier(WidgetSurface())
        }
        .configurationDisplayName("任务面板")
        .description("正在运行的任务进度一览")
        .supportedFamilies([.systemLarge, .systemMedium])
    }
}

private struct TaskSnapshotEntry: TimelineEntry {
    let date: Date
    let items: [TaskSnapshotItem]
}

private struct TaskSnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> TaskSnapshotEntry {
        TaskSnapshotEntry(date: Date(), items: Self.samples)
    }

    func getSnapshot(in context: Context, completion: @escaping (TaskSnapshotEntry) -> Void) {
        completion(TaskSnapshotEntry(date: Date(), items: TaskSnapshotStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TaskSnapshotEntry>) -> Void) {
        let entry = TaskSnapshotEntry(date: Date(), items: TaskSnapshotStore.load())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(60))))
    }

    static let samples: [TaskSnapshotItem] = [
        TaskSnapshotItem(id: "s1", title: "WeChat.ipa", kind: "download",
                         phase: "下载中", progress: 0.42, status: "running",
                         updatedAt: Date()),
        TaskSnapshotItem(id: "s2", title: "TikTok.ipa", kind: "sign",
                         phase: "签名中", progress: 0.74, status: "running",
                         updatedAt: Date())
    ]
}

private struct TaskStatsView: View {
    @Environment(\.widgetFamily) private var family
    let items: [TaskSnapshotItem]

    private var running: Int { items.filter(\.isRunning).count }
    private var done: Int { items.filter { $0.status == "done" }.count }
    private var failed: Int { items.filter { $0.status == "failed" }.count }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: Double(min(running, 9)), in: 0...9) {
                Image(systemName: "bolt.horizontal.fill")
            } currentValueLabel: {
                Text("\(running)")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircular)
        case .accessoryInline:
            Label("\(running) 个任务运行中", systemImage: "bolt.horizontal.fill")
        default:
            regularBody
        }
    }

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text("任务")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.secondary)

            Text("\(running)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .monospacedDigit()

            Text("运行中")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack(spacing: 10) {
                statBadge(count: done, color: .green, symbol: "checkmark")
                statBadge(count: failed, color: .red, symbol: "xmark")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
    }

    private func statBadge(count: Int, color: Color, symbol: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
    }
}

private struct RecentTasksView: View {
    @Environment(\.widgetFamily) private var family
    let items: [TaskSnapshotItem]

    var body: some View {
        if family == .accessoryRectangular {
            accessoryBody
        } else {
            regularBody
        }
    }

    private var accessoryBody: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let first = items.first {
                Text(first.title)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ProgressView(value: first.progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(first.progress * 100))%")
                        .font(.caption2)
                        .monospacedDigit()
                }
                Text("\(items.filter(\.isRunning).count) 个运行中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无任务")
                    .font(.caption)
            }
        }
    }

    private var regularBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                Text("最近任务")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(.secondary)

            if items.isEmpty {
                Spacer()
                Text("暂无任务")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(items.prefix(4)) { item in
                    HStack(spacing: 8) {
                        Image(systemName: taskSymbol(for: item.kind))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(taskTint(for: item.status, kind: item.kind))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            ProgressView(value: item.progress)
                                .progressViewStyle(.linear)
                                .tint(taskTint(for: item.status, kind: item.kind))
                        }
                        Text(item.status == "done" ? "✓" : "\(Int(item.progress * 100))%")
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(taskTint(for: item.status, kind: item.kind))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
    }
}

private struct TaskBoardView: View {
    let items: [TaskSnapshotItem]

    private var running: [TaskSnapshotItem] {
        items.filter(\.isRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text("任务面板")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(running.count)")
                    .font(.system(size: 12, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(.secondary)

            if running.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 24))
                    Text("没有运行中的任务")
                        .font(.system(size: 12))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ForEach(running.prefix(4)) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: taskSymbol(for: item.kind))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(taskTint(for: item.status, kind: item.kind))
                            Text(item.title)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            Text("\(Int(item.progress * 100))%")
                                .font(.system(size: 10, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(taskTint(for: item.status, kind: item.kind))
                        }
                        ProgressView(value: item.progress)
                            .progressViewStyle(.linear)
                            .tint(taskTint(for: item.status, kind: item.kind))
                        Text(item.phase)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(14)
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

private func taskSymbol(for kind: String) -> String {
    switch kind {
    case "sign": return "signature"
    case "decrypt": return "lock.open"
    case "install": return "shippingbox"
    default: return "arrow.down.to.line"
    }
}

private func taskTint(for status: String, kind: String) -> Color {
    switch status {
    case "done": return .green
    case "failed": return .red
    case "cancelled": return .gray
    default: return kind == "sign" ? .purple : .blue
    }
}

struct StorageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StorageWidget", provider: StorageProvider()) { entry in
            StorageView(entry: entry)
                .modifier(WidgetSurface())
        }
        .configurationDisplayName("存储空间")
        .description("设备剩余空间与占用比例")
        .supportedFamilies([.systemSmall, .accessoryCircular])
    }
}

private struct StorageEntry: TimelineEntry {
    let date: Date
    let free: Int64
    let total: Int64
}

private struct StorageProvider: TimelineProvider {
    func placeholder(in context: Context) -> StorageEntry {
        StorageEntry(date: Date(), free: 64_000_000_000, total: 128_000_000_000)
    }

    func getSnapshot(in context: Context, completion: @escaping (StorageEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StorageEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(900))))
    }

    private func current() -> StorageEntry {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
        let total = Int64(values?.volumeTotalCapacity ?? 0)
        return StorageEntry(date: Date(), free: free, total: total)
    }
}

private struct StorageView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StorageEntry

    private var used: Double {
        guard entry.total > 0 else { return 0 }
        return 1 - Double(entry.free) / Double(entry.total)
    }

    var body: some View {
        if family == .accessoryCircular {
            Gauge(value: used, in: 0...1) {
                Image(systemName: "internaldrive.fill")
            } currentValueLabel: {
                Text("\(Int(used * 100))%")
                    .monospacedDigit()
            }
            .gaugeStyle(.accessoryCircular)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("存储")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.secondary)

                Text(ByteCountFormatter.string(fromByteCount: entry.free, countStyle: .file))
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)

                Text("可用")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                ProgressView(value: used)
                    .progressViewStyle(.linear)
                    .tint(used > 0.9 ? .red : .blue)

                Text("已用 \(Int(used * 100))%")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}
