public enum NotificationHealthStage: Equatable, Sendable {
    case undetermined
    case blocked
    case alertsDisabled
    case ready
}

public enum NotificationHealthPolicy {
    public static func stage(
        authorizationDetermined: Bool,
        authorizationGranted: Bool?,
        alertsEnabled: Bool?
    ) -> NotificationHealthStage {
        guard authorizationDetermined else { return .undetermined }
        guard authorizationGranted == true else { return .blocked }
        guard alertsEnabled != false else { return .alertsDisabled }
        return .ready
    }
}
