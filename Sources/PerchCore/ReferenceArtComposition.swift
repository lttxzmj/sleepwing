import Foundation

/// Deterministic layout for exported reference art: the subject lifted from a
/// user photo is scaled to fit a fixed fraction of a square transparent
/// canvas and centered with even breathing room, so agent skills receive a
/// clean, well-framed character reference.
public enum ReferenceArtComposition {
    public static let canvasSide: Double = 1024
    public static let subjectFraction: Double = 0.82

    public struct Placement: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public static func placement(
        subjectWidth: Double,
        subjectHeight: Double
    ) -> Placement? {
        guard subjectWidth > 0, subjectHeight > 0 else { return nil }
        let maximumSide = canvasSide * subjectFraction
        let scale = min(
            maximumSide / subjectWidth,
            maximumSide / subjectHeight
        )
        let width = subjectWidth * scale
        let height = subjectHeight * scale
        return Placement(
            x: (canvasSide - width) / 2,
            y: (canvasSide - height) / 2,
            width: width,
            height: height
        )
    }
}
