import Foundation

public enum PetAnimationState: String, CaseIterable, Sendable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review
}

public enum PetAnimationPlayback: Equatable, Sendable {
    case loop
    case onceHoldLast
    /// Plays the full arc a fixed number of times, then holds the last
    /// frame. For moments that deserve more than one pass — a celebration —
    /// without becoming an endless loop that outstays the moment.
    case repeatHoldLast(passes: Int)
}

public struct PetAnimationRow: Equatable, Sendable {
    public let state: PetAnimationState
    public let row: Int
    public let frameDurations: [TimeInterval]
    public let playback: PetAnimationPlayback

    public init(
        state: PetAnimationState,
        row: Int,
        frameDurations: [TimeInterval],
        playback: PetAnimationPlayback = .loop
    ) {
        self.state = state
        self.row = row
        self.frameDurations = frameDurations
        self.playback = playback
    }

    public var frameCount: Int {
        frameDurations.count
    }

    public var duration: TimeInterval {
        frameDurations.reduce(0, +)
    }

    /// How long the row actually moves before it loops or settles. This is
    /// what UI windows showing the row alongside text should be sized from,
    /// so the pet is never frozen while its caption is still up.
    public var activeDuration: TimeInterval {
        holdPasses.map { duration * Double($0) } ?? duration
    }

    /// How long visible movement lasts. For hold-last playbacks the final
    /// frame is a held pose — the settle, not motion — so it is excluded;
    /// a loop moves for its whole duration.
    public var motionDuration: TimeInterval {
        guard holdPasses != nil, let finalHold = frameDurations.last else {
            return duration
        }
        return max(0, activeDuration - finalHold)
    }

    /// nil for a loop; otherwise how many full passes play before the last
    /// frame holds.
    private var holdPasses: Int? {
        switch playback {
        case .loop: nil
        case .onceHoldLast: 1
        case let .repeatHoldLast(passes): max(1, passes)
        }
    }

    public func frameIndex(at elapsed: TimeInterval) -> Int {
        guard !frameDurations.isEmpty, duration > 0 else { return 0 }
        let elapsed = max(0, elapsed)
        if holdPasses != nil, elapsed >= activeDuration {
            return frameDurations.count - 1
        }
        var remaining = elapsed.truncatingRemainder(dividingBy: duration)
        if remaining < 0 {
            remaining += duration
        }
        for (index, frameDuration) in frameDurations.enumerated() {
            if remaining < frameDuration {
                return index
            }
            remaining -= frameDuration
        }
        return frameDurations.count - 1
    }

    public func nextFrameBoundary(after elapsed: TimeInterval) -> TimeInterval? {
        guard !frameDurations.isEmpty, duration > 0 else { return nil }
        let elapsed = max(0, elapsed)
        let epsilon = 0.000_001

        if let passes = holdPasses {
            let active = duration * Double(passes)
            guard elapsed + epsilon < active else { return nil }
            let cycle = min(floor(elapsed / duration), Double(passes - 1))
            let cycleStart = cycle * duration
            let position = elapsed - cycleStart
            var boundary: TimeInterval = 0
            for frameDuration in frameDurations {
                boundary += frameDuration
                if boundary > position + epsilon {
                    let absolute = cycleStart + boundary
                    return absolute <= active + epsilon ? absolute : nil
                }
            }
            return nil
        }

        let completedCycles = floor(elapsed / duration)
        let cycleStart = completedCycles * duration
        let position = elapsed - cycleStart
        var boundary: TimeInterval = 0
        for frameDuration in frameDurations {
            boundary += frameDuration
            if boundary > position + epsilon {
                return cycleStart + boundary
            }
        }
        return cycleStart + duration + frameDurations[0]
    }
}

public enum PetDragDirection: Equatable, Sendable {
    case left
    case right
}

public struct PetLookDirection: Equatable, Sendable {
    public static let count = 16
    public static let stepDegrees = 360.0 / Double(count)

    public let index: Int

    public init(index: Int) {
        self.index = ((index % Self.count) + Self.count) % Self.count
    }

    public var degrees: Double {
        Double(index) * Self.stepDegrees
    }

    public var row: Int {
        index < PetSpriteContract.columns ? 9 : 10
    }

