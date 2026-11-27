import AVFAudio
import AudioToolbox
import SwiftUI

enum UISound: CaseIterable {
    case press
    case tap
    case tick
    case copy
    case rise
    case fall
    case dismiss
    case success
    case error
    case attention
}

enum SoundEffects {
    static let enabledKey = "soundEffects"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static func play(_ sound: UISound) {
        guard isEnabled else { return }
        queue.async {
            if let id = loadedIDs()[sound] {
                AudioServicesPlaySystemSound(id)
            }
        }
    }

    static func prepare() {
        queue.async { _ = loadedIDs() }
    }

    private static let queue = DispatchQueue(label: "SoundEffects", qos: .userInteractive)
    private static var ids: [UISound: SystemSoundID]?

    private static func loadedIDs() -> [UISound: SystemSoundID] {
        if let ids { return ids }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SoundEffects", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var made: [UISound: SystemSoundID] = [:]
        for sound in UISound.allCases {
            let url = folder.appendingPathComponent("\(sound).wav")
            guard (try? sound.wav.write(to: url, options: .atomic)) != nil else { continue }
            var id: SystemSoundID = 0
            if AudioServicesCreateSystemSoundID(url as CFURL, &id) == kAudioServicesNoError {
                made[sound] = id
            }
        }
        ids = made
        return made
    }
}

extension View {
    func buttonStyle<S: PrimitiveButtonStyle>(_ style: S, sound: UISound) -> some View {
        buttonStyle(SoundingPrimitiveButtonStyle(base: style, sound: sound))
    }

    func buttonStyle<S: ButtonStyle>(_ style: S, sound: UISound) -> some View {
        buttonStyle(SoundingButtonStyle(base: style, sound: sound))
    }
}

private struct SoundingPrimitiveButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    var base: Base
    var sound: UISound

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            SoundEffects.play(sound)
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(base)
    }
}

struct SoundingButtonStyle<Base: ButtonStyle>: PrimitiveButtonStyle {
    var base: Base
    var sound: UISound

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role) {
            SoundEffects.play(sound)
            configuration.trigger()
        } label: {
            configuration.label
        }
        .buttonStyle(base)
    }
}

struct SoundingToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(isOn: Binding(
            get: { configuration.isOn },
            set: { isOn in
                configuration.$isOn.wrappedValue = isOn
                SoundEffects.play(isOn ? .rise : .fall)
            }
        )) {
            configuration.label
        }
        .toggleStyle(.switch)
    }
}

private struct Note {
    var at: Double = 0
    var pitch: Double
    var slidesTo: Double? = nil
    var glide: Double = 0
    var ring: Double
    var level: Double = 1
    var attack: Double = 0.002
    var overtones: [Overtone] = []
}

private struct Overtone {
    var ratio: Double
    var level: Double
    var ring: Double
}

private extension Overtone {
    static let wood = [Overtone(ratio: 2, level: 0.3, ring: 0.6),
                       Overtone(ratio: 3, level: 0.08, ring: 0.4)]
    static let mallet = [Overtone(ratio: 2, level: 0.28, ring: 0.55),
                         Overtone(ratio: 3, level: 0.1, ring: 0.35),
                         Overtone(ratio: 4.2, level: 0.05, ring: 0.25)]
    static let glass = [Overtone(ratio: 2.0, level: 0.22, ring: 0.5),
                        Overtone(ratio: 3.01, level: 0.08, ring: 0.3),
                        Overtone(ratio: 5.4, level: 0.035, ring: 0.15)]
    static let muted = [Overtone(ratio: 2, level: 0.45, ring: 0.45),
                        Overtone(ratio: 3, level: 0.12, ring: 0.3)]
}

