import SwiftUI
import UIKit

struct SigningDeviceUDIDSheet: View {
    @Binding var deviceUDID: String
    @Binding var serviceURL: String
    let profile: SigningProfile?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager

    private var trimmedUDID: String {
        deviceUDID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var profileDevices: [String] {
        profile?.provisionedDevices ?? []
    }

    private var allDevices: Bool {
        profile?.provisionsAllDevices == true || profile?.isEnterprise == true
    }

    private var status: (text: String, color: Color, icon: String) {
        guard profile != nil else {
            return ("sign_device_no_profile".localized, .secondary, "doc")
        }
        if allDevices {
            return ("sign_device_all_devices".localized, .green, "checkmark.circle.fill")
        }
        if profileDevices.isEmpty {
            return ("sign_device_no_list".localized, .orange, "exclamationmark.triangle.fill")
        }
        if trimmedUDID.isEmpty {
            return ("sign_device_not_set".localized, .orange, "questionmark.circle.fill")
        }
        if profileDevices.contains(where: { $0.caseInsensitiveCompare(trimmedUDID) == .orderedSame }) {
            return ("sign_device_in_profile".localized, .green, "checkmark.circle.fill")
        }
        return ("sign_device_not_in_profile".localized, .red, "xmark.circle.fill")
    }

    var body: some SwiftUI.View {
        NavigationView {
            ScrollView {
                VStack(spacing: 12) {
                    statusCard
                    udidCard
                    serviceCard
                    helpCard
                }
                .padding(16)
            }
            .background(themeManager.backgroundColor.ignoresSafeArea())
            .navigationTitle("sign_device_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .presentationDetents([.large])
    }

    private var statusCard: some SwiftUI.View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: status.icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(status.color)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(status.color)
                if let profile {
                    Text(profile.displayName)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(format: "sign_device_count".localized, profileDevices.count))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(status.color.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(status.color.opacity(0.18), lineWidth: 0.5)
        )
    }

    private var udidCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 8) {
            Text("sign_device_udid".localized)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)

            TextField("sign_device_udid_placeholder".localized, text: $deviceUDID)
                .font(.system(size: 11, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )

            HStack(spacing: 9) {
                Button {
                    if let value = UIPasteboard.general.string {
                        deviceUDID = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Label("sign_device_paste".localized, systemImage: "doc.on.clipboard")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(themeManager.accentColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(themeManager.accentColor.opacity(0.10)))
                }
                .buttonStyle(.plain)

                Button {
                    openService()
                } label: {
                    Label("sign_device_get".localized, systemImage: "safari")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(LinearGradient(colors: [themeManager.accentColor, .cyan], startPoint: .leading, endPoint: .trailing)))
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var serviceCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 6) {
            Text("sign_device_service".localized)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("https://udid.my/", text: $serviceURL)
                .font(.system(size: 9.5, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(9)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            Text("sign_device_service_hint".localized)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private var helpCard: some SwiftUI.View {
        VStack(alignment: .leading, spacing: 6) {
            Text("sign_device_help_title".localized)
                .font(.system(size: 11, weight: .bold))
            Text("sign_device_help".localized)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("sign_device_privacy".localized)
                .font(.system(size: 8.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func openService() {
        let raw = serviceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = raw.isEmpty ? "https://udid.my/" : raw
        guard let url = URL(string: target) else { return }
        UIApplication.shared.open(url)
    }
}
