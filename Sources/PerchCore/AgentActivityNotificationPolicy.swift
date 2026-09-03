import Foundation

/// Which session lifecycle edge is asking to become a system banner. The
/// companion and menu bar always reflect state; this policy only governs
/// the optional notification that reaches the user after they step away.
public enum AgentActivityNotificationKind: String, CaseIterable, Sendable {
    case completion
    case attention
}

public enum AgentActivityNotificationSuppression: Equatable, Sendable {
    case disabled
    case channelUnavailable
    case quietHours
    case sessionMuted
    case hostAppFrontmost
    case burstWindow
}

public enum AgentActivityNotificationDecision: Equatable, Sendable {
    case deliver
    case suppressed(AgentActivityNotificationSuppression)
}

public struct AgentActivityNotificationContext: Equatable, Sendable {
    public let enabled: Bool
    /// Whether the delivery channel being decided (system banner, spoken
    /// announcement, …) can currently reach the user at all.
    public let channelAvailable: Bool
    public let quietHoursActive: Bool
    public let sessionMuted: Bool
    /// The app hosting this provider's session is already frontmost, so
    /// the user can see the outcome where it happened.
    public let hostAppFrontmost: Bool
    /// Seconds since the last keyboard or mouse input, when known. A
    /// frontmost app with an idle keyboard means the user walked away
    /// mid-screen; nil (unknown) conservatively counts as active.
    public let inputIdleSeconds: TimeInterval?

    public init(
        enabled: Bool,
        channelAvailable: Bool,
        quietHoursActive: Bool,
        sessionMuted: Bool,
        hostAppFrontmost: Bool,
        inputIdleSeconds: TimeInterval? = nil
    ) {
        self.enabled = enabled
        self.channelAvailable = channelAvailable
        self.quietHoursActive = quietHoursActive
        self.sessionMuted = sessionMuted
        self.hostAppFrontmost = hostAppFrontmost
        self.inputIdleSeconds = inputIdleSeconds
    }
}

public struct AgentActivityNotificationPolicy: Sendable {
    /// Parallel completions from one provider collapse into a single
    /// banner per window instead of a burst. Attention edges are never
    /// throttled: each one is an actionable ask.
    public static let completionBurstWindow: TimeInterval = 30

    /// Frontmost only counts as "watching" while there has been input
    /// this recently; beyond it the user is treated as away even though
    /// the hosting app still owns the screen.
    public static let presenceIdleThreshold: TimeInterval = 3 * 60

    /// Spoken follow-ups for an unresolved ask: the first announcement
    /// can be missed from another room, so it repeats on this cadence up
    /// to the cap — but any suppression at fire time (user present,
    /// quiet hours, mute) ends the ladder for good.
    public static let voiceRepeatInterval: TimeInterval = 2 * 60
    public static let voiceMaxAnnouncements = 3

    private var lastCompletionAt: [AgentProvider: Date] = [:]

    public init() {}

    public mutating func decision(
        kind: AgentActivityNotificationKind,
        provider: AgentProvider,
        context: AgentActivityNotificationContext,
        at now: Date
    ) -> AgentActivityNotificationDecision {
        guard context.enabled else { return .suppressed(.disabled) }
        guard context.channelAvailable else {
            return .suppressed(.channelUnavailable)
        }
        if context.quietHoursActive { return .suppressed(.quietHours) }
        if context.sessionMuted { return .suppressed(.sessionMuted) }
        if context.hostAppFrontmost,
           (context.inputIdleSeconds ?? 0) < Self.presenceIdleThreshold {
            return .suppressed(.hostAppFrontmost)
        }
        if kind == .completion {
            if let last = lastCompletionAt[provider],
               now >= last,
               now.timeIntervalSince(last) < Self.completionBurstWindow {
                return .suppressed(.burstWindow)
            }
            lastCompletionAt[provider] = now
        }
        return .deliver
    }
}
