import CryptoKit
import Foundation

public struct CanonicalAgentEvent: Codable, Equatable, Sendable {
    public let provider: AgentProvider
    public let sessionID: String
    public let phase: AgentPhase
    public let timestamp: Date
    public let taskLabel: String?
    public let taskLabelKind: AgentTaskLabelKind?
    public let resumeURL: String?

    public init(
        provider: AgentProvider,
        sessionID: String,
        phase: AgentPhase,
        timestamp: Date,
        taskLabel: String? = nil,
        taskLabelKind: AgentTaskLabelKind? = nil,
        resumeURL: String? = nil
    ) {
        self.provider = provider
        self.sessionID = sessionID
        self.phase = phase
        self.timestamp = timestamp
        self.taskLabel = taskLabel
        self.taskLabelKind = taskLabelKind
        self.resumeURL = resumeURL
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case sessionID = "session_id"
        case phase
        case timestamp
        case taskLabel = "task_label"
        case taskLabelKind = "task_label_kind"
        case resumeURL = "resume_url"
    }
}

public enum CanonicalAgentEventError: Error, Equatable {
    case providerMismatch
    case invalidPayload
}

public enum HookPayloadSanitizer {
    public static let maximumRawPayloadBytes = 256 * 1024

    public static func sanitize(
        provider: AgentProvider,
        rawData: Data,
        receivedAt: Date = .now,
        controllingTTY: String? = nil
    ) throws -> Data {
        guard rawData.count <= maximumRawPayloadBytes else {
            throw CanonicalAgentEventError.invalidPayload
        }
        let event = try HookEventAdapter.adapt(provider: provider, data: rawData, receivedAt: receivedAt)
        let taskIdentity = taskIdentity(provider: provider, rawData: rawData)
        let canonical = CanonicalAgentEvent(
            provider: provider,
            sessionID: opaqueSessionID(provider: provider, rawSessionID: event.sessionID),
            phase: event.phase,
            timestamp: receivedAt,
            taskLabel: taskIdentity?.label,
            taskLabelKind: taskIdentity?.kind,
            // Plugin-hosted providers (OpenCode, pi) spawn the relay
            // detached — a new session with no controlling terminal — so
            // the hosting process captures its own tty and ships it in
            // the payload. The process-derived name wins when both exist;
            // either way the value passes the same strict validation.
            resumeURL: resumeURL(
                provider: provider,
                rawSessionID: event.sessionID,
                controllingTTY: controllingTTY ?? payloadControllingTTY(rawData)
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(canonical)
    }

    public static func decodeCanonical(
        expectedProvider: AgentProvider,
        data: Data
    ) throws -> AgentEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let canonical = try? decoder.decode(CanonicalAgentEvent.self, from: data) else {
            throw CanonicalAgentEventError.invalidPayload
        }
        guard canonical.provider == expectedProvider else {
            throw CanonicalAgentEventError.providerMismatch
        }
        return AgentEvent(
            provider: canonical.provider,
            sessionID: canonical.sessionID,
            phase: canonical.phase,
            timestamp: canonical.timestamp,
            taskLabel: AgentTaskLabelNormalizer.normalize(
                canonical.taskLabel,
                kind: canonical.taskLabelKind ?? .title
            ),
            taskLabelKind: canonical.taskLabelKind,
            resumeURL: validatedResumeURL(
                canonical.resumeURL,
                expectedProvider: expectedProvider
            )
        )
    }

    private static func taskIdentity(
        provider: AgentProvider,
        rawData: Data
    ) -> (label: String, kind: AgentTaskLabelKind)? {
        guard let object = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any] else {
            return nil
        }
        let properties = object["properties"] as? [String: Any]
        let info = properties?["info"] as? [String: Any]
        let eventName = (
            object["hook_event_name"] as? String
                ?? object["hookEventName"] as? String
                ?? object["type"] as? String
                ?? ""
        ).lowercased()

        if provider == .opencode,
           let title = object["task_title"] as? String
                ?? info?["title"] as? String
                ?? properties?["title"] as? String,
           let normalized = AgentTaskLabelNormalizer.normalize(title, kind: .title) {
            return (normalized, .title)
        }

        if provider == .codex,
           eventName == "userpromptsubmit",
           let prompt = object["prompt"] as? String
                ?? object["user_prompt"] as? String
                ?? object["userPrompt"] as? String,
           let normalized = AgentTaskLabelNormalizer.normalize(prompt, kind: .prompt) {
            return (normalized, .prompt)
        }

        let workspaceName = object["workspace_name"] as? String
            ?? properties?["workspaceName"] as? String
        if let workspaceName,
           let normalized = AgentTaskLabelNormalizer.normalize(
               workspaceName,
               kind: .workspace
           ) {
            return (normalized, .workspace)
        }

        let cwd = object["cwd"] as? String
            ?? object["workspace_root"] as? String
            ?? properties?["cwd"] as? String
            ?? info?["directory"] as? String
        guard let cwd else { return nil }
        let component = URL(fileURLWithPath: cwd)
            .standardizedFileURL
            .lastPathComponent
        return AgentTaskLabelNormalizer.normalize(component, kind: .workspace)
            .map { ($0, .workspace) }
    }

