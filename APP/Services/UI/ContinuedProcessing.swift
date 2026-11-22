import BackgroundTasks
import UIKit

@MainActor
final class ContinuedProcessing {
    static let shared = ContinuedProcessing()

    private struct Run {
        let identifier: String
        var task: BGTask?
        var lastPercent: Int
    }

    private var runs: [String: Run] = [:]

    static var isSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    @discardableResult
    func begin(_ key: String, title: String, subtitle: String) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard runs[key] == nil else { return true }
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }

        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains("\(bundleID).task.*") else { return false }

        let identifier = "\(bundleID).task.\(UUID().uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            Task { @MainActor in self?.attach(task, to: key) }
        }
        guard registered else { return false }

        runs[key] = Run(identifier: identifier, task: nil, lastPercent: -1)

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        request.requiredResources = []

        if #available(iOS 27.0, *) {
            Task {
                do {
                    try await BGTaskScheduler.shared.submitTaskRequest(request)
                } catch {
                    await MainActor.run {
                        if self.runs[key]?.identifier == identifier {
                            self.runs[key] = nil
                        }
                    }
                }
            }
        } else {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                runs[key] = nil
            }
        }
        return true
    }

    func update(_ key: String, title: String? = nil, subtitle: String? = nil, progress: Double? = nil) {
        guard #available(iOS 26.0, *) else { return }
        guard var run = runs[key] else { return }
        guard let task = run.task as? BGContinuedProcessingTask else {
            runs[key] = run
            return
        }

        if let title, let subtitle {
            task.updateTitle(title, subtitle: subtitle)
        }

        if let progress {
            let percent = Int((max(0, min(1, progress)) * 100).rounded(.down))
            if percent != run.lastPercent {
                run.lastPercent = percent
                let total: Int64 = 1000
                task.progress.totalUnitCount = total
                task.progress.completedUnitCount = Int64(progress * Double(total))
            }
        }

        runs[key] = run
    }

    func end(_ key: String, success: Bool) {
        guard #available(iOS 26.0, *) else { return }
        guard let run = runs.removeValue(forKey: key) else { return }
        if let task = run.task as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: success)
        }
    }

    func endAll() {
        guard #available(iOS 26.0, *) else { return }
        for key in runs.keys { end(key, success: false) }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGTask, to key: String) {
        guard var run = runs[key] else {
            task.setTaskCompleted(success: false)
            return
        }
        run.task = task
        runs[key] = run

        task.expirationHandler = { [weak self] in
            Task { @MainActor in self?.end(key, success: false) }
        }

        if let continued = task as? BGContinuedProcessingTask {
            continued.progress.totalUnitCount = 1000
            continued.progress.completedUnitCount = 0
        }
    }
}
