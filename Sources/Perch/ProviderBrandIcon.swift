import AppKit
import PerchCore
import SwiftUI

/// Shows the installed product's real macOS icon when possible, then falls back
/// to the provider's bundled official brand asset.
struct ProviderBrandIcon: View {
    let provider: AgentProvider
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let icon = installedApplicationIcon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .accessibilityHidden(true)
            } else if let asset = bundledBrandAsset {
                brandAssetImage(asset)
            } else {
                fallbackMark
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.brandName)
    }

    /// Real macOS app icons carry the system icon-grid margin inside their
    /// canvas. Every other mark is drawn on the same grid — an inset tile with
    /// the macOS corner ratio — so all provider rows share one visual weight.
    private var tileSize: CGFloat { size * 0.804 }
    private var tileCorner: CGFloat { tileSize * 0.225 }

    private func tile(_ background: Color, @ViewBuilder content: () -> some View) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: tileCorner, style: .continuous)
                .fill(background)
            content()
        }
        .frame(width: tileSize, height: tileSize)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func brandAssetImage(_ image: NSImage) -> some View {
        if provider == .pi {
            tile(brandPalette.background) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(brandPalette.foreground)
                    .padding(tileSize * 0.2)
            }
        } else {
            // These bundled logos are full-bleed artwork with no built-in margin,
            // unlike the transparent keyline margin baked into real app icons, so
            // they need the same inset the fallback marks get to read as the same
            // visual weight instead of looking larger than every other tile. Clip
            // at the inset size, then center it in the full tile, so the logo's
            // own hard corners stay rounded instead of floating uncropped.
            Image(nsImage: image)
                .renderingMode(.original)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: tileSize * 0.76, height: tileSize * 0.76)
                .clipShape(RoundedRectangle(cornerRadius: tileCorner * 0.76, style: .continuous))
                .frame(width: tileSize, height: tileSize)
                .accessibilityHidden(true)
        }
    }

    private var bundledBrandAsset: NSImage? {
        let asset: (name: String, extension: String)? = switch provider {
        case .opencode: ("opencode", "png")
        case .gemini: ("gemini-cli", "png")
        case .pi: ("pi", "svg")
        default: nil
        }
        guard let asset else { return nil }
        let resourceBundle = PerchResources.bundle
        let url = resourceBundle.url(
            forResource: asset.name,
            withExtension: asset.extension,
            subdirectory: "BrandAssets"
        ) ?? resourceBundle.url(forResource: asset.name, withExtension: asset.extension)
        guard let url else { return nil }
        return NSImage(contentsOf: url)
    }

    private var installedApplicationIcon: NSImage? {
        for bundleName in provider.applicationBundleNames {
            for root in applicationRoots {
                let url = root.appendingPathComponent(bundleName, isDirectory: true)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }

    private var applicationRoots: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    private var fallbackMark: some View {
        tile(brandPalette.background) {
            Text(provider.fallbackBrandMark)
                .font(.system(
                    size: fallbackFontSize,
                    weight: .bold,
                    design: provider == .pi ? .serif : .rounded
                ))
                .foregroundStyle(brandPalette.foreground)
                .minimumScaleFactor(0.7)
                .padding(tileSize * 0.12)
        }
    }

    private var fallbackFontSize: CGFloat {
        switch provider {
        case .codex, .opencode: tileSize * 0.45
        default: tileSize * 0.55
        }
    }

    private var brandPalette: (foreground: Color, background: Color) {
        switch provider {
        case .claude:
            (Color(red: 0.78, green: 0.35, blue: 0.18), Color(red: 0.98, green: 0.93, blue: 0.89))
        case .cursor:
            (.white, Color(red: 0.12, green: 0.13, blue: 0.15))
        case .codex:
            (.white, Color(red: 0.08, green: 0.55, blue: 0.42))
        case .opencode:
            (Color(red: 0.12, green: 0.16, blue: 0.13), Color(red: 0.75, green: 0.94, blue: 0.68))
        case .gemini:
            (Color(red: 0.30, green: 0.34, blue: 0.78), Color(red: 0.91, green: 0.92, blue: 0.99))
        case .trae:
            (.white, Color(red: 0.12, green: 0.50, blue: 0.53))
        case .pi:
            (Color(red: 0.48, green: 0.25, blue: 0.64), Color(red: 0.95, green: 0.91, blue: 0.98))
        }
    }
}
