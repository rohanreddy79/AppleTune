// FineTuneTests/DesignTokensTests.swift
// Tests that DesignTokens values are valid and consistent.
// No rendering — just value validation.

import Testing
import SwiftUI
import AppKit
@testable import FineTune

// MARK: - Spacing

@Suite("DesignTokens — Spacing scale")
struct DesignTokensSpacingTests {

    @Test("All spacing values are positive")
    func allPositive() {
        #expect(DesignTokens.Spacing.xxs > 0)
        #expect(DesignTokens.Spacing.xs > 0)
        #expect(DesignTokens.Spacing.sm > 0)
        #expect(DesignTokens.Spacing.md > 0)
        #expect(DesignTokens.Spacing.lg > 0)
        #expect(DesignTokens.Spacing.xl > 0)
        #expect(DesignTokens.Spacing.xxl > 0)
    }

    @Test("Spacing scale is strictly increasing")
    func strictlyIncreasing() {
        let scale: [CGFloat] = [
            DesignTokens.Spacing.xxs,
            DesignTokens.Spacing.xs,
            DesignTokens.Spacing.sm,
            DesignTokens.Spacing.md,
            DesignTokens.Spacing.lg,
            DesignTokens.Spacing.xl,
            DesignTokens.Spacing.xxl,
        ]
        for i in 1..<scale.count {
            #expect(scale[i] > scale[i - 1],
                    "Spacing[\(i)] (\(scale[i])) should be > spacing[\(i-1)] (\(scale[i-1]))")
        }
    }

    @Test("Spacing values are reasonable (2-24pt range)")
    func reasonableRange() {
        #expect(DesignTokens.Spacing.xxs == 2)
        #expect(DesignTokens.Spacing.xs == 4)
        #expect(DesignTokens.Spacing.sm == 8)
        #expect(DesignTokens.Spacing.md == 12)
        #expect(DesignTokens.Spacing.lg == 16)
        #expect(DesignTokens.Spacing.xl == 20)
        #expect(DesignTokens.Spacing.xxl == 24)
    }

    @Test("Island spacing is the md step (Control Center gap)")
    func islandSpacing() {
        #expect(DesignTokens.Spacing.islandSpacing == DesignTokens.Spacing.md)
    }
}

// MARK: - Dimensions

@Suite("DesignTokens — Dimensions")
struct DesignTokensDimensionTests {

    @Test("Popup width is positive and reasonable")
    func popupWidth() {
        #expect(DesignTokens.Dimensions.popupWidth > 300)
        #expect(DesignTokens.Dimensions.popupWidth < 1000)
    }

    @Test("contentWidth is popupWidth minus double padding")
    func contentWidthFormula() {
        let expected = DesignTokens.Dimensions.popupWidth - (DesignTokens.Dimensions.contentPadding * 2)
        #expect(DesignTokens.Dimensions.contentWidth == expected)
    }

    @Test("Corner radii are positive")
    func cornerRadiiPositive() {
        #expect(DesignTokens.Dimensions.cornerRadius > 0)
        #expect(DesignTokens.Dimensions.rowRadius > 0)
        #expect(DesignTokens.Dimensions.buttonRadius > 0)
        #expect(DesignTokens.Dimensions.cardRadius > 0)
        #expect(DesignTokens.Dimensions.controlRadius > 0)
        #expect(DesignTokens.Dimensions.pickerItemRadius > 0)
        #expect(DesignTokens.Dimensions.fieldRadius > 0)
        #expect(DesignTokens.Dimensions.capsuleRadius > 0)
    }

    @Test("Capsule radius is half the resting island row height")
    func capsuleRadiusFormula() {
        let expected = (DesignTokens.Dimensions.rowContentHeight
            + DesignTokens.Spacing.sm * 2) / 2
        #expect(DesignTokens.Dimensions.capsuleRadius == expected)
        #expect(DesignTokens.Dimensions.capsuleRadius == 22)
    }

    @Test("Surface radii values match the shipped design")
    func surfaceRadiiValues() {
        #expect(DesignTokens.Dimensions.cardRadius == 10)
        #expect(DesignTokens.Dimensions.controlRadius == 8)
        #expect(DesignTokens.Dimensions.pickerItemRadius == 5)
        #expect(DesignTokens.Dimensions.fieldRadius == 4)
    }

