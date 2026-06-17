// FineTuneTests/ControlCenterSliderTests.swift
// Tests for the Control Center-style slider geometry.
//
// Two invariants define the Control Center look:
//  1. The leading fill never shrinks below the capsule diameter, so at 0 the
//     fill reads as a perfect circle housing the embedded icon.
//  2. Pointer position maps linearly across the full track width (absolute
//     positioning), clamped at both ends.

import SwiftUI
import Testing
@testable import FineTune

@Suite("ControlCenterSlider — Fill geometry")
struct ControlCenterSliderFillTests {

    private let trackWidth: CGFloat = 200
    private let trackHeight: CGFloat = 22

    @Test("Fill bottoms out at the capsule diameter at 0")
    func minimumFillIsLeadingCircle() {
        let width = ControlCenterSlider.fillWidth(
            normalizedValue: 0, trackWidth: trackWidth, trackHeight: trackHeight)
        #expect(width == trackHeight)
    }

    @Test("Fill spans the whole track at 1")
    func fullFill() {
        let width = ControlCenterSlider.fillWidth(
            normalizedValue: 1, trackWidth: trackWidth, trackHeight: trackHeight)
        #expect(width == trackWidth)
    }

    @Test("Fill is proportional once past the minimum")
    func proportionalFill() {
        let width = ControlCenterSlider.fillWidth(
            normalizedValue: 0.5, trackWidth: trackWidth, trackHeight: trackHeight)
        #expect(width == trackWidth / 2)
    }

    @Test("Small values stay pinned to the minimum circle",
          arguments: [0.0, 0.01, 0.05, 0.1])
    func smallValuesPinToMinimum(value: Double) {
        // 0.1 × 200 = 20 < 22, so everything below 11% pins to the diameter.
        let width = ControlCenterSlider.fillWidth(
            normalizedValue: value, trackWidth: trackWidth, trackHeight: trackHeight)
        #expect(width == trackHeight)
    }

    @Test("Out-of-range values clamp to the track bounds",
          arguments: [(-0.5, 22.0), (1.5, 200.0), (2.0, 200.0), (-10.0, 22.0)])
    func clamping(input: Double, expected: Double) {
        let width = ControlCenterSlider.fillWidth(
            normalizedValue: input, trackWidth: 200, trackHeight: 22)
        #expect(width == CGFloat(expected))
    }

    @Test("Degenerate track (track narrower than height) never overflows")
    func degenerateTrack() {
        let width = ControlCenterSlider.fillWidth(
            normalizedValue: 0.7, trackWidth: 10, trackHeight: 22)
        #expect(width == 10)
    }

    @Test("Fill stays inside [diameter, trackWidth] across the whole range")
    func alwaysInsideTrack() {
        for step in 0...20 {
            let value = Double(step) / 20.0
            let width = ControlCenterSlider.fillWidth(
                normalizedValue: value, trackWidth: trackWidth, trackHeight: trackHeight)
            #expect(width >= trackHeight)
            #expect(width <= trackWidth)
        }
    }
}

@Suite("ControlCenterSlider — Pointer mapping")
struct ControlCenterSliderPointerTests {

    private let trackWidth: CGFloat = 200

    @Test("Leading edge maps to 0")
    func leadingEdge() {
        let value = ControlCenterSlider.normalizedValue(
            forLocationX: 0, trackWidth: trackWidth)
        #expect(value == 0)
    }

    @Test("Trailing edge maps to 1")
    func trailingEdge() {
        let value = ControlCenterSlider.normalizedValue(
            forLocationX: trackWidth, trackWidth: trackWidth)
        #expect(value == 1)
    }

    @Test("Midpoint maps to 0.5")
    func midpoint() {
        let value = ControlCenterSlider.normalizedValue(
            forLocationX: trackWidth / 2, trackWidth: trackWidth)
        #expect(value == 0.5)
    }

    @Test("Drags past either end clamp",
          arguments: [(-50.0, 0.0), (-1.0, 0.0), (250.0, 1.0), (1000.0, 1.0)])
    func clamping(x: Double, expected: Double) {
        let value = ControlCenterSlider.normalizedValue(
            forLocationX: CGFloat(x), trackWidth: 200)
        #expect(value == expected)
    }

    @Test("Zero-width track maps every position to 0")
    func zeroWidthTrack() {
        let value = ControlCenterSlider.normalizedValue(
            forLocationX: 50, trackWidth: 0)
        #expect(value == 0)
    }

    @Test("Mapping is linear across the whole track")
    func linearity() {
        for step in 0...10 {
            let x = trackWidth * CGFloat(step) / 10
            let value = ControlCenterSlider.normalizedValue(
                forLocationX: x, trackWidth: trackWidth)
            #expect(abs(value - Double(step) / 10) < 1e-9)
        }
    }
}

@Suite("ControlCenterSlider — Token pins")
struct ControlCenterSliderTokenTests {

    @Test("Capsule height matches the Control Center module scale")
    func capsuleHeight() {
        #expect(DesignTokens.Dimensions.ccSliderHeight == 22)
    }

    @Test("Capsule is taller than the legacy minimal slider thumb")
    func tallerThanLegacySlider() {
        #expect(DesignTokens.Dimensions.ccSliderHeight
                > DesignTokens.Dimensions.sliderThumbHeight)
    }

    @Test("Embedded icon fits inside the leading circle")
    func iconFitsCircle() {
        #expect(DesignTokens.Dimensions.ccSliderIconSize
                < DesignTokens.Dimensions.ccSliderHeight)
    }
}
