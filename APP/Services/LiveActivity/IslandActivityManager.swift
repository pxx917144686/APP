import ActivityKit
import Foundation
import os

@MainActor
final class IslandActivityManager {
    static let shared = IslandActivityManager()

    private var activities: [String: Activity<IslandAttributes>] = [:]
    private var lastPercent: [String: Int] = [:]
    private var lastPhase: [String: String] = [:]
    private var lastStatus: [String: String] = [:]
    private var lastUpdateAt: [String: Date] = [:]
    private var observers: [String: Task<Void, Never>] = [:]
    private var dismissed: Set<String> = []
    private var loggedDisabled = false

    private let log = Logger(subsystem: "com.pxx917144686.App", category: "island")

    private init() {
        endDuplicateActivities()
        adoptExistingActivities()
        endDisabledActivities()
        NotificationCenter.default.addObserver(
            forName: .islandSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endDisabledActivities()
            }
        }
    }

    private func endDisabledActivities() {
        for (key, activity) in Array(activities) where !IslandSettings.shared.isVisible(activity.attributes.kind) {
            end(key: key, removeSnapshot: false)
        }
    }

    var isAuthorized: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func hasActivity(key: String) -> Bool {
        activities[key] != nil || Activity<IslandAttributes>.activities.contains { $0.attributes.taskKey == key }
    }

    private func resolve(_ key: String) -> Activity<IslandAttributes>? {
        if let activity = activities[key] { return activity }
        guard let existing = Activity<IslandAttributes>.activities.first(where: { $0.attributes.taskKey == key }) else {
            return nil
        }
        store(existing, key: key, state: existing.content.state)
        observeEnd(for: key, activity: existing)
        return existing
    }

    func start(
        key: String,
        kind: String,
        title: String,
        phase: String,
        detail: String = "",
        progress: Double = 0,
        remaining: String = "",
        status: String = "running"
    ) {
        guard isAuthorized else {
            if !loggedDisabled {
                loggedDisabled = true
                log.notice("live activities disabled by system")
            }
            return
        }
        loggedDisabled = false
        guard !dismissed.contains(key) else { return }
        guard IslandSettings.shared.isVisible(kind) else { return }

        if resolve(key) != nil {
            update(
                key: key,
                phase: phase,
                detail: detail,
                progress: progress,
                remaining: remaining,
                status: status
            )
            return
        }

        let attributes = IslandAttributes(kind: kind, startedAt: Date(), taskKey: key)
        let state = IslandAttributes.ContentState(
            title: title,
            phase: phase,
            detail: detail,
            progress: clamp(progress),
            remaining: remaining,
            status: status,
            staleDate: nil
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: staleDate(for: status)),
                pushType: nil
            )
            store(activity, key: key, state: state)
            log.notice("island start \(key, privacy: .public) \(phase, privacy: .public)")
            TaskSnapshotStore.upsert(
                key: key,
                title: title,
                kind: kind,
                phase: phase,
                progress: clamp(progress),
                status: status
            )
            observeEnd(for: key, activity: activity)
        } catch {
            log.error("start failed \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(
        key: String,
        phase: String,
        detail: String = "",
        progress: Double,
        remaining: String = "",
        status: String = "running"
    ) {
        guard let activity = resolve(key) else { return }

        let percent = Int((clamp(progress) * 100).rounded())
        let phaseChanged = lastPhase[key] != phase
        let statusChanged = lastStatus[key] != status
        guard phaseChanged || statusChanged || percent != lastPercent[key] else { return }
        if !phaseChanged, !statusChanged,
           let last = lastUpdateAt[key], Date().timeIntervalSince(last) < 0.9 {
            return
        }

        log.debug("island update \(key, privacy: .public) \(percent) \(status, privacy: .public) \(phase, privacy: .public)")
        lastPhase[key] = phase
        lastStatus[key] = status
        lastPercent[key] = percent
        lastUpdateAt[key] = Date()

        let state = IslandAttributes.ContentState(
            title: activity.content.state.title,
            phase: phase,
            detail: detail,
            progress: clamp(progress),
            remaining: remaining,
            status: status,
            staleDate: nil
        )
        TaskSnapshotStore.upsert(
            key: key,
            title: state.title,
            kind: activity.attributes.kind,
            phase: phase,
            progress: clamp(progress),
            status: status
        )
        Task { @MainActor in
            await activity.update(ActivityContent(state: state, staleDate: staleDate(for: status)))
        }
    }

    func allowRecreate(key: String) {
        dismissed.remove(key)
    }

    func finish(key: String, detail: String = "") {
        guard let activity = resolve(key) else { return }
        dismissed.remove(key)
        log.notice("island finish \(key, privacy: .public)")

        let state = IslandAttributes.ContentState(
            title: activity.content.state.title,
            phase: "download_completed".localized,
            detail: detail,
            progress: 1,
            remaining: "",
            status: "done",
            staleDate: nil
        )
        lastStatus[key] = "done"
        lastPercent[key] = 100
        lastPhase[key] = state.phase
        TaskSnapshotStore.upsert(
            key: key,
            title: state.title,
            kind: activity.attributes.kind,
            phase: state.phase,
            progress: 1,
            status: "done"
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(20))
        Task { @MainActor in
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(8)))
            self.forget(key: key)
        }
    }

    func fail(key: String, reason: String, cancelled: Bool = false) {
        guard let activity = resolve(key) else { return }
        dismissed.remove(key)
        log.notice("island fail \(key, privacy: .public) cancelled=\(cancelled)")

        let state = IslandAttributes.ContentState(
            title: activity.content.state.title,
            phase: (cancelled ? "decrypt_state_cancelled" : "failed").localized,
            detail: reason,
            progress: activity.content.state.progress,
            remaining: "",
            status: cancelled ? "cancelled" : "failed",
            staleDate: nil
        )
        lastStatus[key] = state.status
        lastPhase[key] = state.phase
        TaskSnapshotStore.upsert(
            key: key,
            title: state.title,
            kind: activity.attributes.kind,
            phase: state.phase,
            progress: activity.content.state.progress,
            status: state.status
        )
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(20))
        Task { @MainActor in
            await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(6)))
            self.forget(key: key)
        }
    }

    func end(key: String, removeSnapshot: Bool = false) {
        dismissed.remove(key)
        observers.removeValue(forKey: key)?.cancel()
        lastPercent.removeValue(forKey: key)
        lastPhase.removeValue(forKey: key)
        lastStatus.removeValue(forKey: key)
        lastUpdateAt.removeValue(forKey: key)
        if removeSnapshot {
            TaskSnapshotStore.remove(key: key)
        }
        let activity = activities.removeValue(forKey: key)
            ?? Activity<IslandAttributes>.activities.first(where: { $0.attributes.taskKey == key })
        guard let activity else { return }
        Task { @MainActor in
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    func endAll(removeSnapshots: Bool = false) {
        for key in Array(activities.keys) {
            end(key: key, removeSnapshot: removeSnapshots)
        }
    }

    private func endDuplicateActivities() {
        var newest: [String: Activity<IslandAttributes>] = [:]
        for activity in Activity<IslandAttributes>.activities {
            let key = activity.attributes.taskKey
            guard !key.isEmpty else { continue }
            guard let current = newest[key] else {
                newest[key] = activity
                continue
            }
            let currentIsNewer = current.attributes.startedAt >= activity.attributes.startedAt
            let keep = currentIsNewer ? current : activity
            let drop = currentIsNewer ? activity : current
            newest[key] = keep
            Task { @MainActor in
                await drop.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func endOrphanedDownloadActivities(validKeys: Set<String>) {
        for key in Array(activities.keys) where key.hasPrefix("download-") && !validKeys.contains(key) {
            end(key: key, removeSnapshot: true)
        }
    }

    private func adoptExistingActivities() {
        for activity in Activity<IslandAttributes>.activities {
            let key = activity.attributes.taskKey
            guard !key.isEmpty, activities[key] == nil else { continue }
            guard !activity.content.state.isFinished,
                  IslandSettings.shared.isVisible(activity.attributes.kind) else {
                Task { @MainActor in
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                continue
            }
            store(activity, key: key, state: activity.content.state)
            observeEnd(for: key, activity: activity)
        }
    }

    private func store(_ activity: Activity<IslandAttributes>, key: String, state: IslandAttributes.ContentState) {
        activities[key] = activity
        lastPercent[key] = Int((clamp(state.progress) * 100).rounded())
        lastPhase[key] = state.phase
        lastStatus[key] = state.status
        lastUpdateAt[key] = Date()
    }

    private func observeEnd(for key: String, activity: Activity<IslandAttributes>) {
        observers[key]?.cancel()
        observers[key] = Task { @MainActor [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                guard let self, self.activities[key] != nil else { return }
                if state == .dismissed {
                    self.dismissed.insert(key)
                }
                self.forget(key: key)
                return
            }
        }
    }

    private func forget(key: String) {
        activities.removeValue(forKey: key)
        lastPercent.removeValue(forKey: key)
        lastPhase.removeValue(forKey: key)
        lastStatus.removeValue(forKey: key)
        lastUpdateAt.removeValue(forKey: key)
        observers.removeValue(forKey: key)?.cancel()
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func staleDate(for status: String) -> Date {
        status == "running" ? Date().addingTimeInterval(5 * 60) : Date().addingTimeInterval(10)
    }
}
