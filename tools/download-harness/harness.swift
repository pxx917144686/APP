// 下载器回归测试工具（独立于 App 目标，macOS 上直接编译运行）
//
// 编译时把 APP/Services/Download/SegmentedIPADownloader.swift 一起编进来
// （见 run.sh）。文件顶部的 DownloadError / .localized 是 App 环境的最小 stub，
// **若 App 里的 DownloadError 或下载器用到的 case 有变动，请同步更新 stub**。
//
// 用法（一般直接跑 run.sh）：
//   testrun              —— 基础套件：分段 / 回退 / 取消 / 暂停恢复 / 取消后续传
//   testrun die          —— 下载到 ~20MB 时直接 exit(0) 模拟进程被杀（保留临时文件+断点）
//   testrun resume       —— 紧接 die 阶段：新进程从断点续传并校验 MD5
//   testrun corrupt      —— 故意写坏断点文件：应自动丢弃、全新下载
//
// 端口约定：18999=Range 正常  18998=无 Range  18997=限速  18996=限速  18995=超慢速(die 用)
import Foundation
import CryptoKit

let baseDir = "./.harness_tmp"

// --- 最小 stub，模拟 App 工程环境（DownloadError / .localized） ---
enum DownloadError: Error, LocalizedError {
    case invalidURL(String)
    case networkError(Error)
    case unknownError(String)
    case fileSystemError(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL(let m): return m
        case .networkError(let e): return e.localizedDescription
        case .unknownError(let m): return m
        case .fileSystemError(let m): return m
        }
    }
}
extension String {
    var localized: String { self }
    func localized(_ args: CVarArg...) -> String { self }
}

func md5(of url: URL) -> String {
    var hasher = Insecure.MD5()
    let handle = try! FileHandle(forReadingFrom: url)
    while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    try? handle.close()
    return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
}

final class Box: @unchecked Sendable {
    var result: Result<(tempFileURL: URL, totalBytes: Int64), DownloadError>?
    var firstProgress: Int64 = -1
    var lastProgress: (Int64, Int64) = (0, 0)
}

enum Mode { case plain, cancel, pauseResume, expectResume }

