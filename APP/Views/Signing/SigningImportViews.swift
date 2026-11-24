import SwiftUI
import UIKit

struct SigningIPAPickerSheet: View {
    @ObservedObject var downloads: UnifiedDownloadManager
    let onPick: (URL) -> Void
    let onImportFile: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager

    private enum Source: String, CaseIterable {
        case decrypted
        case downloads
    }

    @State private var source: Source = .decrypted
    @State private var decryptedItems: [DecryptedFileItem] = []

    private var items: [DownloadRequest] {
        downloads.downloadRequests
            .filter { request in
                guard request.runtime.status == .completed,
                      let path = request.localFilePath else { return false }
                return FileManager.default.fileExists(atPath: path)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("", selection: $source) {
                        Text(String(format: "sign_ipa_source_decrypted".localized, decryptedItems.count))
                            .tag(Source.decrypted)
                        Text(String(format: "sign_ipa_source_downloads".localized, items.count))
                            .tag(Source.downloads)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }

                if source == .decrypted {
                    if decryptedItems.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "lock.open.display")
                                .font(.system(size: 30, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("sign_ipa_decrypted_empty".localized)
                                .font(.system(size: 12, weight: .semibold))
                            Text("sign_ipa_decrypted_hint".localized)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                            HStack(spacing: 8) {
                                Button {
                                    source = .downloads
                                } label: {
                                    Label(String(format: "sign_ipa_source_downloads".localized, items.count), systemImage: "arrow.down.circle")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(themeManager.accentColor)
                                Button {
                                    onImportFile()
                                    dismiss()
                                } label: {
                                    Label("sign_from_files".localized, systemImage: "doc.badge.plus")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(decryptedItems) { item in
                            Button {
                                onPick(item.url)
                                dismiss()
                            } label: {
                                decryptedRow(item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else if items.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.system(size: 34, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("sign_ipa_empty".localized)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Button {
                            onImportFile()
                            dismiss()
                        } label: {
                            Label("sign_from_files".localized, systemImage: "doc.badge.plus")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(themeManager.accentColor)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(items) { request in
                        if let path = request.localFilePath {
                            Button {
                                onPick(URL(fileURLWithPath: path))
                                dismiss()
                            } label: {
                                row(for: request, path: path)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("sign_choose_ipa".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onImportFile()
                        dismiss()
                    } label: {
                        Image(systemName: "doc.badge.plus")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            reloadDecrypted()
        }
    }

    private func decryptedRow(_ item: DecryptedFileItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(themeManager.accentColor)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(themeManager.accentColor.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(item.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isPartial {
                        Text("sign_ipa_partial".localized)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }
                }
                Text("\(item.sizeText) · \(item.dateText)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func reloadDecrypted() {
        let manager = FileManager.default
        let folder = DecryptedFilesView.folderURL
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = (try? manager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []
        decryptedItems = urls
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .map { url in
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return DecryptedFileItem(
                    url: url,
                    size: Int64(values?.fileSize ?? 0),
                    modified: values?.contentModificationDate ?? .distantPast
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    private func row(for request: DownloadRequest, path: String) -> some View {
        HStack(spacing: 10) {
            if let iconURL = request.package.iconURL, let url = URL(string: iconURL) {
                ResourceImage(
                    url: url,
                    pointSize: CGSize(width: 34, height: 34),
                    cornerRadius: 9,
                    showsBorder: true
                )
                .frame(width: 34, height: 34)
            } else {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(themeManager.accentColor)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(themeManager.accentColor.opacity(0.12))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(request.package.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(request.version) · \(request.bundleIdentifier)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(fileSize(path))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private func fileSize(_ path: String) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: size)
    }
}

struct CertificateImportSheet: View {
    let fileName: String
    let onImport: (String, String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager

    @State private var password = ""
    @State private var displayName = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "key.horizontal.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(themeManager.accentColor)
                            .frame(width: 38, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(themeManager.accentColor.opacity(0.12))
                            )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fileName)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("sign_import_cert_hint".localized)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }

                    field(title: "sign_p12_password".localized, placeholder: "sign_p12_password_placeholder".localized) {
                        SecureField("sign_p12_password_placeholder".localized, text: $password)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    field(title: "sign_p12_display_name".localized, placeholder: "sign_p12_display_name_placeholder".localized) {
                        TextField("sign_p12_display_name_placeholder".localized, text: $displayName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        importCertificate()
                    } label: {
                        HStack(spacing: 6) {
                            if isWorking {
                                ProgressView()
                                    .progressViewStyle(.circular)
                                    .tint(.white)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "checkmark.seal.fill")
                            }
                            Text("sign_import_action".localized)
                        }
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(LinearGradient(colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(isWorking)
                }
                .padding(16)
            }
            .background(themeManager.backgroundColor.ignoresSafeArea())
            .navigationTitle("sign_import_cert_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("cancel".localized) { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .presentationDetents([.medium])
    }

    private func field<Content: View>(title: String, placeholder: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
        }
    }

    private func importCertificate() {
        isWorking = true
        errorMessage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            do {
                try onImport(password, displayName)
                isWorking = false
                dismiss()
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
