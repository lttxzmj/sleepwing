import Foundation

public struct ReminderCandidate: Equatable, Sendable {
    public let kind: ReminderKind
    public let qualifyingDuration: TimeInterval

    public init(kind: ReminderKind, qualifyingDuration: TimeInterval) {
        self.kind = kind
        self.qualifyingDuration = qualifyingDuration
    }
}

public struct ReminderEngine: Sendable {
    public var policy: ReminderPolicy
    public private(set) var records: [ReminderRecord]
    private var nextKindIndex = 0
    private var lastQualifyingPeriodReminderAt: Date?

    public init(policy: ReminderPolicy = ReminderPolicy(), records: [ReminderRecord] = []) {
        self.policy = policy
        self.records = records
    }

    public mutating func evaluate(
        state: AgentStateReducer,
        at now: Date,
        eligibleKinds: [ReminderKind] = ReminderKind.allCases
    ) -> ReminderCandidate? {
        evaluate(
            opportunityDuration: state.qualifyingDuration(at: now),
            at: now,
            eligibleKinds: eligibleKinds
        )
    }

    public mutating func evaluate(
        opportunityDuration duration: TimeInterval,
        at now: Date,
        eligibleKinds: [ReminderKind] = ReminderKind.allCases
    ) -> ReminderCandidate? {
        guard !eligibleKinds.isEmpty else { return nil }
        guard !policy.quietHours.contains(now) else { return nil }
        guard duration >= policy.waitingThreshold else {
            lastQualifyingPeriodReminderAt = nil
            return nil
        }
        if let last = lastQualifyingPeriodReminderAt,
           now.timeIntervalSince(last) < policy.waitingThreshold {
            return nil
        }
        let lastHour = records.filter { now.timeIntervalSince($0.triggeredAt) >= 0 && now.timeIntervalSince($0.triggeredAt) < 3600 }
        guard lastHour.count < policy.hourlyLimit else { return nil }

        let kinds = eligibleKinds
        for offset in 0..<kinds.count {
            let index = (nextKindIndex + offset) % kinds.count
            let kind = kinds[index]
            let mostRecent = records.last(where: { $0.kind == kind })
            if mostRecent.map({ now.timeIntervalSince($0.triggeredAt) }) ?? .infinity
                >= policy.sameKindCooldown {
                nextKindIndex = (index + 1) % kinds.count
                return ReminderCandidate(kind: kind, qualifyingDuration: duration)
            }
        }
        return nil
    }

    @discardableResult
    public mutating func record(_ candidate: ReminderCandidate, at now: Date, experimentArm: String? = nil) -> ReminderRecord {
        let record = ReminderRecord(
            kind: candidate.kind,
            triggeredAt: now,
            experimentArm: experimentArm,
            opportunityDuration: candidate.qualifyingDuration
        )
        records.append(record)
        lastQualifyingPeriodReminderAt = now
        return record
    }

    public mutating func respond(to id: UUID, with response: ReminderResponse) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        if response == .snoozed {
            records[index].snoozeCount = (records[index].snoozeCount ?? 0) + 1
        }
        records[index].response = response
    }

    public mutating func retainRecords(since cutoff: Date) {
        records.removeAll { $0.triggeredAt < cutoff }
        if let last = lastQualifyingPeriodReminderAt, last < cutoff {
            lastQualifyingPeriodReminderAt = nil
        }
    }
}
