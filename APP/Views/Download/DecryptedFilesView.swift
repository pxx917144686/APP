import SwiftUI
import UIKit

struct DecryptedFileItem: Identifiable {
    let url: URL
    let size: Int64
    let modified: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var isPartial: Bool { name.contains("-PARTIAL") }

    var displayName: String {
        name
            .replacingOccurrences(of: "-PARTIAL.ipa", with: "")
            .replacingOccurrences(of: "-decrypted.ipa", with: "")
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var dateText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: modified)
    }
}

struct DecryptedFilesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var items: [DecryptedFileItem] = []
    @State private var shareItem: ShareFile?
    @State private var pendingDelete: DecryptedFileItem?

    static var folderURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Decrypted", isDirectory: true)
    }

    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "shippingbox")
                            .font(.system(size: 34))
                            .foregroundStyle(.tertiary)
                        Text("decrypted_files_empty".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(items) { item in
                            row(item)
                        }
                        .onDelete(perform: delete)
                    } header: {
                        Text(summary)
                    }
                }
            }
            .navigationTitle("decrypted_files_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
            }
            .confirmationDialog(
                "delete".localized,
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("delete".localized, role: .destructive) {
                    if let target = pendingDelete {
                        try? FileManager.default.removeItem(at: target.url)
                        reload()
                        NotificationCenter.default.post(name: NSNotification.Name("DecryptedFilesChanged"), object: nil)
                    }
                    pendingDelete = nil
                }
                Button("cancel".localized, role: .cancel) {
                    pendingDelete = nil
                }
            } message: {
                Text(pendingDelete?.name ?? "")
            }
            .onAppear { reload() }
        }
    }

    private var summary: String {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "decrypted_files_total".localized(items.count, size)
    }

    private func row(_ item: DecryptedFileItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isPartial ? "exclamationmark.triangle.fill" : "shippingbox.fill")
                .font(.system(size: 15))
                .foregroundStyle(item.isPartial ? .orange : themeManager.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.sizeText)
                    Text("·")
                    Text(item.dateText)
                    if item.isPartial {
                        Text("·")
                        Text("decrypted_files_partial".localized)
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Button {
                SoundEffects.play(.tap)
                shareItem = ShareFile(url: item.url)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(themeManager.accentColor)
            }
            .buttonStyle(.plain)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                SoundEffects.play(.dismiss)
                pendingDelete = item
            } label: {
                Label("delete".localized, systemImage: "trash")
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let manager = FileManager.default
        for index in offsets {
            try? manager.removeItem(at: items[index].url)
        }
        reload()
    }

    private func reload() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.folderURL, withIntermediateDirectories: true)

        let urls = (try? manager.contentsOfDirectory(
            at: Self.folderURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]
        )) ?? []

        items = urls
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
}

struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {
        guard let popover = controller.popoverPresentationController else { return }
        popover.sourceView = controller.view
        popover.sourceRect = CGRect(
            x: controller.view.bounds.midX,
            y: controller.view.bounds.midY,
            width: 0,
            height: 0
        )
        popover.permittedArrowDirections = []
    }
}
