import Foundation

public enum HealthOpportunityStage: Equatable, Sendable {
    case inactive
    case silent
    case microCue
    case reminderReady
}

public struct HealthOpportunityLadder: Equatable, Sendable {
    public var microCueThreshold: TimeInterval

    public init(microCueThreshold: TimeInterval = 60) {
        self.microCueThreshold = microCueThreshold
    }

    public func stage(
        opportunityDuration: TimeInterval,
        isEligible: Bool,
        reminderThreshold: TimeInterval
    ) -> HealthOpportunityStage {
        guard isEligible else { return .inactive }
        if opportunityDuration >= reminderThreshold { return .reminderReady }
        if opportunityDuration >= min(microCueThreshold, reminderThreshold) { return .microCue }
        return .silent
    }
}

public struct HealthOpportunityClock: Equatable, Sendable {
    public private(set) var accumulated: TimeInterval = 0
    public var maximumContinuousInterval: TimeInterval
    private var lastUpdatedAt: Date?
    private var wasEligible = false
    private var idleStartedAt: Date?

    public init(maximumContinuousInterval: TimeInterval = 60) {
        self.maximumContinuousInterval = maximumContinuousInterval
    }

    @discardableResult
    public mutating func transition(to state: AgentStateReducer, at now: Date) -> TimeInterval {
        var eligibleElapsed: TimeInterval = 0
        if let lastUpdatedAt {
            let elapsed = min(
                max(0, now.timeIntervalSince(lastUpdatedAt)),
                max(0, maximumContinuousInterval)
            )
            if wasEligible {
                accumulated += elapsed
                eligibleElapsed = elapsed
            }
        }

        if state.hasActiveSessions {
            idleStartedAt = nil
        } else {
            if idleStartedAt == nil {
                idleStartedAt = now
            }
            if let idleStartedAt, now.timeIntervalSince(idleStartedAt) >= 5 * 60 {
                accumulated = 0
            }
        }

        lastUpdatedAt = now
        wasEligible = state.isHealthOpportunityActive
        return eligibleElapsed
    }

    public mutating func reset(at now: Date, state: AgentStateReducer) {
        accumulated = 0
        lastUpdatedAt = now
        wasEligible = state.isHealthOpportunityActive
        idleStartedAt = state.hasActiveSessions ? nil : now
    }
}
