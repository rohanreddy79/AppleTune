// FineTune/Views/DesignSystem/GlassButtonStyles.swift
import SwiftUI

/// Unified glass button family for the popup, HUD, and Settings.
///
/// `GlassIconButtonStyle` covers every square icon button (settings gear,
/// reorder pencil, EQ toggle, pin/eye edit controls, EQ-panel save/rename).
/// Flat at rest like the rows around it; hover reveals `hoverSurface`, the
/// press compresses slightly, and an active state keeps the fill lit.
///
/// Capsule text buttons (Quit, Retry, Connect) use the `.glassButtonStyle()`
/// modifier in ViewModifiers.swift, which renders interactive Liquid Glass
/// on macOS 26+ and the shipped ultraThinMaterial capsule on 15.x.
struct GlassIconButtonStyle: ButtonStyle {
    /// Keeps the button lit (fill + strongest foreground) while the control
    /// it toggles is engaged — e.g. the EQ panel is expanded or edit mode is on.
    var isActive: Bool = false

    /// Press compression, shared with the pill style for one family feel.
    static let pressedScale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        GlassIconButtonBody(configuration: configuration, isActive: isActive)
    }
}

/// `ButtonStyle.makeBody` cannot own `@State`, so the hover tracking lives
/// in this private body view (standard SwiftUI pattern).
private struct GlassIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool

    @State private var isHovered = false

    var body: some View {
        configuration.label
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(foregroundColor)
            .frame(minWidth: DesignTokens.Dimensions.minTouchTarget,
                   minHeight: DesignTokens.Dimensions.minTouchTarget)
            .padding(DesignTokens.Spacing.xxs)
            .background {
                RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius)
                    .fill(isHovered || isActive ? DesignTokens.Colors.hoverSurface : Color.clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius))
            .scaleEffect(configuration.isPressed ? GlassIconButtonStyle.pressedScale : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .animation(DesignTokens.Animation.quick, value: configuration.isPressed)
    }

    /// Default foreground ladder. Labels that set an explicit
    /// `foregroundStyle` (semantic colors like the pinned-accent pin) win
    /// over this, keeping their meaning while still gaining the hover fill.
    private var foregroundColor: Color {
        if isActive || configuration.isPressed {
            return DesignTokens.Colors.interactiveActive
        } else if isHovered {
            return DesignTokens.Colors.interactiveHover
        } else {
            return DesignTokens.Colors.interactiveDefault
        }
    }
}

// MARK: - Previews

#Preview("Glass Icon Buttons") {
    HStack(spacing: 16) {
        Button("Settings", systemImage: "gearshape.fill") {}
            .labelStyle(.iconOnly)
            .buttonStyle(GlassIconButtonStyle())

        Button("Reorder", systemImage: "pencil") {}
            .labelStyle(.iconOnly)
            .buttonStyle(GlassIconButtonStyle())

        Button("Equalizer", systemImage: "slider.vertical.3") {}
            .labelStyle(.iconOnly)
            .buttonStyle(GlassIconButtonStyle(isActive: true))
    }
    .font(.system(size: 12))
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
