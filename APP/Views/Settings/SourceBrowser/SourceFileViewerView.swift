import SwiftUI

// MARK: - 文件内容查看器（GitHub 式等宽 + 行号）

struct SourceFileViewerView: View {
    let path: String
    let ref: String

    private let service = SourceBrowserService.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @State private var phase: SourceLoadPhase<SourceFile> = .loading
    @State private var copied = false

    private static let maxDisplayedLines = 4000

    private var fileName: String {
        (path as NSString).lastPathComponent
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("source_browser_loading".localized)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .failed(let message):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await load() }
                    } label: {
                        Text("source_browser_retry".localized)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(themeManager.accentColor)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(themeManager.accentColor.opacity(0.12)))
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .loaded(let file):
                content(for: file)
            }
        }
        .background(themeManager.backgroundColor.ignoresSafeArea())
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .loaded(let file) = phase, file.kind == .text {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        copyAll(file)
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel("source_browser_copy".localized)
                    .accessibilityValue(copied ? "source_browser_copied".localized : "")
                }
            }
            if case .loaded = phase {
                ToolbarItem(placement: .topBarTrailing) {
                    Link(destination: SourceBrowserService.fileWebURL(path: path, ref: ref)) {
                        Image(systemName: "safari")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .accessibilityLabel("source_browser_open_github".localized)
                }
            }
        }
        .task(id: "\(ref)#\(path)") {
            await load()
        }
    }

    // MARK: 内容分区

    @ViewBuilder
    private func content(for file: SourceFile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            fileHeader(file)

            switch file.kind {
            case .text:
                textBody(file)
            case .image:
                imageBody(file)
            case .binary:
                binaryBody(file)
            }
        }
    }

    private func fileHeader(_ file: SourceFile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Text(service.formattedSize(file.size))

                if file.kind == .text, let text = file.text {
                    let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
                    Text("source_browser_line_count".localized(lineCount))
                }

                Text(file.shortSha)

                Spacer()

                let ext = (path as NSString).pathExtension
                if !ext.isEmpty {
                    Text(ext.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(themeManager.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(themeManager.accentColor.opacity(0.12)))
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(themeManager.accentColor.opacity(0.06))
    }

    private func textBody(_ file: SourceFile) -> some View {
        let lines = file.text.map { text -> [String] in
            var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if all.last?.isEmpty == true { all.removeLast() }
            return all
        } ?? []

        let displayLines = lines.prefix(Self.maxDisplayedLines)
        let gutterWidth = CGFloat(max(2, String(lines.count).count)) * 7.5 + 10
        let language = SourceCodeLanguage.detect(fileName: fileName)

        // 按顺序构建带高亮的行（跨行注释/字符串状态机）
        var scan = SourceSyntaxScanState()
        let highlighted = displayLines.map { line -> AttributedString in
            SourceSyntaxHighlighter.highlight(line.isEmpty ? " " : line,
                                              language: language,
                                              state: &scan)
        }

        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if lines.count > Self.maxDisplayedLines {
                        Text("source_browser_truncated".localized(Self.maxDisplayedLines))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08))
                            .id("source-file-truncation-banner")
                    }

                    ForEach(Array(highlighted.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .frame(width: gutterWidth, alignment: .trailing)
                                .frame(maxHeight: .infinity)
                                .background(Color.primary.opacity(0.04))

                            Text(line)
                                .font(.system(size: 12, design: .monospaced))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(.vertical, 1)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .padding(.vertical, 10)
            }
            .onAppear {
                if lines.count > Self.maxDisplayedLines {
                    proxy.scrollTo("source-file-truncation-banner", anchor: .top)
                }
            }
        }
    }

    private func imageBody(_ file: SourceFile) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                if let data = file.imageData, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 14)
                } else {
                    Text("source_browser_binary_file".localized)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 60)
                }
            }
            .padding(.vertical, 12)
        }
    }

    private func binaryBody(_ file: SourceFile) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "archivebox")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("source_browser_binary_file".localized)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: 动作

    private func copyAll(_ file: SourceFile) {
        UIPasteboard.general.string = file.text
        SoundEffects.play(.copy)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

    private func load() async {
        phase = .loading
        do {
            phase = .loaded(try await service.fetchFile(path, ref: ref))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
