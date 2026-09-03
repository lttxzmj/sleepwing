import Foundation
import IOKit.ps

final class IdleSleepProtectionController {
    private var activity: (any NSObjectProtocol)?

    var isActive: Bool {
        activity != nil
    }

    func update(shouldPreventIdleSystemSleep: Bool) {
        if shouldPreventIdleSystemSleep {
            guard activity == nil else { return }
            // .idleSystemSleepDisabled alone (like `caffeinate -i`) keeps the
            // system from suspending but leaves the display's own idle timeout
            // running, so it still turns off on schedule. Disable both so the
            // screen actually stays on while a verified agent is working.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "A verified local AI agent is working"
            )
        } else {
            release()
        }
    }

    static var hasLowBatteryWarning: Bool {
        IOPSGetBatteryWarningLevel() != kIOPSLowBatteryWarningNone
    }

    private func release() {
        guard let activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

}
