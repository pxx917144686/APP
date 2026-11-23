import AVFoundation

@MainActor
final class InstallKeepAlive {
    static let shared = InstallKeepAlive()

    private let engine = AVAudioEngine()
    private lazy var source = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        for buffer in buffers {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        return noErr
    }

    private(set) var isActive = false
    private var holders: Set<String> = []
    private var watchdog: Task<Void, Never>?
    private var sourceAttached = false
    private static let maxDuration: TimeInterval = 3 * 60 * 60

    func start(_ holder: String = "default") {
        holders.insert(holder)
        activateIfNeeded()
    }

    func stop(_ holder: String = "default") {
        holders.remove(holder)
        guard holders.isEmpty else { return }
        deactivate()
    }

    func stopAll() {
        holders.removeAll()
        deactivate()
    }

    private func activateIfNeeded() {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            if !sourceAttached {
                engine.attach(source)
                engine.connect(source, to: engine.mainMixerNode, format: nil)
                sourceAttached = true
            }
            engine.mainMixerNode.outputVolume = 0
            try engine.start()
            isActive = true
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.maxDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.stopAll()
            }
        } catch {
            isActive = false
        }
    }

    private func deactivate() {
        watchdog?.cancel()
        watchdog = nil
        guard isActive else { return }
        isActive = false
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
