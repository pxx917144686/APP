import SwiftUI

enum DecryptConsoleOutcome {
    case idle
    case running
    case completed
    case failed
    case cancelled
}

struct DecryptConsoleView: SwiftUI.View {
    @ObservedObject var log: DecryptLog
    let outcome: DecryptConsoleOutcome
    let appName: String
    let bundleIdentifier: String
    let message: String?
    let decryptedURL: URL?
    let accentColor: Color
    let onCancel: () -> Void
    let onShare: () -> Void
    var onCollapse: () -> Void = {}

    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false
    @State private var sweep: CGFloat = -0.35

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private let bottomAnchor = "decrypt-console-bottom"

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 10) {
            header
            progressSection
            statsRow
            phaseRail
            console
            footer
        }
        .padding(12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [accentColor.opacity(0.45), accentColor.opacity(0.10), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: accentColor.opacity(outcome == .running ? 0.22 : 0.12), radius: 18, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                sweep = 1.35
            }
            if outcome == .running {
                log.isExpanded = true
            }
        }
    }

    private var header: some SwiftUI.View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [accentColor, accentColor.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 36, height: 36)
                    .shadow(color: accentColor.opacity(0.45), radius: 6, x: 0, y: 2)
                Image(systemName: outcome == .completed ? "checkmark.shield.fill" : "lock.open.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: outcome == .running)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("dc_console_title".localized)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                    statusPill
                }
                Text("\(appName) · \(bundleIdentifier)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(percentText)
                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    .foregroundStyle(LinearGradient(colors: [accentColor, .cyan], startPoint: .top, endPoint: .bottom))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: percentText)
                Text("\( "dc_stat_elapsed".localized ) \(elapsedText)")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusPill: some SwiftUI.View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
                .shadow(color: statusColor.opacity(0.8), radius: 3)
                .scaleEffect(pulse && outcome == .running ? 1.35 : 1)
            Text(statusText)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(statusColor.opacity(0.12)))
        .overlay(Capsule().strokeBorder(statusColor.opacity(0.22), lineWidth: 0.5))
    }

    private var progressSection: some SwiftUI.View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06))
                    if log.total > 0 {
                        Capsule()
                            .fill(LinearGradient(colors: [accentColor, accentColor.opacity(0.65), .cyan], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(6, geometry.size.width * progress))
                            .shadow(color: accentColor.opacity(0.55), radius: 5)
                            .animation(.easeOut(duration: 0.35), value: progress)
                    } else if outcome == .running {
                        Capsule()
                            .fill(LinearGradient(colors: [.clear, accentColor, .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * 0.3)
                            .offset(x: geometry.size.width * sweep - geometry.size.width * 0.3)
                            .shadow(color: accentColor.opacity(0.6), radius: 6)
                    }
                }
            }
            .frame(height: 7)

            HStack {
                Text(progressCaption)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(log.total > 0 ? log.summary : "")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statsRow: some SwiftUI.View {
        HStack(spacing: 5) {
            statChip(icon: "checkmark.shield.fill", value: "\(log.decrypted)", title: "dc_stat_decrypted".localized, tint: .green)
            statChip(icon: "doc.plaintext", value: "\(log.plain)", title: "dc_stat_plain".localized, tint: .cyan)
            statChip(icon: "exclamationmark.triangle.fill", value: "\(log.failed)", title: "dc_status_failed".localized, tint: .orange)
            statChip(icon: "square.stack.3d.up.fill", value: log.total > 0 ? "\(log.total)" : "—", title: "dc_stat_total".localized, tint: accentColor)
        }
    }

    private func statChip(icon: String, value: String, title: String, tint: Color) -> some SwiftUI.View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
            }
            Text(title)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.06 : 0.045))
        )
    }

    private var phaseRail: some SwiftUI.View {
        ZStack(alignment: .top) {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.horizontal, 24)
                    .offset(y: 6)
            }
            HStack(spacing: 0) {
                ForEach(Array(phases.enumerated()), id: \.offset) { index, title in
                    VStack(spacing: 3) {
                        phaseCircle(index: index)
                        Text(title)
                            .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(stepColor(index: index).opacity(index == phaseIndex ? 1 : 0.72))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(height: 34)
    }

    private func phaseCircle(index: Int) -> some SwiftUI.View {
        let state = stepState(index: index)
        return ZStack {
            switch state {
            case .done:
                Circle()
                    .fill(LinearGradient(colors: [.green, .green.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 15, height: 15)
                Image(systemName: "checkmark")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.white)
            case .failed:
                Circle()
                    .fill(LinearGradient(colors: [.red, .red.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 15, height: 15)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.white)
            case .current:
                Circle()
                    .stroke(accentColor.opacity(0.28), lineWidth: 1)
                    .frame(width: 21, height: 21)
                    .scaleEffect(pulse ? 1.08 : 0.85)
                    .opacity(pulse ? 0.2 : 0.6)
                Circle()
                    .fill(accentColor)
                    .frame(width: 15, height: 15)
                    .shadow(color: accentColor.opacity(0.6), radius: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 5, height: 5)
            case .pending:
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    .frame(width: 13, height: 13)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var console: some SwiftUI.View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    Circle().fill(Color(red: 1.0, green: 0.27, blue: 0.23)).frame(width: 5, height: 5)
                    Circle().fill(Color(red: 1.0, green: 0.74, blue: 0.18)).frame(width: 5, height: 5)
                    Circle().fill(Color(red: 0.16, green: 0.78, blue: 0.35)).frame(width: 5, height: 5)
                }
                Text("dc_console_log".localized.uppercased())
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("\(log.lines.count)")
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        log.isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: log.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(log.isExpanded ? "dc_collapse_log".localized : "dc_expand_log".localized)

                Button(action: onCollapse) {
                    Image(systemName: "rectangle.compress.vertical")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("dc_collapse_log".localized)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.035))

            if log.isExpanded {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 0.5)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if log.lines.isEmpty {
                                Text("dc_console_waiting".localized)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.35))
                            } else {
                                ForEach(Array(log.lines.suffix(400))) { line in
                                    logRow(line)
                                }
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchor)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .frame(height: 170)
                    .onChange(of: log.lines.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(bottomAnchor, anchor: .bottom)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(bottomAnchor, anchor: .bottom)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(red: 0.035, green: 0.045, blue: 0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
        )
    }

    private func logRow(_ line: DecryptLogLine) -> some SwiftUI.View {
        HStack(alignment: .top, spacing: 5) {
            Text(Self.logTimeFormatter.string(from: line.time))
                .font(.system(size: 7.5, design: .monospaced))
                .foregroundStyle(.white.opacity(0.25))
                .frame(width: 52, alignment: .leading)
            Text(logSymbol(for: line.level))
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(logColor(for: line.level))
                .frame(width: 9)
            Text(line.text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(logColor(for: line.level).opacity(0.95))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var footer: some SwiftUI.View {
        HStack(spacing: 8) {
            if outcome == .running {
                Button(action: onCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("dc_cancel".localized)
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            } else if outcome == .completed, decryptedURL != nil {
                Button(action: onShare) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 9, weight: .bold))
                        Text("dc_share_decrypted".localized)
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(accentColor.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(accentColor.opacity(0.25), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            Text(footerText)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private var progress: Double {
        if log.total > 0 { return log.fraction }
        return outcome == .completed ? 1 : 0
    }

    private var percentText: String {
        if log.total > 0 { return log.percentText }
        return outcome == .completed ? "100%" : "—"
    }

    private var progressCaption: String {
        if log.total == 0 && outcome == .running {
            return "dc_scanning".localized
        }
        if outcome == .completed {
            return "dc_phase_done".localized
        }
        if outcome == .failed {
            return "dc_status_failed".localized
        }
        if outcome == .cancelled {
            return "dc_status_cancelled".localized
        }
        return phaseTitle
    }

    private var elapsedText: String {
        let value = max(0, log.elapsed)
        let minutes = Int(value) / 60
        let seconds = value - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }

    private var phaseTitle: String {
        switch log.phase.uppercased() {
        case "INIT", "EXTRACT": return "dc_phase_extract".localized
        case "SINF": return "dc_phase_sinf".localized
        case "DECRYPT": return "dc_phase_decrypt".localized
        case "PACK": return "dc_phase_pack".localized
        case "DONE": return "dc_phase_done".localized
        default: return log.phase.isEmpty ? "dc_phase_prepare".localized : log.phase
        }
    }

    private var statusText: String {
        switch outcome {
        case .idle: return "dc_phase_prepare".localized
        case .running: return "dc_status_running".localized
        case .completed: return "dc_status_completed".localized
        case .failed: return "dc_status_failed".localized
        case .cancelled: return "dc_status_cancelled".localized
        }
    }

    private var statusColor: Color {
        switch outcome {
        case .idle: return .secondary
        case .running: return accentColor
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private var footerText: String {
        if let message, !message.isEmpty { return message }
        if outcome == .running {
            return log.total > 0 ? phaseTitle : "dc_scanning".localized
        }
        return statusText
    }

    private var phases: [String] {
        [
            "dc_phase_prepare".localized,
            "dc_phase_sinf".localized,
            "dc_phase_decrypt".localized,
            "dc_phase_pack".localized,
            "dc_phase_done".localized,
        ]
    }

    private var phaseIndex: Int {
        if outcome == .completed { return phases.count - 1 }
        switch log.phase.uppercased() {
        case "INIT", "EXTRACT": return 0
        case "SINF": return 1
        case "DECRYPT": return 2
        case "PACK": return 3
        case "DONE": return 4
        default: return -1
        }
    }

    private enum StepState {
        case done
        case current
        case failed
        case pending
    }

    private func stepState(index: Int) -> StepState {
        if outcome == .completed { return .done }
        if index < phaseIndex { return .done }
        if index == phaseIndex {
            if outcome == .failed { return .failed }
            if outcome == .cancelled { return .pending }
            return .current
        }
        return .pending
    }

    private func stepColor(index: Int) -> Color {
        switch stepState(index: index) {
        case .done: return .green
        case .current: return accentColor
        case .failed: return .red
        case .pending: return .secondary
        }
    }

    private func logSymbol(for level: DecryptLogLevel) -> String {
        switch level {
        case .phase: return "▸"
        case .info: return "·"
        case .detail: return "·"
        case .success: return "✓"
        case .warning: return "!"
        case .failure: return "✕"
        }
    }

    private func logColor(for level: DecryptLogLevel) -> Color {
        switch level {
        case .phase: return .cyan
        case .info: return .white.opacity(0.82)
        case .detail: return .white.opacity(0.52)
        case .success: return Color(red: 0.35, green: 0.85, blue: 0.55)
        case .warning: return Color(red: 1.0, green: 0.72, blue: 0.28)
        case .failure: return Color(red: 1.0, green: 0.38, blue: 0.38)
        }
    }

    private var cardBackground: some SwiftUI.View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark
                            ? [Color(red: 0.085, green: 0.095, blue: 0.12), Color(red: 0.045, green: 0.05, blue: 0.07)]
                            : [Color.white, Color(red: 0.965, green: 0.975, blue: 0.99)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(accentColor.opacity(colorScheme == .dark ? 0.16 : 0.10))
                .frame(width: 170, height: 170)
                .blur(radius: 55)
                .offset(x: 130, y: -80)
            Circle()
                .fill(Color.cyan.opacity(colorScheme == .dark ? 0.08 : 0.05))
                .frame(width: 140, height: 140)
                .blur(radius: 50)
                .offset(x: -120, y: 120)
        }
    }
}
