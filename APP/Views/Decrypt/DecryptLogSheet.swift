import SwiftUI
import UIKit

struct DecryptLogSheet: SwiftUI.View {
    @ObservedObject var log: DecryptLog
    let title: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager
    @State private var copied = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some SwiftUI.View {
        NavigationView {
            ZStack {
                themeManager.backgroundColor.ignoresSafeArea()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            ForEach(log.lines) { line in
                                row(line)
                                    .id(line.id)
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("decrypt-log-bottom")
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: log.lines.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("decrypt-log-bottom", anchor: .bottom)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo("decrypt-log-bottom", anchor: .bottom)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("done".localized) { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        copyAll()
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .disabled(log.lines.isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func row(_ line: DecryptLogLine) -> some SwiftUI.View {
        HStack(alignment: .top, spacing: 7) {
            Text(Self.timeFormatter.string(from: line.time))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)

            Text(line.text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(color(for: line.level))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            Spacer(minLength: 0)
        }
    }

    private func color(for level: DecryptLogLevel) -> Color {
        switch level {
        case .phase: return .cyan
        case .info: return .primary.opacity(0.85)
        case .detail: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .failure: return .red
        }
    }

    private func copyAll() {
        let text = log.lines
            .map { "\(Self.timeFormatter.string(from: $0.time))  \($0.text)" }
            .joined(separator: "\n")
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }
}
