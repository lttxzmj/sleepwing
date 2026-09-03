import Foundation

public struct ProviderDiagnosticSnapshot: Equatable, Sendable {
    public let provider: AgentProvider
    public let connectionStage: IntegrationConnectionStage
    public let lastRealEventAge: TimeInterval?

    public init(
        provider: AgentProvider,
        connectionStage: IntegrationConnectionStage,
        lastRealEventAge: TimeInterval?
    ) {
        self.provider = provider
        self.connectionStage = connectionStage
        self.lastRealEventAge = lastRealEventAge
    }
}

public struct PerchDiagnosticSnapshot: Equatable, Sendable {
    public let appVersion: String
    public let operatingSystemVersion: String
    public let receiverReady: Bool
    public let notificationHealth: NotificationHealthStage
    public let providers: [ProviderDiagnosticSnapshot]
    public let workingTaskCount: Int
    public let attentionTaskCount: Int
    public let failedTaskCount: Int
    public let todayReclaimedMinutes: Int
    public let todayCompletedBreaks: Int
    public let sevenDayReminderCount: Int

    public init(
        appVersion: String,
        operatingSystemVersion: String,
        receiverReady: Bool,
        notificationHealth: NotificationHealthStage,
        providers: [ProviderDiagnosticSnapshot],
        workingTaskCount: Int,
        attentionTaskCount: Int,
        failedTaskCount: Int,
        todayReclaimedMinutes: Int,
        todayCompletedBreaks: Int,
        sevenDayReminderCount: Int
    ) {
        self.appVersion = appVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.receiverReady = receiverReady
        self.notificationHealth = notificationHealth
        self.providers = providers
        self.workingTaskCount = workingTaskCount
        self.attentionTaskCount = attentionTaskCount
        self.failedTaskCount = failedTaskCount
        self.todayReclaimedMinutes = todayReclaimedMinutes
        self.todayCompletedBreaks = todayCompletedBreaks
        self.sevenDayReminderCount = sevenDayReminderCount
    }
}

public enum DiagnosticReportRenderer {
    public static func render(
        _ snapshot: PerchDiagnosticSnapshot,
        generatedAt: Date = .now
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var lines = [
            "PERCH DIAGNOSTIC REPORT",
            "Generated: \(formatter.string(from: generatedAt))",
            "Privacy: contains no prompts, code, responses, tool inputs, file paths, or identifiers.",
            "",
            "[Runtime]",
            "Perch: \(snapshot.appVersion)",
            "macOS: \(snapshot.operatingSystemVersion)",
            "Local receiver: \(snapshot.receiverReady ? "ready" : "unavailable")",
            "Notifications: \(notificationText(snapshot.notificationHealth))",
            "",
            "[Connections]",
        ]
        for provider in snapshot.providers.sorted(by: { $0.provider.rawValue < $1.provider.rawValue }) {
            let age = provider.lastRealEventAge.map(lastEventText) ?? "never received in retained history"
            lines.append(
                "\(providerName(provider.provider)): \(connectionText(provider.connectionStage)); last real event: \(age)"
            )
        }
        lines.append(contentsOf: [
            "",
            "[Current activity]",
            "Working tasks: \(max(0, snapshot.workingTaskCount))",
            "Tasks needing attention: \(max(0, snapshot.attentionTaskCount))",
            "Failed tasks: \(max(0, snapshot.failedTaskCount))",
            "",
            "[Local health summary]",
            "Reclaimed today: \(max(0, snapshot.todayReclaimedMinutes)) min",
            "Breaks completed today: \(max(0, snapshot.todayCompletedBreaks))",
            "Reminders shown in 7 days: \(max(0, snapshot.sevenDayReminderCount))",
            "",
        ])
        return lines.joined(separator: "\n")
    }

    private static func providerName(_ provider: AgentProvider) -> String {
        switch provider {
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .trae: "TRAE"
        case .pi: "Pi"
        }
    }

    private static func connectionText(_ stage: IntegrationConnectionStage) -> String {
        switch stage {
        case .receiverUnavailable: "receiver unavailable"
        case .notConnected: "not connected"
        case .checking: "checking local connection"
        case .checkFailed: "connection check failed"
        case .awaitingRealState: "local connection ready; awaiting real task"
        case .live: "verified by real task"
        }
    }

    private static func notificationText(_ stage: NotificationHealthStage) -> String {
        switch stage {
        case .undetermined: "permission not requested"
        case .blocked: "permission blocked"
        case .alertsDisabled: "permission allowed; banners disabled"
        case .ready: "permission and banners ready"
        }
    }

    private static func lastEventText(_ age: TimeInterval) -> String {
        let elapsed = max(0, age)
        if elapsed < 60 { return "less than 1 min ago" }
        if elapsed < 60 * 60 { return "\(Int(elapsed / 60)) min ago" }
        if elapsed < 24 * 60 * 60 { return "\(Int(elapsed / (60 * 60))) hr ago" }
        return "\(Int(elapsed / (24 * 60 * 60))) days ago"
    }

}
