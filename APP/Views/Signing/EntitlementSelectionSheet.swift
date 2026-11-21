import SwiftUI
import UniformTypeIdentifiers

enum SigningEntitlementsMode: String, CaseIterable, Identifiable {
    case profile
    case appDeclared
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return "sign_ent_mode_profile".localized
        case .appDeclared: return "sign_ent_mode_app".localized
        case .custom: return "sign_ent_mode_custom".localized
        }
    }

    var hint: String {
        switch self {
        case .profile: return "sign_ent_mode_profile_hint".localized
        case .appDeclared: return "sign_ent_mode_app_hint".localized
        case .custom: return "sign_ent_mode_custom_hint".localized
        }
    }
}

enum SigningEntitlementCategory: String, CaseIterable, Identifiable {
    case core
    case appGroup
    case keychain
    case push
    case network
    case web
    case icloud
    case media
    case siri
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .core: return "sig_ent_cat_core".localized
        case .appGroup: return "sig_ent_cat_app_group".localized
        case .keychain: return "sig_ent_cat_keychain".localized
        case .push: return "sig_ent_cat_push".localized
        case .network: return "sig_ent_cat_network".localized
        case .web: return "sig_ent_cat_web".localized
        case .icloud: return "sig_ent_cat_icloud".localized
        case .media: return "sig_ent_cat_media".localized
        case .siri: return "sig_ent_cat_siri".localized
        case .other: return "sig_ent_cat_other".localized
        }
    }

    var icon: String {
        switch self {
        case .core: return "app.badge.checkmark"
        case .appGroup: return "square.stack.3d.up.fill"
        case .keychain: return "key.fill"
        case .push: return "bell.badge.fill"
        case .network: return "network"
        case .web: return "link"
        case .icloud: return "icloud.fill"
        case .media: return "heart.fill"
        case .siri: return "waveform.circle.fill"
        case .other: return "puzzlepiece.extension.fill"
        }
    }

    var sortOrder: Int { Self.allCases.firstIndex(of: self) ?? 99 }
}

struct SigningEntitlementInfo {
    let title: String
    let description: String
    let category: SigningEntitlementCategory
    let isCritical: Bool
}

enum SigningEntitlementCatalog {
    static func info(for key: String, profileDescription: String?) -> SigningEntitlementInfo {
        let known = knownInfo[key]
        let fallbackTitle = humanize(key)
        let description = known?.description
            ?? (profileDescription?.isEmpty == false ? profileDescription! : "sig_ent_generic_desc".localized)
        return SigningEntitlementInfo(
            title: known?.title ?? fallbackTitle,
            description: description,
            category: known?.category ?? .other,
            isCritical: known?.critical ?? false
        )
    }

