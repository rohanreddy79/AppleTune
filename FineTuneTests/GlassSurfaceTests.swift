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
}
