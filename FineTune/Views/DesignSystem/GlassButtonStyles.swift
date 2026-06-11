// FineTune/Views/DesignSystem/GlassButtonStyles.swift
import SwiftUI

/// Unified glass button family for the popup, HUD, and Settings.
///
/// `GlassIconButtonStyle` covers every small icon button in two shapes:
/// - `.roundedRectangle` (default): flat at rest like the rows around it;
///   hover reveals `hoverSurface`, the press compresses slightly, and an
///   active state keeps the fill lit (pin/eye edit controls, EQ-panel
///   save/rename).
/// - `.circle`: always-visible glass circle like Control Center's
///   screenshot/mirroring buttons — Liquid Glass on macOS 26+,
///   `Materials.cardSurface` + hairline on 15.x. The active state inverts
///   to the near-white `iconWellSelectedFill` with an accent glyph
///   (settings gear, reorder pencil, per-row EQ toggle).
///
/// Capsule text buttons (Quit, Retry, Connect) use the `.glassButtonStyle()`
/// modifier in ViewModifiers.swift, which renders interactive Liquid Glass
/// on macOS 26+ and the shipped ultraThinMaterial capsule on 15.x.
struct GlassIconButtonStyle: ButtonStyle {
    /// Outline of the button surface.
    enum ButtonShape {
        /// Soft rounded square, flat at rest (the shipped treatment).
        case roundedRectangle
        /// Control Center-style glass circle, visible at rest.
        case circle
    }

    /// Keeps the button lit (fill + strongest foreground) while the control
    /// it toggles is engaged — e.g. the EQ panel is expanded or edit mode is on.
    var isActive: Bool = false

    /// Surface outline; `.roundedRectangle` keeps the shipped treatment.
    var shape: ButtonShape = .roundedRectangle

    /// Press compression, shared with the pill style for one family feel.
    static let pressedScale: CGFloat = 0.95

    func makeBody(configuration: Configuration) -> some View {
        GlassIconButtonBody(configuration: configuration, isActive: isActive, shape: shape)
    }
}

/// `ButtonStyle.makeBody` cannot own `@State`, so the hover tracking lives
/// in this private body view (standard SwiftUI pattern).
private struct GlassIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isActive: Bool
    let shape: GlassIconButtonStyle.ButtonShape

    @State private var isHovered = false

    var body: some View {
        styledLabel
            .scaleEffect(configuration.isPressed ? GlassIconButtonStyle.pressedScale : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .animation(DesignTokens.Animation.quick, value: configuration.isPressed)
    }

    @ViewBuilder
    private var styledLabel: some View {
        switch shape {
        case .roundedRectangle:
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

        case .circle:
            configuration.label
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(circleForegroundColor)
                .frame(width: DesignTokens.Dimensions.circularButtonSize,
                       height: DesignTokens.Dimensions.circularButtonSize)
                .background { circleSurface }
                .contentShape(Circle())
        }
    }

    /// Glass circle under the glyph. Active inverts to the near-white
    /// engaged fill; otherwise Liquid Glass on macOS 26+ and the
    /// cardSurface material + hairline (with a hover wash) on 15.x.
    @ViewBuilder
    private var circleSurface: some View {
        if isActive {
            Circle()
                .fill(DesignTokens.Colors.iconWellSelectedFill)
        } else if #available(macOS 26.0, *) {
            Color.clear
                .glassEffect(.regular.interactive(), in: Circle())
        } else {
            ZStack {
                Circle()
                    .fill(DesignTokens.Materials.cardSurface)
                if isHovered {
                    Circle()
                        .fill(DesignTokens.Colors.hoverSurface)
                }
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        isHovered ? DesignTokens.Colors.glassBorderHover : DesignTokens.Colors.glassBorder,
                        lineWidth: 0.5
                    )
            }
        }
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

    /// Circle ladder: accent glyph on the inverted active circle, the
    /// shared interactive ladder otherwise.
    private var circleForegroundColor: Color {
        if isActive {
            return DesignTokens.Colors.accentPrimary
        }
        return foregroundColor
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

#Preview("Circular Glass Buttons") {
    HStack(spacing: 16) {
        Button("Settings", systemImage: "gearshape.fill") {}
            .labelStyle(.iconOnly)
            .buttonStyle(GlassIconButtonStyle(shape: .circle))

        Button("Reorder", systemImage: "pencil") {}
            .labelStyle(.iconOnly)
            .buttonStyle(GlassIconButtonStyle(shape: .circle))

        Button("Equalizer", systemImage: "slider.vertical.3") {}
            .labelStyle(.iconOnly)
            .buttonStyle(GlassIconButtonStyle(isActive: true, shape: .circle))
    }
    .font(.system(size: 12))
    .padding()
    .darkGlassBackground()
    .environment(\.colorScheme, .dark)
}
