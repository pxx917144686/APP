import SwiftUI

struct ShelfView<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let title: String?
    let showAllTitle: String?
    let itemWidth: CGFloat
    let spacing: CGFloat = 12
    let horizontalPadding: CGFloat = 16
    @ViewBuilder let itemContent: (Item) -> Content
    var onShowAll: (() -> Void)?

    init(
        items: [Item],
        title: String? = nil,
        showAllTitle: String? = nil,
        itemWidth: CGFloat = 150,
        @ViewBuilder itemContent: @escaping (Item) -> Content,
        onShowAll: (() -> Void)? = nil
    ) {
        self.items = items
        self.title = title
        self.showAllTitle = showAllTitle
        self.itemWidth = itemWidth
        self.itemContent = itemContent
        self.onShowAll = onShowAll
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || showAllTitle != nil {
                headerView
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: spacing) {
                    ForEach(items) { item in
                        itemContent(item)
                            .frame(width: itemWidth)
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }
        }
    }

    private var headerView: some View {
        HStack {
            if let title = title {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)
            }

            Spacer()

            if let showAllTitle = showAllTitle, let onShowAll = onShowAll {
                Button(action: onShowAll) {
                    HStack(spacing: 4) {
                        Text(showAllTitle)
                            .font(.system(size: 15, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(.blue)
                }
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 8)
    }
}
