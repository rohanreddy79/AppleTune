// FineTune/Views/Components/ExpandableGlassRow.swift
import SwiftUI

/// A reusable expandable row with Liquid Glass styling
/// The glass container grows/shrinks smoothly during expansion using SwiftUI's natural height calculation
struct ExpandableGlassRow<Header: View, ExpandedContent: View>: View {
    /// Surface treatment for the row container.
    enum Style {
        /// Flat at rest; hover/expansion reveals `hoverSurface` (System
        /// Settings pattern). Used by edit-mode rows.
        case flat
        /// Always-on floating capsule island (Control Center style):
        /// Liquid Glass on macOS 26+, `Materials.cardSurface` + hairline on
        /// 15.x, with the hover wash layered on top. Used by app rows; the
        /// non-expandable device rows get the same chrome from
        /// `capsuleIslandRow`.
        case island
    }

    let isExpanded: Bool
    var isFocused: Bool = false
    var style: Style = .flat
    @ViewBuilder let header: Header
    @ViewBuilder let expandedContent: ExpandedContent

    @State private var isHovered = false

    var body: some View {
        styledContainer
            .onHover { hovering in
                isHovered = hovering
            }
            .animation(DesignTokens.Animation.hover, value: isHovered)
            .animation(DesignTokens.Animation.hover, value: isFocused)
        // NOTE: Do NOT add .animation(_, value: isExpanded) here!
        // Animation is handled by the caller via withAnimation in onEQToggle.
        // Adding animation here causes layout loops with conditional content rendering.
        // The hoverSurface fill flips with isExpanded under that same caller
        // animation, so it cross-fades smoothly without an explicit modifier.
    }

    /// True while the row should read as active (hover, open panel, or
    /// keyboard focus) — drives the `hoverSurface` wash in both styles.
    private var isLit: Bool {
        isHovered || isExpanded || isFocused
    }

    @ViewBuilder
    private var styledContainer: some View {
        switch style {
        case .flat:
            // Flat at rest, hover reveals hoverSurface (System Settings pattern).
            // An open panel keeps the same fill so the active row reads at a glance.
            // The 1pt vertical inset on the fill keeps adjacent active rows
            // visually separated when two are simultaneously lit (e.g. an
            // expanded row with a hovered neighbour).
            content
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                        .fill(isLit ? DesignTokens.Colors.hoverSurface : Color.clear)
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                }
                // Soft hairline pairs with hoverSurface so the active row reads as
                // a glass tile. Inset matches the fill's 1pt vertical padding.
                .overlay {
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.rowRadius)
                        .strokeBorder(
                            isLit ? DesignTokens.Colors.glassRowBorderHover : Color.clear,
                            lineWidth: 0.5
                        )
                        .padding(.vertical, 1)
                        .allowsHitTesting(false)
                }

        case .island:
            // Floating capsule island: a collapsed row is a perfect capsule
            // (capsuleRadius is half its resting height); an expanded EQ
            // island grows into a rounded card with the same fully-rounded
            // ends. The hover/focus wash sits above the glass, below the
            // content — mirrors CapsuleIslandRowModifier on device rows.
            content
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background {
                    RoundedRectangle(cornerRadius: DesignTokens.Dimensions.capsuleRadius)
                        .fill(isLit ? DesignTokens.Colors.hoverSurface : Color.clear)
                        .allowsHitTesting(false)
                }
                .adaptiveGlassSurface(
                    cornerRadius: DesignTokens.Dimensions.capsuleRadius,
                    fallbackMaterial: DesignTokens.Materials.cardSurface,
                    fallbackBorder: DesignTokens.Colors.eqCardBorder
                )
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Header content - always visible
            header

            // Expandable content - conditional rendering lets SwiftUI calculate natural height
            if isExpanded {
                expandedContent
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                        )
                    )
            }
        }
    }
}

// MARK: - Previews

#Preview("Expandable Glass Row - Collapsed") {
    PreviewContainer {
        ExpandableGlassRow(isExpanded: false) {
            HStack {
                Image(systemName: "music.note")
                Text("Spotify")
                Spacer()
                Text("75%")
                    .foregroundStyle(.secondary)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            VStack {
                Text("Expanded Content")
                    .padding()
            }
            .frame(height: 100)
            .background(DesignTokens.Colors.recessedBackground)
        }
    }
}

#Preview("Expandable Glass Row - Expanded") {
    PreviewContainer {
        ExpandableGlassRow(isExpanded: true) {
            HStack {
                Image(systemName: "music.note")
                Text("Spotify")
                Spacer()
                Text("75%")
                    .foregroundStyle(.secondary)
            }
            .frame(height: DesignTokens.Dimensions.rowContentHeight)
        } expandedContent: {
            VStack(spacing: 8) {
                Text("EQ Panel Content")
                HStack(spacing: 16) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(.secondary)
                            .frame(width: 4, height: 60)
                    }
                }
            }
            .padding(.top, DesignTokens.Spacing.sm)
            .padding(.bottom, DesignTokens.Spacing.xs)
        }
    }
}
