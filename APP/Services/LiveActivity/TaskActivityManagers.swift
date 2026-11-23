import ActivityKit
import Foundation
import os

@MainActor
final class DecryptActivityManager {
    static let shared = DecryptActivityManager()

    private var activities: [String: Activity<DecryptActivityAttributes>] = [:]
    private var lastSteps: [String: String] = [:]
    private var lastCounts: [String: Int] = [:]
    private var observers: [String: Task<Void, Never>] = [:]

    private let log = Logger(subsystem: "com.pxx917144686.App", category: "island")

    private init() {
        for activity in Activity<DecryptActivityAttributes>.activities {
            let key = activity.attributes.taskKey
            guard !key.isEmpty, activities[key] == nil else { continue }
            activities[key] = activity
            lastSteps[key] = activity.content.state.step
            lastCounts[key] = activity.content.state.entryCount
            observeEnd(for: key, activity: activity)
        }
        NotificationCenter.default.addObserver(
            forName: .islandSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endDisabledActivities()
            }
        }
        endDisabledActivities()
    }

    private func endDisabledActivities() {
        guard !IslandSettings.shared.isVisible(IslandTaskKind.decrypt) else { return }
        for key in Array(activities.keys) {
            end(key: key)
        }
    }

    func start(key: String, title: String, step: String, detail: String = "") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              IslandSettings.shared.isVisible(IslandTaskKind.decrypt) else { return }
        if activities[key] != nil {
            update(key: key, step: step, detail: detail)
            return
        }

        let attributes = DecryptActivityAttributes(startedAt: Date(), taskKey: key)
        let state = DecryptActivityAttributes.ContentState(
            title: title,
            step: step,
            detail: detail,
            status: "running",
            entryCount: 0
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(600)),
                pushType: nil
            )
            activities[key] = activity
            lastSteps[key] = step
            lastCounts[key] = 0
            TaskSnapshotStore.upsert(
                key: key,
                title: title,
                kind: IslandTaskKind.decrypt,
                phase: step,
                progress: 0,
                status: "running"
            )
            observeEnd(for: key, activity: activity)
        } catch {
            log.error("decrypt start failed \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(key: String, step: String, detail: String = "", entryCount: Int? = nil) {
        guard let activity = activities[key] else { return }
        let count = entryCount ?? activity.content.state.entryCount
        guard lastSteps[key] != step || lastCounts[key] != count || !detail.isEmpty else { return }
        lastSteps[key] = step
        lastCounts[key] = count

        let state = DecryptActivityAttributes.ContentState(
            title: activity.content.state.title,
            step: step,
            detail: detail,
            status: "running",
            entryCount: count
        )
        TaskSnapshotStore.upsert(
            key: key,
            title: state.title,
            kind: IslandTaskKind.decrypt,
            phase: step,
            progress: 0,
            status: "running"
        )
        Task { @MainActor in
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(600)))
        }
    }

    func finish(key: String, detail: String = "") {
        guard let activity = activities[key] else { return }
        let state = DecryptActivityAttributes.ContentState(
            title: activity.content.state.title,
            step: "decrypt_state_completed".localized,
            detail: detail,
            status: "done",
            entryCount: activity.content.state.entryCount
        )
        TaskSnapshotStore.upsert(
            key: key,
            title: state.title,
            kind: IslandTaskKind.decrypt,
            phase: state.step,
            progress: 1,
            status: "done"
        )
        Task { @MainActor in
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10)))
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self.end(key: key)
        }
    }

    func fail(key: String, reason: String, cancelled: Bool = false) {
        guard let activity = activities[key] else { return }
        let state = DecryptActivityAttributes.ContentState(
            title: activity.content.state.title,
            step: (cancelled ? "decrypt_state_cancelled" : "decrypt_state_failed").localized,
            detail: reason,
            status: cancelled ? "cancelled" : "failed",
            entryCount: activity.content.state.entryCount
        )
        TaskSnapshotStore.upsert(
            key: key,
            title: state.title,
            kind: IslandTaskKind.decrypt,
            phase: state.step,
            progress: 0,
            status: state.status
        )
        Task { @MainActor in
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10)))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.end(key: key)
        }
    }

    func end(key: String) {
        observers.removeValue(forKey: key)?.cancel()
        lastSteps.removeValue(forKey: key)
        lastCounts.removeValue(forKey: key)
        guard let activity = activities.removeValue(forKey: key) else { return }
        Task { @MainActor in
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func observeEnd(for key: String, activity: Activity<DecryptActivityAttributes>) {
        observers[key]?.cancel()
        observers[key] = Task { @MainActor [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                self?.forget(key: key)
                return
            }
        }
    }

    private func forget(key: String) {
        activities.removeValue(forKey: key)
        lastSteps.removeValue(forKey: key)
        lastCounts.removeValue(forKey: key)
        observers.removeValue(forKey: key)?.cancel()
    }
}

@MainActor
final class InstallActivityManager {
    static let shared = InstallActivityManager()

    private var activities: [String: Activity<InstallActivityAttributes>] = [:]
    private var lastSteps: [String: String] = [:]
    private var observers: [String: Task<Void, Never>] = [:]

    private let log = Logger(subsystem: "com.pxx917144686.App", category: "island")

    private init() {
        for activity in Activity<InstallActivityAttributes>.activities {
            let key = activity.attributes.taskKey
            guard !key.isEmpty, activities[key] == nil else { continue }
            activities[key] = activity
            lastSteps[key] = activity.content.state.step
            observeEnd(for: key, activity: activity)
        }
        NotificationCenter.default.addObserver(
            forName: .islandSettingsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endDisabledActivities()
            }
        }
        endDisabledActivities()
    }

    private func endDisabledActivities() {
        guard !IslandSettings.shared.isVisible(IslandTaskKind.install) else { return }
        for key in Array(activities.keys) {
            end(key: key)
        }
    }

    func start(key: String, title: String, step: String, detail: String = "") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              IslandSettings.shared.isVisible(IslandTaskKind.install) else { return }
        if activities[key] != nil {
            update(key: key, step: step, detail: detail)
            return
        }

        let attributes = InstallActivityAttributes(startedAt: Date(), taskKey: key)
        let state = InstallActivityAttributes.ContentState(
            title: title,
            step: step,
            detail: detail,
            status: "running"
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(600)),
                pushType: nil
            )
            activities[key] = activity
            lastSteps[key] = step
            TaskSnapshotStore.upsert(
                key: key,
                title: title,
                kind: IslandTaskKind.install,
                phase: step,
                progress: 0,
                status: "running"
            )
            observeEnd(for: key, activity: activity)
        } catch {
            log.error("install start failed \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func update(key: String, step: String, detail: String = "") {
        guard let activity = activities[key] else { return }
        guard lastSteps[key] != step || !detail.isEmpty else { return }
        lastSteps[key] = step

        let state = InstallActivityAttributes.ContentState(
            title: activity.content.state.title,
            step: step,
            detail: detail,
            status: "running"
        )
        TaskSnapshotStore.upsert(
            key: key,
            title: state.title,
            kind: IslandTaskKind.install,
            phase: step,
            progress: 0,
            status: "running"
        )
        Task { @MainActor in
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(600)))
        }
    }

    func finish(key: String, detail: String = "") {
        guard let activity = activities[key] else { return }
        let state = InstallActivityAttributes.ContentState(
            title: activity.content.state.title,
            step: "install_stage_completed".localized,
            detail: detail,
            status: "done"
        )
        TaskSnapshotStore.upsert(
            key: key,
            title: state.title,
            kind: IslandTaskKind.install,
            phase: state.step,
            progress: 1,
            status: "done"
        )
        Task { @MainActor in
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10)))
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self.end(key: key)
        }
    }

    func fail(key: String, reason: String) {
        guard let activity = activities[key] else { return }
        let state = InstallActivityAttributes.ContentState(
            title: activity.content.state.title,
            step: "install_stage_failed".localized,
            detail: reason,
            status: "failed"
        )
        TaskSnapshotStore.upsert(
            key: key,
            title: state.title,
            kind: IslandTaskKind.install,
            phase: state.step,
            progress: 0,
            status: "failed"
        )
        Task { @MainActor in
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(10)))
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self.end(key: key)
        }
    }

    func end(key: String) {
        observers.removeValue(forKey: key)?.cancel()
        lastSteps.removeValue(forKey: key)
        guard let activity = activities.removeValue(forKey: key) else { return }
        Task { @MainActor in
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func observeEnd(for key: String, activity: Activity<InstallActivityAttributes>) {
        observers[key]?.cancel()
        observers[key] = Task { @MainActor [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                self?.forget(key: key)
                return
            }
        }
    }

    private func forget(key: String) {
        activities.removeValue(forKey: key)
        lastSteps.removeValue(forKey: key)
        observers.removeValue(forKey: key)?.cancel()
    }
}
