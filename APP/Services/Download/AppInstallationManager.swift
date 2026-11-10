import Foundation
import UIKit
import Combine

@MainActor
final class AppInstallationManager: ObservableObject, @unchecked Sendable {
    static let shared = AppInstallationManager()

    @Published var installingRequests: [UUID: InstallationState] = [:]

    private var installationTimers: [UUID: Timer] = [:]
    private var installationTimeouts: [UUID: DispatchWorkItem] = [:]
    private var installationTasks: [UUID: Task<Void, Never>] = [:]

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkInstallationStatusOnReturn()
            }
        }
    }

    func startInstallation(
        request: DownloadRequest,
        port: Int,
        bundleIdentifier: String
    ) {
        let state = InstallationState(
            requestId: request.id,
            bundleIdentifier: bundleIdentifier,
            port: port,
            status: .preparing,
            startTime: Date()
        )
        installingRequests[request.id] = state

        let task = Task { [weak self] in
            _ = await self?.performInstallation(request: request, state: state)
        }
        installationTasks[request.id] = task
    }

    private func performInstallation(
        request: DownloadRequest,
        state: InstallationState
    ) async {
        updateState(for: request.id, status: .preparing, progress: 0.2)

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if Task.isCancelled { return }

        updateState(for: request.id, status: .prompting, progress: 0.6)

        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if Task.isCancelled { return }

        updateState(for: request.id, status: .installing, progress: 0.8)

        beginInstallationMonitoring(
            requestId: request.id,
            bundleIdentifier: state.bundleIdentifier
        )

        installationTasks[request.id] = nil
    }

    private func beginInstallationMonitoring(requestId: UUID, bundleIdentifier: String) {
        installationTimeouts[requestId]?.cancel()

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                if self.installingRequests[requestId]?.status == .installing {
                    self.updateState(for: requestId, status: .timeout, error: "install_err_timeout_check_home".localized)
                    self.cleanupMonitoring(for: requestId)
                }
            }
        }
        installationTimeouts[requestId] = timeoutWorkItem

        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timeoutWorkItem)

        startPollingInstallationStatus(requestId: requestId, bundleIdentifier: bundleIdentifier)
    }

    private func startPollingInstallationStatus(requestId: UUID, bundleIdentifier: String) {
        installationTimers[requestId]?.invalidate()

        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollInstallationStatus(requestId: requestId, bundleIdentifier: bundleIdentifier)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        installationTimers[requestId] = timer
    }

    private func pollInstallationStatus(requestId: UUID, bundleIdentifier: String) {
        guard let state = installingRequests[requestId],
              state.status == .installing else {
            return
        }

        let isInstalled = isAppInstalled(bundleIdentifier: bundleIdentifier)

        if isInstalled {
            updateState(for: requestId, status: .completed, progress: 1.0)
            cleanupMonitoring(for: requestId)
            HTTPServerManager.shared.stopServer(for: requestId)
        }
    }

    private func checkInstallationStatusOnReturn() {
        for (requestId, state) in installingRequests {
            guard state.status == .installing else { continue }

            let isInstalled = isAppInstalled(bundleIdentifier: state.bundleIdentifier)
            if isInstalled {
                updateState(for: requestId, status: .completed, progress: 1.0)
                cleanupMonitoring(for: requestId)
                HTTPServerManager.shared.stopServer(for: requestId)
            }
        }
    }

    func isAppInstalled(bundleIdentifier: String) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace"),
              let workspace = workspaceClass.value(forKey: "defaultWorkspace") as? NSObject else {
            return false
        }

        let selector = Selector(("applicationIsInstalled:"))
        guard workspace.responds(to: selector) else {
            return false
        }

        let result = workspace.perform(selector, with: bundleIdentifier)
        return result?.takeUnretainedValue() as? Bool ?? false
    }

    private func cleanupMonitoring(for requestId: UUID) {
        installationTimers[requestId]?.invalidate()
        installationTimers.removeValue(forKey: requestId)
        installationTimeouts[requestId]?.cancel()
        installationTimeouts.removeValue(forKey: requestId)
    }

    func cancelInstallation(requestId: UUID) {
        installationTasks[requestId]?.cancel()
        installationTasks.removeValue(forKey: requestId)
        cleanupMonitoring(for: requestId)
        installingRequests.removeValue(forKey: requestId)
        HTTPServerManager.shared.stopServer(for: requestId)
    }

    private func updateState(
        for requestId: UUID,
        status: InstallationStatus,
        progress: Double? = nil,
        error: String? = nil
    ) {
        guard var state = installingRequests[requestId] else { return }
        state.status = status
        if let progress = progress {
            state.progress = progress
        }
        if let error = error {
            state.errorMessage = error
        }
        installingRequests[requestId] = state

        if status.isFinal {
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
                Task { @MainActor in
                    self?.installingRequests.removeValue(forKey: requestId)
                }
            }
        }
    }
}

struct InstallationState {
    let requestId: UUID
    let bundleIdentifier: String
    let port: Int
    var status: InstallationStatus
    var progress: Double = 0.0
    var errorMessage: String? = nil
    let startTime: Date
}

enum InstallationStatus {
    case preparing
    case prompting
    case installing
    case completed
    case failed
    case timeout
    case cancelled

    var isFinal: Bool {
        switch self {
        case .completed, .failed, .timeout, .cancelled:
            return true
        default:
            return false
        }
    }

    var description: String {
        switch self {
        case .preparing: return "install_stage_preparing".localized
        case .prompting: return "install_stage_opening_system".localized
        case .installing: return "install_stage_in_progress".localized
        case .completed: return "install_stage_completed".localized
        case .failed: return "install_stage_failed".localized
        case .timeout: return "install_stage_timeout".localized
        case .cancelled: return "status_cancelled".localized
        }
    }
}
