import Foundation

/// Codex `Stop` is a turn boundary, not a guaranteed end of ongoing work.
/// Another Stop hook may request a continuation, so Perch holds completion
/// briefly and discards it when a newer lifecycle event resumes the session.
public struct CodexCompletionGate: Sendable {
    public static let defaultGracePeriod: TimeInterval = 5

    private var pending: [AgentSessionKey: AgentEvent] = [:]

    public init() {}

    public var pendingCount: Int { pending.count }

    public mutating func route(_ event: AgentEvent) -> AgentEvent? {
        let key = AgentSessionKey(provider: event.provider, sessionID: event.sessionID)
        guard Self.isProvisionalCompletion(event) else {
            if let current = pending[key], event.timestamp >= current.timestamp {
                // Hooks are fired as independent detached processes, so
                // arrival order is not firing order. A permission ask can
                // only happen mid-turn — every turn opens with prompt/tool
                // hooks before any ask — so an ask arriving while this
                // turn's Stop is already pending is a late pre-Stop hook,
                // not a new ask. Letting it through would both fabricate a
                // phantom "needs you" (with nothing left to approve) and
                // cancel the real completion. A genuine new ask is safe:
                // its preceding prompt/tool events clear the gate first.
                if event.phase == .waitingForInput {
                    return nil
                }
                pending.removeValue(forKey: key)
            }
            return event
        }

        if let current = pending[key], event.timestamp < current.timestamp {
            return nil
        }
        pending[key] = event
        return nil
    }

    public func nextDeadline(
        gracePeriod: TimeInterval = Self.defaultGracePeriod
    ) -> Date? {
        pending.values
            .map { $0.timestamp.addingTimeInterval(gracePeriod) }
            .min()
    }

    public mutating func drain(
        at now: Date,
        gracePeriod: TimeInterval = Self.defaultGracePeriod
    ) -> [AgentEvent] {
        let due = pending
            .filter { now.timeIntervalSince($0.value.timestamp) >= gracePeriod }
            .sorted {
                if $0.value.timestamp == $1.value.timestamp {
                    return $0.key.sessionID < $1.key.sessionID
                }
                return $0.value.timestamp < $1.value.timestamp
            }
        for (key, _) in due {
            pending.removeValue(forKey: key)
        }
        return due.map { _, event in
            AgentEvent(
                provider: event.provider,
                sessionID: event.sessionID,
                phase: event.phase,
                timestamp: now,
                sourceEventName: event.sourceEventName,
                taskLabel: event.taskLabel,
                taskLabelKind: event.taskLabelKind,
                resumeURL: event.resumeURL
            )
        }
    }

    private static func isProvisionalCompletion(_ event: AgentEvent) -> Bool {
        guard event.provider == .codex, event.phase == .done else { return false }
        switch event.sourceEventName?.lowercased() {
        case "stop", "agent-turn-complete":
            return true
        default:
            return false
        }
    }
}