    @Test("Radius hierarchy: field < pickerItem < button < control < card ≤ popup < capsule")
    func radiusHierarchy() {
        #expect(DesignTokens.Dimensions.fieldRadius < DesignTokens.Dimensions.pickerItemRadius)
        #expect(DesignTokens.Dimensions.pickerItemRadius < DesignTokens.Dimensions.buttonRadius)
        #expect(DesignTokens.Dimensions.buttonRadius < DesignTokens.Dimensions.controlRadius)
        #expect(DesignTokens.Dimensions.controlRadius < DesignTokens.Dimensions.cardRadius)
        #expect(DesignTokens.Dimensions.cardRadius <= DesignTokens.Dimensions.cornerRadius)
        #expect(DesignTokens.Dimensions.cornerRadius < DesignTokens.Dimensions.capsuleRadius)
    }

    @Test("Icon well houses the standard icon with breathing room")
    func iconWellSize() {
        #expect(DesignTokens.Dimensions.iconWellSize == 36)
        #expect(DesignTokens.Dimensions.iconWellSize > DesignTokens.Dimensions.iconSize)
        // The well must fit inside a resting capsule island
        // (rowContentHeight + 2 × Spacing.sm = 2 × capsuleRadius).
        #expect(DesignTokens.Dimensions.iconWellSize <= DesignTokens.Dimensions.capsuleRadius * 2)
    }

    @Test("Circular utility button sits between touch target and icon well")
    func circularButtonSize() {
        #expect(DesignTokens.Dimensions.circularButtonSize == 28)
        #expect(DesignTokens.Dimensions.circularButtonSize >= DesignTokens.Dimensions.minTouchTarget)
        #expect(DesignTokens.Dimensions.circularButtonSize <= DesignTokens.Dimensions.iconWellSize)
    }

    @Test("Slider dimensions are positive")
    func sliderDimensionsPositive() {
        #expect(DesignTokens.Dimensions.sliderTrackHeight > 0)
        #expect(DesignTokens.Dimensions.sliderThumbWidth > 0)
        #expect(DesignTokens.Dimensions.sliderThumbHeight > 0)
        #expect(DesignTokens.Dimensions.sliderThumbSize > 0)
    }

    @Test("Icon sizes are positive")
    func iconSizes() {
        #expect(DesignTokens.Dimensions.iconSize > 0)
        #expect(DesignTokens.Dimensions.iconSizeSmall > 0)
        #expect(DesignTokens.Dimensions.iconSizeSmall < DesignTokens.Dimensions.iconSize)
    }

    @Test("VU meter has 8 bars")
    func vuMeterBarCount() {
        #expect(DesignTokens.Dimensions.vuMeterBarCount == 8)
    }

    @Test("Min touch target is at least 16pt (Apple HIG minimum)")
    func minTouchTarget() {
        #expect(DesignTokens.Dimensions.minTouchTarget >= 16)
    }
}

// MARK: - Shadows

@Suite("DesignTokens — Shadow tokens")
struct DesignTokensShadowTests {

    @Test("cardShadow is the shipped soft lift shadow")
    func cardShadow() {
        #expect(DesignTokens.Colors.cardShadow == Color.black.opacity(0.06))
    }

    @Test("thumbShadow is the shipped knob drop shadow")
    func thumbShadow() {
        #expect(DesignTokens.Colors.thumbShadow == Color.black.opacity(0.4))
    }

    @Test("Shadows stay subtle (card) and readable (thumb)")
    func shadowOrdering() {
        // Both are static black-alpha colors; the thumb shadow must be the
        // stronger of the two so the knob separates from any track color.
        let card = NSColor(DesignTokens.Colors.cardShadow).alphaComponent
        let thumb = NSColor(DesignTokens.Colors.thumbShadow).alphaComponent
        #expect(card < thumb)
    }
}

// MARK: - Timing

@Suite("DesignTokens — Timing constants")
struct DesignTokensTimingTests {

    @Test("VU meter update interval is ~30fps")
    func vuMeterInterval() {
        let interval = DesignTokens.Timing.vuMeterUpdateInterval
        #expect(abs(interval - 1.0 / 30.0) < 0.001)
    }

    @Test("VU meter peak hold is positive")
    func vuMeterPeakHold() {
        #expect(DesignTokens.Timing.vuMeterPeakHold > 0)
    }
}
