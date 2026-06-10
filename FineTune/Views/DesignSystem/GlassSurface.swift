// FineTune/Views/DesignSystem/GlassSurface.swift
import SwiftUI

extension DesignTokens {
    /// Centralized material choices. Call sites reference these instead of
    /// hard-coding SwiftUI materials so surface treatments can evolve in one
    /// place (and gain Liquid Glass on macOS 26 via AdaptiveGlassSurface).
    enum Materials {
        /// Floating HUD panels (the volume overlay, both styles).
        static let hudSurface: Material = .regularMaterial
    }
}

/// Renders a rounded glass surface behind content.
///
/// On macOS 26+ this is Apple's Liquid Glass (`glassEffect`), picking up the
/// system's dynamic refraction and adaptive contrast. On earlier systems it
/// falls back to the exact material + hairline border treatment the app
/// shipped before this modifier existed — adopting it is visually a no-op
/// for the macOS 15.4 deployment target.
struct AdaptiveGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    var fallbackMaterial: Material = DesignTokens.Materials.hudSurface
    var fallbackBorder: Color = DesignTokens.Colors.hudBorder

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(fallbackMaterial)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(fallbackBorder, lineWidth: 1)
                }
        }
    }
}

extension View {
    /// Rounded glass surface: Liquid Glass on macOS 26+, the app's classic
    /// material + hairline border on earlier systems.
    func adaptiveGlassSurface(
        cornerRadius: CGFloat,
        fallbackMaterial: Material = DesignTokens.Materials.hudSurface,
        fallbackBorder: Color = DesignTokens.Colors.hudBorder
    ) -> some View {
        modifier(AdaptiveGlassSurface(
            cornerRadius: cornerRadius,
            fallbackMaterial: fallbackMaterial,
            fallbackBorder: fallbackBorder
        ))
    }
}