    private static func humanize(_ key: String) -> String {
        let stripped = key
            .replacingOccurrences(of: "com.apple.developer.", with: "")
            .replacingOccurrences(of: "com.apple.security.", with: "")
            .replacingOccurrences(of: "com.apple.", with: "")
        let parts = stripped.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
        return parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    private static let knownInfo: [String: (title: String, description: String, category: SigningEntitlementCategory, critical: Bool)] = [
        "application-identifier": (
            "sig_ent_app_identifier_title".localized,
            "sig_ent_app_identifier_desc".localized,
            .core, true
        ),
        "com.apple.developer.team-identifier": (
            "sig_ent_team_title".localized,
            "sig_ent_team_desc".localized,
            .core, true
        ),
        "get-task-allow": (
            "sig_ent_get_task_allow_title".localized,
            "sig_ent_get_task_allow_desc".localized,
            .core, true
        ),
        "keychain-access-groups": (
            "sig_ent_keychain_title".localized,
            "sig_ent_keychain_desc".localized,
            .keychain, true
        ),
        "com.apple.security.application-groups": (
            "sig_ent_app_group_title".localized,
            "sig_ent_app_group_desc".localized,
            .appGroup, true
        ),
        "aps-environment": (
            "sig_ent_aps_title".localized,
            "sig_ent_aps_desc".localized,
            .push, false
        ),
        "com.apple.developer.usernotifications.filtering": (
            "sig_ent_notification_filter_title".localized,
            "sig_ent_notification_filter_desc".localized,
            .push, false
        ),
        "com.apple.developer.usernotifications.communication": (
            "sig_ent_communication_notification_title".localized,
            "sig_ent_communication_notification_desc".localized,
            .push, false
        ),
        "com.apple.developer.associated-domains": (
            "sig_ent_associated_domains_title".localized,
            "sig_ent_associated_domains_desc".localized,
            .web, false
        ),
        "com.apple.developer.networking.networkextension": (
            "sig_ent_ne_title".localized,
            "sig_ent_ne_desc".localized,
            .network, false
        ),
        "com.apple.developer.networking.vpn.api": (
            "sig_ent_vpn_title".localized,
            "sig_ent_vpn_desc".localized,
            .network, false
        ),
        "com.apple.developer.devicecheck.appattest-environment": (
            "sig_ent_appattest_title".localized,
            "sig_ent_appattest_desc".localized,
            .network, false
        ),
        "com.apple.developer.icloud-container-identifiers": (
            "sig_ent_icloud_container_title".localized,
            "sig_ent_icloud_container_desc".localized,
            .icloud, false
        ),
        "com.apple.developer.ubiquity-kvstore-identifier": (
            "sig_ent_icloud_kv_title".localized,
            "sig_ent_icloud_kv_desc".localized,
            .icloud, false
        ),
        "com.apple.developer.healthkit": (
            "sig_ent_healthkit_title".localized,
            "sig_ent_healthkit_desc".localized,
            .media, false
        ),
        "com.apple.developer.homekit": (
            "sig_ent_homekit_title".localized,
            "sig_ent_homekit_desc".localized,
            .media, false
        ),
        "com.apple.developer.game-center": (
            "sig_ent_gamecenter_title".localized,
            "sig_ent_gamecenter_desc".localized,
            .media, false
        ),
        "com.apple.developer.in-app-payments": (
            "sig_ent_applepay_title".localized,
            "sig_ent_applepay_desc".localized,
            .media, false
        ),
        "com.apple.developer.pass-type-identifiers": (
            "sig_ent_wallet_title".localized,
            "sig_ent_wallet_desc".localized,
            .media, false
        ),
        "com.apple.developer.siri": (
            "sig_ent_siri_title".localized,
            "sig_ent_siri_desc".localized,
            .siri, false
        )
    ]
}

struct EntitlementSelectionSheet: View {
    let profile: SigningProfile
    @Binding var selectedKeys: Set<String>
    let requiredKeys: Set<String>
    let requiredKeysKnown: Bool
    @Binding var mode: SigningEntitlementsMode

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager
    @State private var search = ""
    @State private var showImporter = false
    @State private var importedMissingCount = 0
    @State private var shareFile: ShareFile?
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false

    private var keys: [String] { profile.entitlementKeys ?? [] }
    private var descriptions: [String: String] { profile.entitlementDescriptions ?? [:] }
    private static var parsedValuesCache: [String: [String: Any]] = [:]

