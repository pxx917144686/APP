import SwiftUI

struct AppSearchResultCardView: View {
    let app: iTunesSearchResult
    let onTap: () -> Void
    let onGetAction: () -> Void
    @Binding var isDownloading: Bool
    var isPreview: Bool = false
    var showLicenseHint: Bool = false
    var isOwned: Bool? = nil

    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.sizeCategory) private var sizeCategory

    private var ratingText: String {
        guard let rating = app.averageUserRating, rating > 0 else { return "" }
        return String(format: "%.1f", rating)
    }

    private var ratingCountText: String {
        guard let count = app.userRatingCount, count > 0 else { return "" }
        return formatRatingCount(count)
    }

    private var hasRating: Bool {
        guard let rating = app.averageUserRating, rating > 0,
              let count = app.userRatingCount, count > 0 else { return false }
        return true
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 16) {
                topSection
                if !isPreview {
                    screenshotsSection
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.clear)
        }
        .buttonStyle(PlainButtonStyle())
        .id(app.trackId)
    }

    private var topSection: some View {
        HStack(alignment: .top, spacing: 12) {
            appIconView
            appInfoView
            Spacer(minLength: 8)
            getButtonView
        }
    }

    private var appIconView: some View {
        Group {
            if let iconURL = app.artworkUrl100, let url = URL(string: iconURL) {
                ArtworkView(
                    url: url,
                    aspectRatio: 1,
                    contentMode: .fill,
                    cornerRadius: 14,
                    showsBorder: true,
                    loadingAnimation: !isPreview,
                    isPreview: isPreview
                )
                .frame(width: 64, height: 64)
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.systemGray6))
                    .overlay(
                        Image(systemName: "app.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                    )
                    .frame(width: 64, height: 64)
            }
        }
    }

    private var appInfoView: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let genre = app.primaryGenreName {
                Text(genre.uppercased())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text(" ")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.clear)
            }

            Text(app.name)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            if let developer = app.artistName {
                Text(developer)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else {
                Text(" ")
                    .font(.system(size: 15))
                    .foregroundColor(.clear)
            }

            if hasRating, let rating = app.averageUserRating {
                ratingView(rating: rating)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "star")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.clear)
                    Text("0.0")
                        .font(.system(size: 12))
                        .foregroundColor(.clear)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ratingView(rating: Double) -> some View {
        HStack(spacing: 4) {
            StarRatingView(rating: rating, size: 12)

            Text(ratingText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            Text("·")
                .font(.system(size: 12))
                .foregroundColor(.secondary.opacity(0.6))

            Text(ratingCountText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var getButtonView: some View {
        VStack(spacing: 2) {
            Group {
                if isDownloading {
                    AppStoreProgressButtonStyle()
                } else {
                    Button(action: onGetAction) {
                        Text(buttonTitle)
                    }
                    .buttonStyle(AppStoreButtonStyle())
                }
            }
            if showLicenseHint, let owned = isOwned {
                licenseHintText(isOwned: owned)
            }
        }
    }

    private func licenseHintText(isOwned: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isOwned ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.system(size: 10))
                .foregroundColor(isOwned ? .green : .secondary)
            Text(isOwned ? "已获取" : "未获取")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var screenshotsSection: some View {
        let screenshots = app.screenshotUrls ?? app.ipadScreenshotUrls ?? []
        if !screenshots.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(screenshots.enumerated()), id: \.offset) { _, screenshotURL in
                        if let url = URL(string: screenshotURL) {
                            ArtworkView(
                                url: url,
                                contentMode: .fit,
                                cornerRadius: 12,
                                showsBorder: true,
                                loadingAnimation: false,
                                isPreview: isPreview
                            )
                            .frame(
                                width: screenshotWidth,
                                height: screenshotHeight
                            )
                            .background(Color(.systemGray6))
                            .clipped()
                        }
                    }
                }
                .padding(.horizontal, 0)
            }
        }
    }

    private var screenshotWidth: CGFloat {
        140
    }

    private var screenshotHeight: CGFloat {
        250
    }

    private var buttonTitle: String {
        if let fp = app.formattedPrice {
            let lower = fp.lowercased()
            if lower.contains("free") || fp == "free".localized || app.price == 0 {
                return "get".localized
            }
            return fp
        }
        return "get".localized
    }

    private func formatRatingCount(_ count: Int) -> String {
        if count >= 10000 {
            return "\(count / 10000)万"
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        } else {
            return "\(count)"
        }
    }
}
