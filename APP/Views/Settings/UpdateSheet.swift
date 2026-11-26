import SwiftUI
import UIKit

struct UpdateSheet: View {
    @ObservedObject var checker: UpdateChecker
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var downloader = UpdateDownloader()
    @State private var shareItem: ShareFile?

    private var accent: Color { themeManager.accentColor }

    private var latest: AppRelease? { checker.latestRelease }
    private var asset: AppReleaseAsset? { checker.ipaAsset }

    private var displayedReleases: [AppRelease] {
        if !checker.changelog.isEmpty { return checker.changelog }
        return latest.map { [$0] } ?? []
    }

    private var canInstallViaTrollStore: Bool {
        EnvironmentDetector.shared.isTrollStore && asset != nil
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 14) {
                        headerCard
                        changelogCard
                    }
                    .padding(16)
                }
                actionBar
            }
            .background(themeManager.backgroundColor.ignoresSafeArea())
            .navigationTitle("update_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onDisappear { downloader.cancel() }
        .sheet(item: $shareItem) { file in
            ActivityView(items: [file.url])
        }
    }

    private var headerCard: some View {
        GlassSurface(cornerRadius: 18, blur: 18, saturation: 1.7, tintOpacity: 0.12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [accent, accent.opacity(0.55)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 44, height: 44)
                    Image(systemName: "arrow.down.app.fill")
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("v\(latest?.version ?? "-")")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("update_current_version".localized(checker.currentVersion))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 5) {
                    Text(EnvironmentDetector.shared.environmentDescription)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(accent.opacity(0.15)))
                    if let asset {
                        Text(DownloadByteFormatter.file.string(fromByteCount: asset.size))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
        }
    }

    private var changelogCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("update_changelog".localized)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(displayedReleases) { release in
                VStack(alignment: .leading, spacing: 8) {
                    Text("v\(release.version)")
                        .font(.system(size: 15, weight: .bold, design: .rounded))

                    if let text = changelogText(release.body) {
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("update_no_notes".localized)
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                }

                if release.id != displayedReleases.last?.id {
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            if case .downloading(let progress) = downloader.phase {
                HStack {
                    Spacer()
                    UpdateProgressRing(progress: progress, tint: accent)
                    Spacer()
                }
                .padding(.bottom, 2)
            }

            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    Image(systemName: primaryIcon)
                        .font(.system(size: 14, weight: .bold))
                    Text(primaryTitle)
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent)
                )
            }
            .buttonStyle(.plain)

            if case .failed(let message) = downloader.phase {
                Text("update_install_failed".localized(message))
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(hintText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .finished(let url) = downloader.phase {
                Button {
                    shareItem = ShareFile(url: url)
                } label: {
                    Text("update_share".localized)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }

            Button {
                checker.openReleasesPage()
            } label: {
                Text("update_view_github".localized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var primaryTitle: String {
        switch downloader.phase {
        case .downloading:
            return "update_cancel".localized
        case .finished:
            return "update_go_sign".localized
        default:
            return canInstallViaTrollStore
                ? "update_install_trollstore".localized
                : "update_download".localized
        }
    }

    private var primaryIcon: String {
        switch downloader.phase {
        case .downloading:
            return "xmark"
        case .finished:
            return "signature"
        default:
            return canInstallViaTrollStore ? "arrow.down.circle.fill" : "square.and.arrow.down"
        }
    }

    private var hintText: String {
        if case .finished(let url) = downloader.phase {
            return "update_downloaded".localized(url.lastPathComponent)
        }
        return canInstallViaTrollStore
            ? "update_trollstore_hint".localized
            : "update_sign_hint".localized
    }

    private func primaryAction() {
        switch downloader.phase {
        case .downloading:
            downloader.cancel()
        case .finished(let url):
            handOffToSigning(url)
        case .idle, .failed:
            guard let asset else {
                checker.openReleasesPage()
                return
            }
            if canInstallViaTrollStore {
                installViaTrollStore(asset)
            } else {
                downloader.start(url: asset.browserDownloadURL, version: latest?.version ?? "latest")
            }
        }
    }

    private func installViaTrollStore(_ asset: AppReleaseAsset) {
        let raw = asset.browserDownloadURL.absoluteString
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        guard let url = URL(string: "apple-magnifier://install?url=\(encoded)"),
              UIApplication.shared.canOpenURL(url) else {
            downloader.start(url: asset.browserDownloadURL, version: latest?.version ?? "latest")
            return
        }
        UIApplication.shared.open(url)
    }

    private func handOffToSigning(_ url: URL) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            SigningHandoff.shared.send(url)
            TabRouter.shared.select(.sign)
        }
    }

    private func changelogText(_ raw: String?) -> AttributedString? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let lines = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        text = lines.joined(separator: "\n")
        text = text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return try? AttributedString(markdown: text)
    }
}
