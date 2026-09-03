import Foundation

public extension AgentProvider {
    /// The product name shown to people. Keep this separate from the host app
    /// because one agent may run in an app, an IDE, or a terminal.
    var brandName: String {
        switch self {
        case .claude: "Claude Code"
        case .cursor: "Cursor"
        case .codex: "ChatGPT"
        case .opencode: "OpenCode"
        case .gemini: "Gemini CLI"
        case .trae: "TRAE"
        case .pi: "Pi"
        }
    }

    /// Known macOS app bundles whose real icon can represent this provider.
    /// CLI-only providers intentionally have no app bundle here.
    var applicationBundleNames: [String] {
        switch self {
        case .claude: ["Claude.app"]
        case .cursor: ["Cursor.app"]
        case .codex: ["ChatGPT.app", "Codex.app"]
        case .opencode: ["OpenCode.app"]
        case .gemini: []
        case .trae: ["TRAE.app", "Trae.app", "Trae CN.app"]
        case .pi: []
        }
    }

    /// A truthful last-resort mark when neither an installed app icon nor a
    /// bundled official brand asset can be loaded.
    var fallbackBrandMark: String {
        switch self {
        case .claude: "✳"
        case .cursor: "C"
        case .codex: "GPT"
        case .opencode: "OC"
        case .gemini: "✦"
        case .trae: "T"
        case .pi: "π"
        }
    }
}
