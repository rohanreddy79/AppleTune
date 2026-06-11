// FineTune/Views/Components/DeviceBadge.swift
import SwiftUI
import AppKit

/// Circular icon well that replaces the leading radio button on a device row —
/// sized like Control Center's Wi-Fi circle (`iconWellSize`). Selected state
/// inverts to a near-white filled circle (`iconWellSelectedFill`) with an
/// accent-colored glyph, Control Center's engaged-toggle treatment. Unselected
/// state uses a subtle monochrome fill from
/// `DesignTokens.Colors.deviceBadgeMonoFill`.
///
/// The badge owns no behavior. The parent row container handles tap-to-set-default
/// via a row-level `TapGesture` so the click target spans the whole row, mirroring
/// the macOS Sound submenu pattern.
struct DeviceBadge: View {
    /// The device's icon image, if available. Falls back to `fallbackSymbol`.
    let icon: NSImage?
    /// Whether this row is the current default device.
    let isSelected: Bool
    /// SF Symbol name used when `icon` is nil. Defaults to a speaker glyph for
    /// output devices; input device rows pass `"mic"` so the fallback matches
    /// the row's domain.
    var fallbackSymbol: String = "speaker.wave.2.fill"

    private static let badgeSize = DesignTokens.Dimensions.iconWellSize
    private static let glyphSize = DesignTokens.Dimensions.iconSize

    var body: some View {
        ZStack {
            // Background fill — inverted near-white when selected (Control
            // Center's engaged toggle), subtle mono fill otherwise.
            if isSelected {
                Circle()
                    .fill(DesignTokens.Colors.iconWellSelectedFill)
            } else {
                Circle()
                    .fill(DesignTokens.Colors.deviceBadgeMonoFill)
            }

            // Glyph — device icon when present, fallback SF Symbol otherwise.
            Group {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: fallbackSymbol)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(width: Self.glyphSize, height: Self.glyphSize)
            .foregroundStyle(glyphForeground)
        }
        .frame(width: Self.badgeSize, height: Self.badgeSize)
        .accessibilityHidden(true)
    }

    /// Accent glyph on the inverted near-white circle when selected;
    /// applies fully to the SF Symbol fallback and tints template device
    /// icons (full-color NSImages render as-is, as before).
    private var glyphForeground: Color {
        isSelected
            ? DesignTokens.Colors.accentPrimary
            : DesignTokens.Colors.deviceBadgeMonoForeground
    }
}

// MARK: - Previews

#Preview("DeviceBadge States") {
    HStack(spacing: 16) {
        VStack(spacing: 6) {
            DeviceBadge(icon: nil, isSelected: true)
            Text("Selected")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        VStack(spacing: 6) {
            DeviceBadge(icon: nil, isSelected: false)
            Text("Unselected")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    .padding()
    .frame(width: 200)
}
