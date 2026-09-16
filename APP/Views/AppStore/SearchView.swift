import SwiftUI
import UIKit

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct UIKitTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var onEditingChanged: ((Bool) -> Void)?
    var onCommit: (() -> Void)?
    var onTextChange: ((String) -> Void)?

    func makeUIView(context: Context) -> UITextField {
        let textField = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 34))
        textField.placeholder = placeholder
        textField.font = .systemFont(ofSize: 17)
        textField.textColor = .label
        textField.tintColor = .systemBlue
        textField.clearButtonMode = .whileEditing
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.spellCheckingType = .no
        textField.returnKeyType = .search
        textField.enablesReturnKeyAutomatically = true
        textField.delegate = context.coordinator
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.required, for: .vertical)
        textField.setContentHuggingPriority(.required, for: .vertical)
        textField.addTarget(
            context.coordinator,
            action: #selector(Coordinator.textDidChange(_:)),
            for: .editingChanged
        )
        return textField
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.placeholder != placeholder {
            uiView.placeholder = placeholder
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: UIKitTextField

        init(_ parent: UIKitTextField) {
            self.parent = parent
        }

        @objc func textDidChange(_ textField: UITextField) {
            let newText = textField.text ?? ""
            if parent.text != newText {
                parent.text = newText
                parent.onTextChange?(newText)
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            parent.onEditingChanged?(true)
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.onEditingChanged?(false)
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            parent.onCommit?()
            textField.resignFirstResponder()
            return true
        }
    }
}

 extension Date {
     var iso8601: String {
         let formatter = ISO8601DateFormatter()
         return formatter.string(from: self)
     }
 }

func withTimeout<T>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in

        let timeoutTask = Task { () -> T in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }

        group.addTask { [timeoutTask] in
            defer { timeoutTask.cancel() }
            return try await operation()
        }

        let result = try await group.next()
        group.cancelAll()

        if let result = result {
            return result
        } else {
            throw CancellationError()
        }
    }
}

struct EnhancedAppCard: SwiftUI.View {
    let app: iTunesSearchResult
    let onTap: () -> Void
    let onGetAction: () -> Void
    @Binding var isDownloading: Bool
    @SwiftUI.EnvironmentObject var themeManager: ThemeManager

    var body: some SwiftUI.View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 16) {
                topSection

                if !getFeatureTags().isEmpty {
                    featuresSection
                }

                if let screenshots = app.screenshotUrls, !screenshots.isEmpty {
                    screenshotsSection(screenshots)
                }
            }
            .padding()
            .background(Color.clear)
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(0.98)
    }

    private func getFeatureTags() -> [String] {
        var tags: [String] = []

        if let genres = app.genres, !genres.isEmpty {
            tags.append(contentsOf: genres.prefix(3))
        } else if let primaryGenre = app.primaryGenreName {

            tags.append(primaryGenre)
        }

        if let developer = app.artistName, !tags.contains(developer) {
            tags.append(developer)
        }

        let result = Array(Set(tags)).prefix(3).map { $0 }
        return result
    }

    private var topSection: some SwiftUI.View {
        HStack(alignment: .center, spacing: 12) {

            appIcon

            VStack(alignment: .leading, spacing: 4) {

                Text(app.name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                if let developer = app.artistName {
                    Text(developer)
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let rating = app.averageUserRating, rating > 0, let count = app.userRatingCount, count > 0 {
                    HStack(spacing: 4) {
                        HStack(spacing: 1) {
                            ForEach(0..<5) { index in
                                Image(systemName: index < Int(rating.rounded()) ? "star.fill" : "star")
                                    .font(.system(size: 12))
                                    .foregroundColor(.orange)
                            }
                        }
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(formatRatingCount(count))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            getButton
        }
    }

    private var featuresSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            Text("feature_tags".localized)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(getFeatureTags(), id: \.self) {
                        Text($0)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color(.systemGray6))
                            )
                    }
                }
            }
        }
    }

    private func screenshotsSection(_ screenshots: [String]) -> some SwiftUI.View {
        ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(screenshots.prefix(3), id: \.self) { screenshotURL in
                        if let url = URL(string: screenshotURL) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    Color(.systemGray6)
                                }
                            }
                            .frame(width: 120, height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
    }

    private var appIcon: some SwiftUI.View {
        AnyView(
            Group {
                if let iconURL = app.artworkUrl100, let url = URL(string: iconURL) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color(.systemGray6)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    Rectangle()
                        .fill(Color(.systemGray6))
                        .overlay(
                            Image(systemName: "app.fill")
                                .foregroundColor(.secondary)
                        )
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        )
    }

    private var getButton: some SwiftUI.View {
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

struct SearchSuggestionsView: SwiftUI.View {
    let suggestions: [String]
    let onSelect: (String) -> Void
    @SwiftUI.EnvironmentObject var themeManager: ThemeManager

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(suggestions, id: \.self) { suggestion in
                Button(action: {
                    onSelect(suggestion)
                }) {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)

                        Text(suggestion)
                            .font(.body)
                            .foregroundColor(.primary)

                        Spacer()

                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.clear)
                }
                .buttonStyle(PlainButtonStyle())

                if suggestion != suggestions.last {
                    Divider()
                        .background(Color(.separator))
                        .padding(.leading, 44)
                }
            }
        }

    }
}

class APIService: NSObject, URLSessionDelegate {
    static let shared = APIService()

    let baseURL = "https://itunes.apple.com"

    enum Endpoint {
        case search(term: String, country: String, limit: Int = 20)
        case lookup(id: String)
        case reviews(id: String, page: Int = 1)
        case similar(id: String, limit: Int = 10)

        private static let baseURL = "https://itunes.apple.com"

        var urlString: String {
            switch self {
            case .search(let term, let country, let limit):
                return "\(Self.baseURL)/search?term=\(term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term)&country=\(country)&media=software&limit=\(limit)"
            case .lookup(let id):
                return "\(Self.baseURL)/lookup?id=\(id)"
            case .reviews(let id, let page):
                return "\(Self.baseURL)/customer-reviews/id=\(id)/page=\(page)"
            case .similar(let id, let limit):
                return "\(Self.baseURL)/similar/id=\(id)/limit=\(limit)"
            }
        }
    }

