import AppKit
import PerchCore

/// `ttyfocus <ttys###>` — bring the terminal tab (or tmux pane) that owns a
/// tty device to the front.
///
/// This exists as a standalone tool because it is the one hard part of every
/// agent-notification script and nobody publishes it. Three open issues in
/// peon-ping (#573 Ghostty focus, #541 per-window focus colliding on shared
/// cwd, #574 panes swallowing notifications) are requests for exactly this,
/// and the cross-platform notifiers cannot do it because the only reliable
/// mechanism is macOS-native: ask the terminal, by AppleScript, which tab
/// owns the device, and ask tmux which pane does.
///
/// Scope is deliberately narrow and honest: Terminal.app and iTerm2 get true
/// tab selection, tmux gets pane selection plus focus of the attached
/// client's tab, and everything else exits non-zero so the caller can fall
/// back instead of believing a lie.
enum TTYFocus {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let first = arguments.first, !first.hasPrefix("-") else {
            printUsage()
            exit(arguments.isEmpty ? 2 : 0)
        }

        guard let ttyName = TmuxPaneLocator.ttyName(fromDevicePath: first) else {
            FileHandle.standardError.write(Data(
                "ttyfocus: not a tty device name: \(first)\n".utf8
            ))
            exit(2)
        }

        switch focus(ttyName: ttyName) {
        case .tab(let app):
            print("focused \(app) tab owning /dev/\(ttyName)")
            exit(0)
        case .pane(let paneID, let app):
            print("selected tmux pane \(paneID) and focused its \(app) tab")
            exit(0)
        case .paneOnlyDetached(let paneID):
            // Honest partial success: the pane is now the active one, so a
            // later attach lands on it, but nothing was brought to the front.
            print("selected tmux pane \(paneID); its session is detached, nothing to focus")
            exit(3)
        case .notFound:
            FileHandle.standardError.write(Data(
                "ttyfocus: no Terminal.app/iTerm2 tab or tmux pane owns /dev/\(ttyName)\n".utf8
            ))
            exit(1)
        }
    }

    enum Outcome {
        case tab(app: String)
        case pane(paneID: String, app: String)
        case paneOnlyDetached(paneID: String)
        case notFound
    }

    static func focus(ttyName: String) -> Outcome {
        let device = "/dev/\(ttyName)"
        if let app = focusDirectTab(device: device) { return .tab(app: app) }

        guard let tmux = tmuxExecutableURL(),
              let panes = output(of: tmux, [
                  "list-panes", "-a", "-F", "#{pane_tty}\t#{pane_id}\t#{session_id}",
              ]),
              let clients = output(of: tmux, [
                  "list-clients", "-F", "#{client_tty}\t#{session_id}",
              ]),
              let route = TmuxPaneLocator.route(
                  forAgentTTYName: ttyName, panes: panes, clients: clients
              )
        else { return .notFound }

        // Ids are %N / $N, validated by the locator, and reach tmux through
        // argv — never a shell, never an AppleScript string.
        _ = output(of: tmux, ["select-window", "-t", route.paneID])
        _ = output(of: tmux, ["select-pane", "-t", route.paneID])

        guard let clientTTY = route.clientTTYName else {
            return .paneOnlyDetached(paneID: route.paneID)
        }
        if let app = focusDirectTab(device: "/dev/\(clientTTY)") {
            return .pane(paneID: route.paneID, app: app)
        }
        return .paneOnlyDetached(paneID: route.paneID)
    }

    private static func focusDirectTab(device: String) -> String? {
        if isRunning("com.apple.Terminal"), run(appleTerminalScript(device: device)) {
            return "Terminal.app"
        }
        if isRunning("com.googlecode.iterm2"), run(iterm2Script(device: device)) {
            return "iTerm2"
        }
        return nil
    }

    private static func printUsage() {
        print("""
        ttyfocus — focus the terminal tab or tmux pane that owns a tty device.

        usage:  ttyfocus <ttys###|/dev/ttys###>

        exit codes:
          0  a tab was focused (Terminal.app or iTerm2), or a pane was
             selected and its tab focused
          1  nothing owns that device — fall back to activating the app
          2  the argument is not a tty device name
          3  a tmux pane was selected but its session is detached, so
             nothing could be brought to the front

        Typical use, from an agent hook that knows its own tty:
          ttyfocus "$(ps -o tty= -p $PPID | tr -d ' ')" || open -a iTerm

        MIT. Extracted from Sleepwing (https://github.com/lttxzmj/sleepwing),
        which needs it to send you back to the agent that is waiting on you.
        """)
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

    private static func tmuxExecutableURL() -> URL? {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// A wedged tmux server must not hang a notification hook.
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

TTYFocus.main()
