import Foundation

/// Locates the tmux pane hosting an agent session, so "Open task" lands on
/// the pane the agent is actually in rather than whatever pane happened to be
/// active. An agent inside tmux sees the *pane's* pty, which is never a tab of
/// Terminal.app or iTerm2 — so without this step the exact-tab return silently
/// degrades to app activation for every multiplexer user, which is most people
/// running several agents at once.
///
/// Parsing is pure and lives here; the shelling out lives in the app target.
/// Both lookups are addressed by tmux's own `%pane` / `$session` identifiers
/// rather than `session:window.pane` names: a session named
/// `perch probe: weird name` breaks name-based targeting outright (measured
/// 2026-10-22 on tmux 3.7b — `attach -t` with a colon in the name fails).
public enum TmuxPaneLocator {
    /// One pane row from `list-panes -a -F '#{pane_tty}\t#{pane_id}\t#{session_id}'`.
    public struct Pane: Equatable {
        public let ttyName: String
        public let paneID: String
        public let sessionID: String

        public init(ttyName: String, paneID: String, sessionID: String) {
            self.ttyName = ttyName
            self.paneID = paneID
            self.sessionID = sessionID
        }
    }

    /// Where to land: select this pane, then focus the terminal tab the
    /// attached client occupies. `clientTTYName` is nil when the session is
    /// detached — selecting the pane is still worth doing so a later attach
    /// arrives in the right place, but the caller must fall back for focus.
    public struct Route: Equatable {
        public let paneID: String
        public let sessionID: String
        public let clientTTYName: String?

        public init(paneID: String, sessionID: String, clientTTYName: String?) {
            self.paneID = paneID
            self.sessionID = sessionID
            self.clientTTYName = clientTTYName
        }
    }

    public static func parsePanes(_ output: String) -> [Pane] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let tty = ttyName(fromDevicePath: String(fields[0])),
                  isIdentifier(String(fields[1]), sigil: "%"),
                  isIdentifier(String(fields[2]), sigil: "$")
            else { return nil }
            return Pane(
                ttyName: tty,
                paneID: String(fields[1]),
                sessionID: String(fields[2])
            )
        }
    }

    /// `list-clients -F '#{client_tty}\t#{session_id}'` → session id to the
    /// tty of the terminal tab showing it. First client wins: a session shown
    /// in two tabs is ambiguous and guessing twice is worse than guessing once.
    public static func parseClients(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let tty = ttyName(fromDevicePath: String(fields[0])),
                  isIdentifier(String(fields[1]), sigil: "$")
            else { continue }
            if map[String(fields[1])] == nil { map[String(fields[1])] = tty }
        }
        return map
    }

    public static func route(
        forAgentTTYName ttyName: String,
        panes: String,
        clients: String
    ) -> Route? {
        guard let pane = parsePanes(panes).first(where: { $0.ttyName == ttyName })
        else { return nil }
        return Route(
            paneID: pane.paneID,
            sessionID: pane.sessionID,
            clientTTYName: parseClients(clients)[pane.sessionID]
        )
    }

    /// `/dev/ttys005` → `ttys005`. Rejects anything that is not a plain tty
    /// device so no value from tmux output can reach an AppleScript string.
    public static func ttyName(fromDevicePath path: String) -> String? {
        let name = path.hasPrefix("/dev/") ? String(path.dropFirst(5)) : path
        guard (5 ... 16).contains(name.count),
              name.hasPrefix("ttys"),
              name.dropFirst(4).allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return name
    }

    private static func isIdentifier(_ value: String, sigil: Character) -> Bool {
        guard value.count >= 2, value.first == sigil else { return false }
        return value.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
}
