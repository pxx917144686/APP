import SwiftUI
import UIKit

struct DecryptView: SwiftUI.View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var tabBarStyleManager: TabBarStyleManager
    @StateObject private var store = DecryptInboxStore.shared

    @State private var showImporter = false
    @State private var showDecryptedFiles = false
    @State private var shareItem: ShareFile?
    @State private var importFailures: [String] = []
    @State private var logJob: DecryptJob?
    @State private var showClearConfirm = false

    var body: some SwiftUI.View {
        ZStack {
            LiquidGlassBackdrop()
                .environmentObject(themeManager)
                .ignoresSafeArea()

            List {
                importSection

                if store.jobs.isEmpty {
                    emptySection
                } else {
                    jobsSection
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
        }
        .navigationTitle("tab_decrypt".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if store.readyCount > 0 {
                        Button {
                            store.startAll()
                        } label: {
                            Image(systemName: "play.circle")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .accessibilityLabel("decrypt_action_start_all".localized)
                    }

                    Button {
                        showDecryptedFiles = true
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .accessibilityLabel("decrypted_files_title".localized)

                    if store.jobs.contains(where: { $0.state.isFinished }) {
                        Menu {
                            Button(role: .destructive) {
                                showClearConfirm = true
                            } label: {
                                Label("decrypt_clear_finished".localized, systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showImporter) {
            DocumentPicker(types: [.item], allowsMultipleSelection: true) { urls in
                showImporter = false
                Task {
                    let failures = await store.importIPAs(from: urls)
                    if !failures.isEmpty { importFailures = failures }
                }
            }
        }
        .sheet(isPresented: $showDecryptedFiles) {
            DecryptedFilesView()
                .environmentObject(themeManager)
        }
        .sheet(item: $shareItem) { item in
            ActivityView(items: [item.url])
        }
        .sheet(item: $logJob) { job in
            DecryptLogSheet(log: job.log, title: job.displayName)
                .environmentObject(themeManager)
        }
        .confirmationDialog(
            "decrypt_clear_finished".localized,
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("decrypt_clear_confirm".localized, role: .destructive) {
                store.clearFinished()
            }
            Button("cancel".localized, role: .cancel) {}
        } message: {
            Text("decrypt_clear_hint".localized)
        }
        .alert(
            "decrypt_import_result".localized,
            isPresented: Binding(
                get: { !importFailures.isEmpty },
                set: { if !$0 { importFailures = [] } }
            )
        ) {
            Button("ok".localized, role: .cancel) { importFailures = [] }
        } message: {
            Text(importFailures.joined(separator: "\n"))
        }
        .alert(
            "dc_failed_title".localized,
            isPresented: Binding(
                get: { store.failureAlert != nil },
                set: { if !$0 { store.failureAlert = nil } }
            )
        ) {
            Button("ok".localized, role: .cancel) { store.failureAlert = nil }
        } message: {
            Text(store.failureAlert ?? "")
        }
        .onAppear { store.reload() }
    }

    private var importSection: some SwiftUI.View {
        Section {
            Button {
                showImporter = true
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(themeManager.accentColor.opacity(0.15))
                        if store.isImporting {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(themeManager.accentColor)
                        } else {
                            Image(systemName: "square.and.arrow.down.on.square")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(themeManager.accentColor)
                        }
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.isImporting ? "decrypt_importing".localized : "decrypt_import".localized)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("decrypt_import_hint".localized)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain, sound: .tap)
            .disabled(store.isImporting)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 2, trailing: 16))
        }
    }

    private var emptySection: some SwiftUI.View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "lock.open.display")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("decrypt_empty".localized)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("decrypt_empty_hint".localized)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 52)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var jobsSection: some SwiftUI.View {
        Section {
            ForEach(store.jobs) { job in
                DecryptJobCard(
                    job: job,
                    onStart: { store.start(job) },
                    onCancel: { store.cancel(job) },
                    onRemove: { store.remove(job) },
                    onShare: { url in shareItem = ShareFile(url: url) },
                    onSign: { url in
                        SigningHandoff.shared.send(url)
                        TabRouter.shared.select(.sign)
                    },
                    onLog: { logJob = job }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }
        }
    }
}

private struct DecryptJobCard: SwiftUI.View {
    @ObservedObject var job: DecryptJob
    @EnvironmentObject var themeManager: ThemeManager
    @SwiftUI.Environment(\.colorScheme) private var colorScheme

    let onStart: () -> Void
    let onCancel: () -> Void
    let onRemove: () -> Void
    let onShare: (URL) -> Void
    let onSign: (URL) -> Void
    let onLog: () -> Void

    @State private var isConsoleCollapsed = false

    private var showsConsole: Bool {
        job.state == .running || (!job.log.lines.isEmpty && job.state != .importing)
    }

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 9) {
            header

            if showsConsole {
                if isConsoleCollapsed {
                    collapsedBar
                } else {
                    DecryptConsoleView(
                        log: job.log,
                        outcome: job.state.consoleOutcome,
                        appName: job.displayName,
                        bundleIdentifier: job.metadata.bundleIdentifier,
                        message: job.message,
                        decryptedURL: job.outputURL,
                        accentColor: themeManager.accentColor,
                        onCancel: onCancel,
                        onShare: {
                            if let url = job.outputURL { onShare(url) }
                        },
                        onCollapse: {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                                isConsoleCollapsed = true
                            }
                        }
                    )
                }
            } else if let message = job.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !job.failedPaths.isEmpty {
                failedBlock
            }

            actionRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.ultraThinMaterial)
                .shadow(
                    color: colorScheme == .dark ? Color.black.opacity(0.4) : Color.black.opacity(0.08),
                    radius: colorScheme == .dark ? 10 : 6,
                    x: 0,
                    y: 2
                )
        )
    }

    private var header: some SwiftUI.View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let data = job.metadata.iconPNG, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(themeManager.accentColor.opacity(0.14))
                        Image(systemName: job.state == .completed ? "lock.open.fill" : "shippingbox.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(themeManager.accentColor)
                    }
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(job.subtitle)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(outputLine)
                    .font(.system(size: 10))
                    .foregroundStyle(job.outputURL == nil ? Color.secondary.opacity(0.7) : themeManager.accentColor.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            statusPill
        }
    }

    private var outputLine: String {
        guard let output = job.outputURL else { return job.fileName }
        if let size = job.outputSizeText {
            return "\(output.lastPathComponent) · \(size)"
        }
        return output.lastPathComponent
    }

    private var failedBlock: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 3) {
            Text("decrypt_failed_binaries".localized(job.failedPaths.count))
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)

            ForEach(Array(job.failedPaths.prefix(3)), id: \.self) { path in
                Text(path)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if job.failedPaths.count > 3 {
                Text("+\(job.failedPaths.count - 3)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
    }

    private var statusPill: some SwiftUI.View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
            Text(job.state.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(statusColor.opacity(0.12)))
        .overlay(Capsule().strokeBorder(statusColor.opacity(0.22), lineWidth: 0.5))
    }

    private var statusColor: Color {
        switch job.state {
        case .importing: return .secondary
        case .ready: return .secondary
        case .running: return themeManager.accentColor
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private var collapsedBar: some SwiftUI.View {
        Button {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                isConsoleCollapsed = false
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "lock.open.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(themeManager.accentColor)
                Text("dc_console_title".localized)
                    .font(.system(size: 11, weight: .semibold))
                Text(job.state.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.07 : 0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var actionRow: some SwiftUI.View {
        HStack(spacing: 8) {
            switch job.state {
            case .importing:
                HStack(spacing: 5) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                    Text("decrypt_state_importing".localized)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            case .ready:
                primaryButton("decrypt_action_start".localized, icon: "play.fill", action: onStart)
            case .running:
                primaryButton("decrypt_action_cancel".localized, icon: "stop.fill", tint: .red, action: onCancel)
            case .completed:
                if let url = job.outputURL {
                    primaryButton("decrypt_action_share".localized, icon: "square.and.arrow.up") {
                        onShare(url)
                    }
                    secondaryButton("decrypt_action_sign".localized, icon: "signature") {
                        onSign(url)
                    }
                }
            case .failed, .cancelled:
                primaryButton("decrypt_action_retry".localized, icon: "arrow.clockwise", action: onStart)
            }

            Spacer(minLength: 4)

            if !job.log.lines.isEmpty {
                Button(action: onLog) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain, sound: .tap)
                .accessibilityLabel("decrypt_action_log".localized)
            }

            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary.opacity(0.06)))
            }
            .buttonStyle(.plain, sound: .dismiss)
            .accessibilityLabel("delete".localized)
        }
    }

    private func secondaryButton(_ title: String, icon: String, action: @escaping () -> Void) -> some SwiftUI.View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        }
        .buttonStyle(.plain, sound: .tap)
    }

    private func primaryButton(_ title: String, icon: String, tint: Color? = nil, action: @escaping () -> Void) -> some SwiftUI.View {
        let color = tint ?? themeManager.accentColor
        return Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain, sound: .press)
    }
}
