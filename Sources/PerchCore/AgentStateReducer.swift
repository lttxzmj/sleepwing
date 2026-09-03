import Foundation

public struct AgentSessionKey: Hashable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String

    public init(provider: AgentProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }
}

public struct AgentStateChange: Equatable, Sendable {
    public let didComplete: Bool
    /// The session just entered an attention state (waiting for input or
    /// failed) from a non-attention state. Escalating between attention
    /// states does not raise the edge again.
    public let didRequestAttention: Bool
    /// The session is terminal now that this event has been applied. A
    /// session-end event the reducer deliberately ignores — the trailing
    /// idle that follows a failure — settles nothing, so callers that retire
    /// per-session state must ask rather than read the event's own phase.
    public let didSettle: Bool

    public init(
        didComplete: Bool = false,
        didRequestAttention: Bool = false,
        didSettle: Bool = false
    ) {
        self.didComplete = didComplete
        self.didRequestAttention = didRequestAttention
        self.didSettle = didSettle
    }
}

public struct SessionState: Equatable, Sendable {
    public var provider: AgentProvider
    public var phase: AgentPhase
    public var startedAt: Date
    public var phaseStartedAt: Date
    public var lastEventAt: Date
    public var taskLabel: String?
    public var taskLabelKind: AgentTaskLabelKind?
    public var resumeURL: String?
    /// The provider has not emitted a lifecycle signal within the expected
    /// window. Keep the task visible, but do not claim it is still running.
    public var isSignalStale: Bool

    public init(
        provider: AgentProvider,
        phase: AgentPhase,
        startedAt: Date? = nil,
        phaseStartedAt: Date,
        lastEventAt: Date,
        taskLabel: String? = nil,
        taskLabelKind: AgentTaskLabelKind? = nil,
        resumeURL: String? = nil,
        isSignalStale: Bool = false
    ) {
        self.provider = provider
        self.phase = phase
        self.startedAt = startedAt ?? phaseStartedAt
        self.phaseStartedAt = phaseStartedAt
        self.lastEventAt = lastEventAt
        self.taskLabel = taskLabel
        self.taskLabelKind = taskLabelKind
        self.resumeURL = resumeURL
        self.isSignalStale = isSignalStale
    }
}

public struct AgentStateReducer: Sendable {
    public private(set) var sessions: [AgentSessionKey: SessionState] = [:]

    public init() {}

    @discardableResult
    public mutating func ingest(_ event: AgentEvent) -> AgentStateChange {
        let key = AgentSessionKey(provider: event.provider, sessionID: event.sessionID)
        if let current = sessions[key], event.timestamp < current.lastEventAt {
            return AgentStateChange()
        }
        // Providers may dispatch failure and session-end hooks concurrently. Keep the
        // actionable failure visible until a real recovery event arrives or terminal
        // cleanup expires it; a trailing idle event must not erase it immediately.
        if let current = sessions[key], current.phase == .failed, event.phase == .idle {
            return AgentStateChange()
        }
        if let current = sessions[key], current.phase == event.phase {
            sessions[key]?.lastEventAt = event.timestamp
            sessions[key]?.isSignalStale = false
            updateTaskMetadata(for: key, from: event)
            return AgentStateChange(didSettle: current.phase.isTerminal)
        }
        let didComplete = event.phase == .done && sessions[key]?.phase != .done
        let current = sessions[key]
        let wasAttention = current?.phase == .waitingForInput || current?.phase == .failed
        let didRequestAttention = (event.phase == .waitingForInput || event.phase == .failed)
            && !wasAttention
        let useIncomingLabel = shouldUseIncomingLabel(
            currentLabel: current?.taskLabel,
            current: current?.taskLabelKind,
            incomingLabel: event.taskLabel,
            incoming: event.taskLabelKind,
            hasIncomingLabel: event.taskLabel != nil
        )
        sessions[key] = SessionState(
            provider: event.provider,
            phase: event.phase,
            startedAt: sessions[key]?.startedAt ?? event.timestamp,
            phaseStartedAt: event.timestamp,
            lastEventAt: event.timestamp,
            taskLabel: useIncomingLabel ? event.taskLabel : current?.taskLabel,
            taskLabelKind: useIncomingLabel
                ? (event.taskLabelKind ?? .title)
                : current?.taskLabelKind,
            resumeURL: event.resumeURL ?? current?.resumeURL
        )
        return AgentStateChange(
            didComplete: didComplete,
            didRequestAttention: didRequestAttention,
            didSettle: event.phase.isTerminal
        )
    }

