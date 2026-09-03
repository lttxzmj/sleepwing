import Foundation

public enum IdleSleepProtectionState: Equatable, Sendable {
    case disabled
    case waitingForVerifiedWork
    case active
    case pausedForLowPower
    case pausedForLowBattery
    case timedOut
}

public struct IdleSleepProtectionGate: Sendable {
    public var maximumContinuousDuration: TimeInterval
    private var activeSince: Date?
    private var timedOutForCurrentRun = false

    public init(maximumContinuousDuration: TimeInterval = 4 * 60 * 60) {
        self.maximumContinuousDuration = maximumContinuousDuration
    }

    public mutating func evaluate(
        enabled: Bool,
        hasVerifiedWorkingAgent: Bool,
        isLowPowerModeEnabled: Bool,
        hasLowBatteryWarning: Bool,
        at now: Date
    ) -> IdleSleepProtectionState {
        guard enabled else {
            reset()
            return .disabled
        }
        guard hasVerifiedWorkingAgent else {
            reset()
            return .waitingForVerifiedWork
        }
        guard !isLowPowerModeEnabled else {
            activeSince = nil
            return .pausedForLowPower
        }
        guard !hasLowBatteryWarning else {
            activeSince = nil
            return .pausedForLowBattery
        }
        guard !timedOutForCurrentRun else {
            return .timedOut
        }
        if activeSince == nil {
            activeSince = now
        }
        if now.timeIntervalSince(activeSince ?? now) >= maximumContinuousDuration {
            activeSince = nil
            timedOutForCurrentRun = true
            return .timedOut
        }
        return .active
    }

    private mutating func reset() {
        activeSince = nil
        timedOutForCurrentRun = false
    }
}
