import Foundation

public enum ReminderPresentationPolicy {
    /// A health nudge outranks "working" on the companion, so an
    /// unanswered one hid which agents were running for as long as the
    /// user stayed logged in: the only ways out were the three bubble
    /// buttons, a system-notification hand-off that fires solely when the
    /// macOS session goes inactive, or nothing at all. A nudge is a
    /// moment, not a state — once its moment has passed it must yield the
    /// pet back to agent status.
    public static let unansweredLifetime: TimeInterval = 10 * 60

    /// Whether a nudge that was never answered has outlived its moment.
    /// Deliberately the same window as a snooze: if a snoozed reminder
    /// earns a second chance after ten minutes, an ignored one has had
    /// exactly as long to be acted on.
    public static func hasLapsed(
        presentedAt: Date,
        now: Date,
        lifetime: TimeInterval = unansweredLifetime
    ) -> Bool {
        now.timeIntervalSince(presentedAt) >= lifetime
    }
}
