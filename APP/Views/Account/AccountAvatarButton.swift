import SwiftUI
import UIKit

struct AccountAvatarButton: View {
    @EnvironmentObject private var appStore: AppStore
    @EnvironmentObject private var themeManager: ThemeManager

    @State private var customAvatarImage: UIImage?
    @State private var showImagePicker = false

    var size: CGFloat = 36
    var isEditable: Bool = true

    var body: some View {
        Group {
            if isEditable {
                Button {
                    showImagePicker = true
                } label: {
                    avatarView
                }
                .buttonStyle(.plain)
            } else {
                avatarView
            }
        }
        .onAppear { loadCustomAvatar() }
        .onChange(of: appStore.selectedAccount?.email) { _, _ in
            loadCustomAvatar()
        }
        .sheet(isPresented: $showImagePicker) {
            ImagePicker { image in
                if let image = image {
                    let cropped = cropToSquare(image: image)
                    saveCustomAvatar(cropped)
                    customAvatarImage = cropped
                }
                showImagePicker = false
            }
            .ignoresSafeArea()
        }
    }

    private var avatarView: some View {
        Group {
            if let image = customAvatarImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(themeManager.accentColor.opacity(0.5), lineWidth: 1.5)
                    )
            } else {
                Image("DefaultAvatar")
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(appStore.selectedAccount == nil ? Color.secondary.opacity(0.3) : themeManager.accentColor.opacity(0.5), lineWidth: 1.5)
                    )
            }
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if isEditable && appStore.selectedAccount != nil {
                Image(systemName: "camera.circle.fill")
                    .font(.system(size: size * 0.35))
                    .foregroundStyle(.white, themeManager.accentColor)
                    .offset(x: 2, y: 2)
            }
        }
    }

    private func loadCustomAvatar() {
        guard let account = appStore.selectedAccount else {
            customAvatarImage = nil
            return
        }
        let cacheKey = "custom_avatar_\(account.email)"
        if let cached = UserDefaults.standard.data(forKey: cacheKey),
           let image = UIImage(data: cached) {
            customAvatarImage = image
        } else {
            customAvatarImage = nil
        }
    }

    private func saveCustomAvatar(_ image: UIImage) {
        guard let account = appStore.selectedAccount else { return }
        let cacheKey = "custom_avatar_\(account.email)"
        if let pngData = image.pngData() {
            UserDefaults.standard.set(pngData, forKey: cacheKey)
        }
    }

    private func cropToSquare(image: UIImage) -> UIImage {
        let imageSize = image.size
        let sideLength = min(imageSize.width, imageSize.height)
        let x = (imageSize.width - sideLength) / 2
        let y = (imageSize.height - sideLength) / 2
        let cropRect = CGRect(x: x, y: y, width: sideLength, height: sideLength)
        if let cgImage = image.cgImage?.cropping(to: cropRect) {
            return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
        }
        return image
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    var onPicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.allowsEditing = true
        picker.sourceType = .photoLibrary
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            let image = info[.editedImage] as? UIImage ?? info[.originalImage] as? UIImage
            parent.onPicked(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onPicked(nil)
        }
    }
}

#Preview {
    AccountAvatarButton()
        .environmentObject(AppStore.this)
        .environmentObject(ThemeManager.shared)
}
