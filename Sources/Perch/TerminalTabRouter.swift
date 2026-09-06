import AppKit

/// Selects the exact terminal tab hosting an agent session, identified by
/// the session's controlling tty device. Scriptable terminals (Terminal.app,
/// iTerm2) get true tab selection; unscriptable ones fall back to the
/// app-activation path in `PerchModel.focusProvider`.
enum TerminalTabRouter {
    static func focusTab(ttyName: String) -> Bool {
        // Re-validated at the composition site so the type stays safe even
        // if a caller ever bypasses the PerchCore transport validation.
        guard isRoutableTTYName(ttyName) else { return false }
        let device = "/dev/\(ttyName)"
        if isRunning("com.apple.Terminal"),
           run(appleTerminalScript(device: device)) {
            return true
        }
        if isRunning("com.googlecode.iterm2"),
           run(iterm2Script(device: device)) {
            return true
        }
        return false
    }

    private static func isRoutableTTYName(_ value: String) -> Bool {
        (5 ... 16).contains(value.count)
            && value.hasPrefix("ttys")
            && value.dropFirst(4).allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).isEmpty
    }

    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    private static func appleTerminalScript(device: String) -> String {
        """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(device)" then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }

    private static func iterm2Script(device: String) -> String {
        """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(device)" then
                            tell w to select
                            tell t to select
                            tell s to select
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
    }
}
