import AppKit
import PerchCore

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
        // Not a tab tty: the session may be inside a tmux pane, whose pty no
        // terminal owns. Select the pane first, then focus the tab the
        // attached client occupies.
        return focusTmuxPane(agentTTYName: ttyName)
    }

    /// Returns true only when the outer tab was actually focused. Selecting
    /// the pane while the session is detached is still worth doing — a later
    /// attach then lands on the agent — but it is not a focus, so the caller
    /// keeps its app-activation fallback.
    private static func focusTmuxPane(agentTTYName: String) -> Bool {
        guard let tmux = tmuxExecutableURL(),
              let panes = output(of: tmux, [
                  "list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_id}",
              ]),
              let clients = output(of: tmux, [
                  "list-clients", "-F", "#{client_tty}\t#{session_id}",
              ]),
              let route = TmuxPaneLocator.route(
                  forAgentTTYName: agentTTYName, panes: panes, clients: clients
              )
        else { return false }

        // Identifiers are %N / $N, validated by the locator, and go to tmux
        // through argv — never a shell, never an AppleScript string.
        _ = output(of: tmux, ["select-window", "-t", route.paneID])
        _ = output(of: tmux, ["select-pane", "-t", route.paneID])

        guard let clientTTY = route.clientTTYName else { return false }
        let clientDevice = "/dev/\(clientTTY)"
        if isRunning("com.apple.Terminal"),
           run(appleTerminalScript(device: clientDevice)) {
            return true
        }
        if isRunning("com.googlecode.iterm2"),
           run(iterm2Script(device: clientDevice)) {
            return true
        }
        return false
    }

    private static func tmuxExecutableURL() -> URL? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Never blocks the caller for long: tmux answers in milliseconds, and a
    /// wedged server must not freeze a click on "Open task".
    private static func output(of executable: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        // readToEnd() returns nil for an empty stream, and `tmux
        // list-clients` legitimately prints nothing when a session is
        // detached. Treating that as failure made the detached-pane path
        // unreachable, which falsified a claim we had already published.
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8)
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
