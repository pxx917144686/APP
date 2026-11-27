import SwiftUI
import UIKit

struct AppearanceView: View {
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Button(action: {
                            let impactMed = UIImpactFeedbackGenerator(style: .light)
                            impactMed.impactOccurred()
                            SoundEffects.play(.tick)
                            themeManager.selectedTheme = theme
                        }) {
                            Text(theme.displayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(themeManager.selectedTheme == theme ? .white : .primary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(themeManager.selectedTheme == theme ? themeManager.accentColor : Color(.systemGray5))
                                )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            } header: {
                Text("appearance".localized)
            }
        }
        .navigationTitle("appearance".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}
