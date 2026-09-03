import Foundation

public enum AgentProvider: String, Codable, CaseIterable, Hashable, Sendable {
    case claude
    case cursor
    case codex
    case opencode
    case gemini
    case trae
    case pi
}

public enum AgentPhase: String, Codable, CaseIterable, Sendable {
    case idle
    case working
    case waitingForInput = "waiting_for_input"
    case failed
    case done

    /// The session is over and asks nothing of the user. `failed` is
    /// deliberately absent: it ends the run but still needs someone.
    public var isTerminal: Bool { self == .idle || self == .done }
}

public enum AgentTaskLabelKind: String, Codable, Sendable {
    case workspace
    case prompt
    case title
}

public struct AgentEvent: Codable, Equatable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let phase: AgentPhase
    public let timestamp: Date
    public let sourceEventName: String?
    public let taskLabel: String?
    public let taskLabelKind: AgentTaskLabelKind?
    public let resumeURL: String?

    public init(
        provider: AgentProvider,
        sessionID: String,
        phase: AgentPhase,
        timestamp: Date = .now,
        sourceEventName: String? = nil,
        taskLabel: String? = nil,
        taskLabelKind: AgentTaskLabelKind? = nil,
        resumeURL: String? = nil
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.phase = phase
        self.timestamp = timestamp
        self.sourceEventName = sourceEventName
        self.taskLabel = taskLabel
        self.taskLabelKind = taskLabelKind
        self.resumeURL = resumeURL
    }
}

public enum ReminderKind: String, Codable, CaseIterable, Sendable {
    case hydrate
    case stand
    case eyes
    case posture
    case breathe
}

public enum ReminderResponse: String, Codable, Sendable {
    case completed
    case snoozed
    case skipped
}

public struct ReminderRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: ReminderKind
    public let triggeredAt: Date
    public var response: ReminderResponse?
    public var snoozeCount: Int?
    public var experimentArm: String?
    public var opportunityDuration: TimeInterval?

    public init(
        id: UUID = UUID(),
        kind: ReminderKind,
        triggeredAt: Date,
        response: ReminderResponse? = nil,
        snoozeCount: Int? = nil,
        experimentArm: String? = nil,
        opportunityDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.kind = kind
        self.triggeredAt = triggeredAt
        self.response = response
        self.snoozeCount = snoozeCount
        self.experimentArm = experimentArm
        self.opportunityDuration = opportunityDuration
    }
}

public struct AttentionResponseRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let provider: AgentProvider
    public let resolvedAt: Date
    public let duration: TimeInterval

    public init(
        id: UUID = UUID(),
        provider: AgentProvider,
        resolvedAt: Date,
        duration: TimeInterval
    ) {
        self.id = id
        self.provider = provider
        self.resolvedAt = resolvedAt
        self.duration = duration
    }
}

public struct QuietHours: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int

    public init(startMinute: Int = 0, endMinute: Int = 0) {
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard startMinute != endMinute else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if startMinute < endMinute {
            return minute >= startMinute && minute < endMinute
        }
        return minute >= startMinute || minute < endMinute
    }
}

public struct ReminderPolicy: Codable, Equatable, Sendable {
    public var waitingThreshold: TimeInterval
    public var sameKindCooldown: TimeInterval
    public var hourlyLimit: Int
    public var quietHours: QuietHours

    public init(
        waitingThreshold: TimeInterval = 180,
        sameKindCooldown: TimeInterval = 45 * 60,
        hourlyLimit: Int = 2,
        quietHours: QuietHours = QuietHours()
    ) {
        self.waitingThreshold = waitingThreshold
        self.sameKindCooldown = sameKindCooldown
        self.hourlyLimit = hourlyLimit
        self.quietHours = quietHours
    }
}
