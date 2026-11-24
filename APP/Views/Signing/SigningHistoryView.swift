import SwiftUI
import LocalAuthentication

struct SigningHistoryViewState: BindableState {
    var activeRecord: SigningHistoryRecord?
    var shareFile: ShareFile?
    var isInstalling = false
    var hiddenUnlocked = false
}

enum SigningHistoryViewAction {
    case select(SigningHistoryRecord)
    case clearSelection
    case share(SigningHistoryRecord)
    case clearShare
    case install(SigningHistoryRecord)
    case delete(SigningHistoryRecord)
    case toggleHidden(SigningHistoryRecord)
    case toggleVault
}

@MainActor
final class SigningHistoryViewModel: StateStoreViewModel<SigningHistoryViewState, SigningHistoryViewAction> {
    private let store: SigningHistoryStore

    init(store: SigningHistoryStore = .shared) {
        self.store = store
        super.init(initialViewState: SigningHistoryViewState())
    }

    override func process(viewAction: SigningHistoryViewAction) {
        switch viewAction {
        case .select(let record):
            state.activeRecord = record
        case .clearSelection:
            state.activeRecord = nil
        case .share(let record):
            state.shareFile = ShareFile(url: store.outputURL(for: record))
        case .clearShare:
            state.shareFile = nil
        case .install(let record):
            install(record)
        case .delete(let record):
            delete(record)
        case .toggleHidden(let record):
            store.setHidden(record, hidden: record.isHidden != true)
        case .toggleVault:
            toggleVault()
        }
    }

    private func install(_ record: SigningHistoryRecord) {
        let url = store.outputURL(for: record)
        guard let info = try? SigningIPAInfo.read(url: url) else {
            presentError("sign_err_invalid_ipa".localized)
            return
        }
        guard info.bundleIdentifier != Bundle.main.bundleIdentifier else {
            presentError("sign_history_install_self".localized, title: "sign_install_self_title".localized)
            return
        }
        state.isInstalling = true
        Task { @MainActor in
            do {
                try await SigningInstaller.install(ipaURL: url)
                state.isInstalling = false
                TopBannerPresenter.shared.show(TopBanner(
                    message: "sign_install_handed_off".localized,
                    systemImage: "checkmark.seal.fill"
                ))
            } catch {
                state.isInstalling = false
                presentError(error.localizedDescription)
            }
        }
    }

    private func delete(_ record: SigningHistoryRecord) {
        guard store.delete(record) else {
            presentError("sign_history_delete_failed".localized)
            return
        }
    }

    private func toggleVault() {
        if state.hiddenUnlocked {
            state.hiddenUnlocked = false
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            presentError(
                error?.localizedDescription ?? "sign_history_auth_unavailable_hint".localized,
                title: "sign_history_auth_unavailable".localized
            )
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "sign_history_hidden_auth_reason".localized) { success, error in
            Task { @MainActor in
                if success {
                    self.state.hiddenUnlocked = true
                } else {
                    self.presentError(
                        error?.localizedDescription ?? "sign_history_auth_failed_hint".localized,
                        title: "sign_history_auth_failed".localized
                    )
                }
            }
        }
    }

    private func presentError(_ message: String, title: String? = nil) {
        AppPresenter.shared.present(alert: AppAlert(
            title: title ?? "sign_error_title".localized,
            message: message
        ))
    }
}

struct SigningHistoryView: View {
    var onRefresh: (SigningHistoryRecord) -> Void = { _ in }

    @ObservedObject private var store = SigningHistoryStore.shared
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appViewFactory) private var appViewFactory

    @State private var model = SigningHistoryViewModel()
    @AppStorage("signing.strictHiddenLibrary") private var strictHiding = false

    var body: some SwiftUI.View {
        NavigationView {
            ZStack {
                themeManager.backgroundColor.ignoresSafeArea()

                if store.records.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            if !hiddenRecords.isEmpty {
                                notchVault
                            }
                            summary
                            ForEach(regularRecords) { record in
                                recordRow(record)
                            }
                            if model.state.hiddenUnlocked, !hiddenRecords.isEmpty {
                                Text("sign_history_hidden_title".localized)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.secondary)
                                    .tracking(0.5)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                                ForEach(hiddenRecords) { record in
                                    recordRow(record)
                                }
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 30)
                    }
                    .scrollEdgeFade(top: 14, bottom: 24)
                }
            }
            .navigationTitle("sign_history_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            store.refresh()
        }
        .sheet(item: Binding(
            get: { model.state.shareFile },
            set: { if $0 == nil { model.send(viewAction: .clearShare) } }
        )) { file in
            ActivityView(items: [file.url])
        }
        .confirmationDialog(
            model.state.activeRecord?.displayName ?? "",
            isPresented: Binding(
                get: { model.state.activeRecord != nil },
                set: { if !$0 { model.send(viewAction: .clearSelection) } }
            ),
            presenting: model.state.activeRecord
        ) { record in
            if store.hasRetainedSource(for: record) {
                Button("sign_history_refresh".localized) {
                    onRefresh(record)
                    dismiss()
                }
            }
            if store.fileExists(for: record) {
                Button("sign_install".localized) {
                    model.send(viewAction: .install(record))
                }
                Button("sign_share".localized) {
                    model.send(viewAction: .share(record))
                }
            }
            Button("sign_delete".localized, role: .destructive) {
                model.send(viewAction: .delete(record))
            }
        } message: { record in
            Text(store.fileExists(for: record) ? record.outputName : "sign_history_file_missing".localized)
        }
    }

    private var regularRecords: [SigningHistoryRecord] {
        store.records.filter { $0.isHidden != true }
    }

    private var hiddenRecords: [SigningHistoryRecord] {
        store.records.filter { $0.isHidden == true }
    }

    private var notchVault: some SwiftUI.View {
        Button {
            model.send(viewAction: .toggleVault)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.black)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                Text(model.state.hiddenUnlocked ? "sign_history_hidden_unlocked".localized : "sign_history_hidden_vault".localized)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(strictHiding && !model.state.hiddenUnlocked ? "•••" : String(format: "sign_history_hidden_count".localized, hiddenRecords.count))
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Image(systemName: model.state.hiddenUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule().fill(Color.black)
            )
            .overlay(
                Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var summary: some SwiftUI.View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themeManager.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "sign_history_records".localized, store.records.count))
                    .font(.system(size: 12, weight: .semibold))
                Text(String(format: "sign_history_size".localized, byteText(store.totalBytes)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.state.isInstalling {
                ProgressView()
                    .scaleEffect(0.8)
                    .tint(themeManager.accentColor)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func recordRow(_ record: SigningHistoryRecord) -> some SwiftUI.View {
        appViewFactory.signingHistoryRow(SigningHistoryRowOptions(
            record: record,
            isAvailable: store.fileExists(for: record),
            hasRetainedSource: store.hasRetainedSource(for: record),
            accentColor: themeManager.accentColor,
            onSelect: { model.send(viewAction: .select(record)) },
            onToggleHidden: { model.send(viewAction: .toggleHidden(record)) },
            onDelete: { model.send(viewAction: .delete(record)) }
        ))
    }

    private var emptyState: some SwiftUI.View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.secondary)
            Text("sign_history_empty".localized)
                .font(.system(size: 13, weight: .semibold))
            Text("sign_history_empty_hint".localized)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(30)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
