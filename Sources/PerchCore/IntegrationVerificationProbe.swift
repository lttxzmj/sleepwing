import Foundation

public enum IntegrationVerificationProbe {
    public static let rawSessionID = "perch-local-verification-v1"

    public static func rawPayload(for provider: AgentProvider) -> Data {
        let eventName: String
        switch provider {
        case .claude, .cursor:
            eventName = "SessionEnd"
        case .codex:
            eventName = "SessionStart"
        case .opencode:
            eventName = "SessionDeleted"
        case .gemini, .trae, .pi:
            eventName = "SessionStart"
        }
        return (try? JSONSerialization.data(
            withJSONObject: [
                "hook_event_name": eventName,
                "session_id": rawSessionID,
            ],
            options: [.sortedKeys]
        )) ?? Data()
    }

    public static func expectedOpaqueSessionID(for provider: AgentProvider) -> String {
        guard let canonical = try? HookPayloadSanitizer.sanitize(
            provider: provider,
            rawData: rawPayload(for: provider),
            receivedAt: Date(timeIntervalSince1970: 0)
        ), let event = try? HookPayloadSanitizer.decodeCanonical(
            expectedProvider: provider,
            data: canonical
        ) else {
            return ""
        }
        return event.sessionID
    }

    public static func matches(_ event: AgentEvent) -> Bool {
        event.phase == .idle
            && event.sessionID == expectedOpaqueSessionID(for: event.provider)
    }
}
