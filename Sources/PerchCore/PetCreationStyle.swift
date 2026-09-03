import Foundation

/// The art styles a user can pick when turning a photo into a pet. Each
/// case maps onto a hatch-pet style preset so the choice travels through
/// the creation prompt as a concrete, machine-usable instruction.
///
/// `faithful` is the default: it maximizes likeness by demanding rendering
/// that stays as close to the photo's real appearance as generation
/// allows, via `auto` plus explicit photo-faithful style notes.
public enum PetCreationStyle: String, CaseIterable, Sendable {
    case faithful
    case pixel
    case plush
    case sticker
    case toy3d

    public var hatchStylePreset: String {
        switch self {
        case .faithful: "auto"
        case .pixel: "pixel"
        case .plush: "plush"
        case .sticker: "sticker"
        case .toy3d: "3d-toy"
        }
    }
}
