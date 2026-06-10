// FineTuneTests/GlassButtonStylesTests.swift
// Value-based tests for the unified glass button family.

import SwiftUI
import Testing
@testable import FineTune

@Suite("GlassIconButtonStyle — Defaults & Parameters")
struct GlassButtonStylesTests {

    @Test("Icon buttons are inactive by default")
    func defaultIsInactive() {
        let style = GlassIconButtonStyle()
        #expect(style.isActive == false)
    }

    @Test("Active state passes through", arguments: [true, false])
    func activePassthrough(isActive: Bool) {
        let style = GlassIconButtonStyle(isActive: isActive)
        #expect(style.isActive == isActive)
    }

    @Test("Press compression is subtle (between 0.9 and 1.0)")
    func pressedScaleIsSubtle() {
        #expect(GlassIconButtonStyle.pressedScale > 0.9)
        #expect(GlassIconButtonStyle.pressedScale < 1.0)
    }
}
