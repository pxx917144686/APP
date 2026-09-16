import SwiftUI
import UIKit

struct AltIcon: Identifiable {
	var displayName: String
	var author: String
	var key: String?
	var image: UIImage
	var id: String { key ?? displayName }

	init(displayName: String, author: String, key: String? = nil) {
		self.displayName = displayName
		self.author = author
		self.key = key
		self.image = AppIconView.loadIcon(key)
	}
}

extension Image {
    func appIconStyle() -> some View {
        self
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 64, height: 64)
            .background(Color.white)
            .cornerRadius(13)
            .shadow(radius: 3)
            .padding(8)
    }
}

extension AppIconView {

	static func loadIcon(_ name: String?) -> UIImage {
		guard let iconName = name else {
			if let logo = UIImage(named: "AppLogo") {
				return logo
			}
			return UIImage(systemName: "app.fill") ?? UIImage()
		}

		if iconName == "app" {
			if let logo = UIImage(named: "AppLogo") {
				return logo
			}
		}

		if let image = UIImage(named: iconName) {
			return image
		}

		return UIImage(systemName: "app.fill") ?? UIImage()
	}

	static func getAllIconsFromFolder() -> [AltIcon] {
		let iconInfo: [(key: String?, displayNameKey: String, authorKey: String)] = [
			(nil, "icon_default", "icon_author"),
			("kana_love", "icon_love", "icon_author"),
			("kana_peek", "icon_peek", "icon_author")
		]

		return iconInfo.map { info in
			AltIcon(
				displayName: info.displayNameKey.localized,
				author: info.authorKey.localized,
				key: info.key
			)
		}
	}
}

struct AppIconView: View {
	@Binding var currentIcon: String?
	@State private var showingSuccess = false

	var allIcons: [AltIcon] {
		AppIconView.getAllIconsFromFolder()
	}

	var body: some View {
		ScrollView {
			VStack(spacing: 20) {

				LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
					ForEach(allIcons) { icon in
						_icon(icon: icon)
					}
				}
				.padding(.horizontal, 16)
			}
			.padding(.bottom, 30)
		}
		.navigationTitle("app_icon".localized)
		.onAppear {
			currentIcon = AppIconManager.shared.currentAlternateIconName
		}
	}
}

extension AppIconView {
	@ViewBuilder
	private func _icon(
		icon: AltIcon
	) -> some View {
		let isSelected: Bool = {
			if icon.key == "app" {
				return currentIcon == nil
			} else {
				return currentIcon == icon.key
			}
		}()

		Button {
			if isSelected { return }

			let iconNameToSet = icon.key == "app" ? nil : icon.key

			AppIconManager.shared.setAlternateIconName(iconNameToSet) { success, error in
				DispatchQueue.main.async {
					if success {
						currentIcon = iconNameToSet
					showingSuccess = true
					let impactFeedback = UINotificationFeedbackGenerator()
					impactFeedback.notificationOccurred(.success)
				} else {
					let impactFeedback = UINotificationFeedbackGenerator()
					impactFeedback.notificationOccurred(.error)
				}
				}
			}
		} label: {
			VStack(alignment: .center, spacing: 10) {
				ZStack {
					if icon.image.size.width > 0 && icon.image.size.height > 0 {
						Image(uiImage: icon.image)
							.appIconStyle()
					} else {
						RoundedRectangle(cornerRadius: 13)
							.fill(Color(.systemGray5))
							.frame(width: 64, height: 64)
							.overlay(
								Image(systemName: "app.fill")
									.font(.system(size: 30))
									.foregroundColor(.secondary)
							)
							.padding(8)
					}

					if isSelected {
						VStack {
							Spacer()
							HStack {
								Spacer()
								Image(systemName: "checkmark.circle.fill")
									.font(.system(size: 24, weight: .bold))
									.foregroundColor(.blue)
									.background(Color.white.clipShape(Circle()))
									.padding(.trailing, 2)
									.padding(.bottom, 2)
							}
						}
					}
				}

			}
		}
		.buttonStyle(.plain)
	}
}
