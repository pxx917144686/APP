import SwiftUI
import WidgetKit

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
        Link(destination: URL(string: "bambooapp://tab?name=\(tab)")!) {
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
