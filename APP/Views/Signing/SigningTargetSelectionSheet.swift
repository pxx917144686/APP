import SwiftUI

struct SigningTargetSelectionSheet: View {
    let targets: [SigningTarget]
    @Binding var selected: Set<String>
    let profiles: [SigningProfile]
    let mainProfile: SigningProfile?

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var themeManager: ThemeManager

    private struct TargetGroup: Identifiable {
        let kind: SigningTarget.Kind
        let targets: [SigningTarget]
        var id: String { kind.rawValue }
    }

    private var groupedTargets: [TargetGroup] {
        let grouped = Dictionary(grouping: targets, by: \.kind)
        return grouped
            .map { TargetGroup(kind: $0.key, targets: $0.value.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) }
            .sorted { $0.kind.sortOrder < $1.kind.sortOrder }
    }

    var body: some SwiftUI.View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 8) {
                        Image(systemName: "scope")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(themeManager.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("sign_target_title".localized)
                                .font(.system(size: 13, weight: .semibold))
                            Text(String(format: "sign_target_selected_count".localized, selected.count, targets.count))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)

                    HStack(spacing: 10) {
                        Button {
                            selected = Set(targets.map(\.id)).union(["."])
                        } label: {
                            Label("sign_target_select_all".localized, systemImage: "checkmark.circle")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(themeManager.accentColor)

                        Button {
                            selected = ["."]
                        } label: {
                            Label("sign_target_main_only".localized, systemImage: "app")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }

                if targets.isEmpty {
                    Text("sign_target_empty".localized)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(groupedTargets) { group in
                        Section {
                            ForEach(group.targets) { target in
                                targetRow(target)
                            }
                        } header: {
                            HStack(spacing: 5) {
                                Image(systemName: group.kind.icon)
                                    .font(.system(size: 10))
                                Text(group.kind.title)
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Text("sign_target_hint".localized)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("sign_target_profile_note".localized)
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("sign_target_appgroup_note".localized)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("sign_target_title".localized)
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
            if selected.isEmpty {
                selected = ["."]
            }
        }
        .presentationDetents([.large])
    }

    private func targetRow(_ target: SigningTarget) -> some SwiftUI.View {
        let isMain = target.kind == .main
        return Toggle(isOn: binding(for: target, isMain: isMain)) {
            HStack(spacing: 9) {
                Image(systemName: target.kind.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isMain ? themeManager.accentColor : .secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill((isMain ? themeManager.accentColor : Color.secondary).opacity(0.10))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.displayName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(target.bundleIdentifier.isEmpty ? target.bundlePath : target.bundleIdentifier)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let point = target.extensionPoint, !point.isEmpty {
                        Text(point)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    coverageLine(for: target)

                    let groups = appGroups(for: target)
                    if !groups.isEmpty {
                        Text("\( "sign_target_app_groups".localized ): \(groups.joined(separator: ", "))")
                            .font(.system(size: 7.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
        .tint(themeManager.accentColor)
    }

    private enum ProfileCoverage {
        case matched
        case wildcard
        case missing
    }

    private func matchedProfile(for target: SigningTarget) -> SigningProfile? {
        if target.kind == .main {
            return mainProfile
        }
        let team = mainProfile?.teamID ?? ""
        if let exact = profiles.first(where: { $0.bundleIDPattern == target.bundleIdentifier && (team.isEmpty || $0.teamID == team) }) {
            return exact
        }
        return profiles
            .filter { $0.covers(bundleID: target.bundleIdentifier) && (team.isEmpty || $0.teamID == team) }
            .sorted { $0.bundleIDPattern.count > $1.bundleIDPattern.count }
            .first
    }

    private func coverage(for target: SigningTarget) -> ProfileCoverage {
        guard let profile = matchedProfile(for: target) else { return .missing }
        if profile.isWildcard { return .wildcard }
        return .matched
    }

    @ViewBuilder
    private func coverageLine(for target: SigningTarget) -> some SwiftUI.View {
        HStack(spacing: 4) {
            switch coverage(for: target) {
            case .matched:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("sign_target_coverage_matched".localized)
                    .foregroundStyle(.green)
            case .wildcard:
                Image(systemName: "asterisk.circle.fill")
                    .foregroundStyle(.green)
                Text("sign_target_coverage_wildcard".localized)
                    .foregroundStyle(.green)
            case .missing:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("sign_target_coverage_missing".localized)
                    .foregroundStyle(.red)
            }
        }
        .font(.system(size: 7.5, weight: .semibold))
    }

    private func appGroups(for target: SigningTarget) -> [String] {
        guard let profile = matchedProfile(for: target),
              let data = profile.entitlementsData,
              let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return []
        }
        return dictionary["com.apple.security.application-groups"] as? [String] ?? []
    }

    private func binding(for target: SigningTarget, isMain: Bool) -> Binding<Bool> {
        Binding(
            get: { selected.contains(target.id) },
            set: { newValue in
                if newValue {
                    selected.insert(target.id)
                } else {
                    guard selected.count > 1 else { return }
                    selected.remove(target.id)
                }
            }
        )
    }
}
