import SwiftUI
import UIKit

struct ConnectionLimitControl: View {
    @Binding var value: Int
    var accent: Color
    var totalBytes: Int64 = 0
    var showsHint: Bool = true

    private var current: Int {
        DownloadConnectionSettings.clamp(value)
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { Double(current) },
            set: { newValue in
                let next = DownloadConnectionSettings.clamp(Int(newValue.rounded()))
                if next != value {
                    value = next
                }
            }
        )
    }

    private var hint: String {
        if totalBytes > 0 {
            let size = DownloadByteFormatter.file.string(fromByteCount: totalBytes)
            let effective = DownloadConnectionSettings.effectiveLimit(current, totalBytes: totalBytes)
            return "download_connections_effective".localized(size, effective)
        }
        return "download_connections_hint".localized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(DownloadConnectionSettings.presets, id: \.self) { preset in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        SoundEffects.play(.tick)
                        value = preset
                    } label: {
                        Text("\(preset)")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(current == preset ? .white : .primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(current == preset ? accent : Color(.systemGray5))
                            )
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }

            HStack(spacing: 10) {
                Text("\(DownloadConnectionSettings.minimum)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Slider(
                    value: sliderValue,
                    in: Double(DownloadConnectionSettings.minimum)...Double(DownloadConnectionSettings.maximum),
                    step: 1
                )
                .tint(accent)

                Text("\(DownloadConnectionSettings.maximum)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if showsHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
