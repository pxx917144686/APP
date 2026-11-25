import Foundation
import ZIPFoundation

private final class TFZipHandle {
    let archive: Archive
    let names: [String]
    var cNames: [UnsafeMutablePointer<CChar>?]

    init?(path: String) {
        guard let archive = Archive(url: URL(fileURLWithPath: path), accessMode: .read) else { return nil }
        self.archive = archive
        self.names = archive.map(\.path)
        self.cNames = names.map { strdup($0) }
    }

    deinit {
        for pointer in cNames { free(pointer) }
    }
}

private var tfZipError = "ZIPFoundation runtime"
private let tfZipLock = NSLock()

private func setZipError(_ message: String) {
    tfZipLock.lock()
    tfZipError = message
    tfZipLock.unlock()
}

@_cdecl("tf_zip_open_read")
public func tfZipOpenRead(_ path: UnsafePointer<CChar>?) -> OpaquePointer? {
    guard let path else { return nil }
    guard let handle = TFZipHandle(path: String(cString: path)) else {
        setZipError("cannot open archive")
        return nil
    }
    return OpaquePointer(Unmanaged.passRetained(handle).toOpaque())
}

@_cdecl("tf_zip_close_read")
public func tfZipCloseRead(_ pointer: OpaquePointer?) {
    guard let pointer else { return }
    Unmanaged<TFZipHandle>.fromOpaque(UnsafeRawPointer(pointer)).release()
}

@_cdecl("tf_zip_count")
public func tfZipCount(_ pointer: OpaquePointer?) -> Int32 {
    guard let pointer else { return 0 }
    let handle = Unmanaged<TFZipHandle>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
    return Int32(handle.names.count)
}

@_cdecl("tf_zip_name")
public func tfZipName(_ pointer: OpaquePointer?, _ index: UInt32) -> UnsafePointer<CChar>? {
    guard let pointer else { return nil }
    let handle = Unmanaged<TFZipHandle>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
    guard Int(index) < handle.cNames.count else { return nil }
    return UnsafePointer(handle.cNames[Int(index)])
}

@_cdecl("tf_zip_read")
public func tfZipRead(_ pointer: OpaquePointer?, _ entry: UnsafePointer<CChar>?,
                      _ data: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                      _ size: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard let pointer, let entry, let data, let size else { return 0 }
    let handle = Unmanaged<TFZipHandle>.fromOpaque(UnsafeRawPointer(pointer)).takeUnretainedValue()
    let name = String(cString: entry)
    guard let record = handle.archive[name] else {
        setZipError("entry not found: \(name)")
        return 0
    }
    var output = Data()
    do {
        _ = try handle.archive.extract(record, skipCRC32: false) { chunk in
            output.append(chunk)
        }
    } catch {
        setZipError(error.localizedDescription)
        return 0
    }
    guard output.count <= Int(UInt32.max) else {
        setZipError("entry is too large")
        return 0
    }
    let buffer = malloc(max(output.count, 1))!.assumingMemoryBound(to: UInt8.self)
    output.withUnsafeBytes { source in
        if let base = source.baseAddress { memcpy(buffer, base, output.count) }
    }
    data.pointee = buffer
    size.pointee = UInt32(output.count)
    return 1
}

@_cdecl("tf_add_sinf")
public func tfAddSinf(_ ipa: UnsafePointer<CChar>?, _ entry: UnsafePointer<CChar>?,
                      _ data: UnsafePointer<UInt8>?, _ size: UInt32) -> Int32 {
    guard let ipa, let entry, let data else { return 0 }
    let url = URL(fileURLWithPath: String(cString: ipa))
    let name = String(cString: entry)
    do {
        guard var archive = Archive(url: url, accessMode: .update) else {
            setZipError("cannot update archive")
            return 0
        }
        if let existing = archive[name] {
            try archive.remove(existing)
        }
        let payload = Data(bytes: data, count: Int(size))
        try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(payload.count),
                              compressionMethod: .deflate) { position, chunkSize in
            let start = Int(position)
            let end = min(start + chunkSize, payload.count)
            return payload.subdata(in: start..<end)
        }
        return 1
    } catch {
        setZipError(error.localizedDescription)
        return 0
    }
}

@_cdecl("tf_free")
public func tfFree(_ pointer: UnsafeMutableRawPointer?) {
    free(pointer)
}

@_cdecl("tf_last_error")
public func tfLastError() -> UnsafePointer<CChar>? {
    tfZipLock.lock()
    let message = tfZipError
    tfZipLock.unlock()
    return UnsafePointer(strdup(message))
}