    private static func resumeURL(
        provider: AgentProvider,
        rawSessionID: String,
        controllingTTY: String?
    ) -> String? {
        if provider == .codex {
            guard rawSessionID != IntegrationVerificationProbe.rawSessionID,
                  isValidResumeRouteComponent(rawSessionID) else {
                return nil
            }
            return "codex://threads/\(rawSessionID)"
        }
        guard let controllingTTY, isValidTerminalTTYName(controllingTTY) else {
            return nil
        }
        return "perch-tty://\(controllingTTY)"
    }

    private static func validatedResumeURL(
        _ value: String?,
        expectedProvider: AgentProvider
    ) -> String? {
        guard let value, let url = URL(string: value) else { return nil }
        if expectedProvider != .codex {
            guard url.scheme == "perch-tty",
                  let host = url.host,
                  url.user == nil,
                  url.password == nil,
                  url.port == nil,
                  url.query == nil,
                  url.fragment == nil,
                  url.path.isEmpty,
                  isValidTerminalTTYName(host),
                  value == "perch-tty://\(host)" else {
                return nil
            }
            return value
        }
        guard url.scheme == "codex",
              url.host == "threads",
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil,
              url.path.hasPrefix("/"),
              isValidResumeRouteComponent(String(url.path.dropFirst())),
              value == "codex://threads/\(url.path.dropFirst())" else {
            return nil
        }
        return value
    }

    /// Codex currently uses UUID-like thread identifiers. Keep the return
    /// route to one short RFC 3986 unreserved path component so canonical
    /// events cannot smuggle a second route, authority, query, or control
    /// character into `NSWorkspace.open` even if a local token is exposed.
    private static func isValidResumeRouteComponent(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1 ... 256).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (48 ... 57).contains(byte)
                || (65 ... 90).contains(byte)
                || (97 ... 122).contains(byte)
                || byte == 45
                || byte == 46
                || byte == 95
                || byte == 126
        }
    }

    private static func payloadControllingTTY(_ rawData: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let tty = object["tty"] as? String,
              isValidTerminalTTYName(tty) else {
            return nil
        }
        return tty
    }

    /// macOS pseudo-terminal device basenames are `ttys` plus digits.
    /// Anything else is not a routable tab and must never reach the
    /// AppleScript that selects one, so it is rejected at the transport.
    private static func isValidTerminalTTYName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (5 ... 16).contains(bytes.count),
              value.hasPrefix("ttys") else {
            return false
        }
        return bytes.dropFirst(4).allSatisfy { (48 ... 57).contains($0) }
    }

    private static func opaqueSessionID(provider: AgentProvider, rawSessionID: String) -> String {
        let digest = SHA256.hash(data: Data("\(provider.rawValue):\(rawSessionID)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
