import Foundation

@MainActor
final class AnalyticsManager {
    static let shared = AnalyticsManager()

    private var eventQueue: [[String: Any]] = []
    private let flushInterval: TimeInterval = 30
    private var flushTimer: Timer?
    private var isEnabled = true

    private var providers: [AnalyticsProvider] = []

    private init() {
        startFlushTimer()
    }

    func addProvider(_ provider: AnalyticsProvider) {
        providers.append(provider)
    }

    func removeAllProviders() {
        providers.removeAll()
    }

    func track(_ event: String, properties: [String: Any] = [:]) {
        guard isEnabled else { return }

        var eventData: [String: Any] = [
            "event": event,
            "timestamp": Date().timeIntervalSince1970,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        ]

        for (key, value) in properties {
            eventData[key] = value
        }

        eventQueue.append(eventData)

        providers.forEach { $0.track(event, properties: properties) }

        if eventQueue.count >= 20 {
            flush()
        }
    }

    func trackScreen(_ screenName: String, properties: [String: Any] = [:]) {
        var props = properties
        props["screen_name"] = screenName
        track("screen_view", properties: props)
    }

    func trackClick(element: String, properties: [String: Any] = [:]) {
        var props = properties
        props["element"] = element
        track("click", properties: props)
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }

    func flush() {
        guard !eventQueue.isEmpty else { return }

        let events = eventQueue
        eventQueue.removeAll()

        Task {
            for provider in providers {
                try? await provider.flush(events: events)
            }
        }
    }

    private func startFlushTimer() {
        flushTimer = Timer.scheduledTimer(withTimeInterval: flushInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.flush()
            }
        }
    }

    deinit {
        flushTimer?.invalidate()
    }
}

protocol AnalyticsProvider {
    func track(_ event: String, properties: [String: Any])
    func flush(events: [[String: Any]]) async throws
}

final class ConsoleAnalyticsProvider: AnalyticsProvider {
    func track(_ event: String, properties: [String: Any]) {}
    func flush(events: [[String: Any]]) async throws {}
}

final class FileAnalyticsProvider: AnalyticsProvider {
    private let fileURL: URL

    init() {
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documentsDir.appendingPathComponent("analytics.log")
    }

    func track(_ event: String, properties: [String: Any]) {}

    func flush(events: [[String: Any]]) async throws {
        let data = try JSONSerialization.data(withJSONObject: events, options: .prettyPrinted)

        if let existing = try? Data(contentsOf: fileURL) {
            var combined = existing
            combined.append("\n".data(using: .utf8)!)
            combined.append(data)
            try combined.write(to: fileURL)
        } else {
            try data.write(to: fileURL)
        }
    }
}
