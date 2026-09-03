import Foundation

public struct AgentTaskInboxEntry: Equatable, Sendable {
    public let key: AgentSessionKey
    public let provider: AgentProvider
    public let phase: AgentPhase
    public let startedAt: Date
    public let phaseStartedAt: Date
    public let updatedAt: Date
    public let isMuted: Bool
    public let isSignalStale: Bool
    public let taskLabel: String?
    public let taskLabelKind: AgentTaskLabelKind?
    public let resumeURL: String?

    public init(
        key: AgentSessionKey,
        provider: AgentProvider,
        phase: AgentPhase,
        startedAt: Date,
        phaseStartedAt: Date,
        updatedAt: Date,
        isMuted: Bool,
        isSignalStale: Bool,
        taskLabel: String?,
        taskLabelKind: AgentTaskLabelKind?,
        resumeURL: String?
    ) {
        self.key = key
        self.provider = provider
        self.phase = phase
        self.startedAt = startedAt
        self.phaseStartedAt = phaseStartedAt
        self.updatedAt = updatedAt
        self.isMuted = isMuted
        self.isSignalStale = isSignalStale
        self.taskLabel = taskLabel
        self.taskLabelKind = taskLabelKind
        self.resumeURL = resumeURL
    }
}

public enum AgentTaskInbox {
    public static func entries(
        sessions: [AgentSessionKey: SessionState],
        mutedSessionKeys: Set<AgentSessionKey>
    ) -> [AgentTaskInboxEntry] {
        sessions.compactMap { key, session in
            guard session.phase == .working
                    || session.phase == .waitingForInput
                    || session.phase == .failed else {
                return nil
            }
            return AgentTaskInboxEntry(
                key: key,
                provider: session.provider,
                phase: session.phase,
                startedAt: session.startedAt,
                phaseStartedAt: session.phaseStartedAt,
                updatedAt: session.lastEventAt,
                isMuted: mutedSessionKeys.contains(key),
                isSignalStale: session.isSignalStale,
                taskLabel: session.taskLabel,
                taskLabelKind: session.taskLabelKind,
                resumeURL: session.resumeURL
            )
        }
        .sorted {
            let left = rank($0)
            let right = rank($1)
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            if $0.provider != $1.provider {
                return $0.provider.rawValue < $1.provider.rawValue
            }
            return $0.key.sessionID < $1.key.sessionID
        }
    }

    private static func rank(_ entry: AgentTaskInboxEntry) -> Int {
        if entry.isMuted { return 4 }
        if entry.isSignalStale { return 3 }
        switch entry.phase {
        case .failed: return 0
        case .waitingForInput: return 1
        case .working: return 2
        case .idle, .done: return 5
        }
    }
}
