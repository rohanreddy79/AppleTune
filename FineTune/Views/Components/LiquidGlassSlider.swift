// FineTune/Views/Components/LiquidGlassSlider.swift
import SwiftUI

/// A slider using native SwiftUI Slider for Liquid Glass effect on macOS 26+
/// Styled to match the minimal track appearance of device sliders
struct LiquidGlassSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let showUnityMarker: Bool
    let onEditingChanged: ((Bool) -> Void)?

    @State private var isEditing = false
    @State private var isHovered = false

    /// Show thumb only when hovering or dragging
    private var showThumb: Bool {
        isHovered || isEditing
    }

    init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        showUnityMarker: Bool = false,
        onEditingChanged: ((Bool) -> Void)? = nil
    ) {
        self._value = value
        self.range = range
        self.showUnityMarker = showUnityMarker
        self.onEditingChanged = onEditingChanged
    }

    private let trackHeight: CGFloat = 4

    private var normalizedValue: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    /// Native-slider visibility. On macOS 26+ the native thumb is always
    /// suppressed (a real Liquid Glass thumb is drawn separately); on
    /// earlier systems the native thumb shows on hover/drag as shipped.
    private var nativeSliderOpacity: Double {
        if #available(macOS 26.0, *) {
            return 0.01  // Interactive but never visible
        }
        return showThumb ? 1 : 0.01
    }

    /// Horizontal center of the thumb for a normalized value, keeping the
    /// thumb fully inside the track bounds (mirrors AppKit slider geometry).
    static func thumbCenterX(
        normalizedValue: Double,
        trackWidth: CGFloat,
        thumbWidth: CGFloat
    ) -> CGFloat {
        let clamped = min(max(normalizedValue, 0), 1)
        return thumbWidth / 2 + (trackWidth - thumbWidth) * clamped
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Custom track overlay (always visible, hides native track)
                ZStack(alignment: .leading) {
                    // Track background
                    Capsule()
                        .fill(DesignTokens.Colors.sliderTrack)
                        .frame(height: trackHeight)

                    // Filled track
                    Capsule()
                        .fill(DesignTokens.Colors.accentPrimary)
                        .frame(width: max(trackHeight, geo.size.width * normalizedValue), height: trackHeight)
                }
                .frame(maxHeight: .infinity)
                .allowsHitTesting(false)

                // Unity marker at 50% (horizontally centered, vertically centered via frame)
                if showUnityMarker {
                    HStack {
                        Spacer()
                        Rectangle()
                            .fill(DesignTokens.Colors.unityMarker)
                            .frame(width: 1.5, height: 8)
                        Spacer()
                    }
                    .frame(maxHeight: .infinity)
                    .allowsHitTesting(false)
                }

                // Native SwiftUI Slider drives the interaction; visuals are
                // suppressed on macOS 26+ in favor of the glass thumb below.
                Slider(value: $value, in: range) { editing in
                    isEditing = editing
                    onEditingChanged?(editing)
                }
                .controlSize(.mini)
                .tint(.clear)  // Hide native track, we draw our own
                .opacity(nativeSliderOpacity)

                // Real Liquid Glass thumb (macOS 26+): interactive glass
                // capsule that tracks the value, shown on hover/drag like
                // the legacy thumb.
                if #available(macOS 26.0, *) {
                    Capsule()
                        .fill(.clear)
                        .glassEffect(.regular.interactive(), in: Capsule())
                        .frame(
                            width: DesignTokens.Dimensions.sliderThumbWidth,
                            height: DesignTokens.Dimensions.sliderThumbHeight
                        )
                        .position(
                            x: Self.thumbCenterX(
                                normalizedValue: normalizedValue,
                                trackWidth: geo.size.width,
                                thumbWidth: DesignTokens.Dimensions.sliderThumbWidth
                            ),
                            y: geo.size.height / 2
                        )
                        .opacity(showThumb ? 1 : 0)
                        .allowsHitTesting(false)
                        .animation(DesignTokens.Animation.hover, value: showThumb)
                }
            }
        }
        .frame(height: DesignTokens.Dimensions.sliderThumbHeight)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

#Preview("Liquid Glass Slider") {
    struct PreviewWrapper: View {
        @State private var value: Double = 0.5

        var body: some View {
            VStack(spacing: 30) {
                LiquidGlassSlider(value: $value, showUnityMarker: true)
                    .frame(width: 200)

                Text("\(Int(value * 200))%")
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .background(Color.black)
        }
    }
    return PreviewWrapper()
}
