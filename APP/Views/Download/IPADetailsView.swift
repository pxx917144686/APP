import SwiftUI
import UIKit

struct IPADetailsView: View {
    let ipaURL: URL
    let appName: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager

    @State private var details: IPADetails?
    @State private var failure: String?
    @State private var iconImage: UIImage?

    var body: some View {
        NavigationView {
            Group {
                if let details {
                    content(details)
                } else if let failure {
                    errorState(failure)
                } else {
                    loadingState
                }
            }
            .navigationTitle(appName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await load() }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .scaleEffect(1.1)
                .tint(themeManager.accentColor)
            Text("analyzing".localized)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text(ipaURL.lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .lineLimit(1)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ details: IPADetails) -> some View {
        List {
            headerSection(details)
            basicsSection(details)
            if details.encryptedCount > 0 || details.hasSCInfo {
                encryptionSection(details)
            }
            if details.teamIdentifier != nil || !details.entitlements.isEmpty {
                signingSection(details)
            }
            if !details.components.isEmpty {
                componentsSection(details)
            }
            if !details.linkedLibraries.isEmpty {
                librariesSection(details)
            }
        }
        .listStyle(.insetGrouped)
    }

    private func headerSection(_ details: IPADetails) -> some View {
        Section {
            HStack(spacing: 14) {
                Group {
                    if let iconImage {
                        Image(uiImage: iconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.secondary.opacity(0.15))
                            .overlay(
                                Image(systemName: "shippingbox.fill")
                                    .font(.system(size: 22))
                                    .foregroundColor(.secondary)
                            )
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(details.name)
                        .font(.system(size: 17, weight: .bold))
                        .lineLimit(1)
                    Text(details.bundleIdentifier)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(details.version) (\(details.buildNumber))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
        }
    }

    private func basicsSection(_ details: IPADetails) -> some View {
        Section {
            infoRow("detail_min_os".localized, details.minimumOS.isEmpty ? "—" : details.minimumOS)
            infoRow("detail_devices".localized,
                    details.deviceFamilies.isEmpty ? "—" : details.deviceFamilies.joined(separator: " · "))
            infoRow("detail_arch".localized,
                    details.architectures.isEmpty ? "—" : details.architectures.joined(separator: " · "))
            infoRow("detail_size".localized, bytes(details.totalSize))
            infoRow("detail_files".localized, "\(details.fileCount)")
            infoRow("detail_binaries".localized, "\(details.binaryCount)")
        } header: {
            Text("detail_section_basics".localized)
        }
    }

    private func encryptionSection(_ details: IPADetails) -> some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: details.isEncrypted ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 13))
                    .foregroundColor(details.isEncrypted ? .orange : .green)
                Text(details.isEncrypted ? "detail_encrypted".localized : "detail_plain".localized)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text("\(details.encryptedCount)/\(details.binaryCount)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            if details.hasSCInfo {
                infoRow("detail_scinfo".localized, "SC_Info ✓")
            }
        } header: {
            Text("detail_section_encryption".localized)
        }
    }

    private func signingSection(_ details: IPADetails) -> some View {
        Section {
            if let team = details.teamIdentifier {
                infoRow("detail_team".localized, team, mono: true)
            }
            if let profile = details.profileName {
                infoRow("detail_profile".localized, profile)
            }
            if let expiry = details.profileExpiry {
                HStack {
                    Text("detail_expiry".localized)
                        .font(.system(size: 13))
                    Spacer()
                    Text(expiry.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(expiry < Date() ? .red : .secondary)
                }
            }
            if details.provisionedDevices > 0 {
                infoRow("detail_devices_count".localized, "\(details.provisionedDevices)")
            }

            if !details.entitlements.isEmpty {
                ForEach(details.entitlements) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.key)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(item.isHighlighted ? themeManager.accentColor : .secondary)
                        Text(item.value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary.opacity(0.8))
                            .lineLimit(4)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 1)
                }
            }
        } header: {
            Text("detail_section_signing".localized)
        }
    }

    private func componentsSection(_ details: IPADetails) -> some View {
        Section {
            ForEach(details.components) { component in
                HStack(spacing: 9) {
                    Image(systemName: component.kind.icon)
                        .font(.system(size: 12))
                        .foregroundColor(themeManager.accentColor.opacity(0.85))
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(shortName(component.path))
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(component.kind.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    Spacer(minLength: 4)

                    if component.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                    }

                    Text(bytes(component.size))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 1)
            }
        } header: {
            Text("detail_section_components".localized)
        }
    }

    private func librariesSection(_ details: IPADetails) -> some View {
        Section {
            ForEach(details.linkedLibraries, id: \.self) { library in
                Text(library)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } header: {
            Text("detail_section_libraries".localized)
        }
    }

    private func infoRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func shortName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func load() async {
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try IPAAnalyzer.analyze(ipaURL: ipaURL)
            }.value

            await MainActor.run {
                details = result
                if let path = result.iconPath {
                    iconImage = UIImage(contentsOfFile: path)
                }
            }
        } catch {
            await MainActor.run { failure = error.localizedDescription }
        }
    }
}
