import SwiftUI

struct ResourceImage: View {
    let url: URL?
    var pointSize: CGSize = CGSize(width: 52, height: 52)
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0
    var showsBorder: Bool = false
    var placeholderColor: Color = Color(.systemGray6)

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var failed = false
    @State private var loadTask: Task<Void, Never>?
    @State private var loadingID: ResourceID?

    private var resourceID: ResourceID? {
        guard let url, !url.absoluteString.isEmpty else { return nil }
        return ResourceID(url: url, pointSize: pointSize, scale: displayScale)
    }

    var body: some View {
        ZStack {
            placeholderColor

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .cornerRadius(cornerRadius)
        .shimmering(active: image == nil && !failed)
        .overlay(
            showsBorder
                ? RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5)
                : nil
        )
        .animation(.easeInOut(duration: 0.22), value: image != nil)
        .onAppear { start() }
        .onDisappear { stop() }
        .onChange(of: resourceID) { _, _ in
            stop()
            image = nil
            failed = false
            start()
        }
    }

    private func start() {
        guard let id = resourceID else {
            failed = true
            return
        }

        if let cached = ResourceStore.shared.cachedImage(for: id) {
            image = cached
            failed = false
            return
        }

        loadingID = id
        ResourceStore.shared.beginLoading(id)

        loadTask = Task { @MainActor in
            let loaded = await ResourceStore.shared.image(for: id)
            guard !Task.isCancelled else { return }
            if let loaded {
                image = loaded
            } else {
                failed = true
            }
            if loadingID == id {
                loadingID = nil
                ResourceStore.shared.endLoading(id)
            }
        }
    }

    private func stop() {
        loadTask?.cancel()
        loadTask = nil
        if let id = loadingID {
            loadingID = nil
            ResourceStore.shared.endLoading(id)
        }
    }
}
