import Foundation

public struct ReminderExperimentMetrics: Equatable, Sendable {
    public let arm: String
    public let reminderCount: Int
    public let completedCount: Int
    public let completionRate: Double?
    public let averageOpportunityDuration: TimeInterval?

    public init(
        arm: String,
        reminderCount: Int,
        completedCount: Int,
        completionRate: Double?,
        averageOpportunityDuration: TimeInterval?
    ) {
        self.arm = arm
        self.reminderCount = reminderCount
        self.completedCount = completedCount
        self.completionRate = completionRate
        self.averageOpportunityDuration = averageOpportunityDuration
    }
}

public enum ReminderExperimentAnalyzer {
    public static func metrics(
        records: [ReminderRecord],
        arm: String
    ) -> ReminderExperimentMetrics {
        let matching = records.filter { $0.experimentArm == arm }
        let completedCount = matching.filter { $0.response == .completed }.count
        let durations = matching.compactMap(\.opportunityDuration)
        return ReminderExperimentMetrics(
            arm: arm,
            reminderCount: matching.count,
            completedCount: completedCount,
            completionRate: matching.isEmpty
                ? nil
                : Double(completedCount) / Double(matching.count),
            averageOpportunityDuration: durations.isEmpty
                ? nil
                : durations.reduce(0, +) / Double(durations.count)
        )
    }

    public static func medianAttentionResponse(
        records: [AttentionResponseRecord]
    ) -> TimeInterval? {
        let durations = records.map(\.duration).filter { $0 >= 0 }.sorted()
        guard !durations.isEmpty else { return nil }
        let midpoint = durations.count / 2
        if durations.count.isMultiple(of: 2) {
            return (durations[midpoint - 1] + durations[midpoint]) / 2
        }
        return durations[midpoint]
    }
}
