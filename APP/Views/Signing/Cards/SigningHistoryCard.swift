import SwiftUI

struct SigningHistoryCard: SwiftUI.View {
    let records: [SigningHistoryRecord]
    let accent: Color
    let colorScheme: ColorScheme
    let onOpen: () -> Void

    var body: some SwiftUI.View {
        SigningSectionCard(
            title: "sign_history_title".localized,
            icon: "clock.arrow.circlepath",
            count: records.count,
            accent: accent,
            action: onOpen
        ) {
            if records.isEmpty {
                SigningEmptyRow(
                    icon: "clock",
                    title: "sign_history_empty".localized,
                    hint: "sign_history_empty_hint".localized,
                    actionTitle: "sign_history_open".localized,
                    accent: accent,
                    colorScheme: colorScheme,
                    action: onOpen
                )
            } else {
                VStack(spacing: 6) {
                    ForEach(records.prefix(3)) { record in
                        Button(action: onOpen) {
                            HStack(spacing: 8) {
                                Image(systemName: "app.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .frame(width: 26, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .fill(accent.opacity(0.10))
                                    )
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(record.displayName)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .lineLimit(1)
                                    Text(record.bundleId.isEmpty ? record.outputName : record.bundleId)
                                        .font(.system(size: 8, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 4)
                                Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(7)
                            .background(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    if records.count > 3 {
                        Button(action: onOpen) {
                            Text("sign_history_view_all".localized)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
