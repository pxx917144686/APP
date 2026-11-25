import SwiftUI
import WidgetKit

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
