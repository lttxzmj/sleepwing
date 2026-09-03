import Foundation

public struct SRGBColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = SRGBColor(red: 1, green: 1, blue: 1)

    public func contrastRatio(with other: SRGBColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private var relativeLuminance: Double {
        0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }

    private func linearized(_ component: Double) -> Double {
        if component <= 0.04045 {
            return component / 12.92
        }
        return pow((component + 0.055) / 1.055, 2.4)
    }
}

public enum CompanionSemanticTone: CaseIterable, Sendable {
    case resting
    case working
    case health
    case attention
    case celebration
}

public enum CompanionVisualPalette {
    public static func badgeBackground(for tone: CompanionSemanticTone) -> SRGBColor {
        switch tone {
        case .resting:
            SRGBColor(red: 0.294, green: 0.333, blue: 0.388)
        case .working:
            SRGBColor(red: 0.086, green: 0.396, blue: 0.204)
        case .health:
            SRGBColor(red: 0.059, green: 0.400, blue: 0.455)
        case .attention:
            SRGBColor(red: 0.604, green: 0.204, blue: 0.071)
        case .celebration:
            SRGBColor(red: 0.114, green: 0.306, blue: 0.847)
        }
    }
}
