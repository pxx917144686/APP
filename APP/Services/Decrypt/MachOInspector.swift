import Foundation

enum MachOInspector {
    struct Result {
        var architectures: [String] = []
        var libraries: [String] = []
        var minimumOS: String?
    }

    struct Section {
        let segment: String
        let name: String
        let size: UInt64
        let fileOffset: UInt32
    }

    static func sections(url: URL) -> [Section] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return [] }
        let bigEndian = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.byteSwapped

        var sliceOffset: UInt64 = 0
        if bigEndian == magicFat {
            guard let countData = try? handle.read(upToCount: 4), countData.count == 4 else { return [] }
            let archCount = Int(countData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.byteSwapped)
            guard archCount > 0, archCount < 16,
                  let entry = try? handle.read(upToCount: 20), entry.count == 20 else { return [] }
            let offset = entry.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }.byteSwapped
            sliceOffset = UInt64(offset)
        }

        return readSections(handle: handle, sliceOffset: sliceOffset)
    }

    private static func readSections(handle: FileHandle, sliceOffset: UInt64) -> [Section] {
        guard (try? handle.seek(toOffset: sliceOffset)) != nil,
              let header = try? handle.read(upToCount: 32), header.count >= 28 else { return [] }

        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard magic == magic64 else { return [] }

        let ncmds = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        let sizeofcmds = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        guard ncmds > 0, ncmds < 8192, sizeofcmds > 0, sizeofcmds < 4 << 20 else { return [] }

        guard (try? handle.seek(toOffset: sliceOffset + 32)) != nil,
              let commands = try? handle.read(upToCount: Int(sizeofcmds)),
              commands.count == Int(sizeofcmds) else { return [] }

        let bytes = [UInt8](commands)
        var result: [Section] = []
        var cursor = 0

        for _ in 0..<Int(ncmds) {
            guard cursor + 8 <= bytes.count else { break }
            let cmd = readUInt32(bytes, cursor)
            let cmdSize = readUInt32(bytes, cursor + 4)
            guard cmdSize >= 8, cursor + Int(cmdSize) <= bytes.count else { break }

            if cmd == 0x19, cmdSize >= 72 {
                let nsects = readUInt32(bytes, cursor + 64)
                var sectionOffset = cursor + 72
                for _ in 0..<Int(nsects) {
                    guard sectionOffset + 80 <= cursor + Int(cmdSize) else { break }
                    let name = string(bytes, sectionOffset, 16)
                    let segment = string(bytes, sectionOffset + 16, 16)
                    let size = readUInt64(bytes, sectionOffset + 40)
                    let fileOffset = readUInt32(bytes, sectionOffset + 48)
                    if size > 0 {
                        result.append(Section(segment: segment, name: name, size: size, fileOffset: fileOffset))
                    }
                    sectionOffset += 80
                }
            }

            cursor += Int(cmdSize)
        }
        return result
    }

    private static func string(_ bytes: [UInt8], _ offset: Int, _ length: Int) -> String {
        guard offset + length <= bytes.count else { return "" }
        var out: [UInt8] = []
        for index in offset..<(offset + length) {
            let byte = bytes[index]
            if byte == 0 { break }
            out.append(byte)
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        guard offset + 8 <= bytes.count else { return 0 }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
        }
        return value
    }

    private enum LC {
        static let loadDylib: UInt32 = 0xC
        static let loadWeakDylib: UInt32 = 0x80000018
        static let reexportDylib: UInt32 = 0x8000001F
        static let versionMinIPhoneOS: UInt32 = 0x25
        static let buildVersion: UInt32 = 0x32
    }

    private static let magic32: UInt32 = 0xFEEDFACE
    private static let magic64: UInt32 = 0xFEEDFACF
    private static let magicFat: UInt32 = 0xCAFEBABE

    static func inspect(url: URL) -> Result {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Result() }
        defer { try? handle.close() }

        guard let head = try? handle.read(upToCount: 8), head.count == 8 else { return Result() }

        let bigEndian = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.byteSwapped

        if bigEndian == magicFat {
            return inspectFat(handle: handle)
        }
        return inspectThin(handle: handle, offset: 0)
    }

    private static func inspectFat(handle: FileHandle) -> Result {
        var result = Result()
        guard let countData = try? handle.read(upToCount: 4), countData.count == 4 else { return result }
        let archCount = Int(countData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.byteSwapped)
        guard archCount > 0, archCount < 16 else { return result }

        var offsets: [UInt64] = []
        var cpuTypes: [UInt32] = []
        var cpuSubtypes: [UInt32] = []
        for _ in 0..<archCount {
            guard let entry = try? handle.read(upToCount: 20), entry.count == 20 else { break }
            let cpu = entry.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(fromByteOffset: 0, as: UInt32.self).byteSwapped
            }
            let offset = entry.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self).byteSwapped
            }
            let subtype = entry.withUnsafeBytes { raw -> UInt32 in
                raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self).byteSwapped
            }
            cpuTypes.append(cpu)
            cpuSubtypes.append(subtype)
            offsets.append(UInt64(offset))
        }

        for (index, offset) in offsets.enumerated() {
            let slice = inspectThin(handle: handle, offset: offset)
            if let name = architectureName(cpuTypes[index], cpuSubtypes[index]) {
                result.architectures.append(name)
            }
            if result.minimumOS == nil { result.minimumOS = slice.minimumOS }
            if result.libraries.isEmpty { result.libraries = slice.libraries }
        }
        return result
    }

    private static func inspectThin(handle: FileHandle, offset: UInt64) -> Result {
        var result = Result()
        guard (try? handle.seek(toOffset: offset)) != nil,
              let header = try? handle.read(upToCount: 32), header.count >= 28 else {
            return result
        }

        let magic = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard magic == magic64 || magic == magic32 else { return result }
        let is64 = magic == magic64
        let headerSize = is64 ? 32 : 28

        let cpuType = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let cpuSubtype = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
        if let name = architectureName(cpuType, cpuSubtype) {
            result.architectures.append(name)
        }

        let ncmds = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        let sizeofcmds = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        guard ncmds > 0, ncmds < 8192, sizeofcmds > 0, sizeofcmds < 4 << 20 else { return result }

        guard (try? handle.seek(toOffset: offset + UInt64(headerSize))) != nil,
              let commands = try? handle.read(upToCount: Int(sizeofcmds)),
              commands.count == Int(sizeofcmds) else { return result }

        var cursor = 0
        let bytes = [UInt8](commands)

        for _ in 0..<Int(ncmds) {
            guard cursor + 8 <= bytes.count else { break }
            let cmd = readUInt32(bytes, cursor)
            let cmdSize = readUInt32(bytes, cursor + 4)
            guard cmdSize >= 8, cursor + Int(cmdSize) <= bytes.count else { break }

            switch cmd {
            case LC.loadDylib, LC.loadWeakDylib, LC.reexportDylib:
                if let name = readDylibName(bytes, cursor, cursor + Int(cmdSize)) {
                    result.libraries.append(name)
                }

            case LC.buildVersion:
                if cmdSize >= 16 {
                    let minos = readUInt32(bytes, cursor + 12)
                    if result.minimumOS == nil {
                        result.minimumOS = versionString(minos)
                    }
                }

            case LC.versionMinIPhoneOS:
                if cmdSize >= 12 {
                    let version = readUInt32(bytes, cursor + 8)
                    if result.minimumOS == nil {
                        result.minimumOS = versionString(version)
                    }
                }

            default:
                break
            }

            cursor += Int(cmdSize)
        }

        return result
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readDylibName(_ bytes: [UInt8], _ commandStart: Int, _ end: Int) -> String? {
        guard commandStart + 12 <= end, commandStart + 12 <= bytes.count else { return nil }
        let nameOffset = Int(readUInt32(bytes, commandStart + 8))
        let nameStart = commandStart + nameOffset
        guard nameOffset > 0, nameStart >= commandStart, nameStart < end, nameStart < bytes.count else { return nil }

        var text: [UInt8] = []
        var index = nameStart
        while index < end, index < bytes.count, bytes[index] != 0 {
            text.append(bytes[index])
            index += 1
        }
        let name = String(decoding: text, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    private static func versionString(_ value: UInt32) -> String {
        let major = (value >> 16) & 0xFFFF
        let minor = (value >> 8) & 0xFF
        let patch = value & 0xFF
        if patch != 0 { return "\(major).\(minor).\(patch)" }
        if minor != 0 { return "\(major).\(minor)" }
        return "\(major)"
    }

    private static func architectureName(_ cpuType: UInt32, _ cpuSubtype: UInt32) -> String? {
        switch cpuType {
        case 0x0100000C:
            return (cpuSubtype & 0xFF) == 2 ? "arm64e" : "arm64"
        case 12:
            return "armv7"
        case 0x01000007:
            return "x86_64"
        default:
            return nil
        }
    }
}