    private mutating func updateTaskMetadata(
        for key: AgentSessionKey,
        from event: AgentEvent
    ) {
        if shouldUseIncomingLabel(
            currentLabel: sessions[key]?.taskLabel,
            current: sessions[key]?.taskLabelKind,
            incomingLabel: event.taskLabel,
            incoming: event.taskLabelKind,
            hasIncomingLabel: event.taskLabel != nil
        ) {
            sessions[key]?.taskLabel = event.taskLabel
            sessions[key]?.taskLabelKind = event.taskLabelKind ?? .title
        }
        if let resumeURL = event.resumeURL {
            sessions[key]?.resumeURL = resumeURL
        }
    }

    private func shouldUseIncomingLabel(
        currentLabel: String?,
        current: AgentTaskLabelKind?,
        incomingLabel: String?,
        incoming: AgentTaskLabelKind?,
        hasIncomingLabel: Bool
    ) -> Bool {
        guard hasIncomingLabel else { return false }
        let incomingPriority = labelPriority(incoming ?? .title)
        let currentPriority = current.map(labelPriority) ?? -1
        guard incomingPriority == currentPriority else {
            return incomingPriority > currentPriority
        }
        switch incoming ?? .title {
        case .title:
            return incomingLabel != currentLabel
        case .prompt:
            guard let currentLabel, let incomingLabel else { return false }
            return currentLabel.count < 8
                && incomingLabel.count >= currentLabel.count + 6
        case .workspace:
            return false
        }
    }

    private func labelPriority(_ kind: AgentTaskLabelKind) -> Int {
        switch kind {
        case .workspace: 0
        case .prompt: 1
        case .title: 2
        }
    }

    /// Returns a privacy-safe projection for UI and health scheduling. Muting only
    /// suppresses attention states; resumed work remains eligible for health cues.
    public func applyingAttentionMutes(
        _ mutedSessionKeys: Set<AgentSessionKey>
    ) -> AgentStateReducer {
        var projected = self
        for key in mutedSessionKeys {
            guard let phase = projected.sessions[key]?.phase,
                  phase == .waitingForInput || phase == .failed else {
                continue
            }
            projected.sessions[key]?.phase = .idle
        }
        return projected
    }

    public var aggregatePhase: AgentPhase {
        if sessions.values.contains(where: { $0.phase == .waitingForInput || $0.phase == .failed }) {
            return .waitingForInput
        }
        if sessions.values.contains(where: { $0.phase == .working && !$0.isSignalStale }) {
            return .working
        }
        return .idle
    }

    public var hasFailedSessions: Bool {
        sessions.values.contains { $0.phase == .failed }
    }

    public var hasActiveSessions: Bool {
        sessions.values.contains {
            ($0.phase == .working && !$0.isSignalStale)
                || $0.phase == .waitingForInput
                || $0.phase == .failed
        }
    }

    public var isHealthOpportunityActive: Bool {
        sessions.values.contains(where: { $0.phase == .working && !$0.isSignalStale })
            && !sessions.values.contains(where: {
                $0.phase == .waitingForInput || $0.phase == .failed
            })
    }

    public func qualifyingDuration(at date: Date) -> TimeInterval {
        sessions.values
            .filter { $0.phase == .working && !$0.isSignalStale }
            .map { max(0, date.timeIntervalSince($0.phaseStartedAt)) }
            .max() ?? 0
    }

    /// Restores sessions carried over from a previous run, dropping anything
    /// that cannot still be alive — a session last heard from before the
    /// machine booted is gone no matter what it was doing. Timestamps are
    /// kept as they were, so the inactivity clock keeps running from the last
    /// real event rather than restarting at launch.
    public mutating func restore(
        _ restored: [AgentSessionKey: SessionState],
        notBefore: Date
    ) {
        for (key, session) in restored where session.lastEventAt >= notBefore {
            sessions[key] = session
        }
    }

    @discardableResult
    public mutating func cleanupStaleSessions(
        at now: Date,
        activeTimeout: TimeInterval = 2 * 60 * 60,
        terminalRetention: TimeInterval = 5 * 60,
        // Providers report liveness per turn and per tool launch, so a single
        // long tool run — a full test suite, a slow model call — is silent
        // the whole time it works. Ten minutes cut those off mid-run and told
        // the user their agent had stopped while it was still going.
        inactivityTimeout: TimeInterval = 30 * 60
    ) -> Int {
        for (key, session) in sessions where session.phase == .working {
            if now.timeIntervalSince(session.lastEventAt) >= inactivityTimeout {
                sessions[key]?.isSignalStale = true
            }
        }
        let previousCount = sessions.count
        sessions = sessions.filter { _, session in
            let age = now.timeIntervalSince(session.lastEventAt)
            switch session.phase {
            case .working, .waitingForInput:
                return age < activeTimeout
            case .idle, .failed, .done:
                return age < terminalRetention
            }
        }
        return previousCount - sessions.count
    }
}
