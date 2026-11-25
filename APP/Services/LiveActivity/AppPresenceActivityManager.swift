import ActivityKit
import Foundation
import UIKit
import os

@MainActor
final class AppPresenceActivityManager {
    static let shared = AppPresenceActivityManager()

    private var activity: Activity<IslandAttributes>?
    private var observer: Task<Void, Never>?
    private var wasActive = false
    private var dismissed = false

    private let log = Logger(subsystem: "com.pxx917144686.App", category: "island")

    private init() {
        if let existing = Activity<IslandAttributes>.activities.first(where: { $0.attributes.kind == IslandTaskKind.app }) {
            activity = existing
            observeEnd(existing)
        }
    }

    private var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "APP"
    }

    private var hasRunningTask: Bool {
        if Activity<IslandAttributes>.activities.contains(where: {
            $0.attributes.kind != IslandTaskKind.app && !$0.content.state.isFinished
        }) {
            return true
        }
        if !Activity<DecryptActivityAttributes>.activities.isEmpty { return true }
        if !Activity<InstallActivityAttributes>.activities.isEmpty { return true }
        return false
    }

    func sceneDidBecomeActive() {
        wasActive = true
        dismissed = false
        end()
    }

    func sceneWillResignActive() {
        guard wasActive else { return }
        wasActive = false
        startIfPossible()
    }

    private func startIfPossible() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard IslandSettings.shared.isVisible(IslandTaskKind.app) else { return }
        guard UIApplication.shared.applicationState != .background else { return }
        guard !hasRunningTask else { return }
        if activity != nil { return }
        guard !dismissed else { return }

        let attributes = IslandAttributes(kind: IslandTaskKind.app, startedAt: Date(), taskKey: IslandTaskKey.app)
        let state = IslandAttributes.ContentState(
            title: appName,
            phase: "island_app_phase".localized,
            detail: "island_app_tap_to_open".localized,
            progress: 0,
            remaining: "",
            status: "running",
            staleDate: nil
        )

        do {
            let started = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(4 * 60 * 60)),
                pushType: nil
            )
            activity = started
            observeEnd(started)
            log.notice("app presence started")
        } catch {
            log.error("app presence start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func end() {
        observer?.cancel()
        observer = nil
        guard let activity else {
            self.activity = nil
            return
        }
        self.activity = nil
        log.notice("app presence end")
        Task { @MainActor in
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func observeEnd(_ activity: Activity<IslandAttributes>) {
        observer?.cancel()
        observer = Task { @MainActor [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .ended || state == .dismissed else { continue }
                guard let self else { return }
                if state == .dismissed { self.dismissed = true }
                self.activity = nil
                self.observer = nil
                return
            }
        }
    }
}
