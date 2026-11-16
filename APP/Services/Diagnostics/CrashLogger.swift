import Foundation

/// Minimal crash capture.
///
/// Handlers must be plain C function pointers, so they cannot capture anything:
/// everything they need lives in file-scope storage below.
private var crashLogSignalPath: UnsafeMutablePointer<CChar>?

private func crashLogWriteSignal(_ sig: Int32) {
    if let path = crashLogSignalPath {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            let message = "\n=== FATAL SIGNAL \(sig) ===\n"
            message.withCString { _ = Darwin.write(fd, $0, strlen($0)) }

            // Raw frames: async-signal-safe enough in practice, and the only way
            // to get any stack at all from inside a signal handler.
            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let count = backtrace(&frames, 32)
            backtrace_symbols_fd(&frames, count, fd)
            close(fd)
        }
    }

    // Hand the signal back to the system. Calling exit() here would suppress the
    // system crash report entirely, leaving only our bare signal number.
    signal(sig, SIG_DFL)
    raise(sig)
}

private func crashLogHandleException(_ exception: NSException) {
    let text = """
    [NSException] \(exception.name.rawValue)
    reason: \(exception.reason ?? "-")
    \(exception.callStackSymbols.joined(separator: "\n"))
    """
    CrashLogger.write(text)
}

enum CrashLogger {
    static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("last_crash.log")
    }

    static func install() {
        crashLogSignalPath = strdup(fileURL.path)

        NSSetUncaughtExceptionHandler(crashLogHandleException)

        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig, crashLogWriteSignal)
        }
    }

    static func write(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let body = "\n=== \(stamp) ===\n\(text)\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(Data(body.utf8))
            try? handle.close()
        } else {
            try? body.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    static var lastCrash: String? {
        try? String(contentsOf: fileURL, encoding: .utf8)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