    private var values: [String: Any] {
        guard let data = profile.entitlementsData else { return [:] }
        let cacheKey = "\(profile.id)-\(data.count)"
        if let cached = Self.parsedValuesCache[cacheKey] { return cached }
        let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]) ?? [:]
        Self.parsedValuesCache[cacheKey] = dictionary
        return dictionary
    }

    private var items: [EntitlementRow] {
        keys.map { key in
            let info = SigningEntitlementCatalog.info(for: key, profileDescription: descriptions[key])
            return EntitlementRow(
                key: key,
                info: info,
                value: valueText(for: key)
            )
        }
    }

    private var filteredItems: [EntitlementRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.key.lowercased().contains(query)
                || item.info.title.lowercased().contains(query)
                || item.info.description.lowercased().contains(query)
                || item.value.lowercased().contains(query)
        }
    }

    private var groupedItems: [(category: SigningEntitlementCategory, items: [EntitlementRow])] {
        let grouped = Dictionary(grouping: filteredItems, by: { $0.info.category })
        return grouped
            .map { (category: $0.key, items: $0.value.sorted { $0.info.title.localizedStandardCompare($1.info.title) == .orderedAscending }) }
            .sorted { $0.category.sortOrder < $1.category.sortOrder }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    header
                    Picker("sign_ent_mode".localized, selection: $mode) {
                        ForEach(SigningEntitlementsMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(mode.hint)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if mode != .custom {
                        Text("sign_ent_mode_custom_note".localized)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button {
                            showImporter = true
                        } label: {
                            Label("sign_ent_import".localized, systemImage: "square.and.arrow.down")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(themeManager.accentColor)

                        Button {
                            exportEntitlements()
                        } label: {
                            Label("sign_ent_export".localized, systemImage: "square.and.arrow.up")
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Spacer()
                    }

                    if importedMissingCount > 0 {
                        Text(String(format: "sign_ent_import_missing".localized, importedMissingCount))
                            .font(.system(size: 8.5))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if keys.isEmpty {
                    Text("sign_entitlements_empty".localized)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if filteredItems.isEmpty {
                    Text("sign_entitlements_no_search".localized)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(groupedItems, id: \.category) { group in
                        Section {
                            ForEach(group.items) { item in
                                entitlementRow(item)
                            }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: group.category.icon)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(group.category.title)
                                    .font(.system(size: 11, weight: .bold))
                                Spacer()
                                Text("\(group.items.count)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("sign_entitlements_warning".localized)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("sign_entitlements_app_group_hint".localized)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: "sign_entitlements_search".localized)
            .navigationTitle("sign_entitlements_title".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("done".localized) { dismiss() }
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            selectedKeys = selectedKeys.intersection(Set(keys))
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.propertyList, .xml, .json, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .sheet(item: $shareFile) { file in
            ActivityView(items: [file.url])
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("ok".localized, role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(themeManager.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(themeManager.accentColor.opacity(0.12))
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(profile.applicationIdentifier.isEmpty ? profile.bundleIDPattern : profile.applicationIdentifier)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(String(format: "sign_entitlements_count".localized, selectedKeys.count, keys.count))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 9) {
                Button {
                    selectedKeys = Set(keys)
                } label: {
                    Label("sign_entitlements_select_all".localized, systemImage: "checkmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(themeManager.accentColor)

                Button {
                    selectedKeys.removeAll()
                } label: {
                    Label("sign_entitlements_clear".localized, systemImage: "circle")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    selectedKeys = Set(items.filter { $0.info.isCritical }.map(\.key))
                } label: {
                    Text("sign_entitlements_critical_only".localized)
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("sign_entitlements_source_title".localized)
                        .font(.system(size: 9.5, weight: .semibold))
                    Text("sign_entitlements_source_note".localized)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !requiredKeysKnown {
                        Text("sign_entitlements_unknown_required".localized)
                            .font(.system(size: 8.5))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.cyan.opacity(0.05))
            )

            Text("sign_entitlements_detail_hint".localized)
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    private func entitlementRow(_ item: EntitlementRow) -> some View {
        Toggle(isOn: binding(for: item.key)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(item.info.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    if item.info.isCritical {
                        Text("sign_entitlements_critical".localized)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.orange.opacity(0.12)))
                    }
                    if requiredKeysKnown {
                        if requiredKeys.contains(item.key) {
                            Text("sign_entitlements_app_required".localized)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.12)))
                        } else {
                            Text("sign_entitlements_profile_only".localized)
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.06)))
                        }
                    }
                    Spacer(minLength: 0)
                }

                Text(item.key)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.info.description)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.value.isEmpty {
                    Text(item.value)
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                }
            }
            .padding(.vertical, 3)
        }
        .tint(themeManager.accentColor)
    }

    private func valueText(for key: String) -> String {
        guard let value = values[key] else { return "" }
        if let array = value as? [String] {
            return array.joined(separator: "\n")
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let string = value as? String {
            return string
        }
        if let array = value as? [Any] {
            return array.map { "\($0)" }.joined(separator: "\n")
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().map { "\($0): \(dictionary[$0] ?? "")" }.joined(separator: "\n")
        }
        return "\(value)"
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let dictionary: [String: Any]
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    dictionary = plist
                } else if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    dictionary = json
                } else {
                    throw SigningStoreError.invalidProfile
                }
                let profileKeys = Set(keys)
                let importedKeys = Set(dictionary.keys)
                let applicable = importedKeys.intersection(profileKeys)
                selectedKeys = applicable
                mode = .custom
                importedMissingCount = importedKeys.subtracting(profileKeys).count
                if applicable.isEmpty {
                    alertTitle = "sign_ent_import_failed".localized
                    alertMessage = "sign_ent_import_empty".localized
                    showAlert = true
                }
            } catch {
                alertTitle = "sign_ent_import_failed".localized
                alertMessage = error.localizedDescription
                showAlert = true
            }
        case .failure(let error):
            alertTitle = "sign_ent_import_failed".localized
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func exportEntitlements() {
        let chosen = selectedKeys.isEmpty ? Set(keys) : selectedKeys
        var dictionary: [String: Any] = [:]
        for key in keys where chosen.contains(key) {
            if let value = values[key] {
                dictionary[key] = value
            }
        }
        guard !dictionary.isEmpty else {
            alertTitle = "sign_ent_export_failed".localized
            alertMessage = "sign_ent_export_empty".localized
            showAlert = true
            return
        }
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("entitlements-\(UUID().uuidString).plist")
            try data.write(to: url, options: .atomic)
            shareFile = ShareFile(url: url)
        } catch {
            alertTitle = "sign_ent_export_failed".localized
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }

    private func binding(for key: String) -> Binding<Bool> {
        Binding(
            get: { selectedKeys.contains(key) },
            set: { newValue in
                if newValue {
                    selectedKeys.insert(key)
                } else {
                    selectedKeys.remove(key)
                }
            }
        )
    }
}

private struct EntitlementRow: Identifiable {
    let key: String
    let info: SigningEntitlementInfo
    let value: String
    var id: String { key }
}