    public var column: Int {
        index % PetSpriteContract.columns
    }

    public static func resolve(
        deltaX: Double,
        deltaY: Double,
        current: PetLookDirection? = nil,
        deadZone: Double = 48,
        hysteresisDegrees: Double = 4
    ) -> PetLookDirection? {
        guard hypot(deltaX, deltaY) >= deadZone else { return nil }
        var degrees = atan2(deltaX, deltaY) * 180 / .pi
        if degrees < 0 { degrees += 360 }

        if let current {
            let distance = angularDistance(degrees, current.degrees)
            if distance < (Self.stepDegrees / 2) + hysteresisDegrees {
                return current
            }
        }

        let index = Int((degrees / Self.stepDegrees).rounded()) % Self.count
        return PetLookDirection(index: index)
    }

    private static func angularDistance(_ lhs: Double, _ rhs: Double) -> Double {
        let difference = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}

public enum PetSpriteContract {
    public static let spriteVersionNumber = 2
    public static let columns = 8
    public static let rows = 11
    public static let cellWidth = 192
    public static let cellHeight = 208
    public static let atlasWidth = columns * cellWidth
    public static let atlasHeight = rows * cellHeight

    public static func animation(for state: PetAnimationState) -> PetAnimationRow {
        switch state {
        case .idle:
            PetAnimationRow(
                state: state,
                row: 0,
                frameDurations: milliseconds(900, 140, 120, 140, 240, 1_500)
            )
        case .runningRight:
            PetAnimationRow(
                state: state,
                row: 1,
                frameDurations: milliseconds(120, 120, 120, 120, 120, 120, 120, 220)
            )
        case .runningLeft:
            PetAnimationRow(
                state: state,
                row: 2,
                frameDurations: milliseconds(120, 120, 120, 120, 120, 120, 120, 220)
            )
        case .waving:
            PetAnimationRow(
                state: state,
                row: 3,
                frameDurations: milliseconds(700, 240, 320, 1_400),
                playback: .onceHoldLast
            )
        case .jumping:
            // One deliberate pass, not a sprint: the original 1.8 s arc read
            // as fast-forward, and replaying it twice read worse. The frames
            // hold roughly twice as long so the same eight poses carry a
            // celebration that feels intentional, then settle on the landing.
            PetAnimationRow(
                state: state,
                row: 4,
                frameDurations: milliseconds(320, 400, 180, 220, 520, 220, 360, 900),
                playback: .onceHoldLast
            )
        case .failed:
            PetAnimationRow(
                state: state,
                row: 5,
                frameDurations: milliseconds(220, 220, 240, 260, 320, 500, 320, 900),
                playback: .onceHoldLast
            )
        case .waiting:
            PetAnimationRow(
                state: state,
                row: 6,
                frameDurations: milliseconds(650, 240, 280, 420, 280, 1_100)
            )
        case .running:
            PetAnimationRow(
                state: state,
                row: 7,
                frameDurations: milliseconds(260, 260, 260, 260, 260, 520)
            )
        case .review:
            PetAnimationRow(
                state: state,
                row: 8,
                frameDurations: milliseconds(500, 280, 280, 500, 280, 900)
            )
        }
    }

    public static func animationState(
        phase: AgentPhase,
        presentation: CompanionPresentationState
    ) -> PetAnimationState {
        if phase == .failed {
            return .failed
        }
        switch presentation {
        case .resting:
            return .idle
        case .working:
            return .running
        case .healthOpportunity:
            return .review
        case .needsAttention:
            return .waiting
        case .celebrating:
            return .jumping
        case .healthNudge:
            return .waving
        }
    }

    /// The single source for how long a completion is celebrated: visible
    /// motion plus half a second on the landing pose. The final atlas frame
    /// is a 0.9 s held pose, so sizing the window from the full arc left the
    /// pet frozen under a caption that was still up; sizing it from motion
    /// keeps the caption and the movement ending together.
    public static var celebrationWindow: TimeInterval {
        animation(for: .jumping).motionDuration + 0.5
    }

    private static func milliseconds(_ values: Int...) -> [TimeInterval] {
        values.map { TimeInterval($0) / 1_000 }
    }
}
