// FineTune/Views/Settings/Components/SettingsSection.swift
import SwiftUI

@MainActor
struct SettingsSection<Content: View>: View {
    private let title: String?
    @ViewBuilder private let content: () -> Content

    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(DesignTokens.Typography.cardHeader)
                    .foregroundStyle(DesignTokens.Colors.textPrimary)
                    .padding(.horizontal, DesignTokens.Spacing.xs)
            }
            VStack(spacing: 0) {
                content()
            }
            // Lifted-card fill matches the popup's EQ card so every grouped
            // surface in the app shares one treatment.
            .background(DesignTokens.Colors.eqCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.cardRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .shadow(
                color: DesignTokens.Colors.cardShadow,
                radius: 1.5,
                x: 0,
                y: 0.5
            )
        }
    }
}
