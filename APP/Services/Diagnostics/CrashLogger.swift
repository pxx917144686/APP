import Foundation

private var crashLogSignalPath: UnsafeMutablePointer<CChar>?

private func crashLogWriteSignal(_ sig: Int32) {
    if let path = crashLogSignalPath {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd >= 0 {
            let prefix = "\n=== FATAL SIGNAL "
            _ = prefix.withCString { p in Darwin.write(fd, p, strlen(p)) }
            let number = String(sig)
            _ = number.withCString { p in Darwin.write(fd, p, strlen(p)) }
            let suffix = " ===\n"
            _ = suffix.withCString { p in Darwin.write(fd, p, strlen(p)) }

            var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
            let count = backtrace(&frames, 32)
            backtrace_symbols_fd(&frames, count, fd)
            close(fd)
        }
    }

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
        if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int64, size > 1_000_000 {
            try? FileManager.default.removeItem(at: fileURL)
        }
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
