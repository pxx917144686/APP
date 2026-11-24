import SwiftUI
import ActivityKit
import Foundation
import WidgetKit

struct IslandAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var phase: String
        var detail: String
        var progress: Double
        var remaining: String
        var status: String
        var staleDate: Date?

        var isFinished: Bool {
            status != "running"
        }
    }

    var kind: String
    var startedAt: Date
    var taskKey: String
}

struct DecryptActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var step: String
        var detail: String
        var status: String
        var entryCount: Int

        var isFinished: Bool {
            status != "running"
        }
    }

    var startedAt: Date
    var taskKey: String
}

struct InstallActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var title: String
        var step: String
        var detail: String
        var status: String

        var isFinished: Bool {
            status != "running"
        }
    }

    var startedAt: Date
    var taskKey: String
}

func islandDurationString(_ seconds: Int32, position: Int32? = nil) -> String {
    var duration = seconds
    if let position {
        duration = max(0, duration - position)
    }
    let hours = duration / 3600
    let minutes = duration / 60 % 60
    let remaining = duration % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remaining)
    }
    return String(format: "%d:%02d", minutes, remaining)
}

enum IslandTaskKind {
    static let download = "download"
    static let sign = "sign"
    static let decrypt = "decrypt"
    static let install = "install"
}

enum IslandTaskKey {
    static func download(_ id: UUID) -> String { "download-\(id.uuidString)" }
    static func sign(_ id: UUID) -> String { "sign-\(id.uuidString)" }
    static func decrypt(_ id: UUID) -> String { "decrypt-\(id.uuidString)" }
    static func install(_ id: UUID) -> String { "install-\(id.uuidString)" }

    static func id(from key: String, prefix: String) -> UUID? {
        guard key.hasPrefix(prefix + "-") else { return nil }
        return UUID(uuidString: String(key.dropFirst(prefix.count + 1)))
    }
}

struct TaskSnapshotItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var kind: String
    var phase: String
    var progress: Double
    var status: String
    var updatedAt: Date

    var isRunning: Bool {
        status == "running"
    }
}

enum TaskSnapshotStore {
    static let appGroup = "group.b26d9af3ffccda33.1"
    private static let fileName = "task-snapshot.json"
    private static let limit = 20

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    static func load() -> [TaskSnapshotItem] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([TaskSnapshotItem].self, from: data)) ?? []
    }

    static func upsert(
        key: String,
        title: String,
        kind: String,
        phase: String,
        progress: Double,
        status: String
    ) {
        var items = load()
        let item = TaskSnapshotItem(
            id: key,
            title: title,
            kind: kind,
            phase: phase,
            progress: min(max(progress, 0), 1),
            status: status,
            updatedAt: Date()
        )
        if let index = items.firstIndex(where: { $0.id == key }) {
            items[index] = item
        } else {
            items.insert(item, at: 0)
        }
        items.sort { $0.updatedAt > $1.updatedAt }
        if items.count > limit {
            items = Array(items.prefix(limit))
        }
        save(items)
    }

    static func remove(key: String) {
        var items = load()
        items.removeAll { $0.id == key }
        save(items)
    }

    private static func save(_ items: [TaskSnapshotItem]) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: url, options: .atomic)
        reloadIfNeeded()
    }

    private static let reloadLock = NSLock()
    private static var lastReload = Date.distantPast

    private static func reloadIfNeeded() {
        reloadLock.lock()
        let now = Date()
        let shouldReload = now.timeIntervalSince(lastReload) > 5
        if shouldReload { lastReload = now }
        reloadLock.unlock()
        guard shouldReload else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}

struct TelegramCheckmark: View {
    var size: CGFloat
    var color: Color
    var lineWidth: CGFloat?
    var progress: CGFloat = 1

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        CheckmarkShape()
            .trim(from: 0, to: clamped)
            .stroke(
                color,
                style: StrokeStyle(
                    lineWidth: lineWidth ?? max(1.2, size * 0.085),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private struct CheckmarkShape: Shape {
        func path(in rect: CGRect) -> Path {
            let scale = min(rect.width, rect.height) / 18.0
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let start = CGPoint(
                x: center.x - (4.0 - 0.3333) * scale,
                y: center.y + 0.5 * scale
            )
            let first = CGPoint(x: 2.5 * scale, y: 3.0 * scale)
            let second = CGPoint(x: 4.6667 * scale, y: -6.0 * scale)

            var path = Path()
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x + first.x, y: start.y + first.y))
            path.addLine(to: CGPoint(x: start.x + first.x + second.x, y: start.y + first.y + second.y))
            return path
        }
    }
}

struct IslandProgressBar: View {
    let progress: Double
    let tint: Color
    var height: CGFloat = 8
    var track: Color = Color.primary.opacity(0.08)

    private var fraction: CGFloat {
        CGFloat(min(max(progress, 0), 1))
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule(style: .continuous)
                .fill(track)

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.75), tint],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay(alignment: .top) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.20))
                        .frame(height: 2)
                        .padding(.horizontal, 2)
                        .padding(.top, 1)
                }
                .scaleEffect(x: max(0.0001, fraction), anchor: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .animation(.linear(duration: 0.25), value: progress)
        .accessibilityHidden(true)
    }
}
