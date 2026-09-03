import Foundation

/// Deterministic gaze behavior for the companion: pointer-driven looking
/// with bounded interest, plus occasional autonomous glances while idle.
///
/// A real animal glances at movement and then loses interest; it does not
/// stare at a stationary object forever, and it does not sit perfectly
/// frozen when nothing happens. Both behaviors are timed here so the UI
/// layer stays a thin poll loop and the policy is unit-testable with an
/// injected clock and random source.
public struct CompanionGazeEngine: Sendable {
    /// How long a stationary pointer keeps the companion's attention.
    public var interestDuration: TimeInterval = 4
    /// How long one autonomous glance lasts.
    public var glanceDuration: TimeInterval = 1.4
    /// How long the companion rests between autonomous glances.
    public var glanceInterval: ClosedRange<TimeInterval> = 4 ... 9
    public var deadZone: Double = 48

    private var interestUntil: Date = .distantPast
    private var glanceUntil: Date = .distantPast
    private var nextGlanceAt: Date?
    private var glanceDirection: PetLookDirection?
    private var current: PetLookDirection?

    public init() {}

    public mutating func update(
        deltaX: Double,
        deltaY: Double,
        pointerMoved: Bool,
        at now: Date,
        randomUnit: () -> Double = { Double.random(in: 0 ... 1) }
    ) -> PetLookDirection? {
        if pointerMoved {
            interestUntil = now.addingTimeInterval(interestDuration)
        }
        let pointerLook = PetLookDirection.resolve(
            deltaX: deltaX,
            deltaY: deltaY,
            current: current,
            deadZone: deadZone
        )
        if now < interestUntil, let pointerLook {
            glanceUntil = .distantPast
            glanceDirection = nil
            nextGlanceAt = nil
            current = pointerLook
            return pointerLook
        }

        if now < glanceUntil, let glanceDirection {
            current = glanceDirection
            return glanceDirection
        }
        if let scheduled = nextGlanceAt {
            if now >= scheduled {
                glanceDirection = PetLookDirection(
                    index: Int(randomUnit() * 16) % 16
                )
                glanceUntil = now.addingTimeInterval(glanceDuration)
                nextGlanceAt = now.addingTimeInterval(randomInterval(randomUnit))
                current = glanceDirection
                return glanceDirection
            }
        } else {
            nextGlanceAt = now.addingTimeInterval(randomInterval(randomUnit))
        }
        glanceDirection = nil
        current = nil
        return nil
    }

    private func randomInterval(_ randomUnit: () -> Double) -> TimeInterval {
        glanceInterval.lowerBound
            + randomUnit() * (glanceInterval.upperBound - glanceInterval.lowerBound)
    }
}
