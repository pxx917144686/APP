import SwiftUI

struct ArtworkView: View {
    let url: URL?
    var placeholderColor: Color?
    var aspectRatio: CGFloat?
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0
    var showsBorder: Bool = false
    var loadingAnimation: Bool = true
    var isPreview: Bool = false
    var onImageLoaded: ((UIImage) -> Void)?

    @State private var loadedImage: UIImage?
    @State private var previewImage: UIImage?
    @State private var isLoading = false
    @State private var hasFailed = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            placeholderBackground

            if let image = loadedImage ?? previewImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: contentMode)
                    .opacity(isLoading && loadedImage == nil ? 0 : 1)
                    .animation(loadingAnimation ? .easeInOut(duration: 0.2) : nil, value: isLoading)
            }

            if isLoading && loadingAnimation && !isPreview && loadedImage == nil && previewImage == nil {
                LoadingPlaceholderView()
                    .transition(.opacity)
            }

            if hasFailed {
                FailedPlaceholderView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .cornerRadius(cornerRadius)
        .overlay(
            showsBorder ? RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(Color(.separator).opacity(0.5), lineWidth: 0.5) : nil
        )
        .onAppear {
            loadImage()
        }
        .onDisappear {
            loadTask?.cancel()
        }
        .onChange(of: url) { _, _ in
            loadedImage = nil
            previewImage = nil
            hasFailed = false
            loadTask?.cancel()
            loadImage()
        }
        .onChange(of: isPreview) { _, newValue in
            if !newValue && previewImage != nil && loadedImage == nil {
                loadFullQualityImage()
            }
        }
    }

    @ViewBuilder
    private var placeholderBackground: some View {
        if let color = placeholderColor {
            color
        } else if let image = loadedImage, let avgColor = image.averageColor() {
            Color(uiColor: avgColor.adjustedForDisplay)
                .opacity(loadedImage != nil ? 0 : 1)
        } else {
            Color(.systemGray6)
        }
    }

    private func loadImage() {
        guard let url = url else {
            hasFailed = true
            return
        }

        if let cached = ImageLoader.shared.getCachedImage(for: url) {
            loadedImage = cached
            isLoading = false
            onImageLoaded?(cached)
            return
        }

        if isPreview {
            if let lowQuality = ImageLoader.shared.getLowQualityCachedImage(for: url) {
                previewImage = lowQuality
                return
            }

            isLoading = true
            hasFailed = false

            loadTask = Task {
                let image = await ImageLoader.shared.loadLowQualityImage(from: url)
                await MainActor.run {
                    isLoading = false
                    if let image = image {
                        previewImage = image
                    } else {
                        hasFailed = true
                    }
                }
            }
        } else {
            if let lowQuality = ImageLoader.shared.getLowQualityCachedImage(for: url) {
                previewImage = lowQuality
            }

            loadFullQualityImage()
        }
    }

    private func loadFullQualityImage() {
        guard let url = url else { return }

        isLoading = true
        hasFailed = false

        loadTask?.cancel()

        loadTask = Task {
            let image = await ImageLoader.shared.loadImage(from: url)
            await MainActor.run {
                isLoading = false
                if let image = image {
                    loadedImage = image
                    previewImage = nil
                    onImageLoaded?(image)
                } else if previewImage == nil {
                    hasFailed = true
                }
            }
        }
    }
}

private struct LoadingPlaceholderView: View {
    @State private var isAnimating = false

    var body: some View {
        ZStack {
            Color(.systemGray6)

            LinearGradient(
                colors: [
                    Color(.systemGray6),
                    Color(.systemGray5),
                    Color(.systemGray6)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .mask(
                Rectangle()
                    .offset(x: isAnimating ? 300 : -300)
            )
            .animation(
                .linear(duration: 1.2).repeatForever(autoreverses: false),
                value: isAnimating
            )
        }
        .onAppear {
            isAnimating = true
        }
        .onDisappear {
            isAnimating = false
        }
    }
}

private struct FailedPlaceholderView: View {
    var body: some View {
        ZStack {
            Color(.systemGray6)

            Image(systemName: "photo")
                .font(.system(size: 20))
                .foregroundColor(.secondary)
        }
    }
}
