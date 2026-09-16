import Foundation
import SystemConfiguration
#if canImport(IOKit)
import IOKit
#endif

struct MachineIdentity: Equatable, Sendable {
    let guid: String
    let machineID: Data
}

enum MachineIdentityProvider {

    private static let invalidGUIDs: Set<String> = [
        "000000000000",
        "020000000000",
        "FFFFFFFFFFFF"
    ]

    static func isValidGUID(_ guid: String) -> Bool {
        guard guid.count == 12, !invalidGUIDs.contains(guid) else { return false }
        guard let firstByte = UInt8(guid.prefix(2), radix: 16) else { return false }
        return firstByte & 1 == 0
    }

    static func resolve() throws -> MachineIdentity {
        #if targetEnvironment(simulator) || os(iOS)
        let mac = persistentWiFiAddress() ?? fallbackRandomMAC()
        #else
        let mac = try primaryMACAddress() ?? fallbackRandomMAC()
        #endif
        let machineID = Data(mac)
        let guid = machineID.map { String(format: "%02X", $0) }.joined()
        if !isValidGUID(guid) {
        }
        return MachineIdentity(guid: guid, machineID: machineID)
    }

    #if os(iOS)
    private static func persistentWiFiAddress() -> [UInt8]? {
        if let cached = UserDefaults.standard.string(forKey: "sap_mac_address_v1") {
            return parseMAC(cached)
        }
        let addr = fallbackRandomMAC()
        let s = addr.map { String(format: "%02X", $0) }.joined(separator: ":")
        UserDefaults.standard.set(s, forKey: "sap_mac_address_v1")
        return addr
    }
    #endif

    #if os(macOS)
    private static func primaryMACAddress() throws -> [UInt8]? {
        for target in ["en0", "en1"] {
            var addrs: [String] = []
            var ifaddr: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { continue }
            defer { freeifaddrs(first) }
            for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let name = String(cString: ptr.pointee.ifa_name)
                guard name == target else { continue }
                guard let sa = ptr.pointee.ifa_addr,
                      sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
                var sdl = unsafeBitCast(sa, to: UnsafeMutablePointer<sockaddr_dl>.self)
                let lladdr = UnsafeRawBufferPointer(
                    start: UnsafeRawPointer(sdl) + 8 + Int(sdl.pointee.sdl_nlen),
                    count: Int(sdl.pointee.sdl_alen)
                )
                let bytes = Array(lladdr)
                guard bytes.count == 6 else { continue }
                let hex = bytes.map { String(format: "%02X", $0) }.joined()
                if isValidGUID(hex) {
                    return bytes
                }
            }
        }
        return nil
    }
    #endif

    private static func fallbackRandomMAC() -> [UInt8] {
        var addr: [UInt8] = Array(repeating: 0, count: 6)
        for i in 0..<6 {
            addr[i] = UInt8.random(in: 0...255)
        }
        addr[0] = (addr[0] & 0xFE) | 0x02
        return addr
    }

    private static func parseMAC(_ s: String) -> [UInt8]? {
        let parts = s.components(separatedBy: ":")
        guard parts.count == 6 else { return nil }
        var bytes: [UInt8] = []
        for p in parts {
            guard let v = UInt8(p, radix: 16) else { return nil }
            bytes.append(v)
        }
        return bytes
    }
}
