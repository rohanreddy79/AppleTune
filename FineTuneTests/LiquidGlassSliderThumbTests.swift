// FineTuneTests/LiquidGlassSliderThumbTests.swift
// Tests for the Liquid Glass thumb geometry used on macOS 26+.
// thumbCenterX must keep the thumb fully inside the track at the extremes
// and clamp out-of-range values, mirroring AppKit slider geometry.

import SwiftUI
import Testing
@testable import FineTune

@Suite("LiquidGlassSlider — Thumb geometry")
struct LiquidGlassSliderThumbTests {

    private let trackWidth: CGFloat = 100
    private let thumbWidth: CGFloat = 16

    @Test("Thumb hugs the leading edge at 0")
    func leadingEdge() {
        let x = LiquidGlassSlider.thumbCenterX(
            normalizedValue: 0, trackWidth: trackWidth, thumbWidth: thumbWidth)
        #expect(x == thumbWidth / 2)
    }

    @Test("Thumb hugs the trailing edge at 1")
    func trailingEdge() {
        let x = LiquidGlassSlider.thumbCenterX(
            normalizedValue: 1, trackWidth: trackWidth, thumbWidth: thumbWidth)
        #expect(x == trackWidth - thumbWidth / 2)
    }

    @Test("Thumb is centered at 0.5")
    func midpoint() {
        let x = LiquidGlassSlider.thumbCenterX(
            normalizedValue: 0.5, trackWidth: trackWidth, thumbWidth: thumbWidth)
        #expect(x == trackWidth / 2)
    }

    @Test("Out-of-range values clamp to the track bounds",
          arguments: [(-0.5, 8.0), (1.5, 92.0), (2.0, 92.0), (-10.0, 8.0)])
    func clamping(input: Double, expected: Double) {
        let x = LiquidGlassSlider.thumbCenterX(
            normalizedValue: input, trackWidth: 100, thumbWidth: 16)
        #expect(x == CGFloat(expected))
    }

    @Test("Degenerate track (track == thumb width) pins the thumb center")
    func degenerateTrack() {
        let x = LiquidGlassSlider.thumbCenterX(
            normalizedValue: 0.7, trackWidth: 16, thumbWidth: 16)
        #expect(x == 8)
    }

    @Test("Thumb stays inside the track across the whole range")
    func alwaysInsideTrack() {
        for step in 0...20 {
            let value = Double(step) / 20.0
            let x = LiquidGlassSlider.thumbCenterX(
                normalizedValue: value, trackWidth: trackWidth, thumbWidth: thumbWidth)
            #expect(x >= thumbWidth / 2)
            #expect(x <= trackWidth - thumbWidth / 2)
        }
    }
}
