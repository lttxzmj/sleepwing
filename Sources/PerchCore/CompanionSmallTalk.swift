import Foundation

/// Deterministic small-talk selection for the companion's poke response:
/// the user double-clicks the pet and it says one short in-character line
/// grounded in the real current state. The policy only chooses a string
/// key; localization and rendering stay in the UI layer.
public enum CompanionSmallTalk {
    public struct Context: Sendable {
        public var isWorking: Bool
        public var isWaiting: Bool
        public var hour: Int

        public init(isWorking: Bool, isWaiting: Bool, hour: Int) {
            self.isWorking = isWorking
            self.isWaiting = isWaiting
            self.hour = hour
        }
    }

    public enum Category: String, CaseIterable, Sendable {
        case waiting
        case working
        case restingNight
        case resting
    }

    public static let variantCounts: [Category: Int] = [
        .waiting: 1,
        .working: 2,
        .restingNight: 1,
        .resting: 2,
    ]

    public static func category(for context: Context) -> Category {
        if context.isWaiting { return .waiting }
        if context.isWorking { return .working }
        if context.hour >= 22 || context.hour < 5 { return .restingNight }
        return .resting
    }

    public static func lineKey(
        role: String,
        context: Context,
        variant: (Int) -> Int = { Int.random(in: 0 ..< $0) }
    ) -> String {
        let category = category(for: context)
        let count = variantCounts[category] ?? 1
        let index = max(0, min(count - 1, variant(count)))
        return "smalltalk.\(role).\(category.rawValue).\(index)"
    }
}
