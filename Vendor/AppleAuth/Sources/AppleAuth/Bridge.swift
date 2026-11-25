import Foundation
import apple_auth

internal final class NativeBridge: @unchecked Sendable {
    let deviceID = UUID()
    let transport: HTTPTransport
    let clock: @Sendable () -> Date
    private let systemHTTP: SystemHTTP?
    // These fields are used only on the device's native queue.
    var operation: NativeOperation?
    var verification: Verification?
    var failure: Error?

    init(transport: HTTPTransport?, clock: @escaping @Sendable () -> Date) {
        self.clock = clock
        if let transport { self.transport = transport; systemHTTP = nil }
        else {
            let http = SystemHTTP()
            systemHTTP = http
            self.transport = { try await http.send($0) }
        }
    }

    func close() { systemHTTP?.close() }

    func activeOperation() throws -> NativeOperation {
        guard let operation else { throw AppleAuthError("Native callback is outside a device operation") }
        return operation
    }
}

internal let transportCallback: aauth_transport_callback = { context, input, output in
    guard let context, let input, let output,
          let urlText = input.pointee.url, let method = input.pointee.method,
          let headerText = input.pointee.headers_json else { return -1 }
    let bridge = Unmanaged<NativeBridge>.fromOpaque(context).takeUnretainedValue()
    do {
        guard let url = URL(string: String(cString: urlText)), url.scheme == "https" else {
            throw AppleAuthError("Invalid native HTTPS request")
        }
        var request = URLRequest(url: url)
        request.httpMethod = String(cString: method)
        request.allHTTPHeaderFields = try JSONDecoder().decode([String: String].self, from: Data(String(cString: headerText).utf8))
        if let body = input.pointee.body, input.pointee.body_size > 0 {
            request.httpBody = Data(bytes: body, count: input.pointee.body_size)
        }
        let transport = bridge.transport
        let copied = request
        let deviceID = bridge.deviceID
        let response = try bridge.activeOperation().blocking {
            try await NativeCallbackContext.$deviceID.withValue(deviceID) { try await transport(copied) }
        }
        guard (100...599).contains(response.status), response.body.count <= 16 * 1024 * 1024 else {
            throw AppleAuthError("Invalid custom transport response")
        }
        let headers = try JSONSerialization.data(withJSONObject: response.headers.map { [$0.name, $0.value] })
        guard headers.count <= 64 * 1024 else { throw AppleAuthError("HTTP headers exceed 64 KiB") }
        try checkClient(aauth_client_buffer_alloc(response.body.count, &output.pointee.body))
        try checkClient(aauth_client_buffer_alloc(headers.count, &output.pointee.headers_json))
        if let body = output.pointee.body.data { response.body.copyBytes(to: body, count: response.body.count) }
        if let bytes = output.pointee.headers_json.data { headers.copyBytes(to: bytes, count: headers.count) }
        output.pointee.status = response.status
        return 0
    } catch { bridge.failure = error; return -1 }
}

internal let clockCallback: aauth_clock_callback = { context in
    guard let context else { return 0 }
    let bridge = Unmanaged<NativeBridge>.fromOpaque(context).takeUnretainedValue()
    let seconds = bridge.clock().timeIntervalSince1970
    return seconds.isFinite && seconds >= 0 && seconds < Double(Int64.max) ? Int64(seconds) : 0
}

internal let codeCallback: aauth_two_factor_callback = { context, output, capacity, written in
    guard let context, let output, let written else { return -1 }
    let bridge = Unmanaged<NativeBridge>.fromOpaque(context).takeUnretainedValue()
    do {
        guard let verification = bridge.verification else { throw AppleAuthError("Missing verification handler") }
        let deviceID = bridge.deviceID
        let code = try bridge.activeOperation().blocking {
            try await NativeCallbackContext.$deviceID.withValue(deviceID) { try await verification.code() }
        }
        let bytes = Array(code.utf8)
        guard bytes.count <= capacity else { throw AppleAuthError("Verification code is too long") }
        for (index, byte) in bytes.enumerated() { output[index] = CChar(bitPattern: byte) }
        written.pointee = bytes.count
        return 0
    } catch { bridge.failure = error; return -1 }
}

internal let phoneCallback: aauth_phone_selection_callback = { context, input, selected in
    guard let context, let input, let selected else { return -1 }
    let bridge = Unmanaged<NativeBridge>.fromOpaque(context).takeUnretainedValue()
    do {
        guard let choose = bridge.verification?.selectPhone else { throw AppleAuthError("Missing phone selection handler") }
        let phones = try JSONDecoder().decode([TrustedPhoneNumber].self, from: Data(String(cString: input).utf8))
        let deviceID = bridge.deviceID
        selected.pointee = try bridge.activeOperation().blocking {
            try await NativeCallbackContext.$deviceID.withValue(deviceID) { try await choose(phones) }
        }
        return 0
    } catch { bridge.failure = error; return -1 }
}