    func post<T: Codable>(urlString: String, parameters: [String: Any], completion: @escaping (Result<T, Error>) -> Void) {
        guard let url = URL(string: urlString) else {
            completion(.failure(NSError(domain: "com.apple", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

            let task = URLSession.shared.dataTask(with: request) { (data, response, error) in
                if let error = error {
                    completion(.failure(error))
                    return
                }

                guard let data = data else {
                    completion(.failure(NSError(domain: "com.apple", code: 404, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                    return
                }

                do {
                    let decoder = JSONDecoder()
                    let result = try decoder.decode(T.self, from: data)
                    completion(.success(result))
                } catch {
                    completion(.failure(error))
                }
            }

            task.resume()
        } catch {
            completion(.failure(error))
        }
    }
}

struct AppReview: Codable, Identifiable {
    let id: String
    let userName: String
    let rating: Double
    let title: String
    let content: String
    let date: Date
    let version: String
}

struct EmptyStateView: SwiftUI.View {
    let message: String
    let imageName: String

    var body: some SwiftUI.View {
        VStack(spacing: 16) {
            Image(systemName: imageName)
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AppReviewsView: SwiftUI.View {
    @State private var reviews: [AppReview] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    let appID: String

    var body: some SwiftUI.View {
        VStack {
            if isLoading {
                ProgressView()
                    .padding()
            } else if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            } else if reviews.isEmpty {
                EmptyStateView(message: "no_reviews".localized, imageName: "star.fill")
            } else {
                List(reviews) { review in
                    ReviewCard(review: review)
                }
                .listStyle(PlainListStyle())
            }
        }
        .onAppear(perform: fetchReviews)
    }

    func fetchReviews() {
        Task {
            self.isLoading = true
            self.errorMessage = nil

            do {

                let appID = Int(self.appID) ?? 0
                if appID > 0 {
                    let apiReviews = try await iTunesClient.shared.reviews(id: appID)

                    self.reviews = apiReviews.map { apiReview in

                        let dateFormatter = ISO8601DateFormatter()
                        let date = dateFormatter.date(from: apiReview.updated) ?? Date()

                        return AppReview(
                            id: apiReview.id,
                            userName: apiReview.userName,
                            rating: Double(apiReview.score),
                            title: apiReview.title,
                            content: apiReview.text,
                            date: date,
                            version: apiReview.version
                        )
                    }
                }
            } catch {
                self.errorMessage = String(format: "get_reviews_failed".localized, error.localizedDescription)
            }
            self.isLoading = false
        }
    }
}

struct ReviewCard: SwiftUI.View {
    let review: AppReview

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text(review.userName)
                        .font(.headline)

                    HStack(spacing: 2) {
                        ForEach(1..<6) { star in
                            Image(systemName: star <= Int(review.rating) ? "star.fill" : "star")
                                .font(.system(size: 12))
                                .foregroundColor(star <= Int(review.rating) ? .yellow : Color(.systemGray4))
                        }
                        Text("\(review.rating)/5")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
            }

            Text(review.title)
                .font(.system(size: 15, weight: .medium))

            Text(review.content)
                .font(.body)
                .foregroundColor(.secondary)
                .lineLimit(3)

            HStack {
                Text(String(format: "version_x".localized, review.version))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(formattedDate(review.date))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
    }

    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }
}

struct EnhancedAppDetailView: SwiftUI.View {
    let app: iTunesSearchResult

    var onPrimaryAction: ((iTunesSearchResult) -> Void)? = nil
    @Binding var isDownloading: Bool
    @SwiftUI.Environment(\.dismiss) var dismiss
    @SwiftUI.EnvironmentObject var themeManager: ThemeManager
    @State private var isReleaseNotesExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                headerSection

                if let rating = app.averageUserRating, rating > 0 {
                    ratingsSection

                    AppReviewsView(appID: String(app.trackId))
                        .padding(.horizontal, 16)
                        .frame(height: 300)
                }

                if let description = app.description {
                    descriptionSection(description)
                }

                if let releaseNotes = app.releaseNotes, !releaseNotes.isEmpty {
                    updateNotesSection(releaseNotes)
                }

                informationSection
            }
            .padding()
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var headerSection: some SwiftUI.View {
        let iconURL = app.artworkUrl512 ?? app.artworkUrl100

        return ZStack(alignment: .top) {
            GeometryReader { geometry in
                ZStack {
                    ArtworkView(
                        url: URL(string: iconURL ?? ""),
                        contentMode: .fill,
                        cornerRadius: 0,
                        showsBorder: false,
                        loadingAnimation: false
                    )
                    .frame(width: geometry.size.width * 2, height: geometry.size.width * 2)
                    .position(x: geometry.size.width / 2, y: 0)
                    .blur(radius: 50)
                    .clipped()

                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.black.opacity(0),
                            themeManager.selectedTheme == .dark ? Color.black.opacity(0.7) : Color.black.opacity(0.5)
                        ]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: 210)
            }
            .frame(height: 210)

            VStack(spacing: 0) {
                HStack(alignment: .bottom, spacing: 16) {
                    ArtworkView(
                        url: URL(string: iconURL ?? ""),
                        contentMode: .fill,
                        cornerRadius: 28,
                        showsBorder: true
                    )
                    .frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.15), radius: 12, x: 0, y: 6)

                    VStack(alignment: .leading, spacing: 6) {
                        if let genre = app.primaryGenreName {
                            Text(genre.uppercased())
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        Text(app.name)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.primary)
                            .lineLimit(2)

                        if let developer = app.artistName {
                            Text(developer)
                                .font(.system(size: 15, weight: .regular))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }

                        if let formattedPrice = app.formattedPrice {
                            Text(formattedPrice)
                                .font(.system(size: 13, weight: .regular))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)

                HStack(spacing: 12) {
                    Button(action: { onPrimaryAction?(app) }) {
                        if isDownloading {
                            AppStoreProgressButtonStyle()
                        } else {
                            Text(buttonTitle)
                        }
                    }
                    .buttonStyle(AppStoreButtonStyle())
                    .disabled(isDownloading)

                    Button(action: shareApp) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .frame(width: 36, height: 36)
                            .background(
                                Circle()
                                    .fill(Color(.systemGray6))
                            )
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 20)
            }
        }
        .frame(height: 280)
    }

    private func shareApp() {
        guard let url = URL(string: app.trackViewUrl) else { return }
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)

        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            activityVC.popoverPresentationController?.sourceView = rootVC.view
            rootVC.present(activityVC, animated: true)
        }
    }

    private var ratingsSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ratings_and_reviews".localized)
                .font(.system(size: 20, weight: .bold))

            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 6) {
                    Text(String(format: "%.1f", app.averageUserRating ?? 0))
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.primary)

                    StarRatingView(rating: app.averageUserRating ?? 0, size: 12)

                    if let count = app.userRatingCount {
                        Text(String(format: "x_ratings".localized, formatNumber(count)))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 100, alignment: .center)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach((1...5).reversed(), id: \.self) { star in
                        HStack(spacing: 8) {
                            HStack(spacing: 0) {
                                ForEach(0..<star, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 8))
                                }
                            }
                            .foregroundColor(.secondary)
                            .frame(width: 45, alignment: .trailing)

                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color(.systemGray6))
                                        .frame(height: 3)

                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(themeManager.accentColor)
                                        .frame(width: geometry.size.width * estimatedPercentage(for: star))
                                        .frame(height: 3)
                                }
                            }
                            .frame(height: 3)
                        }
                    }
                }
                .padding(.top, 12)
            }

            Divider()

            NavigationLink(destination: AppReviewsView(appID: String(app.trackId))) {
                HStack {
                    Text("see_all_reviews".localized)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
    }

    private func estimatedPercentage(for star: Int) -> Double {
        let rating = app.averageUserRating ?? 0
        let percentages: [Int: Double]

        if rating >= 4.5 {
            percentages = [5: 0.75, 4: 0.18, 3: 0.04, 2: 0.02, 1: 0.01]
        } else if rating >= 4.0 {
            percentages = [5: 0.60, 4: 0.25, 3: 0.10, 2: 0.03, 1: 0.02]
        } else if rating >= 3.5 {
            percentages = [5: 0.45, 4: 0.30, 3: 0.15, 2: 0.06, 1: 0.04]
        } else if rating >= 3.0 {
            percentages = [5: 0.30, 4: 0.30, 3: 0.20, 2: 0.12, 1: 0.08]
        } else {
            percentages = [5: 0.15, 4: 0.20, 3: 0.25, 2: 0.20, 1: 0.20]
        }

        return percentages[star] ?? 0
    }

    private func descriptionSection(_ description: String) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 12) {
            Text("description".localized)
                .font(.system(size: 20, weight: .bold))

            DescriptionExpandableText(text: description, lineLimit: 5)
        }
    }

    private var informationSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 16) {
            Text("information".localized)
                .font(.system(size: 20, weight: .bold))

            let columns = [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ]

            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(buildInfoItems(), id: \.title) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)

                        Text(item.value)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.primary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                }
            }
        }
    }

    private func buildInfoItems() -> [(title: String, value: String)] {
        var items: [(title: String, value: String)] = []

        if let size = app.fileSizeBytes, !size.isEmpty {
            items.append((title: "size".localized, value: formatFileSize(size)))
        }

        if let category = app.primaryGenreName {
            items.append((title: "category".localized, value: category))
        }

        if let rating = app.contentAdvisoryRating, !rating.isEmpty {
            items.append((title: "age_rating".localized, value: rating))
        }

        if let seller = app.sellerName {
            items.append((title: "developer".localized, value: seller))
        } else if let artist = app.artistName {
            items.append((title: "developer".localized, value: artist))
        }

        if !app.version.isEmpty {
            items.append((title: "current_version".localized, value: app.version))
        }

        if let languages = app.languageCodesISO2A, !languages.isEmpty {
            let langName = Locale.current.localizedString(forLanguageCode: languages.first ?? "") ?? languages.first ?? "EN"
            items.append((title: "language".localized, value: languages.count > 1 ? String(format: "x_languages".localized, String(languages.count)) : langName))
        } else {
            items.append((title: "language".localized, value: "N/A"))
        }

        return items
    }

    private func updateNotesSection(_ notes: String) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("whats_new".localized)
                    .font(.system(size: 20, weight: .bold))

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if !app.version.isEmpty {
                        Text(app.version)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }

                    if let releaseDate = app.currentVersionReleaseDate, !releaseDate.isEmpty {
                        Text(formatShortReleaseDate(releaseDate))
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(notes)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineSpacing(6)
                    .lineLimit(isReleaseNotesExpanded ? nil : 3)

                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isReleaseNotesExpanded.toggle()
                    }
                }) {
                    Text(isReleaseNotesExpanded ? "collapse".localized : "expand".localized)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.blue)
                }
            }
        }
    }

    private var technicalInfoSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 16) {
            Text("tech_info".localized)
                .font(.system(size: 20, weight: .bold))

            VStack(spacing: 12) {
                infoRow(title: "Bundle ID", value: app.bundleId)
                infoRow(title: "Track ID", value: String(app.trackId))

                if let releaseDate = app.releaseDate, !releaseDate.isEmpty {
                    infoRow(title: "first_release".localized, value: formatReleaseDate(releaseDate))
                }

                if let updateDate = app.currentVersionReleaseDate, !updateDate.isEmpty {
                    infoRow(title: "last_updated".localized, value: formatReleaseDate(updateDate))
                }
            }
        }
    }

    private func infoRow(title: String, value: String) -> some SwiftUI.View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(value)
                .font(.subheadline)
                .foregroundColor(.primary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    private func formatFileSize(_ sizeString: String) -> String {
        if let sizeBytes = Double(sizeString) {
            let sizeMB = sizeBytes / (1024 * 1024)
            return String(format: "%.1f MB", sizeMB)
        }
        return sizeString
    }

    private func randomPercentage() -> Double {
        return Double.random(in: 0.1...1.0)
    }

    private func formatReleaseDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"

        if let date = formatter.date(from: dateString) {
            formatter.dateFormat = "yyyy年MM月dd日"
            return formatter.string(from: date)
        }
        return dateString
    }

    private func formatShortReleaseDate(_ dateString: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"

        if let date = formatter.date(from: dateString) {
            formatter.dateFormat = "MM/dd/yyyy"
            return formatter.string(from: date)
        }
        return dateString
    }

    var buttonTitle: String {
        if let fp = app.formattedPrice {
            let lower = fp.lowercased()
            if lower.contains("free") || fp == "free".localized || app.price == 0 {
                return "get".localized
            }
            return fp
        }
        return "get".localized
    }
}

