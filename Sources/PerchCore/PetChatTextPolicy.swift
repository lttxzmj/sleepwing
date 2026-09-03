import Foundation

public enum PetChatTextPolicy {
    public static let maximumInputCharacters = 500
    public static let maximumReplyCharacters = 600
    public static let maximumAgentPromptCharacters = 8_000
    public static let retainedExchangeCount = 3

    public static func input(_ value: String) -> String {
        bounded(value, maximumCharacters: maximumInputCharacters)
    }

    public static func reply(_ value: String) -> String {
        bounded(value, maximumCharacters: maximumReplyCharacters)
    }

    public static func agentPrompt(_ value: String) -> String {
        bounded(value, maximumCharacters: maximumAgentPromptCharacters)
    }

    private static func bounded(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        String(
            value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumCharacters)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
