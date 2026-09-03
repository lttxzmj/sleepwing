import Foundation

/// The brief signature move a built-in companion performs the moment work
/// completes, layered on top of the shared celebration sprite row.
///
/// Signature moves belong to the two built-in characters only: an imported
/// custom pet has no inherent personality to lean into, so it keeps the
/// generic celebration row untouched.
public struct PetSignatureFlourish: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// One quiet hop with a soft landing — Sleepwing Bird's terse
        /// night-watch acknowledgement.
        case hop
        /// A slow contented lean-and-settle — Moontail Cat speaking through
        /// body language instead of bouncing.
        case settle
    }

    public let kind: Kind
    public let duration: TimeInterval

    public init(kind: Kind, duration: TimeInterval) {
        self.kind = kind
        self.duration = duration
    }

    public static func flourish(
        forSpriteResource resource: String
    ) -> PetSignatureFlourish? {
        switch resource {
        case "perch-sleepwing-bird-v2":
            PetSignatureFlourish(kind: .hop, duration: 0.9)
        case "perch-crescent-cat-v2":
            PetSignatureFlourish(kind: .settle, duration: 1.3)
        default:
            nil
        }
    }
}