struct DescriptionExpandableText: View {
    let text: String
    var lineLimit: Int = 5

    @State private var isExpanded = false
    @State private var isTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomTrailing) {
                Text(text)
                    .font(.body)
                    .foregroundColor(.primary)
                    .lineSpacing(6)
                    .lineLimit(isExpanded ? nil : lineLimit)
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear {
                                    detectTruncation(in: geometry)
                                }
                                .onChange(of: text) { _, _ in
                                    detectTruncation(in: geometry)
                                }
                        }
                    )

                if isTruncated && !isExpanded {
                    HStack(spacing: 0) {
                        Spacer()

                        LinearGradient(
                            colors: [
                                Color(.systemBackground).opacity(0),
                                Color(.systemBackground).opacity(1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 60, height: 24)

                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                isExpanded = true
                            }
                        }) {
                            Text("more".localized)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.blue)
                                .padding(.leading, 8)
                                .background(Color(.systemBackground))
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }

            if isExpanded && isTruncated {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            isExpanded = false
                        }
                    }) {
                        Text("less".localized)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detectTruncation(in geometry: GeometryProxy) {
        let textView = UITextView()
        textView.text = text
        textView.font = .systemFont(ofSize: UIFont.systemFontSize)
        textView.textContainer.maximumNumberOfLines = lineLimit
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.frame.size = CGSize(
            width: geometry.size.width,
            height: .greatestFiniteMagnitude
        )
        textView.sizeToFit()

        let layoutHeight = textView.sizeThatFits(
            CGSize(width: geometry.size.width, height: .greatestFiniteMagnitude)
        ).height

        let lineHeight = textView.font?.lineHeight ?? 20
        let maxHeight = CGFloat(lineLimit) * lineHeight + (CGFloat(lineLimit - 1) * 6)

        DispatchQueue.main.async {
            isTruncated = layoutHeight > maxHeight
        }
    }
}

struct SearchView: SwiftUI.View {

    @AppStorage("searchKey") var searchKey = ""
    @AppStorage("searchHistory") var searchHistoryData = Data()
    @FocusState var searchKeyFocused
    @State var searchType = DeviceFamily.phone
    @EnvironmentObject var themeManager: ThemeManager

    private var searchBarBackgroundColor: Color {
        Color(.systemGray6)
    }
    @EnvironmentObject var appStore: AppStore
    @StateObject private var sessionManager = SessionManager.shared
    @State var searching = false

    @State var showLoginSheet = false
    @State var showAccountMenu = false
    @State var showAccountSheet = false

    @State var isDownloading = false

    @State var purchasingTrackId: Int?

    static let countryCodeMap: [String: String] = [
        "AE": "United Arab Emirates", "AG": "Antigua and Barbuda", "AI": "Anguilla", "AL": "Albania", "AM": "Armenia",
        "AO": "Angola", "AR": "Argentina", "AT": "Austria", "AU": "Australia", "AZ": "Azerbaijan",
        "BB": "Barbados", "BD": "Bangladesh", "BE": "Belgium", "BG": "Bulgaria", "BH": "Bahrain",
        "BM": "Bermuda", "BN": "Brunei", "BO": "Bolivia", "BR": "Brazil", "BS": "Bahamas",
        "BW": "Botswana", "BY": "Belarus", "BZ": "Belize", "CA": "Canada", "CH": "Switzerland",
        "CI": "Côte d'Ivoire", "CL": "Chile", "CN": "China", "CO": "Colombia", "CR": "Costa Rica",
        "CY": "Cyprus", "CZ": "Czech Republic", "DE": "Germany", "DK": "Denmark", "DM": "Dominica",
        "DO": "Dominican Republic", "DZ": "Algeria", "EC": "Ecuador", "EE": "Estonia", "EG": "Egypt",
        "ES": "Spain", "FI": "Finland", "FR": "France", "GB": "United Kingdom", "GD": "Grenada",
        "GE": "Georgia", "GH": "Ghana", "GR": "Greece", "GT": "Guatemala", "GY": "Guyana",
        "HK": "Hong Kong", "HN": "Honduras", "HR": "Croatia", "HU": "Hungary", "ID": "Indonesia",
        "IE": "Ireland", "IL": "Israel", "IN": "India", "IS": "Iceland", "IT": "Italy",
        "JM": "Jamaica", "JO": "Jordan", "JP": "Japan", "KE": "Kenya", "KN": "Saint Kitts and Nevis",
        "KR": "South Korea", "KW": "Kuwait", "KY": "Cayman Islands", "KZ": "Kazakhstan", "LB": "Lebanon",
        "LC": "Saint Lucia", "LI": "Liechtenstein", "LK": "Sri Lanka", "LT": "Lithuania", "LU": "Luxembourg",
        "LV": "Latvia", "MD": "Moldova", "MG": "Madagascar", "MK": "North Macedonia", "ML": "Mali",
        "MN": "Mongolia", "MO": "Macao", "MS": "Montserrat", "MT": "Malta", "MU": "Mauritius",
        "MV": "Maldives", "MX": "Mexico", "MY": "Malaysia", "NE": "Niger", "NG": "Nigeria",
        "NI": "Nicaragua", "NL": "Netherlands", "NO": "Norway", "NP": "Nepal", "NZ": "New Zealand",
        "OM": "Oman", "PA": "Panama", "PE": "Peru", "PH": "Philippines", "PK": "Pakistan",
        "PL": "Poland", "PT": "Portugal", "PY": "Paraguay", "QA": "Qatar", "RO": "Romania",
        "RS": "Serbia", "RU": "Russia", "SA": "Saudi Arabia", "SE": "Sweden", "SG": "Singapore",
        "SI": "Slovenia", "SK": "Slovakia", "SN": "Senegal", "SR": "Suriname", "SV": "El Salvador",
        "TC": "Turks and Caicos", "TH": "Thailand", "TN": "Tunisia", "TR": "Turkey", "TT": "Trinidad and Tobago",
        "TW": "Taiwan", "TZ": "Tanzania", "UA": "Ukraine", "UG": "Uganda", "US": "United States",
        "UY": "Uruguay", "UZ": "Uzbekistan", "VC": "Saint Vincent and the Grenadines", "VE": "Venezuela",
        "VG": "British Virgin Islands", "VN": "Vietnam", "YE": "Yemen", "ZA": "South Africa"
    ]

    static let countryCodeMapChinese: [String: String] = [
        "AE": "阿联酋", "AG": "安提瓜和巴布达", "AI": "安圭拉", "AL": "阿尔巴尼亚", "AM": "亚美尼亚",
        "AO": "安哥拉", "AR": "阿根廷", "AT": "奥地利", "AU": "澳大利亚", "AZ": "阿塞拜疆",
        "BB": "巴巴多斯", "BD": "孟加拉国", "BE": "比利时", "BG": "保加利亚", "BH": "巴林",
        "BM": "百慕大", "BN": "文莱", "BO": "玻利维亚", "BR": "巴西", "BS": "巴哈马",
        "BW": "博茨瓦纳", "BY": "白俄罗斯", "BZ": "伯利兹", "CA": "加拿大", "CH": "瑞士",
        "CI": "科特迪瓦", "CL": "智利", "CN": "中国", "CO": "哥伦比亚", "CR": "哥斯达黎加",
        "CY": "塞浦路斯", "CZ": "捷克", "DE": "德国", "DK": "丹麦", "DM": "多米尼克",
        "DO": "多米尼加", "DZ": "阿尔及利亚", "EC": "厄瓜多尔", "EE": "爱沙尼亚", "EG": "埃及",
        "ES": "西班牙", "FI": "芬兰", "FR": "法国", "GB": "英国", "GD": "格林纳达",
        "GE": "格鲁吉亚", "GH": "加纳", "GR": "希腊", "GT": "危地马拉", "GY": "圭亚那",
        "HK": "香港", "HN": "洪都拉斯", "HR": "克罗地亚", "HU": "匈牙利", "ID": "印度尼西亚",
        "IE": "爱尔兰", "IL": "以色列", "IN": "印度", "IS": "冰岛", "IT": "意大利",
        "JM": "牙买加", "JO": "约旦", "JP": "日本", "KE": "肯尼亚", "KN": "圣基茨和尼维斯",
        "KR": "韩国", "KW": "科威特", "KY": "开曼群岛", "KZ": "哈萨克斯坦", "LB": "黎巴嫩",
        "LC": "圣卢西亚", "LI": "列支敦士登", "LK": "斯里兰卡", "LT": "立陶宛", "LU": "卢森堡",
        "LV": "拉脱维亚", "MD": "摩尔多瓦", "MG": "马达加斯加", "MK": "北马其顿", "ML": "马里",
        "MN": "蒙古", "MO": "澳门", "MS": "蒙特塞拉特", "MT": "马耳他", "MU": "毛里求斯",
        "MV": "马尔代夫", "MX": "墨西哥", "MY": "马来西亚", "NE": "尼日尔", "NG": "尼日利亚",
        "NI": "尼加拉瓜", "NL": "荷兰", "NO": "挪威", "NP": "尼泊尔", "NZ": "新西兰",
        "OM": "阿曼", "PA": "巴拿马", "PE": "秘鲁", "PH": "菲律宾", "PK": "巴基斯坦",
        "PL": "波兰", "PT": "葡萄牙", "PY": "巴拉圭", "QA": "卡塔尔", "RO": "罗马尼亚",
        "RS": "塞尔维亚", "RU": "俄罗斯", "SA": "沙特阿拉伯", "SE": "瑞典", "SG": "新加坡",
        "SI": "斯洛文尼亚", "SK": "斯洛伐克", "SN": "塞内加尔", "SR": "苏里南", "SV": "萨尔瓦多",
        "TC": "特克斯和凯科斯群岛", "TH": "泰国", "TN": "突尼斯", "TR": "土耳其", "TT": "特立尼达和多巴哥",
        "TW": "台湾", "TZ": "坦桑尼亚", "UA": "乌克兰", "UG": "乌干达", "US": "美国",
        "UY": "乌拉圭", "UZ": "乌兹别克斯坦", "VC": "圣文森特和格林纳丁斯", "VE": "委内瑞拉",
        "VG": "英属维尔京群岛", "VN": "越南", "YE": "也门", "ZA": "南非"
    ]

