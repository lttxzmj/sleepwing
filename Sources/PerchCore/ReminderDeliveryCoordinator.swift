import Foundation

public enum ReminderDeliveryChannel: Equatable, Sendable {
    case companion
    case systemNotification
}

public enum ReminderDeliveryDeferral: Equatable, Sendable {
    case attentionRequired
    case quietHours
    case reminderAlreadyVisible
    case noAvailableChannel
}

public enum ReminderDeliveryDecision: Equatable, Sendable {
    case deliver(ReminderDeliveryChannel)
    case deferred(ReminderDeliveryDeferral)
}

public struct ReminderDeliveryContext: Equatable, Sendable {
    public let companionAvailable: Bool
    public let systemNotificationAvailable: Bool
    public let attentionRequired: Bool
    public let quietHoursActive: Bool
    public let reminderAlreadyVisible: Bool

    public init(
        companionAvailable: Bool,
        systemNotificationAvailable: Bool,
        attentionRequired: Bool,
        quietHoursActive: Bool,
        reminderAlreadyVisible: Bool
    ) {
        self.companionAvailable = companionAvailable
        self.systemNotificationAvailable = systemNotificationAvailable
        self.attentionRequired = attentionRequired
        self.quietHoursActive = quietHoursActive
        self.reminderAlreadyVisible = reminderAlreadyVisible
    }
}

public struct PendingReminderDelivery: Codable, Equatable, Identifiable, Sendable {
    public let recordID: UUID
    public let kind: ReminderKind
    public let dueAt: Date

    public var id: UUID { recordID }

    public init(recordID: UUID, kind: ReminderKind, dueAt: Date) {
        self.recordID = recordID
        self.kind = kind
        self.dueAt = dueAt
    }
}

public struct ReminderDeliveryCoordinator: Sendable {
    public static let defaultSnoozeInterval: TimeInterval = 10 * 60
    public private(set) var pendingSnoozes: [PendingReminderDelivery]

    public init(pendingSnoozes: [PendingReminderDelivery] = []) {
        self.pendingSnoozes = pendingSnoozes.sorted { $0.dueAt < $1.dueAt }
    }

    public func decision(for context: ReminderDeliveryContext) -> ReminderDeliveryDecision {
        if context.attentionRequired {
            return .deferred(.attentionRequired)
        }
        if context.quietHoursActive {
            return .deferred(.quietHours)
        }
        if context.reminderAlreadyVisible {
            return .deferred(.reminderAlreadyVisible)
        }
        if context.companionAvailable {
            return .deliver(.companion)
        }
        if context.systemNotificationAvailable {
            return .deliver(.systemNotification)
        }
        return .deferred(.noAvailableChannel)
    }

    public mutating func scheduleSnooze(
        recordID: UUID,
        kind: ReminderKind,
        at now: Date,
        interval: TimeInterval = defaultSnoozeInterval
    ) {
        pendingSnoozes.removeAll { $0.recordID == recordID }
        pendingSnoozes.append(PendingReminderDelivery(
            recordID: recordID,
            kind: kind,
            dueAt: now.addingTimeInterval(max(0, interval))
        ))
        pendingSnoozes.sort { $0.dueAt < $1.dueAt }
    }

    public func dueSnooze(at now: Date) -> PendingReminderDelivery? {
        pendingSnoozes.first { $0.dueAt <= now }
    }

    public mutating func markDelivered(recordID: UUID) {
        pendingSnoozes.removeAll { $0.recordID == recordID }
    }

    public mutating func cancel(recordID: UUID) {
        pendingSnoozes.removeAll { $0.recordID == recordID }
    }

    public mutating func retainPending(
        validRecordIDs: Set<UUID>,
        dueAfter cutoff: Date
    ) {
        pendingSnoozes.removeAll {
            !validRecordIDs.contains($0.recordID) || $0.dueAt < cutoff
        }
    }
}
