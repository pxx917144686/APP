import SwiftUI

struct SigningConsoleView: SwiftUI.View {
    @ObservedObject var session: SigningSession
    let certificateName: String
    let profileName: String
    let onCancel: () -> Void
    let onShare: () -> Void
    let onInstall: () -> Void

    @SwiftUI.Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false
    @State private var sweep: CGFloat = -0.35

    private static let logTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private let bottomAnchor = "signing-console-bottom"

    var body: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 10) {
            header
            progressSection
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
                        colors: [accent.opacity(0.45), accent.opacity(0.10), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: accent.opacity(session.outcome == .running ? 0.22 : 0.12), radius: 18, x: 0, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                sweep = 1.35
            }
        }
    }

    private var accent: Color { .cyan }

    private var header: some SwiftUI.View {
        HStack(alignment: .center, spacing: 10) {
            TelegramRadialProgress(
                progress: progress,
                outcome: session.outcome,
                tint: accent,
                size: 44,
                lineWidth: 3.5
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("sign_console_title".localized)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)
                    statusPill
                }
                Text("\(certificateName) · \(profileName)")
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 1) {
                Text(percentText)
                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: percentText)
                Text("\( "sign_elapsed".localized ) \(elapsedText)")
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
                .scaleEffect(pulse && session.outcome == .running ? 1.35 : 1)
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
                    Capsule()
                        .fill(LinearGradient(colors: [.cyan, .blue, .purple.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geometry.size.width * progress))
                        .shadow(color: .cyan.opacity(0.55), radius: 5)
                        .animation(.easeOut(duration: 0.35), value: progress)
                    if session.outcome == .running && progress < 0.02 {
                        Capsule()
                            .fill(LinearGradient(colors: [.clear, .cyan, .clear], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geometry.size.width * 0.3)
                            .offset(x: geometry.size.width * sweep - geometry.size.width * 0.3)
                            .shadow(color: .cyan.opacity(0.6), radius: 6)
                    }
                }
            }
            .frame(height: 7)

            HStack {
                Text(session.phase.title)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(session.isRunning ? "sign_running".localized : statusText)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var phaseRail: some SwiftUI.View {
        ZStack(alignment: .top) {
            GeometryReader { _ in
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
            case .cancelled:
                Circle()
                    .fill(Color.orange.opacity(0.25))
                    .frame(width: 15, height: 15)
                Image(systemName: "pause.fill")
                    .font(.system(size: 6, weight: .black))
                    .foregroundStyle(.orange)
            case .current:
                Circle()
                    .stroke(accent.opacity(0.28), lineWidth: 1)
                    .frame(width: 21, height: 21)
                    .scaleEffect(pulse ? 1.08 : 0.85)
                    .opacity(pulse ? 0.2 : 0.6)
                Circle()
                    .fill(accent)
                    .frame(width: 15, height: 15)
                    .shadow(color: accent.opacity(0.6), radius: 4)
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
                Text("sign_console_log".localized.uppercased())
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text("\(session.lines.count)")
                    .font(.system(size: 7.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        session.isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: session.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isExpanded ? "sign_collapse_log".localized : "sign_expand_log".localized)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.035))

            if session.isExpanded {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 0.5)
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 3) {
                            if session.lines.isEmpty {
                                Text("sign_console_waiting".localized)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.35))
                            } else {
                                ForEach(Array(session.lines.suffix(400))) { line in
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
                    .frame(height: 160)
                    .onChange(of: session.lines.count) { _, _ in
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
            if session.outcome == .running {
                Button(action: onCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 9, weight: .bold))
                        Text("sign_cancel".localized)
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.red.opacity(0.25), lineWidth: 0.5))
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
        session.outcome == .completed ? 1 : min(1, max(0, session.progress))
    }

    private var percentText: String {
        String(format: "%.0f%%", progress * 100)
    }

    private var elapsedText: String {
        let value = max(0, session.elapsed)
        let minutes = Int(value) / 60
        let seconds = value - Double(minutes * 60)
        return String(format: "%02d:%04.1f", minutes, seconds)
    }

    private var phases: [String] {
        [
            "sign_phase_prepare".localized,
            "sign_phase_unpack".localized,
            "sign_phase_sign".localized,
            "sign_phase_pack".localized,
            "sign_phase_done".localized,
        ]
    }

    private var phaseIndex: Int {
        if session.outcome == .completed { return 4 }
        return session.phase.stepIndex
    }

    private var statusText: String {
        switch session.outcome {
        case .idle: return "sign_phase_prepare".localized
        case .running: return "sign_status_running".localized
        case .completed: return "sign_status_completed".localized
        case .failed: return "sign_status_failed".localized
        case .cancelled: return "dc_status_cancelled".localized
        }
    }

    private var statusColor: Color {
        switch session.outcome {
        case .idle: return .secondary
        case .running: return .cyan
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private var footerText: String {
        if let error = session.errorMessage, !error.isEmpty { return error }
        if session.outcome == .running { return session.phase.title }
        return statusText
    }

    private enum StepState {
        case done
        case current
        case failed
        case cancelled
        case pending
    }

    private func stepState(index: Int) -> StepState {
        if session.outcome == .completed { return .done }
        if index < phaseIndex { return .done }
        if index == phaseIndex {
            switch session.outcome {
            case .failed: return .failed
            case .cancelled: return .cancelled
            default: return .current
            }
        }
        return .pending
    }

    private func stepColor(index: Int) -> Color {
        switch stepState(index: index) {
        case .done: return .green
        case .current: return .cyan
        case .failed: return .red
        case .cancelled: return .orange
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
                            ? [Color(red: 0.075, green: 0.095, blue: 0.13), Color(red: 0.04, green: 0.05, blue: 0.07)]
                            : [Color.white, Color(red: 0.96, green: 0.975, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .fill(Color.cyan.opacity(colorScheme == .dark ? 0.16 : 0.10))
                .frame(width: 170, height: 170)
                .blur(radius: 55)
                .offset(x: 130, y: -80)
            Circle()
                .fill(Color.blue.opacity(colorScheme == .dark ? 0.10 : 0.06))
                .frame(width: 140, height: 140)
                .blur(radius: 50)
                .offset(x: -120, y: 120)
        }
    }
}
