// FineTune/Views/Components/ControlCenterSlider.swift
import SwiftUI

/// A Control Center-style capsule slider: a full-height translucent track
/// with a white fill growing from the leading edge and an optional SF Symbol
/// embedded in the leading circle — the signature control of the macOS
/// Control Center volume and brightness modules.
///
/// Geometry contract (mirrors Control Center):
/// - The fill never shrinks below the capsule's diameter, so at 0 it reads
///   as a perfect circle housing the icon rather than vanishing.
/// - A click or drag anywhere on the capsule maps the pointer's x position
///   linearly across the full track width (absolute positioning, not
///   thumb-relative), so the control is one big touch target.
///
/// All colors and dimensions route through `DesignTokens` (`ccSlider*`).
struct ControlCenterSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// SF Symbol shown inside the leading circle (e.g. "speaker.wave.2.fill").
    let icon: String?
    /// Override for the icon color; defaults to `ccSliderIcon` (dark glyph
    /// on the white fill). Used by the HUD to flip the glyph red when muted.
    let iconColor: Color?
    let onEditingChanged: ((Bool) -> Void)?

    @State private var isDragging = false

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        icon: String? = nil,
        iconColor: Color? = nil,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.icon = icon
        self.iconColor = iconColor
        self.onEditingChanged = onEditingChanged
    }

    // MARK: - Geometry (testable)

    /// Width of the leading fill for a normalized value. Clamps the value
    /// to 0...1 and never returns less than the capsule diameter
    /// (`trackHeight`), so the fill bottoms out as the leading circle.
    static func fillWidth(
        normalizedValue: Double,
        trackWidth: CGFloat,
        trackHeight: CGFloat
    ) -> CGFloat {
        let clamped = min(max(normalizedValue, 0), 1)
        return min(trackWidth, max(trackHeight, trackWidth * clamped))
    }

    /// Normalized value for a pointer x position: linear across the full
    /// track width, clamped to 0...1. A degenerate (zero-width) track maps
    /// every position to 0.
    static func normalizedValue(
        forLocationX x: CGFloat,
        trackWidth: CGFloat
    ) -> Double {
        guard trackWidth > 0 else { return 0 }
        return min(max(Double(x / trackWidth), 0), 1)
    }

    // MARK: - Derived state

    private var normalizedValue: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Recessed translucent well
                Capsule()
                    .fill(DesignTokens.Colors.ccSliderTrack)

                // Leading fill. Same corner radius as the track (both are
                // capsules of the same height), so the rounded ends align
                // and the minimum width renders as a circle.
                Capsule()
                    .fill(DesignTokens.Colors.ccSliderFill)
                    .frame(width: Self.fillWidth(
                        normalizedValue: normalizedValue,
                        trackWidth: geo.size.width,
                        trackHeight: geo.size.height
                    ))

                // Embedded glyph, centered in the leading circle
                if let icon {
                    Image(systemName: icon)
                        .font(.system(
                            size: DesignTokens.Dimensions.ccSliderIconSize,
                            weight: .medium
                        ))
                        .foregroundStyle(iconColor ?? DesignTokens.Colors.ccSliderIcon)
                        .frame(width: geo.size.height, height: geo.size.height)
                }
            }
            .overlay(
                Capsule()
                    .strokeBorder(DesignTokens.Colors.ccSliderBorder, lineWidth: 1)
            )
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            onEditingChanged?(true)
                        }
                        let normalized = Self.normalizedValue(
                            forLocationX: gesture.location.x,
                            trackWidth: geo.size.width
                        )
                        value = range.lowerBound
                            + normalized * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEditingChanged?(false)
                    }
            )
        }
        .frame(height: DesignTokens.Dimensions.ccSliderHeight)
    }
}

// MARK: - Preview

#Preview("Control Center Slider") {
    struct PreviewWrapper: View {
        @State private var volume: Double = 0.6
        @State private var low: Double = 0.0
        @State private var full: Double = 1.0

        var body: some View {
            VStack(spacing: 20) {
                ControlCenterSlider(value: $volume, icon: "speaker.wave.2.fill")
                ControlCenterSlider(value: $low, icon: "speaker.fill")
                ControlCenterSlider(value: $full, icon: "speaker.wave.3.fill")
                ControlCenterSlider(value: $volume)

                Text("\(Int(volume * 100))%")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .frame(width: 320)
            .background(Color.black)
        }
    }
    return PreviewWrapper()
}
