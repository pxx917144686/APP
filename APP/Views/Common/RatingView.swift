import SwiftUI

struct RatingBarView: View {
    let averageRating: Double
    let ratingCount: Int
    var ratingCounts: [Int: Int]? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            averageRatingView
                .frame(width: 80)

            VStack(alignment: .leading, spacing: 4) {
                ratingBarsView
                Text("\(formatCount(ratingCount)) 个评分")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
    }

    private var averageRatingView: some View {
        VStack(spacing: 4) {
            Text(String(format: "%.1f", averageRating))
                .font(.system(size: 48, weight: .bold))
                .foregroundColor(.primary)

            StarRatingView(rating: averageRating, size: 12)
        }
    }

    @ViewBuilder
    private var ratingBarsView: some View {
        if let counts = ratingCounts, !counts.isEmpty {
            VStack(spacing: 4) {
                ForEach((1...5).reversed(), id: \.self) { star in
                    HStack(spacing: 6) {
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
                                    .fill(Color(.systemGray4))
                                    .frame(height: 3)

                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.orange)
                                    .frame(width: barWidth(for: star, totalWidth: geometry.size.width))
                                    .frame(height: 3)
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
        } else {
            VStack(spacing: 4) {
                ForEach((1...5).reversed(), id: \.self) { star in
                    HStack(spacing: 6) {
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
                                    .fill(Color(.systemGray4))
                                    .frame(height: 3)

                                RoundedRectangle(cornerRadius: 1)
                                    .fill(Color.orange)
                                    .frame(width: estimatedBarWidth(for: star, totalWidth: geometry.size.width))
                                    .frame(height: 3)
                            }
                        }
                        .frame(height: 3)
                    }
                }
            }
        }
    }

    private func barWidth(for star: Int, totalWidth: CGFloat) -> CGFloat {
        guard let counts = ratingCounts, let count = counts[star], ratingCount > 0 else {
            return 0
        }
        return totalWidth * CGFloat(count) / CGFloat(ratingCount)
    }

    private func estimatedBarWidth(for star: Int, totalWidth: CGFloat) -> CGFloat {
        let percentages: [Int: Double] = [5: 0.7, 4: 0.2, 3: 0.06, 2: 0.02, 1: 0.02]
        return totalWidth * CGFloat(percentages[star] ?? 0)
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 10000 {
            return "\(count / 10000)万"
        } else if count >= 1000 {
            return String(format: "%.1fK", Double(count) / 1000.0)
        } else {
            return "\(count)"
        }
    }
}

struct StarRatingView: View {
    let rating: Double
    var size: CGFloat = 14
    var fillColor: Color = .orange
    var emptyColor: Color = Color(.systemGray4)

    var body: some View {
        HStack(spacing: 1) {
            ForEach(0..<5) { index in
                Image(systemName: starName(for: index))
                    .font(.system(size: size, weight: .semibold))
                    .foregroundColor(index < Int(rating.rounded()) ? fillColor : emptyColor)
            }
        }
    }

    private func starName(for index: Int) -> String {
        let fullStars = Int(rating.rounded())
        if index < fullStars {
            return "star.fill"
        }
        return "star"
    }
}
