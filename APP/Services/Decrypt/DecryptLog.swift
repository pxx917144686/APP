import Foundation

enum DecryptLogLevel: Sendable {
    case phase
    case info
    case detail
    case success
    case warning
    case failure
}

struct DecryptLogLine: Identifiable {
    let id = UUID()
    let text: String
    let level: DecryptLogLevel
    let time: Date
}

enum DecryptEvent: Sendable {
    case phase(String)
    case line(String, DecryptLogLevel)
    case entry(String, Int32, Int64)
    case total(Int)
    case totalBytes(Int64)
}

final class DecryptLog: ObservableObject, @unchecked Sendable {
    @Published private(set) var lines: [DecryptLogLine] = []
    @Published private(set) var phase: String = ""
    @Published private(set) var decrypted = 0
    @Published private(set) var plain = 0
    @Published private(set) var failed = 0
    @Published private(set) var total = 0
    @Published private(set) var totalBytes: Int64 = 0
    @Published private(set) var doneBytes: Int64 = 0
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var isRunning = false
    @Published var isExpanded = true

    private var startedAt: Date?
    private var ticker: Timer?
    private let maxLines = 1200

    private var pendingLines: [DecryptLogLine] = []
    private var pendingDecrypted = 0
    private var pendingPlain = 0
    private var pendingFailed = 0
    private var pendingDoneBytes: Int64 = 0
    private var flushScheduled = false

    var fraction: Double {
        if totalBytes > 0 {
            return min(1, Double(doneBytes) / Double(totalBytes))
        }
        guard total > 0 else { return 0 }
        return min(1, Double(decrypted + plain + failed) / Double(total))
    }

    var summary: String {
        if totalBytes > 0 {
            let done = ByteCountFormatter.string(fromByteCount: doneBytes, countStyle: .file)
            let all = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(done) / \(all)"
        }
        return "\(decrypted + plain + failed)/\(total)"
    }

    var percentText: String { String(format: "%.0f%%", fraction * 100) }

    func reset(title: String) {
        onMain {
            self.lines.removeAll(keepingCapacity: true)
            self.pendingLines.removeAll(keepingCapacity: true)
            self.pendingDecrypted = 0
            self.pendingPlain = 0
            self.pendingFailed = 0
            self.pendingDoneBytes = 0
            self.phase = title
            self.decrypted = 0
            self.plain = 0
            self.failed = 0
            self.total = 0
            self.totalBytes = 0
            self.doneBytes = 0
            self.elapsed = 0
            self.isRunning = true
            self.isExpanded = true
            self.startedAt = Date()
            self.startTicker()
        }
    }

    func finish() {
        onMain {
            self.flushOnMain()
            self.isRunning = false
            self.ticker?.invalidate()
            self.ticker = nil
            if let startedAt = self.startedAt {
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    func append(_ text: String, level: DecryptLogLevel = .info) {
        onMain { self.appendOnMain(text, level: level) }
    }

    func setPhase(_ value: String) {
        onMain { self.phase = value }
    }

    func setTotal(_ value: Int) {
        onMain { self.total = value }
    }

    func consume(_ event: DecryptEvent) {
        onMain {
            switch event {
            case .phase(let value):
                self.phase = value
                self.appendOnMain("▸ \(value)", level: .phase)
            case .line(let text, let level):
                self.appendOnMain(text, level: level)
            case .entry(_, let status, let size):
                self.recordEntryOnMain(status: status, size: size)
            case .total(let value):
                self.total = value
            case .totalBytes(let value):
                self.totalBytes = value
            }
        }
    }

    private func appendOnMain(_ text: String, level: DecryptLogLevel) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        pendingLines.append(DecryptLogLine(text: trimmed, level: level, time: Date()))
        scheduleFlush()
    }

    private func recordEntryOnMain(status: Int32, size: Int64) {
        switch status {
        case 0: pendingDecrypted += 1
        case 1: pendingPlain += 1
        default: pendingFailed += 1
        }
        pendingDoneBytes += max(0, size)
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.flushOnMain()
        }
    }

    private func flushOnMain() {
        flushScheduled = false
        if !pendingLines.isEmpty {
            lines.append(contentsOf: pendingLines)
            pendingLines.removeAll(keepingCapacity: true)
            if lines.count > maxLines {
                lines.removeFirst(lines.count - maxLines)
            }
        }
        if pendingDecrypted != 0 { decrypted += pendingDecrypted; pendingDecrypted = 0 }
        if pendingPlain != 0 { plain += pendingPlain; pendingPlain = 0 }
        if pendingFailed != 0 { failed += pendingFailed; pendingFailed = 0 }
        if pendingDoneBytes != 0 { doneBytes += pendingDoneBytes; pendingDoneBytes = 0 }
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let startedAt = self.startedAt else { return }
                self.elapsed = Date().timeIntervalSince(startedAt)
            }
        }
    }

    deinit {
        ticker?.invalidate()
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
