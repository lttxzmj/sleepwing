import Foundation

/// Which engine answers the companion's free-form chat.
///
/// `library` never generates text; `onDevice` uses the system's local
/// model when the OS provides one and otherwise behaves like `library`;
/// `agent` hands typed messages to one of the user's own local agent
/// CLIs — an explicit, user-selected exception to Perch's default
/// fully-local behavior.
public enum PetChatEngine: String, CaseIterable, Sendable {
    case library
    case onDevice
    case agent
}

/// Deterministic one-shot CLI invocations for agent-backed chat. Only
/// providers with a documented non-interactive prompt mode are supported,
/// and prompts travel as argv elements — never through shell
/// interpolation.
public enum PetChatAgentCommand {
    public static let supportedProviders: [AgentProvider] = [
        .claude, .codex, .gemini, .opencode, .pi,
    ]

    /// The user's own most recently active agent wins the automatic
    /// choice; the static provider order is only a tie-breaker when no
    /// candidate has any real lifecycle activity yet.
    public static func preferredAgent(
        detected: Set<AgentProvider>,
        lastRealEventAt: [AgentProvider: Date]
    ) -> AgentProvider? {
        let candidates = supportedProviders.filter(detected.contains)
        let mostRecent = candidates
            .compactMap { provider in
                lastRealEventAt[provider].map { (provider, $0) }
            }
            .max { $0.1 < $1.1 }
        return mostRecent?.0 ?? candidates.first
    }

    public static func invocation(
        for provider: AgentProvider,
        prompt: String
    ) -> (binary: String, arguments: [String])? {
        switch provider {
        case .claude: ("claude", ["-p", prompt])
        case .codex: ("codex", ["exec", prompt])
        case .gemini: ("gemini", ["-p", prompt])
        case .opencode: ("opencode", ["run", prompt])
        // --no-session keeps pet chatter out of the user's session
        // list; --no-tools keeps a pure conversation channel from
        // running bash or editing files.
        case .pi: ("pi", ["-p", "--no-session", "--no-tools", prompt])
        default: nil
        }
    }

    /// A resumable handle for a dispatched session so the receipt can
    /// open the work where it actually lives. `arguments` are spliced
    /// into the dispatch argv before the prompt; `resumeCommand` is what
    /// a terminal runs in the same directory to reopen that session
    /// interactively. Only verified CLIs participate; others get a
    /// receipt without a jump.
    public struct DispatchHandle: Equatable, Sendable {
        public let arguments: [String]
        public let resumeCommand: String

        public init(arguments: [String], resumeCommand: String) {
            self.arguments = arguments
            self.resumeCommand = resumeCommand
        }
    }

    public static func dispatchHandle(
        for provider: AgentProvider,
        continued: Bool,
        sessionID: String
    ) -> DispatchHandle? {
        switch provider {
        case .pi:
            continued
                ? DispatchHandle(arguments: [], resumeCommand: "pi --continue")
                : DispatchHandle(
                    arguments: ["--session-id", sessionID],
                    resumeCommand: "pi --session-id '\(sessionID)'"
                )
        case .claude:
            DispatchHandle(arguments: [], resumeCommand: "claude --continue")
        default:
            nil
        }
    }

    /// Continue-the-last-session variants for voice dispatch: the agent
    /// resumes with the full context of the work in flight — what
    /// 「继续把测试跑完」 actually means. Only providers with a verified
    /// headless continue flag are listed; nil falls back to a fresh
    /// session.
    public static func continueDispatchInvocation(
        for provider: AgentProvider,
        prompt: String
    ) -> (binary: String, arguments: [String])? {
        switch provider {
        case .claude:
            ("claude", ["-p", "--continue", "--permission-mode", "acceptEdits", prompt])
        case .pi:
            ("pi", ["-p", "--continue", prompt])
        default:
            nil
        }
    }

    /// One-shot invocations for voice-dispatched work. Unlike a chat
    /// reply, a dispatched task is real work: sessions are kept so the
    /// task lands in the user's own history (resumable, visible to
    /// lifecycle hooks), and providers get their workspace-scoped
    /// autonomy mode where one exists — never a permissions bypass.
    /// Prompts travel as the final argv element, not through a shell.
    public static func dispatchInvocation(
        for provider: AgentProvider,
        prompt: String
    ) -> (binary: String, arguments: [String])? {
        switch provider {
        case .claude: ("claude", ["-p", "--permission-mode", "acceptEdits", prompt])
        case .codex: ("codex", ["exec", "--full-auto", prompt])
        case .gemini: ("gemini", ["-p", prompt])
        case .opencode: ("opencode", ["run", prompt])
        case .pi: ("pi", ["-p", prompt])
        default: nil
        }
    }
}
