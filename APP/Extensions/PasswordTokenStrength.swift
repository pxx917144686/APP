import Foundation

func isTrueCommerceKitPasswordToken(_ raw: String) -> Bool {
    guard !raw.isEmpty else { return false }
    if raw.hasPrefix("eyJ") && raw.contains(".") { return false }
    return raw.count >= 450
}
