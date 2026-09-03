import AppKit
import PerchCore
import SwiftUI

enum PerchTheme {
    /// Resolves per-appearance: fixed brand tints picked for a light
    /// canvas turn unreadable on dark backgrounds (deep text over deep
    /// fills, near-invisible low-opacity fills), so any color that plays
    /// a "deep ink" or "faint fill" role needs an explicit dark variant.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
    }

    // Brand roles come directly from the Perch bird: calm teal, warm orange, soft mint.
    static let brand = Color(red: 0.184, green: 0.533, blue: 0.475)
    static let brandDeep = adaptive(
        light: Color(red: 0.09, green: 0.31, blue: 0.27),
        dark: Color(red: 0.62, green: 0.86, blue: 0.79)
    )
    static let accent = Color(red: 0.953, green: 0.639, blue: 0.227)
    static let mint = Color(red: 0.847, green: 0.922, blue: 0.89)
    static let mintHighlight = Color(red: 0.933, green: 0.969, blue: 0.949)
    static let belly = Color(red: 1.0, green: 0.992, blue: 0.973)
    static let ink = Color(red: 0.09, green: 0.247, blue: 0.22)

    static let working = brand
    static let health = Color(red: 0.20, green: 0.53, blue: 0.38)
    static let attention = Color(red: 0.82, green: 0.43, blue: 0.12)
    static let celebration = Color(red: 0.27, green: 0.39, blue: 0.72)
    static let danger = Color(red: 0.72, green: 0.19, blue: 0.18)
    static let resting = Color(red: 0.34, green: 0.37, blue: 0.42)
    static let hairline = adaptive(light: brand.opacity(0.17), dark: brand.opacity(0.36))
    static let subtleFill = adaptive(light: brand.opacity(0.055), dark: brand.opacity(0.15))
    static let selectedFill = adaptive(light: brand.opacity(0.13), dark: brand.opacity(0.26))
    static let screenWash = adaptive(light: brand.opacity(0.025), dark: brand.opacity(0.09))

    struct RolePalette {
        let accent: Color
        let accentDeep: Color
        let surface: Color

        var selectedFill: Color {
            PerchTheme.adaptive(light: accent.opacity(0.14), dark: accent.opacity(0.28))
        }
        var subtleFill: Color {
            PerchTheme.adaptive(light: accent.opacity(0.06), dark: accent.opacity(0.16))
        }
        var screenWash: Color {
            PerchTheme.adaptive(light: accent.opacity(0.035), dark: accent.opacity(0.10))
        }
        var hairline: Color {
            PerchTheme.adaptive(light: accent.opacity(0.2), dark: accent.opacity(0.38))
        }
    }

    static func palette(for role: CompanionRole) -> RolePalette {
        switch role {
        case .sleepwing:
            RolePalette(
                accent: brand,
                accentDeep: brandDeep,
                surface: mintHighlight
            )
        case .cat:
            RolePalette(
                accent: Color(red: 0.82, green: 0.39, blue: 0.12),
                accentDeep: adaptive(
                    light: Color(red: 0.48, green: 0.20, blue: 0.07),
                    dark: Color(red: 0.98, green: 0.76, blue: 0.55)
                ),
                surface: Color(red: 1.0, green: 0.95, blue: 0.87)
            )
        case .custom:
            // Custom pets carry arbitrary artwork colors, so studio chrome falls back
            // to the app's own brand teal rather than an unrelated accent.
            RolePalette(
                accent: brand,
                accentDeep: brandDeep,
                surface: mintHighlight
            )
        }
    }

    static func color(for tone: CompanionSemanticTone) -> Color {
        switch tone {
        case .resting: resting
        case .working: working
        case .health: health
        case .attention: attention
        case .celebration: celebration
        }
    }
}

private struct PerchCardModifier: ViewModifier {
    let radius: CGFloat
    let fill: Color
    let stroke: Color

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            )
    }
}

extension View {
    func perchCard(
        radius: CGFloat = 14,
        fill: Color = PerchTheme.subtleFill,
        stroke: Color = PerchTheme.hairline
    ) -> some View {
        modifier(PerchCardModifier(radius: radius, fill: fill, stroke: stroke))
    }
}
