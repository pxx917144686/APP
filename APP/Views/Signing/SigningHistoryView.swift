import SwiftUI
import LocalAuthentication

struct SigningHistoryView: View {
    var onRefresh: (SigningHistoryRecord) -> Void = { _ in }

    @ObservedObject private var store = SigningHistoryStore.shared
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss

    @State private var activeRecord: SigningHistoryRecord?
    @State private var shareFile: ShareFile?
    @State private var isInstalling = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    @State private var hiddenUnlocked = false
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
                            if hiddenUnlocked, !hiddenRecords.isEmpty {
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
        .sheet(item: $shareFile) { file in
            ActivityView(items: [file.url])
        }
        .confirmationDialog(
            activeRecord?.displayName ?? "",
            isPresented: Binding(
                get: { activeRecord != nil },
                set: { if !$0 { activeRecord = nil } }
            ),
            presenting: activeRecord
        ) { record in
            if store.hasRetainedSource(for: record) {
                Button("sign_history_refresh".localized) {
                    onRefresh(record)
                    dismiss()
                }
            }
            if store.fileExists(for: record) {
                Button("sign_install".localized) {
                    install(record)
                }
                Button("sign_share".localized) {
                    shareFile = ShareFile(url: store.outputURL(for: record))
                }
            }
            Button("sign_delete".localized, role: .destructive) {
                delete(record)
            }
        } message: { record in
            Text(store.fileExists(for: record) ? record.outputName : "sign_history_file_missing".localized)
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("ok".localized, role: .cancel) { }
        } message: {
            Text(alertMessage)
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
            authenticateHiddenVault()
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.black)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                Text(hiddenUnlocked ? "sign_history_hidden_unlocked".localized : "sign_history_hidden_vault".localized)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(strictHiding && !hiddenUnlocked ? "•••" : String(format: "sign_history_hidden_count".localized, hiddenRecords.count))
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Image(systemName: hiddenUnlocked ? "lock.open.fill" : "lock.fill")
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

    private func authenticateHiddenVault() {
        if hiddenUnlocked {
            hiddenUnlocked = false
            return
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            alertTitle = "sign_history_auth_unavailable".localized
            alertMessage = error?.localizedDescription ?? "sign_history_auth_unavailable_hint".localized
            showAlert = true
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "sign_history_hidden_auth_reason".localized) { success, error in
            DispatchQueue.main.async {
                if success {
                    hiddenUnlocked = true
                } else {
                    alertTitle = "sign_history_auth_failed".localized
                    alertMessage = error?.localizedDescription ?? "sign_history_auth_failed_hint".localized
                    showAlert = true
                }
            }
        }
    }

    private func toggleHidden(_ record: SigningHistoryRecord) {
        store.setHidden(record, hidden: record.isHidden != true)
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
            if isInstalling {
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
        let exists = store.fileExists(for: record)
        return Button {
            activeRecord = record
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "app.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(themeManager.accentColor)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(themeManager.accentColor.opacity(0.10))
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        Text(record.bundleId.isEmpty ? record.outputName : record.bundleId)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 4)

                    if store.hasRetainedSource(for: record) {
                        Text("sign_history_source_ready".localized)
                            .font(.system(size: 7.5, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                    if exists {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("sign_history_file_missing".localized)
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                }

                HStack(spacing: 8) {
                    if !record.version.isEmpty {
                        meta("v\(record.version)")
                    }
                    meta(record.date.formatted(date: .abbreviated, time: .shortened))
                    if let profile = record.profileName {
                        meta(profile, limit: 18)
                    }
                }

                if let certificate = record.certificateName, !certificate.isEmpty {
                    Text(certificate)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                toggleHidden(record)
            } label: {
                Label(
                    record.isHidden == true ? "sign_history_unhide".localized : "sign_history_hide".localized,
                    systemImage: record.isHidden == true ? "eye" : "eye.slash"
                )
            }
            Button(role: .destructive) {
                if store.delete(record) == false {
                    alertTitle = "sign_error_title".localized
                    alertMessage = "sign_history_delete_failed".localized
                    showAlert = true
                }
            } label: {
                Label("sign_delete".localized, systemImage: "trash")
            }
        }
    }

    private func meta(_ text: String, limit: Int = 40) -> some SwiftUI.View {
        Text(text)
            .font(.system(size: 8, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: CGFloat(limit) * 5, alignment: .leading)
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

    private func install(_ record: SigningHistoryRecord) {
        let url = store.outputURL(for: record)
        guard let info = try? SigningIPAInfo.read(url: url) else {
            alertTitle = "sign_error_title".localized
            alertMessage = "sign_err_invalid_ipa".localized
            showAlert = true
            return
        }
        guard info.bundleIdentifier != Bundle.main.bundleIdentifier else {
            alertTitle = "sign_install_self_title".localized
            alertMessage = "sign_history_install_self".localized
            showAlert = true
            return
        }
        isInstalling = true
        Task {
            do {
                try await SigningInstaller.install(ipaURL: url)
                await MainActor.run {
                    isInstalling = false
                }
            } catch {
                await MainActor.run {
                    isInstalling = false
                    alertTitle = "sign_error_title".localized
                    alertMessage = error.localizedDescription
                    showAlert = true
                }
            }
        }
    }

    private func delete(_ record: SigningHistoryRecord) {
        guard store.delete(record) else {
            alertTitle = "sign_error_title".localized
            alertMessage = "sign_history_delete_failed".localized
            showAlert = true
            return
        }
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
