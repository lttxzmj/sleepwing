import Foundation

/// Resolves which terminal app should receive a "resume this session"
/// hand-off, and how that terminal accepts a command. Perch must not
/// hardcode any one terminal: the user's terminal is whatever they
/// actually use, so resolution ranks live signals (last activation,
/// running apps) above static defaults.
public enum TerminalHostPolicy {
    /// How a terminal can be handed a shell command to run.
    public enum LaunchStrategy: Equatable, Sendable {
        /// The app registers .command documents (Terminal, iTerm2):
        /// opening the script file runs it inside the app.
        case commandFile
        /// The app exposes a stable CLI: launch a new instance with
        /// argument templates ({dir} and {command} are substituted).
        case appArguments([String])
        /// The app can neither open .command files nor exec an
        /// arbitrary command from launch arguments (Warp): fall back
        /// to the system default handler.
        case unsupported
    }

    public struct KnownTerminal: Equatable, Sendable {
        public let bundleID: String
        public let launch: LaunchStrategy

        public init(bundleID: String, launch: LaunchStrategy) {
            self.bundleID = bundleID
            self.launch = launch
        }
    }

    /// Argument templates come from each terminal's documented, long-stable
    /// CLI; they run the command through a login shell so the user's PATH
    /// applies, matching the .command script's `#!/bin/zsh -l`.
    public static let knownTerminals: [KnownTerminal] = [
        KnownTerminal(bundleID: "com.apple.Terminal", launch: .commandFile),
        KnownTerminal(bundleID: "com.googlecode.iterm2", launch: .commandFile),
        KnownTerminal(bundleID: "dev.warp.Warp-Stable", launch: .unsupported),
        KnownTerminal(
            bundleID: "org.alacritty",
            launch: .appArguments([
                "--working-directory", "{dir}",
                "-e", "/bin/zsh", "-lc", "{command}",
            ])
        ),
        KnownTerminal(
            bundleID: "net.kovidgoyal.kitty",
            launch: .appArguments([
                "--directory", "{dir}",
                "/bin/zsh", "-lc", "{command}",
            ])
        ),
        KnownTerminal(
            bundleID: "com.github.wez.wezterm",
            launch: .appArguments([
                "start", "--cwd", "{dir}",
                "--", "/bin/zsh", "-lc", "{command}",
            ])
        ),
        KnownTerminal(
            bundleID: "com.mitchellh.ghostty",
            launch: .appArguments([
                "--working-directory={dir}",
                "-e", "/bin/zsh", "-lc", "{command}",
            ])
        ),
    ]

    public static func isKnownTerminal(_ bundleID: String) -> Bool {
        knownTerminals.contains { $0.bundleID == bundleID }
    }

    /// Picks the terminal most likely to be "the user's terminal".
    /// Priority: the known terminal the user most recently activated,
    /// then the only known terminal running, then the default .command
    /// handler if it is running, then nil (caller uses the system
    /// default handler).
    public static func resolve(
        runningBundleIDs: [String],
        lastActivatedBundleID: String?,
        defaultHandlerBundleID: String?
    ) -> String? {
        let running = runningBundleIDs.filter(isKnownTerminal)
        if let last = lastActivatedBundleID,
           running.contains(last) {
            return last
        }
        if running.count == 1 { return running[0] }
        if let handler = defaultHandlerBundleID,
           running.contains(handler) {
            return handler
        }
        return nil
    }

    /// Returns the launch strategy with templates substituted, or nil
    /// for unknown terminals. `.unsupported` passes through so callers
    /// can fall back explicitly.
    public static func launch(
        bundleID: String,
        directory: String,
        command: String
    ) -> LaunchStrategy? {
        guard let terminal = knownTerminals.first(where: {
            $0.bundleID == bundleID
        }) else { return nil }
        guard case let .appArguments(template) = terminal.launch else {
            return terminal.launch
        }
        let substituted = template.map {
            $0.replacingOccurrences(of: "{dir}", with: directory)
                .replacingOccurrences(of: "{command}", with: command)
        }
        return .appArguments(substituted)
    }
}
