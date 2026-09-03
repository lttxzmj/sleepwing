import Foundation

public enum IntegrationEventRecency: Equatable, Sendable {
    case justNow
    case minutes(Int)
    case hours(Int)
    case days(Int)
}

public enum IntegrationEventRecencyPolicy {
    public static func recency(
        lastEventAt: Date,
        now: Date = .now
    ) -> IntegrationEventRecency {
        let elapsed = max(0, now.timeIntervalSince(lastEventAt))
        if elapsed < 60 {
            return .justNow
        }
        if elapsed < 60 * 60 {
            return .minutes(max(1, Int(elapsed / 60)))
        }
        if elapsed < 24 * 60 * 60 {
            return .hours(max(1, Int(elapsed / (60 * 60))))
        }
        return .days(max(1, Int(elapsed / (24 * 60 * 60))))
    }
}