    static let storeFrontCodeMap = [
        "AE": "143481", "AG": "143540", "AI": "143538", "AL": "143575", "AM": "143524",
        "AO": "143564", "AR": "143505", "AT": "143445", "AU": "143460", "AZ": "143568",
        "BB": "143541", "BD": "143490", "BE": "143446", "BG": "143526", "BH": "143559",
        "BM": "143542", "BN": "143560", "BO": "143556", "BR": "143503", "BS": "143539",
        "BW": "143525", "BY": "143565", "BZ": "143555", "CA": "143455", "CH": "143459",
        "CI": "143527", "CL": "143483", "CN": "143465", "CO": "143501", "CR": "143495",
        "CY": "143557", "CZ": "143489", "DE": "143443", "DK": "143458", "DM": "143545",
        "DO": "143508", "DZ": "143563", "EC": "143509", "EE": "143518", "EG": "143516",
        "ES": "143454", "FI": "143447", "FR": "143442", "GB": "143444", "GD": "143546",
        "GE": "143615", "GH": "143573", "GR": "143448", "GT": "143504", "GY": "143553",
        "HK": "143463", "HN": "143510", "HR": "143494", "HU": "143482", "ID": "143476",
        "IE": "143449", "IL": "143491", "IN": "143467", "IS": "143558", "IT": "143450",
        "JM": "143511", "JO": "143528", "JP": "143462", "KE": "143529", "KN": "143548",
        "KR": "143466", "KW": "143493", "KY": "143544", "KZ": "143517", "LB": "143497",
        "LC": "143549", "LI": "143522", "LK": "143486", "LT": "143520", "LU": "143451",
        "LV": "143519", "MD": "143523", "MG": "143531", "MK": "143530", "ML": "143532",
        "MN": "143592", "MO": "143515", "MS": "143547", "MT": "143521", "MU": "143533",
        "MV": "143488", "MX": "143468", "MY": "143473", "NE": "143534", "NG": "143561",
        "NI": "143512", "NL": "143452", "NO": "143457", "NP": "143484", "NZ": "143461",
        "OM": "143562", "PA": "143485", "PE": "143507", "PH": "143474", "PK": "143477",
        "PL": "143478", "PT": "143453", "PY": "143513", "QA": "143498", "RO": "143487",
        "RS": "143500", "RU": "143469", "SA": "143479", "SE": "143456", "SG": "143464",
        "SI": "143499", "SK": "143496", "SN": "143535", "SR": "143554", "SV": "143506",
        "TC": "143552", "TH": "143475", "TN": "143536", "TR": "143480", "TT": "143551",
        "TW": "143470", "TZ": "143572", "UA": "143492", "UG": "143537", "US": "143441",
        "UY": "143514", "UZ": "143566", "VC": "143550", "VE": "143502", "VG": "143543",
        "VN": "143471", "YE": "143571", "ZA": "143472"
    ]

    @State var searchResult: [iTunesSearchResult] = []
    @State var legacyResults: [iTunesSearchResult] = []
    @State private var currentPage = 1
    @State private var isLoadingMore = false
    private let pageSize = 20
    @State var searchHistory: [String] = []
    @State var showSearchHistory = false
    @State var isHovered = false
    @State var searchError: String? = nil
    @State var searchSuggestions: [String] = []
    @State var isFetchingSuggestions: Bool = false
    @State var searchCache: [String: [iTunesSearchResult]] = [:]
    @State var showSearchSuggestions = false
    @StateObject private var suggestionsDebounce = Debounce(delay: 0.1)
    private let searchSuggestionsCache = LRUCache<String, [String]>(capacity: 50)
    @StateObject var vm = AppStore.this
    @State private var animateLogo = false
    @State private var scrollVelocity: CGFloat = 0
    @State private var isScrollingFast = false

    @State var showVersionPicker = false
    @State var selectedApp: iTunesSearchResult?
    @State var availableVersions: [StoreAppVersion] = []
    @State var versionHistory: [iTunesClient.AppVersionInfo] = []

