import SwiftUI

struct SigningSectionCard<Content: SwiftUI.View>: SwiftUI.View {
    let title: String
    let icon: String
    var count: Int?
    let accent: Color
    var action: (() -> Void)?
    @SwiftUI.ViewBuilder var content: () -> Content

    init(
        title: String,
        icon: String,
        count: Int? = nil,
        accent: Color,
        action: (() -> Void)? = nil,
        @SwiftUI.ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.accent = accent
        self.action = action
        self.content = content
    }

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(0.55)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
                if let action {
                    Button(action: action) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(accent)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(accent.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
            }

            Rectangle()
                .fill(Color.primary.opacity(0.06))
                .frame(height: 0.5)

            content()
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }
}

struct SigningEmptyRow: SwiftUI.View {
    let icon: String
    let title: String
    let hint: String
    let actionTitle: String
    let accent: Color
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some SwiftUI.View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accent.opacity(0.8))
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(accent.opacity(0.10))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(hint)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Text(actionTitle)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.03))
            )
        }
        .buttonStyle(.plain)
    }
}

struct SigningMetaText: SwiftUI.View {
    let title: String
    let value: String
    var warning: Bool = false

    var body: some SwiftUI.View {
        HStack(spacing: 3) {
            Text(title)
                .font(.system(size: 8.5))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundStyle(warning ? .red : .secondary)
                .lineLimit(1)
        }
    }
}

struct SigningLabeledField: SwiftUI.View {
    let title: String
    @Binding var text: String
    let mono: Bool
    let colorScheme: ColorScheme

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField(title, text: $text)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.04))
                )
        }
    }
}

struct SigningIssue: Identifiable {
    let id = UUID()
    let text: String
    let isError: Bool
}