@main
struct TestMain {
    static func runOne(name: String, port: Int, expectedMD5: String, mode: Mode, clean: Bool = true, minResumedBytes: Int64 = 1) async -> Bool {
        let temp = URL(fileURLWithPath: "\(baseDir)/out_\(name).tmp")
        if clean {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: temp.path + ".segresume"))
        }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let started = Date()
        await SegmentedIPADownloader.shared.start(
            downloadId: "test-\(name)",
            url: URL(string: "http://127.0.0.1:\(port)/file")!,
            tempFileURL: temp,
            onProgress: { bytes, total in
                if box.firstProgress < 0 { box.firstProgress = bytes }
                box.lastProgress = (bytes, total)
            },
            onFinish: { result in
                box.result = result
                sem.signal()
            }
        )
        switch mode {
        case .cancel:
            try? await Task.sleep(nanoseconds: 300_000_000)
            SegmentedIPADownloader.shared.cancel(downloadId: "test-\(name)")
        case .pauseResume:
            try? await Task.sleep(nanoseconds: 300_000_000)
            SegmentedIPADownloader.shared.pause(downloadId: "test-\(name)")
            try? await Task.sleep(nanoseconds: 500_000_000)
            SegmentedIPADownloader.shared.resume(downloadId: "test-\(name)")
        case .plain, .expectResume:
            break
        }
        sem.wait()
        let elapsed = Date().timeIntervalSince(started)
        switch box.result {
        case .success(let url, let size):
            let actual = md5(of: url)
            var ok = actual == expectedMD5
            var extra = ""
            if mode == .expectResume {
                let resumed = box.firstProgress >= minResumedBytes
                ok = ok && resumed
                extra = " resumedFrom=\(box.firstProgress) required>=(\(minResumedBytes)) resumedOk=\(resumed)"
            }
            print("[\(name)] \(ok ? "PASS" : "FAIL") md5=\(actual == expectedMD5 ? "match" : "MISMATCH") size=\(size) elapsed=\(String(format: "%.2f", elapsed))s finalProgress=\(box.lastProgress.0)/\(box.lastProgress.1)\(extra)")
            return ok
        case .failure(let error):
            if mode == .cancel {
                let cancelled = error.localizedDescription.contains("cancel") || error.localizedDescription.contains("取消")
                print("[\(name)] \(cancelled ? "PASS" : "FAIL") (cancelled: \(error.localizedDescription))")
                return cancelled
            }
            print("[\(name)] FAIL: \(error.localizedDescription)")
            return false
        case nil:
            print("[\(name)] FAIL: no result")
            return false
        }
    }

    /// 阶段 die：下载到 ~20MB 时直接 exit(0) 模拟进程被杀（不取消、不清理）
    static func phaseDie() async {
        let temp = URL(fileURLWithPath: "\(baseDir)/out_resume.tmp")
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: temp.path + ".segresume"))
        let box = Box()
        await SegmentedIPADownloader.shared.start(
            downloadId: "test-resume",
            url: URL(string: "http://127.0.0.1:18995/file")!,
            tempFileURL: temp,
            onProgress: { bytes, _ in
                box.lastProgress = (bytes, 0)
            },
            onFinish: { _ in }
        )
        // 等收满至少 20MB（超慢速服务器 ~12.8MB/s，约 1.6 秒）
        for _ in 0..<200 {
            if box.lastProgress.0 >= 20 * 1024 * 1024 { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let resumeExists = FileManager.default.fileExists(atPath: temp.path + ".segresume")
        let tempExists = FileManager.default.fileExists(atPath: temp.path)
        print("[die] received=\(box.lastProgress.0) tempExists=\(tempExists) resumeExists=\(resumeExists)")
        guard tempExists, resumeExists else {
            print("[die] FAIL: artifacts missing before exit")
            exit(1)
        }
        exit(0) // 模拟进程被杀
    }

    /// 阶段 corrupt：故意写坏断点文件（保留上阶段完整临时文件），应丢弃断点回退全新下载并完成
    static func phaseCorrupt(expectedMD5: String) async {
        let temp = URL(fileURLWithPath: "\(baseDir)/out_resume.tmp")
        try? "garbage-not-json".data(using: .utf8)!.write(to: URL(fileURLWithPath: temp.path + ".segresume"))
        let ok = await runOne(name: "resume", port: 18999, expectedMD5: expectedMD5, mode: .plain, clean: false)
        print("ALL TESTS PASSED: \(ok)")
        exit(ok ? 0 : 1)
    }

    /// 阶段 probedge：探测窗口期（服务器延迟 1.5s 响应头）的暂停/取消边界
    static func phaseProbeEdge(expectedMD5: String) async {
        var allPass = true

        // 1) 探测期间暂停 → resume 延迟发起各段并正常完成
        let tempA = URL(fileURLWithPath: "\(baseDir)/out_probe_pause.tmp")
        try? FileManager.default.removeItem(at: tempA)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempA.path + ".segresume"))
        let semA = DispatchSemaphore(value: 0)
        final class BoxA: @unchecked Sendable {
            var result: Result<(tempFileURL: URL, totalBytes: Int64), DownloadError>?
        }
        let boxA = BoxA()
        let startTaskA = Task {
            await SegmentedIPADownloader.shared.start(
                downloadId: "probe-pause",
                url: URL(string: "http://127.0.0.1:18994/file")!,
                tempFileURL: tempA,
                onProgress: { _, _ in },
                onFinish: { r in boxA.result = r; semA.signal() }
            )
        }
        try? await Task.sleep(nanoseconds: 200_000_000) // 探测仍在进行（服务器延迟 1.5s）
        SegmentedIPADownloader.shared.pause(downloadId: "probe-pause")
        await startTaskA.value
        SegmentedIPADownloader.shared.resume(downloadId: "probe-pause")
        let waitA = semA.wait(timeout: .now() + 60)
        switch boxA.result {
        case .success(let url, _) where waitA == .success:
            let ok = md5(of: url) == expectedMD5
            print("[probe-pause] \(ok ? "PASS" : "FAIL") md5=\(ok ? "match" : "MISMATCH")")
            allPass = allPass && ok
        default:
            print("[probe-pause] FAIL: result=\(String(describing: boxA.result)) wait=\(waitA)")
            allPass = false
        }

        // 2) 探测期暂停后再取消（延迟启动状态、无任务可取消）→ 应立即结束
        let tempB = URL(fileURLWithPath: "\(baseDir)/out_probe_cancel.tmp")
        try? FileManager.default.removeItem(at: tempB)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: tempB.path + ".segresume"))
        let semB = DispatchSemaphore(value: 0)
        final class BoxB: @unchecked Sendable {
            var result: Result<(tempFileURL: URL, totalBytes: Int64), DownloadError>?
        }
        let boxB = BoxB()
        let startTaskB = Task {
            await SegmentedIPADownloader.shared.start(
                downloadId: "probe-cancel",
                url: URL(string: "http://127.0.0.1:18994/file")!,
                tempFileURL: tempB,
                onProgress: { _, _ in },
                onFinish: { r in boxB.result = r; semB.signal() }
            )
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        SegmentedIPADownloader.shared.pause(downloadId: "probe-cancel")
        await startTaskB.value
        SegmentedIPADownloader.shared.cancel(downloadId: "probe-cancel")
        let waitB = semB.wait(timeout: .now() + 10)
        var cancelledOk = false
        if case .failure(let e) = boxB.result, waitB == .success,
           e.localizedDescription.contains("cancel") || e.localizedDescription.contains("取消") {
            cancelledOk = true
        }
        print("[probe-cancel] \(cancelledOk ? "PASS" : "FAIL") result=\(String(describing: boxB.result)) wait=\(waitB)")
        allPass = allPass && cancelledOk

        print(allPass ? "ALL TESTS PASSED" : "TESTS FAILED")
        exit(allPass ? 0 : 1)
    }

    /// 阶段 stall：服务器扣住连接不发数据 → 看门狗应在阈值后判定失败并保留断点
    static func phaseStall() async {
        SegmentedIPADownloader.stallTimeout = 3
        let temp = URL(fileURLWithPath: "\(baseDir)/out_stall.tmp")
        try? FileManager.default.removeItem(at: temp)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: temp.path + ".segresume"))
        let sem = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var result: Result<(tempFileURL: URL, totalBytes: Int64), DownloadError>?
        }
        let box = Box()
        let started = Date()
        await SegmentedIPADownloader.shared.start(
            downloadId: "test-stall",
            url: URL(string: "http://127.0.0.1:18992/file")!,
            tempFileURL: temp,
            onProgress: { _, _ in },
            onFinish: { r in box.result = r; sem.signal() }
        )
        let wait = sem.wait(timeout: .now() + 30)
        let elapsed = Date().timeIntervalSince(started)
        SegmentedIPADownloader.stallTimeout = 45
        if wait == .success, case .failure(let e) = box.result {
            let msg = e.localizedDescription
            let timedOut = msg.contains("超时") || msg.contains("timeout") || msg.contains("timed out")
            let inWindow = elapsed >= 3 && elapsed < 20
            let ok = timedOut && inWindow
            print("[stall] \(ok ? "PASS" : "FAIL") elapsed=\(String(format: "%.1f", elapsed))s error=\(msg)")
            print(allPassText(ok))
            exit(ok ? 0 : 1)
        }
        print("[stall] FAIL: wait=\(wait) result=\(String(describing: box.result))")
        print("TESTS FAILED")
        exit(1)
    }

    static func allPassText(_ ok: Bool) -> String { ok ? "ALL TESTS PASSED" : "TESTS FAILED" }

    static func main() async {
        try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
        let sourceURL = URL(fileURLWithPath: "\(baseDir)/big.bin")
        let expected = md5(of: sourceURL)
        let phase = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "all"

        switch phase {
        case "die":
            await phaseDie()
        case "resume":
            var allPass = true
            allPass = await runOne(name: "resume", port: 18995, expectedMD5: expected, mode: .expectResume, clean: false, minResumedBytes: 15 * 1024 * 1024) && allPass
            print(allPass ? "ALL TESTS PASSED" : "TESTS FAILED")
            exit(allPass ? 0 : 1)
        case "corrupt":
            await phaseCorrupt(expectedMD5: expected)
        case "probedge":
            await phaseProbeEdge(expectedMD5: expected)
        case "stall":
            await phaseStall()
        default:
            var allPass = true
            // 1) 分段模式（服务器支持 Range）
            allPass = await runOne(name: "segmented", port: 18999, expectedMD5: expected, mode: .plain) && allPass
            // 2) 回退单流模式（服务器忽略 Range 返回 200）
            allPass = await runOne(name: "fallback", port: 18998, expectedMD5: expected, mode: .plain) && allPass
            // 3) 取消（限速服务器，确保下载未提前完成）
            allPass = await runOne(name: "cancel", port: 18997, expectedMD5: expected, mode: .cancel) && allPass
            // 4) 暂停后恢复（限速服务器）
            allPass = await runOne(name: "pause", port: 18996, expectedMD5: expected, mode: .pauseResume) && allPass
            // 5) 取消后重新下载同一 id → 应从断点续传
            allPass = await runOne(name: "cancelresume", port: 18997, expectedMD5: expected, mode: .cancel) && allPass
            allPass = await runOne(name: "cancelresume", port: 18997, expectedMD5: expected, mode: .expectResume, clean: false) && allPass
            print(allPass ? "ALL TESTS PASSED" : "TESTS FAILED")
            exit(allPass ? 0 : 1)
        }
    }
}
