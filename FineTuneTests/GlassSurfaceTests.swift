// FineTuneTests/GlassSurfaceTests.swift
// Value-based tests for AdaptiveGlassSurface — the availability adapter
// that renders Liquid Glass on macOS 26+ and the app's legacy
// material + hairline border treatment on earlier systems.

import SwiftUI
import Testing
@testable import FineTune

@Suite("AdaptiveGlassSurface — Defaults & Parameters")
struct GlassSurfaceTests {

    @Test("Defaults match the pre-adapter HUD treatment")
    func defaultsMatchLegacyHUD() {
        let surface = AdaptiveGlassSurface(cornerRadius: 22)
        #expect(surface.cornerRadius == 22)
        #expect(surface.fallbackBorder == DesignTokens.Colors.hudBorder,
                "Fallback border must stay the shipped hudBorder token")
    }

    @Test("Corner radius passes through unchanged", arguments: [CGFloat(22), 16, 12])
    func cornerRadiusPassthrough(radius: CGFloat) {
        let surface = AdaptiveGlassSurface(cornerRadius: radius)
        #expect(surface.cornerRadius == radius)
    }

    @Test("Custom fallback border passes through unchanged")
    func fallbackBorderPassthrough() {
        let surface = AdaptiveGlassSurface(
            cornerRadius: 12,
            fallbackBorder: DesignTokens.Colors.eqCardBorder
        )
        #expect(surface.fallbackBorder == DesignTokens.Colors.eqCardBorder)
    }

    @Test("Per-app HUD tile and Tahoe HUD share the same surface defaults")
    func hudTileMatchesTahoe() {
        // Both HUD panels now route through AdaptiveGlassSurface with the
        // default hudSurface material + hudBorder fallback; pin the default
        // so a change to one cannot silently diverge from the other.
        let surface = AdaptiveGlassSurface(cornerRadius: 22)
        #expect(surface.fallbackBorder == DesignTokens.Colors.hudBorder)
    }
}
