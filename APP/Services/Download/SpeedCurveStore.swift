import Foundation

actor SpeedCurveStore {
    static let shared = SpeedCurveStore()

    private struct Stored: Codable {
        var time: [Double]
        var bytes: [Int64]
        var speed: [Double]
    }

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TransferCurves", isDirectory: true)
    }

    private func fileURL(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    func save(id: String, samples: [DownloadRuntime.SpeedSample]) {
        guard !samples.isEmpty else { return }
        let stored = Stored(
            time: samples.map { $0.time },
            bytes: samples.map { $0.bytes },
            speed: samples.map { $0.speed }
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(stored)
            try data.write(to: fileURL(id), options: .atomic)
        } catch {
        }
    }

    func load(id: String) -> [DownloadRuntime.SpeedSample] {
        guard let data = try? Data(contentsOf: fileURL(id)),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.time.count == stored.bytes.count,
              stored.time.count == stored.speed.count else { return [] }
        return zip(zip(stored.time, stored.bytes), stored.speed).map { pair, speed in
            DownloadRuntime.SpeedSample(time: pair.0, bytes: pair.1, speed: speed)
        }
    }
}
