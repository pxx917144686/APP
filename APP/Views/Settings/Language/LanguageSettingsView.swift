import SwiftUI

struct LanguageSettingsView: View {
    @StateObject private var languageManager = LanguageManager.shared
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.dismiss) private var dismiss
    @State private var showRestartAlert = false
    @State private var selectedLanguage: AppLanguage = .system

    var body: some View {
        List {
            Section {
                ForEach(AppLanguage.allCases) { lang in
                    languageRow(language: lang)
                }
            } header: {
                Text("language_select".localized)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("language".localized)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selectedLanguage = languageManager.currentLanguage
        }
        .alert("language_switch".localized, isPresented: $showRestartAlert) {
            Button("cancel".localized, role: .cancel) {
                selectedLanguage = languageManager.currentLanguage
            }
            Button("confirm_switch".localized) {
                SoundEffects.play(.success)
                languageManager.setLanguage(selectedLanguage)
                dismiss()
            }
        } message: {
            Text("language_switch_message".localized)
        }
    }

    private func languageRow(language: AppLanguage) -> some View {
        Button(action: {
            if language != languageManager.currentLanguage {
                SoundEffects.play(.tick)
                selectedLanguage = language
                showRestartAlert = true
            }
        }) {
            HStack(spacing: 12) {
                Text(language.flag)
                    .font(.system(size: 20))
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(language.nativeName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)

                    if language != .system {
                        Text(language.displayName)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if selectedLanguage == language {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(themeManager.accentColor)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}

#Preview {
    NavigationView {
        LanguageSettingsView()
            .environmentObject(ThemeManager.shared)
    }
}