    @State private var showPurchaseAlert: Bool = false
    @State private var purchaseAlertText: String = ""
    @State var isLoadingVersions = false
    @State var versionError: String?
    var possibleReigon: Set<String> {
        vm.selectedAccount != nil ? Set([vm.selectedAccount!.countryCode]) : Set()
    }
    var body: some SwiftUI.View {
        NavigationView {
            ZStack {
                Color(.systemBackground)
                    .ignoresSafeArea()

                VStack(spacing: 0) {

                    modernSearchBar
                        .padding(.horizontal, 16)
                        .background(Color(.systemBackground))

                    categorySelector

                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            searchResultsSection
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .background(
                            GeometryReader { geometry in
                                Color.clear
                                    .preference(key: ScrollOffsetPreferenceKey.self, value: geometry.frame(in: .named("scroll")).origin.y)
                            }
                        )
                        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                            detectScrollVelocity(offset: value)
                        }
                    }
                    .coordinateSpace(name: "scroll")
                    .refreshable {
                        if !searchKey.isEmpty {
                            await performSearch()
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarHidden(true)
            .sheet(isPresented: $showVersionPicker) {
                versionPickerSheet
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
            .sheet(isPresented: $showAccountSheet) {
                AccountSheetView()
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
            .sheet(isPresented: $showLoginSheet) {
                AddAccountView()
                    .environmentObject(appStore)
                    .environmentObject(themeManager)
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            loadSearchHistory()
            sessionManager.startSessionMonitoring()
            animateLogo = true
        }
        .onDisappear {

            sessionManager.stopSessionMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ForceRefreshUI"))) { _ in
            animateLogo = true
        }

    }

    var modernSearchBar: some SwiftUI.View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.secondary)
                UIKitTextField(
                    text: $searchKey,
                    placeholder: "search_placeholder".localized,
                    onEditingChanged: { isFocused in
                        searchKeyFocused = isFocused
                        if isFocused, !searchKey.isEmpty {
                            showSearchSuggestions = true
                            searchSuggestions = getSearchSuggestions(for: searchKey)
                            if let cached = searchSuggestionsCache.value(forKey: searchKey) {
                                let combined = Array(Set((searchSuggestions + cached))).sorted()
                                searchSuggestions = combined
                            }
                        }
                    },
                    onCommit: {
                        showSearchSuggestions = false
                        Task {
                            await performSearch()
                        }
                    },
                    onTextChange: { newValue in
                        if !newValue.isEmpty {
                            showSearchSuggestions = true

                            searchSuggestions = getSearchSuggestions(for: newValue)

                            if let cached = searchSuggestionsCache.value(forKey: newValue) {
                                let combined = Array(Set((searchSuggestions + cached))).sorted()
                                searchSuggestions = combined
                            }

                            suggestionsDebounce.execute {
                                Task { await fetchRemoteSuggestions(for: newValue) }
                            }
                        } else {
                            suggestionsDebounce.cancel()
                            showSearchSuggestions = false
                            searchSuggestions = []
                        }
                    }
                )
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                if !searchKey.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            searchKey = ""
                            searchResult = []
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(searchBarBackgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(
                        searchKeyFocused ? themeManager.accentColor : Color.clear,
                        lineWidth: 2
                    )
            )
            .padding(.top, 8)

            HStack(spacing: 16) {

                Menu {
                    ForEach(DeviceFamily.allCases, id: \.self) { type in
                        Button {
                            searchType = type
                        } label: {
                            HStack {
                                Image(systemName: "iphone")
                                Text(type.displayName)
                                if searchType == type {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                            .font(.system(size: 14, weight: .medium))
                        Text(searchType.displayName)
                            .font(.caption)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(themeManager.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(themeManager.accentColor.opacity(0.1))
                    )
                }

                Spacer()

                Button(action: {
                    showAccountSheet = true
                }) {
                    AccountAvatarButton(size: 36, isEditable: false)
                        .environmentObject(appStore)
                        .environmentObject(themeManager)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
    }

    var accountStatusBar: some SwiftUI.View {
        VStack(spacing: 0) {
            if let currentAccount = appStore.selectedAccount {

                HStack(spacing: 16) {

                    HStack(spacing: 8) {
                        Image(systemName: "person.circle.fill")
                            .font(.title2)
                            .foregroundColor(themeManager.accentColor)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(currentAccount.email)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            HStack(spacing: 8) {
                                Text(flag(country: currentAccount.countryCode))
                                    .font(.caption)
                                Text(SearchView.countryCodeMapChinese[currentAccount.countryCode] ?? SearchView.countryCodeMap[currentAccount.countryCode] ?? currentAccount.countryCode)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Spacer()

                    Button(action: {
                        logoutAccount()
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .font(.caption)
                            Text("logout".localized)
                                .font(.caption)
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color(.systemGray6))
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(themeManager.accentColor.opacity(0.2), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            } else {

                HStack(spacing: 16) {
                    Image(systemName: "person.circle")
                        .font(.title)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button(action: {
                        showLoginSheet = true
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.fill.badge.plus")
                                .font(.caption)
                            Text("login".localized)
                                .font(.caption)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(.separator), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }
        }
    }

    var searchHistorySection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("search_history".localized, systemImage: "clock.arrow.circlepath")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        clearSearchHistory()
                    }
                }) {
                    Text("clear_all".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 24)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(searchHistory.prefix(8), id: \.self) { history in
                        HStack(spacing: 6) {
                            Button(action: {
                                searchKey = history
                                showSearchHistory = false
                                Task {
                                    await performSearch()
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 12))
                                    Text(history)
                                        .font(.caption)
                                }
                                .padding(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                                .background(Capsule().fill(Color(.systemGray6)))
                                .foregroundColor(.primary)
                            }

                            Button(action: {
                                withAnimation(.easeIn(duration: 0.2)) {
                                    removeFromHistory(history)
                                }
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .shadow(radius: 15)
        .padding(.horizontal, 16)
    }

    var searchSuggestionsSection: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lightbulb.fill")
                    .font(.system(size: 16, weight: .medium))
                Text("search_suggestions".localized)
                    .font(.title3)
                Spacer()
                Button("close".localized) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSearchSuggestions = false
                    }
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
            .foregroundColor(.blue)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(searchSuggestions.prefix(8), id: \.self) { suggestion in
                        Button {
                            searchKey = suggestion
                            showSearchSuggestions = false
                            Task {
                                await performSearch()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 12))
                                Text(suggestion)
                                    .font(.caption)
                            }
                            .foregroundColor(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color(.secondarySystemBackground))
                                    .overlay(
                                        Capsule()
                                            .stroke(.blue.opacity(0.2), lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.horizontal, 24)
    }

    var categorySelector: some SwiftUI.View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    var searchResultsSection: some SwiftUI.View {
        VStack(spacing: 16) {
            if !searchResult.isEmpty {

                currentAccountIndicator

                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: "x_results_found".localized, String(searchResult.count)))
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                    Spacer()

                }
                .padding(.horizontal, 16)
            }

            if let error = searchError {
                searchErrorView(error: error)
            } else if searching {
                searchingIndicator
            } else if searchResult.isEmpty {
                if legacyResults.isEmpty {
                    emptyStateView
                } else {
                    legacyResultsSection
                }
            } else {
                searchResultsGrid
                if !legacyResults.isEmpty { legacyResultsSection }
            }
        }
    }

    var legacyResultsSection: some SwiftUI.View {
        VStack(spacing: 16) {
            HStack {
                Text("历史应用（已下架）")
                    .font(.title3.bold())
                    .foregroundColor(.primary)
                Spacer()
                Text("\(legacyResults.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)

            LazyVStack(spacing: 16) {
                ForEach(legacyResults.indices, id: \.self) { index in
                    AnyView(resultCardView(item: legacyResults[index], index: index))
                }
            }
            .padding(.horizontal, 24)
        }
    }

    struct ProIDHistoryVersion {
        let version: String
        let versionId: String
    }

    nonisolated func fetchProIDHistory(trackId: Int) async -> [ProIDHistoryVersion] {
        guard let url = URL(string: "https://appstorepro-id.ericloveyou.dpdns.org/api/history?app_id=\(trackId)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["versions"] as? [[String: Any]] else { return [] }
        var out: [ProIDHistoryVersion] = []
        for item in arr {
            if let v = item["version"] as? String, let vid = item["versionid"] as? String, !vid.isEmpty {
                out.append(ProIDHistoryVersion(version: v, versionId: vid))
            }
        }
        return out
    }

    func fetchLegacyApps(term: String, exclude: Set<String>) async -> [iTunesSearchResult] {
        guard let termEnc = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.appdb.to/v1/search/\(termEnc)") else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue("Asspp/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["status"] as? String) == "ok",
              let arr = obj["data"] as? [[String: Any]] else { return [] }

        let region = appStore.selectedAccount?.countryCode ?? "US"
        var out: [iTunesSearchResult] = []
        for item in arr.prefix(8) {
            guard let bid = item["bid"] as? String, !bid.isEmpty, !exclude.contains(bid) else { continue }
            guard case .some(let hit) = try? await iTunesClient.shared.lookup(bundleIdentifier: bid, countryCode: region) else { continue }
            out.append(hit)
        }
        return out
    }

    var searchingIndicator: some SwiftUI.View {
        VStack(spacing: 24) {

            ZStack {
                Circle()
                    .stroke(themeManager.accentColor.opacity(0.2), lineWidth: 4)
                    .frame(width: 60, height: 60)
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(
                        LinearGradient(
                            colors: [themeManager.accentColor, Color(.systemGray4)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(searching ? 360 : 0))
                    .animation(
                        .linear(duration: 1.5).repeatForever(autoreverses: false),
                        value: searching
                    )
            }
            VStack(spacing: 8) {
                Text("searching".localized)
                    .font(.title2)
                    .foregroundColor(.primary)
                Text("finding_best_results".localized)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    var emptyStateView: some SwiftUI.View {
        VStack(spacing: 24) {

            Image("AppLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .cornerRadius(24)
                .scaleEffect(animateLogo ? 1.1 : 1.0)
                .opacity(animateLogo ? 1.0 : 0.7)
                .animation(
                    Animation.easeInOut(duration: 2).repeatForever(autoreverses: true),
                    value: animateLogo
                )
            VStack(spacing: 8) {
                Text("app_downgrade".localized)
                    .font(.title)
                    .foregroundColor(.primary)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            if !searchHistory.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("search_history".localized)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(searchHistory.prefix(3), id: \.self) { history in
                            HStack(spacing: 4) {
                                Button {
                                    searchKey = history
                                    Task {
                                        await performSearch()
                                    }
                                } label: {
                                    Text(history)
                                        .font(.caption)
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 8)
                                        .background(
                                            Capsule()
                                                .stroke(.blue.opacity(0.3), lineWidth: 1)
                                        )
                                }
                                .buttonStyle(.plain)

                                Button {
                                    withAnimation(.easeInOut) {
                                        removeFromHistory(history)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    func searchErrorView(error: String) -> some SwiftUI.View {
        VStack(spacing: 24) {

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.red.opacity(0.1), .red.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(.red.opacity(0.8))
            }
            VStack(spacing: 8) {
                Text("search_error".localized)
                    .font(.title)
                    .foregroundColor(.primary)
                Text(error)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }

            Button {
                searchError = nil
                Task {
                    await performSearch()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                    Text("retry".localized)
                        .font(.subheadline)
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .blue.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .shadow(color: .blue.opacity(0.3), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    var searchResultsGrid: some SwiftUI.View {
        Group {

            LazyVStack(spacing: 16) {
                ForEach(searchResult.indices, id: \.self) { index in
                    let item = searchResult[index]
                    AnyView(resultCardView(item: item, index: index))
                }
            }
            .padding(.horizontal, 24)
            .onAppear {
            }

            if isLoadingMore {
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("load_more".localized)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 24)
            }
        }
    }

    func resultCardView(item: iTunesSearchResult, index: Int) -> any SwiftUI.View {
        return AppSearchResultCardView(app: item, onTap: {
            handleDownloadApp(item)
        }, onGetAction: {

            handleDownloadApp(item)
        }, isDownloading: $isDownloading, isPreview: isScrollingFast)
        .environmentObject(themeManager)
        .id(item.trackId)
        .animation(nil, value: isScrollingFast)
    }

    @State private var lastScrollOffset: CGFloat = 0
    @State private var lastScrollTime: Date = Date()

    private func detectScrollVelocity(offset: CGFloat) {
        let now = Date()
        let timeDiff = now.timeIntervalSince(lastScrollTime)

        if timeDiff > 0 {
            let offsetDiff = abs(offset - lastScrollOffset)
            let velocity = offsetDiff / timeDiff
            scrollVelocity = velocity

            let fastThreshold: CGFloat = 800
            let isFast = velocity > fastThreshold

            if isFast != isScrollingFast {
                withAnimation(.easeInOut(duration: 0.1)) {
                    isScrollingFast = isFast
                }
            }
        }

        lastScrollOffset = offset
        lastScrollTime = now
    }

    func flag(country: String) -> String {
        let base: UInt32 = 127397
        var s = ""
        for v in country.unicodeScalars {
            if let scalar = UnicodeScalar(base + v.value) {
                s.unicodeScalars.append(scalar)
            }
        }
        return String(s)
    }
    @MainActor
    // 精选下架应用：用户搜索这些关键词时，无论 Apple 索引状态如何，固定置顶显示
    static let curatedApps: [(keywords: [String], bundleId: String)] = [
        (["forward", "fwrd"], "com.forward.iphone")
    ]

    func fetchCuratedApps(term: String, country: String) async -> [iTunesSearchResult] {
        let normalized = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        var bids: [String] = []
        for entry in Self.curatedApps where entry.keywords.contains(where: { normalized.contains($0) || normalized.count >= 3 && $0.hasPrefix(normalized) }) {
            bids.append(entry.bundleId)
        }
        guard !bids.isEmpty else { return [] }
        var regions = [country.lowercased()]
        if !regions.contains("us") { regions.append("us") }
        var out: [iTunesSearchResult] = []
        var seen = Set<Int>()
        for bid in bids {
            for region in regions {
                if case .some(let hit) = try? await iTunesClient.shared.lookup(bundleIdentifier: bid, countryCode: region),
                   !seen.contains(hit.trackId) {
                    seen.insert(hit.trackId)
                    out.append(hit)
                    break
                }
            }
        }
        return out
    }

    func performSearch() async {
        guard !searchKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        AnalyticsManager.shared.track("search", properties: ["keyword": searchKey])

        let regionToUse = appStore.selectedAccount?.countryCode ?? "US"

        // 精选应用保底：与搜索结果合并置顶（搜索接口失败也照样显示）
        let curatedHits = await fetchCuratedApps(term: searchKey, country: regionToUse)

        withAnimation(.easeInOut) {
            searching = true
            searchResult = []
            currentPage = 1
            searchError = nil
        }
        addToSearchHistory(searchKey)
        showSearchHistory = false
        let cacheKey = "\(searchKey)_\(searchType.rawValue)_\(regionToUse)"
        if let cachedResult = searchCache[cacheKey] {
            let curatedIds = Set(curatedHits.map(\.trackId))
            let merged = curatedHits + cachedResult.filter { !curatedIds.contains($0.trackId) }
            await MainActor.run {
                withAnimation(.spring()) {
                    searchResult = merged
                    searching = false
                }
            }
            return
        }

        do {
            let response = try await iTunesClient.shared.search(
                term: searchKey,
                limit: pageSize,
                countryCode: regionToUse,
                deviceFamily: searchType
            )
            var finalResults = response ?? []
            if finalResults.isEmpty, searchKey.contains("."), case .some(let hit) = try? await iTunesClient.shared.lookup(bundleIdentifier: searchKey, countryCode: regionToUse) {
                finalResults = [hit]
            }
            let legacyHits = await fetchLegacyApps(term: searchKey, exclude: Set(finalResults.map(\.bundleId)))
            let curatedIds = Set(curatedHits.map(\.trackId))
            let merged = curatedHits + finalResults.filter { !curatedIds.contains($0.trackId) }
            await MainActor.run {
                withAnimation(.spring()) {
                    searchResult = merged
                    legacyResults = legacyHits
                    searching = false
                    searchCache[cacheKey] = merged
                    updateSearchSuggestions(from: merged)
                }
            }
        } catch {
            await MainActor.run {
                withAnimation(.easeInOut) {
                    searching = false
                    searchError = error.localizedDescription
                }
            }
        }
    }
    func loadSearchHistory() {
        if let data = try? JSONDecoder().decode([String].self, from: searchHistoryData) {
            searchHistory = data
        }
    }
    func saveSearchHistory() {
        if let data = try? JSONEncoder().encode(searchHistory) {
            searchHistoryData = data
        }
    }
    func addToSearchHistory(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        searchHistory.removeAll { $0 == trimmedQuery }

        searchHistory.insert(trimmedQuery, at: 0)

        if searchHistory.count > 20 {
            searchHistory = Array(searchHistory.prefix(20))
        }
        saveSearchHistory()
    }
    func removeFromHistory(_ query: String) {
        searchHistory.removeAll { $0 == query }
        saveSearchHistory()
    }
    func clearSearchHistory() {
        searchHistory.removeAll()
        saveSearchHistory()
        showSearchHistory = false
    }
    func loadMoreResults() {
        guard !isLoadingMore && !searching && !searchKey.isEmpty else { return }
        isLoadingMore = true
        currentPage += 1
        Task {
            do {

                let regionToUse = appStore.selectedAccount?.countryCode ?? "US"
                let response = try await iTunesClient.shared.search(
                    term: searchKey,
                    limit: pageSize,
                    countryCode: regionToUse,
                    deviceFamily: searchType
                )
                let results = response ?? []
                await MainActor.run {

                    if !results.isEmpty {
                        searchResult.append(contentsOf: results)
                    }
                    isLoadingMore = false
                }
            } catch {
                await MainActor.run {
                    isLoadingMore = false
                    currentPage -= 1
                    searchError = error.localizedDescription
                }
            }
        }
    }
    func updateSearchSuggestions(from results: [iTunesSearchResult]) {
        var suggestions: Set<String> = []
        for result in results.prefix(10) {
            let appName = result.name
            if !appName.isEmpty {
                suggestions.insert(appName)
            }
            if let artistName = result.artistName, !artistName.isEmpty {
                suggestions.insert(artistName)
            }
        }
        searchSuggestions = Array(suggestions).sorted()
    }

    func fetchRemoteSuggestions(for query: String) async {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if isFetchingSuggestions { return }
        isFetchingSuggestions = true
        defer { isFetchingSuggestions = false }

        if let cached = searchSuggestionsCache.value(forKey: query) {
            let combined = Array(Set((searchSuggestions + cached))).sorted()
            await MainActor.run { self.searchSuggestions = combined }
            return
        }

        let res = await SearchManager.shared.suggest(term: query)
        switch res {
        case .success(let terms):
            let remote = terms.map { $0.term }
            searchSuggestionsCache.setValue(remote, forKey: query)
            let combined = Array(Set((searchSuggestions + remote))).sorted()
            await MainActor.run { self.searchSuggestions = combined }
        case .failure:
            break
        }
    }
    func clearSearchCache() {
        searchCache.removeAll()
    }
    func getSearchSuggestions(for query: String) -> [String] {
        guard !query.isEmpty else { return [] }
        let lowercaseQuery = query.lowercased()
        let historySuggestions = searchHistory.filter { $0.lowercased().contains(lowercaseQuery) }
        let dynamicSuggestions = searchSuggestions.filter { $0.lowercased().contains(lowercaseQuery) }
        return Array(Set(historySuggestions + dynamicSuggestions)).prefix(5).map { $0 }
    }

   private func starRow(rating: Double?, count: Int?) -> some SwiftUI.View {
        let r = max(0.0, min(rating ?? 0.0, 5.0))
        let full = Int(r)
        let half = (r - Double(full)) >= 0.5
        return HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                if i < full {
                    Image(systemName: "star.fill").foregroundColor(.orange)
                } else if i == full && half {
                    Image(systemName: "star.leadinghalf.filled").foregroundColor(.orange)
                } else {
                    Image(systemName: "star").foregroundColor(Color(.systemGray4))
                }
            }
            if let c = count { Text("(\(c))").font(.caption2).foregroundColor(.secondary) }
        }
    }
    func chip(_ text: String) -> some SwiftUI.View {
        Text(text)
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
    }

    private func bestArtworkURL(from512: String?, fallback100: String?) -> String {
        if var url = from512, !url.isEmpty {

            url = url.replacingOccurrences(of: "/512x512bb", with: "/1024x1024bb")
            return url
        }
        return from512 ?? fallback100 ?? ""
    }

    func purchaseButton(item: iTunesSearchResult) -> some SwiftUI.View {
        Group {
            if (item.price ?? 0.0) == 0.0 {
                Button {
                    Task { await purchaseFreeAppIfNeeded(item: item) }
                } label: {
                    HStack(spacing: 6) {
                        let loading = (purchasingTrackId == (item.trackId))
                        if loading { ProgressView().scaleEffect(0.7) }
                        Text(loading ? "purchasing".localized : "purchase".localized)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(themeManager.accentColor))
                    .foregroundColor(.white)
                }
                .disabled(purchasingTrackId != nil && purchasingTrackId != item.trackId)
                .buttonStyle(.plain)
                .alert("tips".localized, isPresented: $showPurchaseAlert) {
                    Button("got_it".localized, role: .cancel) {}
                } message: {
                    Text(purchaseAlertText)
                }
            }
        }
    }

    func purchaseFreeAppIfNeeded(item: iTunesSearchResult) async {
        guard let account = appStore.selectedAccount else {
            purchaseAlertText = "please_login_first".localized
            showPurchaseAlert = true
            return
        }
        let currentId = item.trackId
        await MainActor.run { purchasingTrackId = currentId }

        let isFree = (item.price ?? 0.0) == 0.0
        if isFree {
            let purchaseTask = Task.detached(priority: .userInitiated) { @Sendable in
                await PurchaseManager.shared.purchaseAppIfNeeded(
                    appIdentifier: String(item.trackId),
                    account: account,
                    countryCode: account.countryCode,
                    isFree: true
                )
            }
            do {
                _ = try await withTimeout(seconds: 8, operation: { @Sendable in
                    await purchaseTask.value
                })
            } catch {
            }
            await MainActor.run {
                loadVersionsForApp(item)
                purchasingTrackId = nil
            }
            if !purchaseTask.isCancelled { purchaseTask.cancel() }
            return
        }

        defer { Task { await MainActor.run { purchasingTrackId = nil } } }
        let check = await PurchaseManager.shared.checkAppOwnership(
            appIdentifier: String(item.trackId),
            account: account,
            countryCode: account.countryCode
        )
        switch check {
        case .success(let owned):
            if owned {
                await MainActor.run { loadVersionsForApp(item) }
                return
            } else {
                openAppStorePage(for: item)
                return
            }
        case .failure:
            openAppStorePage(for: item)
            return
        }
    }

    private func openAppStorePage(for item: iTunesSearchResult) {
        let urlStr = item.trackViewUrl
        guard let url = URL(string: urlStr) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        UIApplication.shared.open(url)
        #endif
    }

    func loadVersionsForApp(_ app: iTunesSearchResult) {

        selectedApp = app
        isLoadingVersions = true
        versionError = nil
        availableVersions = []
        showVersionPicker = true

        Task {
            do {
                guard let account = appStore.selectedAccount else {
                    throw NSError(domain: "SearchView", code: -1, userInfo: [NSLocalizedDescriptionKey: "未登录账户，无法获取版本信息"])
                }

                let accountCopy = account
                let accountCountry = appStore.selectedAccount?.countryCode ?? "US"

                let storeVersionsResult = try? await withTimeout(seconds: 15, operation: {
                    await StoreClient.shared.getAppVersions(
                        trackId: String(app.trackId),
                        account: accountCopy,
                        countryCode: accountCountry
                    )
                })

                var hist: [iTunesClient.AppVersionInfo] = []
                let primaryCountries = accountCountry.uppercased() == "US" ? ["US"] : [accountCountry, "US"]
                for cc in primaryCountries {
                    if let r = try? await withTimeout(seconds: 10, operation: {
                        try await iTunesClient.shared.versionHistory(id: app.trackId, country: cc)
                    }), !r.isEmpty {
                        hist = r
                        break
                    }
                }

                if let result = storeVersionsResult, case .success(let versions) = result, !versions.isEmpty {
                    let proVersions = await fetchProIDHistory(trackId: app.trackId)
                    await MainActor.run {
                        var mergedVersions = versions

                        var versionInfoMap: [String: (releaseDate: Date?, releaseNotes: String?)] = [:]
                        for h in hist {
                            versionInfoMap[h.version] = (h.releaseDate, h.releaseNotes)
                        }

                        for i in 0..<mergedVersions.count {
                            let v = mergedVersions[i]
                            let verStr = v.versionString

                            if v.versionString.hasPrefix("历史版本") || v.versionString.isEmpty {
                                if i < hist.count {
                                    mergedVersions[i].versionString = hist[i].version
                                    if v.releaseDate == nil {
                                        mergedVersions[i].releaseDate = hist[i].releaseDate
                                    }
                                    mergedVersions[i].releaseNotes = hist[i].releaseNotes
                                }
                            } else if let info = versionInfoMap[verStr] {
                                if v.releaseDate == nil {
                                    mergedVersions[i].releaseDate = info.releaseDate
                                }
                                if (v.releaseNotes == nil || v.releaseNotes!.isEmpty) && info.releaseNotes != nil && !info.releaseNotes!.isEmpty {
                                    mergedVersions[i].releaseNotes = info.releaseNotes
                                }
                            }
                        }

                        let incomingNames = Set(proVersions.map { $0.version })
                        let kept = mergedVersions.filter { !incomingNames.contains($0.versionString) }
                        for pv in proVersions {
                            mergedVersions.append(StoreAppVersion(
                                versionString: pv.version,
                                versionId: pv.versionId,
                                isCurrent: false,
                                releaseDate: nil,
                                releaseNotes: nil
                            ))
                        }
                        _ = kept

                        self.availableVersions = mergedVersions
                        self.versionHistory = hist
                        self.isLoadingVersions = false
                    }
                } else if !hist.isEmpty {
                    let fallbackVersions = hist.enumerated().map { idx, info in
                        StoreAppVersion(
                            versionString: info.version,
                            versionId: "",
                            isCurrent: idx == 0,
                            releaseDate: info.releaseDate,
                            releaseNotes: info.releaseNotes
                        )
                    }
                    await MainActor.run {
                        self.availableVersions = fallbackVersions
                        self.versionHistory = hist
                        self.isLoadingVersions = false
                    }
                } else {
                    let proVersions = await fetchProIDHistory(trackId: app.trackId)
                    guard !proVersions.isEmpty else {
                        throw NSError(domain: "SearchView", code: -1, userInfo: [NSLocalizedDescriptionKey: "无法获取版本信息，请检查网络"])
                    }
                    var fallbackVersions: [StoreAppVersion] = []
                    for (idx, pv) in proVersions.enumerated() {
                        fallbackVersions.append(StoreAppVersion(
                            versionString: pv.version,
                            versionId: pv.versionId,
                            isCurrent: idx == 0,
                            releaseDate: nil,
                            releaseNotes: nil
                        ))
                    }
                    await MainActor.run {
                        self.availableVersions = fallbackVersions
                        self.isLoadingVersions = false
                    }
                }
            } catch {
                await MainActor.run {
                    if self.availableVersions.isEmpty {
                        self.versionError = error.localizedDescription
                    }
                    self.isLoadingVersions = false
                }
            }
        }
    }

    var versionPickerSheet: some SwiftUI.View {
        NavigationView {
            ZStack {

                LinearGradient(
                    colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack {

                    versionPickerAccountIndicator

                    if isLoadingVersions {
                        loadingVersionsView
                    } else if let error = versionError {
                        AnyView(errorView(error: error))
                    } else if availableVersions.isEmpty {
                        emptyVersionsView
                    } else {
                        versionsListView
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(.secondarySystemBackground))
                        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                )
                .padding(.horizontal, 16)
                .padding(.top, 16)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("back".localized) {
                        showVersionPicker = false
                    }
                    .foregroundColor(themeManager.accentColor)
                    .font(.system(size: 16, weight: .medium))
                }
            }
        }
    }

    var loadingVersionsView: some SwiftUI.View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.2)
            Text("loading_versions".localized)
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    func errorView(error: String) -> some SwiftUI.View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("load_failed".localized)
                .font(.system(size: 22, weight: .semibold))
            Text(error)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("retry".localized) {
                if let app = selectedApp {
                    loadVersionsForApp(app)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
   private var emptyVersionsView: some SwiftUI.View {
        VStack(spacing: 24) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("no_versions".localized)
                .font(.system(size: 22, weight: .semibold))
            Text("no_versions_desc".localized)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var versionsListView: some SwiftUI.View {
        ScrollView {
            LazyVStack(spacing: 16) {

                VStack(spacing: 16) {

                    ArtworkView(
                        url: URL(string: selectedApp?.artworkUrl512 ?? ""),
                        contentMode: .fit,
                        cornerRadius: 20
                    )
                    .frame(width: 100, height: 100)
                    .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)

                    VStack(spacing: 8) {
                        Text(selectedApp?.trackName ?? "APP")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)

                        Text(selectedApp?.artistName ?? "Unknown Developer")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)

                HStack {
                    Text("version_history".localized)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.primary)

                    Spacer()

                    Text(String(format: "x_versions".localized, String(availableVersions.count)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(themeManager.accentColor.opacity(0.1))
                        )
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                ForEach(availableVersions, id: \.versionId) {
                    AnyView(createModernVersionRow(version: $0))
                }
            }
            .padding(.bottom, 24)
        }
    }
    private func createModernVersionRow(version: StoreAppVersion) -> any SwiftUI.View {
        HStack(spacing: 16) {

            VStack(alignment: .leading, spacing: 8) {

                VStack(alignment: .leading, spacing: 4) {

                    Text(getVersionNumber(version: version))
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(themeManager.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(themeManager.accentColor.opacity(0.1))
                        )

                    if let date = getVersionDate(version: version) {
                        Text(date)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(themeManager.accentColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(themeManager.accentColor.opacity(0.1))
                            )
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "number.circle.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text("ID: \(version.versionId)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button(action: {
                Task {
                    if let app = selectedApp {
                        await downloadVersion(app: app, version: version)
                    }
                }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                    Text("download".localized)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    LinearGradient(
                        colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Capsule())
                .shadow(color: themeManager.accentColor.opacity(0.3), radius: 4, x: 0, y: 2)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
                .shadow(color: .black.opacity(0.05), radius: 3, x: 0, y: 1)
        )
        .padding(.horizontal, 24)
    }

    private func displayVersionTitle(version: StoreAppVersion) -> String {

        if let date = version.formattedReleaseDate {
            return String(format: "version_x_date".localized, version.versionString, date)
        }

        if let h = versionHistory.first(where: { $0.version == version.versionString }) {
            return String(format: "version_x_date".localized, h.version, h.formattedDate)
        }

        if let h = versionHistory.first(where: { version.versionString.hasPrefix($0.version) || $0.version.hasPrefix(version.versionString) }) {
            return String(format: "version_x_date".localized, version.versionString, h.formattedDate)
        }

        if let latestVersion = versionHistory.first {
            return String(format: "version_x_date".localized, version.versionString, latestVersion.formattedDate)
        }

        return String(format: "version_x".localized, version.versionString)
    }

    private func getVersionNumber(version: StoreAppVersion) -> String {
        return String(format: "version_x".localized, version.versionString)
    }

    private func getVersionDate(version: StoreAppVersion) -> String? {
        let versionStr = version.versionString

        if let date = version.formattedReleaseDate {
            return date
        }

        if let h = versionHistory.first(where: { $0.version == versionStr }) {
            return h.formattedDate
        }

        if let h = versionHistory.first(where: { versionStr.hasPrefix($0.version) || $0.version.hasPrefix(versionStr) }) {
            return h.formattedDate
        }

        let versionComponents = versionStr.split(separator: ".").map(String.init)
        for h in versionHistory {
            let hComponents = h.version.split(separator: ".").map(String.init)
            let minCount = min(versionComponents.count, hComponents.count)
            var matchCount = 0
            for i in 0..<minCount {
                if versionComponents[i] == hComponents[i] {
                    matchCount += 1
                } else {
                    break
                }
            }
            if matchCount >= 2 {
                return h.formattedDate
            }
        }

        if let latestVersion = versionHistory.first {
            return latestVersion.formattedDate
        }

        return nil
    }

    private func shortReleaseNote(for version: StoreAppVersion) -> String? {
        if let rn = version.releaseNotes, !rn.isEmpty {
            let firstLine = rn.split(separator: "\n").first.map(String.init) ?? rn
            return firstLine
        }

        let versionStr = version.versionString

        for h in versionHistory {
            if h.version == versionStr {
                if let rn = h.releaseNotes, !rn.isEmpty {
                    let firstLine = rn.split(separator: "\n").first.map(String.init) ?? rn
                    return firstLine
                }
            }
        }

        return nil
    }
    @MainActor
    func downloadVersion(app: iTunesSearchResult, version: StoreAppVersion) async {
        showVersionPicker = false
        guard appStore.selectedAccount != nil else {
            return
        }
        let appId = app.trackId

        let downloadId = UnifiedDownloadManager.shared.addDownload(
            bundleIdentifier: app.bundleId,
            name: app.trackName,
            version: version.versionString,
            identifier: appId,
            iconURL: app.artworkUrl512,
            versionId: version.versionId,
            price: app.price,
            currency: app.currency
        )

        if let request = UnifiedDownloadManager.shared.downloadRequests.first(where: { $0.id == downloadId }) {
            UnifiedDownloadManager.shared.startDownload(for: request)
        } else {
        }
    }

    var accountMenuSheet: some SwiftUI.View {
        NavigationView {
            if appStore.savedAccounts.isEmpty {

                VStack(spacing: 24) {
                    Image(systemName: "person.circle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Button("login_account".localized) {
                        showAccountMenu = false
                        showLoginSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(themeManager.accentColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    LinearGradient(
                        colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                )
                .navigationTitle("account_info".localized)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("close".localized) {
                            showAccountMenu = false
                        }
                        .foregroundColor(themeManager.accentColor)
                        .font(.system(size: 16, weight: .medium))
                    }
                }
            } else {

                multiAccountManagementView
            }
        }
        .navigationViewStyle(.stack)
    }

    var multiAccountManagementView: some SwiftUI.View {
        List {
            if let currentAccount = appStore.selectedAccount {
                Section {
                    AccountDetailView(account: currentAccount)
                        .environmentObject(appStore)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } header: {
                    Text("current_account".localized)
                        .font(.headline)
                        .foregroundColor(.primary)
                }
            }

            Section {
                ForEach(appStore.savedAccounts.indices, id: \.self) { index in
                    let account = appStore.savedAccounts[index]
                    let isSelected = index == appStore.selectedAccountIndex

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(account.email)
                                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(.primary)

                            HStack(spacing: 8) {
                                Text(flag(country: account.countryCode))
                                    .font(.caption)
                                Text(SearchView.countryCodeMapChinese[account.countryCode] ?? SearchView.countryCodeMap[account.countryCode] ?? account.countryCode)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if isSelected {
                                    Text("current".localized)
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(themeManager.accentColor)
                                        )
                                }
                            }
                        }

                        Spacer()

                        HStack(spacing: 8) {
                            if !isSelected {
                                Button("switch".localized) {
                                    appStore.switchToAccount(at: index)
                                }
                                .font(.caption)
                                .foregroundColor(themeManager.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(themeManager.accentColor.opacity(0.1))
                                )
                            }

                            Button("delete".localized) {
                                appStore.deleteAccount(account)
                            }
                            .font(.caption)
                            .foregroundColor(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(Color.red.opacity(0.1))
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("all_accounts".localized)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "x_accounts".localized, String(appStore.savedAccounts.count)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(themeManager.accentColor.opacity(0.1))
                        )
                }
            }

            Section {
                Button("add_new_account".localized) {
                    showAccountMenu = false
                    showLoginSheet = true
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(
                        colors: [themeManager.accentColor, themeManager.accentColor.opacity(0.8)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(12)
                .shadow(color: themeManager.accentColor.opacity(0.3), radius: 8, x: 0, y: 4)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        }
        .listStyle(InsetGroupedListStyle())
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color(.secondarySystemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .navigationTitle("account_management".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("close".localized) {
                    showAccountMenu = false
                }
                .foregroundColor(themeManager.accentColor)
                .font(.system(size: 16, weight: .medium))
            }
        }
    }

    private func logoutAccount() {
        appStore.logoutAccount()
    }

    private var currentAccountIndicator: some SwiftUI.View {
        HStack(spacing: 12) {

            VStack(alignment: .leading, spacing: 2) {
                if let account = appStore.selectedAccount {
                    Text("current_account".localized)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: 8) {
                        Text(account.email)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)

                        Text(flag(country: account.countryCode))
                            .font(.caption)

                        Text(SearchView.countryCodeMapChinese[account.countryCode] ?? account.countryCode)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Image(systemName: "person.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if appStore.hasMultipleAccounts {
                Button("switch_account".localized) {
                    showAccountMenu = true
                }
                .font(.caption)
                .foregroundColor(themeManager.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(themeManager.accentColor.opacity(0.1))
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
    }

    private var versionPickerAccountIndicator: some SwiftUI.View {
        HStack(spacing: 12) {

            VStack(alignment: .leading, spacing: 2) {
                if let account = appStore.selectedAccount {
                    Text("use_account".localized)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    HStack(spacing: 6) {
                        Text(account.email)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(1)

                        Text(flag(country: account.countryCode))
                            .font(.caption2)

                        Text(SearchView.countryCodeMapChinese[account.countryCode] ?? account.countryCode)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Image(systemName: "person.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(themeManager.surfaceSecondary)
        )
        .padding(.horizontal, 16)
    }

    private var cacheStatusIndicator: some SwiftUI.View {
        Button(action: {

            if !sessionManager.isSessionValid {

                Task {
                    await sessionManager.manualSessionCheck()
                }
            } else {

                sessionManager.resetSessionState()
            }
        }) {
            HStack(spacing: 6) {

                Image(systemName: cacheStatusIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)

                Text(cacheStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cacheStatusGradient)
                    .shadow(color: cacheStatusColor.opacity(0.3), radius: 2, x: 0, y: 1)
            )
            .scaleEffect(sessionManager.isReconnecting ? 1.05 : 1.0)
            .animation(.easeInOut(duration: 0.3), value: sessionManager.isReconnecting)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(cacheStatusTooltip)
    }

    private var cacheStatusIcon: String {
        if !sessionManager.isSessionValid {
            return "wifi.slash"
        } else if sessionManager.isReconnecting {
            return "arrow.clockwise"
        } else {
            return "checkmark.shield.fill"
        }
    }

    private var cacheStatusColor: Color {
        if !sessionManager.isSessionValid {
            return Color(red: 0.9, green: 0.2, blue: 0.2)
        } else if sessionManager.isReconnecting {
            return Color(red: 0.95, green: 0.6, blue: 0.1)
        } else {
            return Color(red: 0.2, green: 0.7, blue: 0.3)
        }
    }

    private var cacheStatusGradient: LinearGradient {
        if !sessionManager.isSessionValid {
            return LinearGradient(
                colors: [Color(red: 0.9, green: 0.2, blue: 0.2), Color(red: 0.8, green: 0.1, blue: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else if sessionManager.isReconnecting {
            return LinearGradient(
                colors: [Color(red: 0.95, green: 0.6, blue: 0.1), Color(red: 0.9, green: 0.5, blue: 0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            return LinearGradient(
                colors: [Color(red: 0.2, green: 0.7, blue: 0.3), Color(red: 0.1, green: 0.6, blue: 0.2)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var cacheStatusText: String {
        if !sessionManager.isSessionValid {
            return "connection_lost".localized
        } else if sessionManager.isReconnecting {
            return "reconnecting".localized
        } else {
            return "connected".localized
        }
    }

    private var cacheStatusTooltip: String {
        if !sessionManager.isSessionValid {
            return "apple_id_disconnected".localized
        } else if sessionManager.isReconnecting {
            return "apple_id_reconnecting".localized
        } else {
            return "apple_id_connected".localized
        }
    }

    private func handleDownloadApp(_ app: iTunesSearchResult) {

        guard let account = appStore.selectedAccount else {

            openAppStorePage(for: app)
            return
        }

        Task {
            await MainActor.run { purchasingTrackId = app.trackId }

            let isFree = (app.price ?? 0.0) == 0.0
            if isFree {
                let purchaseTask = Task.detached(priority: .userInitiated) { @Sendable in
                    await PurchaseManager.shared.purchaseAppIfNeeded(
                        appIdentifier: String(app.trackId),
                        account: account,
                        countryCode: account.countryCode,
                        isFree: true
                    )
                }
                do {
                    _ = try await withTimeout(seconds: 8, operation: { @Sendable in
                        await purchaseTask.value
                    })
                } catch {
                }
                await MainActor.run {
                    loadVersionsForApp(app)
                    purchasingTrackId = nil
                }
                if !purchaseTask.isCancelled { purchaseTask.cancel() }
                return
            }

            let check = await PurchaseManager.shared.checkAppOwnership(
                appIdentifier: String(app.trackId),
                account: account,
                countryCode: account.countryCode
            )

            switch check {
            case .success(let owned):
                if owned {

                    await MainActor.run {
                        loadVersionsForApp(app)
                    }
                } else {

                    openAppStorePage(for: app)
                }
            case .failure:

                openAppStorePage(for: app)
            }
        }
    }
}
