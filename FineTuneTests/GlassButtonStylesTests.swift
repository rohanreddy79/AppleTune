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

    @Test("Icon buttons keep the shipped rounded-rectangle shape by default")
    func defaultShapeIsRoundedRectangle() {
        let style = GlassIconButtonStyle()
        #expect(style.shape == .roundedRectangle)
    }

    @Test("Active state passes through", arguments: [true, false])
    func activePassthrough(isActive: Bool) {
        let style = GlassIconButtonStyle(isActive: isActive)
        #expect(style.isActive == isActive)
    }

    @Test("Shape passes through", arguments: [
        GlassIconButtonStyle.ButtonShape.roundedRectangle,
        GlassIconButtonStyle.ButtonShape.circle,
    ])
    func shapePassthrough(shape: GlassIconButtonStyle.ButtonShape) {
        let style = GlassIconButtonStyle(shape: shape)
        #expect(style.shape == shape)
    }

    @Test("Circle variant can carry the active state (EQ toggle, reorder pencil)")
    func activeCircle() {
        let style = GlassIconButtonStyle(isActive: true, shape: .circle)
        #expect(style.isActive == true)
        #expect(style.shape == .circle)
    }

    @Test("Press compression is subtle (between 0.9 and 1.0)")
    func pressedScaleIsSubtle() {
        #expect(GlassIconButtonStyle.pressedScale > 0.9)
        #expect(GlassIconButtonStyle.pressedScale < 1.0)
    }
}
