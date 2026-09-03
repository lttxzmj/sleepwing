import Foundation

public enum CompanionPresentationState: Equatable, Sendable {
    case resting
    case working
    case healthOpportunity
    case needsAttention
    case celebrating
    case healthNudge(ReminderKind)
}

public struct CompanionPresentationReducer: Sendable {
    public private(set) var state: CompanionPresentationState = .resting
    private var celebrationUntil: Date?

    public init() {}

    @discardableResult
    public mutating func derive(
        agentPhase: AgentPhase,
        completedEdge: Bool = false,
        activityResumed: Bool = false,
        healthReminder: ReminderKind? = nil,
        healthOpportunityCue: Bool = false,
        at now: Date,
        celebrationDuration: TimeInterval = PetSpriteContract.celebrationWindow
    ) -> CompanionPresentationState {
        if activityResumed {
            celebrationUntil = nil
        }
        if agentPhase == .waitingForInput {
            celebrationUntil = nil
            state = .needsAttention
            return state
        }
        if let healthReminder {
            state = .healthNudge(healthReminder)
            return state
        }
        if healthOpportunityCue, agentPhase == .working {
            state = .healthOpportunity
            return state
        }
        if completedEdge {
            celebrationUntil = now.addingTimeInterval(celebrationDuration)
        }
        if let celebrationUntil, now < celebrationUntil {
            state = .celebrating
            return state
        }
        celebrationUntil = nil
        state = agentPhase == .working ? .working : .resting
        return state
    }
}
