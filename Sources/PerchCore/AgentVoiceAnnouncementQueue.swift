import Foundation

/// Collects the asks that arrive while the pet is about to speak, so several
/// agents stopping at once become one sentence instead of a queue that talks
/// over itself. Speaking the newest and dropping the rest loses the very
/// information the announcement exists to carry: how many things want you.
public struct AgentVoiceAnnouncementQueue: Sendable {
    public enum Summary: Equatable, Sendable {
        case nothing
        case one(provider: AgentProvider, isFailure: Bool, taskLabel: String?)
        /// `named` is capped for listenability; `total` always reports the
        /// real number so the count stays honest when the list is trimmed.
        case several(named: [AgentProvider], total: Int, includesFailure: Bool)
    }

    /// Naming more than a few agents out loud stops being a summary and
    /// becomes a list nobody can hold in their head.
    public static let spokenNameLimit = 3

    private var pending: [(provider: AgentProvider, isFailure: Bool, taskLabel: String?)] = []

    public init() {}

    public var isEmpty: Bool { pending.isEmpty }

    /// A second ask from the same agent replaces the first rather than
    /// counting twice: it is still one agent standing there waiting. A
    /// failure outranks a plain wait, so escalation is never spoken down.
    public mutating func enqueue(
        provider: AgentProvider,
        isFailure: Bool,
        taskLabel: String? = nil
    ) {
        if let index = pending.firstIndex(where: { $0.provider == provider }) {
            if isFailure { pending[index].isFailure = true }
            if let taskLabel { pending[index].taskLabel = taskLabel }
            return
        }
        pending.append((provider, isFailure, taskLabel))
    }

    public mutating func flush() -> Summary {
        defer { pending.removeAll() }
        guard let first = pending.first else { return .nothing }
        if pending.count == 1 {
            return .one(
                provider: first.provider,
                isFailure: first.isFailure,
                taskLabel: first.taskLabel
            )
        }
        return .several(
            named: pending.prefix(Self.spokenNameLimit).map(\.provider),
            total: pending.count,
            includesFailure: pending.contains { $0.isFailure }
        )
    }
}
