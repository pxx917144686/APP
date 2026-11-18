import SwiftUI

struct TabOrderSettingsView: View {
    @ObservedObject private var store = TabOrderStore.shared
    @EnvironmentObject private var themeManager: ThemeManager

    var body: some View {
        List {
            Section {
                ForEach(store.order, id: \.self) { tab in
                    HStack(spacing: 12) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(themeManager.accentColor)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(tab.title)
                                .font(.system(size: 16))

                            if tab == .search {
                                Text("tab_order_search_hint".localized)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .onMove { source, destination in
                    store.move(from: source, to: destination)
                }
            } footer: {
                Text("tab_order_hint".localized)
            }

            Section {
                Button {
                    store.reset()
                } label: {
                    Text("tab_order_reset".localized)
                        .foregroundStyle(themeManager.accentColor)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .navigationTitle("tab_order_title".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}
