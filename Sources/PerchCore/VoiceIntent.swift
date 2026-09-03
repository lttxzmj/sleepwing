import Foundation

/// Deterministic intent grammar for the voice bridge. P1 understands two
/// verbs — asking for task status and dispatching a new task to a named
/// (or default) agent; everything else is honestly unrecognized. The
/// grammar stays regex-simple on purpose: predictable and testable.
/// Dictation transcripts carry no punctuation, so separators are
/// optional wherever the agent/message boundary is still unambiguous,
/// and common transcription variants of agent names are folded to
/// canonical tokens. The agent choice is never inferred beyond what the
/// user literally said.
public enum VoiceIntent: Equatable, Sendable {
    case statusQuery
    case dispatch(agentName: String?, message: String)
    case unrecognized

    /// Transcription variants for agent names: Chinese dictation cannot
    /// spell "pi", so it writes 派/皮, and "claude" arrives as 克劳德.
    private static let agentAliases: [(alias: String, canonical: String)] = [
        ("克劳德", "claude"),
        ("派", "pi"),
        ("皮", "pi"),
    ]

    /// First/second-person tokens after a dispatch verb mean the user is
    /// addressing Perch ("告诉我进度", "tell me the status"), not naming
    /// an agent.
    private static let pronounTokens: Set<String> = [
        "me", "us", "我", "我们", "你", "你们", "大家",
    ]

    /// Folds case, inner whitespace ("P I" → "pi"), and known
    /// transcription variants so agent matching sees one shape.
    public static func canonicalAgentToken(_ raw: String) -> String {
        let compact = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
            .lowercased()
        return agentAliases.first { $0.alias == compact }?.canonical ?? compact
    }

    public static func parse(_ text: String) -> VoiceIntent {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing(/\s+/, with: " ")
        guard !trimmed.isEmpty else { return .unrecognized }

        if let match = trimmed.firstMatch(
            of: /^(?:请|麻烦)?\s*(?:派\s*单\s*给|派\s*给|交\s*给|告\s*诉|让|叫)\s*(.+)$/
        ), let dispatch = splitDispatch(String(match.1)) {
            return dispatch
        }
        if let match = trimmed.firstMatch(
            of: /^(?i)(?:please\s+)?(?:tell|ask|dispatch\s+to|send\s+to)\s+([a-z0-9._-]{1,24})[，,：:\s]+(?:to\s+|:\s*)?(.+)$/
        ), let dispatch = dispatchIfViable(
            name: String(match.1), message: String(match.2)
        ) {
            return dispatch
        }
        if let match = trimmed.firstMatch(
            of: /^(?i)(?:派个任务|新任务|new\s+task)[，,：:\s]*(.+)$/
        ) {
            let message = String(match.1)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty {
                return .dispatch(agentName: nil, message: message)
            }
        }

        let lowered = trimmed.lowercased()
        let statusMarkers = [
            "状态", "进度", "跑完", "完成了吗", "怎么样", "在干嘛", "好了吗",
            "status", "progress", "done yet", "finished",
            "how's it going", "how is it going", "what's running",
        ]
        if statusMarkers.contains(where: lowered.contains) {
            return .statusQuery
        }
        return .unrecognized
    }

    /// Carves "agent + message" out of what follows a dispatch verb
    /// without requiring punctuation. Returns nil when no agent boundary
    /// is identifiable — the caller then falls through to other rules
    /// instead of guessing.
    private static func splitDispatch(_ remainder: String) -> VoiceIntent? {
        // Spelled-out names arrive letter by letter ("P I 修复构建").
        if let match = remainder.firstMatch(
            of: /^([A-Za-z]\b(?:\s[A-Za-z]\b)+)[，,：:\s]*(.+)$/
        ) {
            return dispatchIfViable(
                name: String(match.1), message: String(match.2)
            )
        }
        // A latin token is self-delimiting before a CJK message
        // ("派给codex跑一遍测试").
        if let match = remainder.firstMatch(
            of: /^([A-Za-z][A-Za-z0-9._-]{0,23})[，,：:\s]*(.+)$/
        ) {
            return dispatchIfViable(
                name: String(match.1), message: String(match.2)
            )
        }
        // Known transliterations are also self-delimiting ("告诉派修复构建").
        for entry in agentAliases where remainder.hasPrefix(entry.alias) {
            let rest = String(remainder.dropFirst(entry.alias.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "，,：: \t"))
            if !rest.isEmpty {
                return .dispatch(agentName: entry.canonical, message: rest)
            }
        }
        // An arbitrary CJK name still needs a separator; without one the
        // boundary is unknowable and we refuse to guess.
        if let match = remainder.firstMatch(
            of: /^([^，,：:\s]{1,24})[，,：:\s]+(.+)$/
        ) {
            return dispatchIfViable(
                name: String(match.1), message: String(match.2)
            )
        }
        return nil
    }

    /// Whether a dispatch message asks to continue existing work rather
    /// than start fresh — 「继续把测试跑完」 belongs in the session where
    /// that work lives, not in an empty one.
    public static func isContinuation(_ message: String) -> Bool {
        let lowered = message.lowercased()
        let markers = [
            "继续", "接着", "刚才", "顺便",
            "continue", "keep going", "follow up",
        ]
        return markers.contains(where: lowered.contains)
    }

    /// Picks which known project folder a spoken task refers to.
    /// Transcripts garble names ("Purch" for "Perch"), so exact
    /// containment is tried first and a bounded edit-distance window
    /// similarity second. Deterministic; returns nil below the
    /// confidence floor rather than guessing.
    public static func matchProjectName(
        in message: String,
        candidates: [String]
    ) -> String? {
        let haystack = normalizeForMatching(message)
        guard !haystack.isEmpty else { return nil }
        var best: (name: String, score: Double)?
        for candidate in candidates {
            let needle = normalizeForMatching(candidate)
            guard needle.count >= 2 else { continue }
            let score: Double = haystack.contains(needle)
                ? 1.0
                : bestWindowSimilarity(of: needle, in: haystack)
            if score >= 0.75, score > (best?.score ?? 0) {
                best = (candidate, score)
            }
        }
        return best?.name
    }

    private static func normalizeForMatching(_ text: String) -> [Character] {
        Array(
            text.lowercased().unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .map(Character.init)
        )
    }

    /// Highest Levenshtein similarity of `needle` against any
    /// same-length window of `haystack`. Inputs are voice-sized, so the
    /// cubic bound is tiny in practice.
    private static func bestWindowSimilarity(
        of needle: [Character], in haystack: [Character]
    ) -> Double {
        guard haystack.count >= needle.count else {
            return similarity(needle, haystack)
        }
        var best = 0.0
        for start in 0...(haystack.count - needle.count) {
            let window = Array(haystack[start..<(start + needle.count)])
            best = max(best, similarity(needle, window))
        }
        return best
    }

    private static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i]
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current.append(min(previous[j] + 1, current[j - 1] + 1, substitution))
            }
            previous = current
        }
        return 1.0 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    private static func dispatchIfViable(
        name: String, message: String
    ) -> VoiceIntent? {
        let token = canonicalAgentToken(name)
        guard !pronounTokens.contains(token) else { return nil }
        let cleaned = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        return .dispatch(agentName: token, message: cleaned)
    }
}