private extension UISound {
    var recipe: (notes: [Note], click: Double, length: Double, peak: Double) {
        switch self {
        case .press:
            return ([Note(pitch: 640, slidesTo: 420, glide: 0.05, ring: 0.035,
                          attack: 0.001, overtones: Overtone.wood),
                     Note(pitch: 1760, ring: 0.018, level: 0.16, attack: 0.001)],
                    click: 0.3, length: 0.18, peak: 0.5)
        case .tap:
            return ([Note(pitch: 1900, slidesTo: 1450, glide: 0.012, ring: 0.012,
                          attack: 0.0008, overtones: [Overtone(ratio: 2, level: 0.25, ring: 0.5)])],
                    click: 0.22, length: 0.07, peak: 0.32)
        case .tick:
            return ([Note(pitch: 2600, slidesTo: 2250, glide: 0.006, ring: 0.006, attack: 0.0005)],
                    click: 0.12, length: 0.04, peak: 0.2)
        case .copy:
            return ([Note(pitch: 1567.98, ring: 0.045, overtones: Overtone.glass),
                     Note(at: 0.05, pitch: 2093, ring: 0.06, overtones: Overtone.glass)],
                    click: 0, length: 0.22, peak: 0.3)
        case .rise:
            return ([Note(pitch: 990, ring: 0.04, overtones: [Overtone(ratio: 2, level: 0.2, ring: 0.5)]),
                     Note(at: 0.05, pitch: 1480, ring: 0.07, overtones: [Overtone(ratio: 2, level: 0.2, ring: 0.5)])],
                    click: 0, length: 0.26, peak: 0.3)
        case .fall:
            return ([Note(pitch: 1480, ring: 0.04, overtones: [Overtone(ratio: 2, level: 0.2, ring: 0.5)]),
                     Note(at: 0.05, pitch: 990, ring: 0.07, overtones: [Overtone(ratio: 2, level: 0.2, ring: 0.5)])],
                    click: 0, length: 0.26, peak: 0.26)
        case .dismiss:
            return ([Note(pitch: 1150, slidesTo: 540, glide: 0.09, ring: 0.05, attack: 0.003,
                          overtones: [Overtone(ratio: 2, level: 0.15, ring: 0.5)])],
                    click: 0, length: 0.2, peak: 0.24)
        case .success:
            let pitches = [880.0, 1108.73, 1318.51, 1760]
            let notes = pitches.enumerated().map { i, pitch in
                Note(at: Double(i) * 0.075, pitch: pitch, ring: i == 3 ? 0.42 : 0.16,
                     level: 0.8 + Double(i) * 0.065, overtones: Overtone.mallet)
            }
            return (notes, click: 0, length: 1.35, peak: 0.5)
        case .error:
            return ([Note(pitch: 659.25, slidesTo: 650, glide: 0.1, ring: 0.11,
                          attack: 0.004, overtones: Overtone.muted),
                     Note(at: 0.14, pitch: 523.25, slidesTo: 512, glide: 0.25, ring: 0.2,
                          attack: 0.004, overtones: Overtone.muted)],
                    click: 0, length: 0.95, peak: 0.52)
        case .attention:
            return ([Note(pitch: 784, ring: 0.05, level: 0.55, overtones: Overtone.glass),
                     Note(at: 0.065, pitch: 1046.5, ring: 0.34, overtones: Overtone.glass)],
                    click: 0, length: 1.2, peak: 0.45)
        }
    }

    var wav: Data {
        let recipe = recipe
        return Synth.wav(Synth.render(recipe.notes, click: recipe.click,
                                      length: recipe.length, peak: recipe.peak))
    }
}

private enum Synth {
    static let rate = 44_100

    static func render(_ notes: [Note], click: Double, length: Double, peak: Double) -> [Int16] {
        let sr = Double(rate)
        let count = Int(length * sr)
        var mix = [Double](repeating: 0, count: count)

        for note in notes {
            let first = Int(note.at * sr)
            let last = min(count, first + Int(note.ring * 9 * sr))
            guard first < last else { continue }
            let partials = [Overtone(ratio: 1, level: 1, ring: 1)] + note.overtones
            var phase = 0.0
            for i in first..<last {
                let t = Double(i - first) / sr
                var pitch = note.pitch
                if let target = note.slidesTo, note.glide > 0 {
                    pitch *= pow(target / note.pitch, min(t / note.glide, 1))
                }
                phase += 2 * .pi * pitch / sr
                let swell = t < note.attack ? pow(sin(.pi / 2 * t / note.attack), 2) : 1
                var sample = 0.0
                for partial in partials {
                    sample += partial.level * sin(phase * partial.ratio)
                        * exp(-t / (note.ring * partial.ring))
                }
                mix[i] += note.level * swell * sample
            }
        }

        if click > 0 {
            var seed: UInt32 = 0x9E37_79B9
            var previous = 0.0
            for i in 0..<min(count, rate / 100) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = Double(seed) / Double(UInt32.max) * 2 - 1
                mix[i] += click * (noise - previous) * exp(-Double(i) / sr / 0.0012)
                previous = noise
            }
        }

        let fade = min(count, Int(0.008 * sr))
        for i in 0..<fade {
            mix[count - 1 - i] *= Double(i) / Double(fade)
        }

        let loudest = mix.lazy.map(abs).max() ?? 0
        let scale = loudest > 0 ? peak / loudest : 0
        return mix.map { Int16(max(-1, min(1, $0 * scale)) * Double(Int16.max)) }
    }

    static func wav(_ samples: [Int16]) -> Data {
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16))
        put(UInt16(1))
        put(UInt16(1))
        put(UInt32(rate))
        put(UInt32(rate * 2))
        put(UInt16(2))
        put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for sample in samples { put(sample) }
        return data
    }
}
