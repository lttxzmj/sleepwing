import Foundation

public enum IntegrationConfigError: Error, Equatable {
    case invalidJSON
    case incompatibleShape
    case existingCodexNotifier
    case existingOpenCodePlugin
    case existingPiExtension
    case unsafeConfiguration
}

public struct CodexIntegrationPlan: Equatable, Sendable {
    public let updatedText: String
    public let previousNotifier: [String]?

    public init(updatedText: String, previousNotifier: [String]?) {
        self.updatedText = updatedText
        self.previousNotifier = previousNotifier
    }
}

public enum IntegrationConfigEditor {
    public static let claudeEvents = [
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Notification",
        "Stop",
        "StopFailure",
        "SessionEnd",
    ]
    public static let cursorEvents = ["beforeSubmitPrompt", "preToolUse", "postToolUse", "afterAgentResponse", "stop", "sessionEnd"]
    public static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop", "SessionEnd"]
    public static let geminiEvents = ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent", "SessionEnd"]
    public static let traeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "Notification"]

    public static func installingClaude(in data: Data?, command: String) throws -> Data {
        var root = try jsonRoot(data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if root["hooks"] != nil, root["hooks"] as? [String: Any] == nil { throw IntegrationConfigError.incompatibleShape }

        for event in claudeEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            if hooks[event] != nil, hooks[event] as? [[String: Any]] == nil { throw IntegrationConfigError.incompatibleShape }
            guard !groups.contains(where: { claudeGroupContains($0, command: command) }) else { continue }
            groups.append([
                "matcher": event == "Notification" ? "permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input" : "",
                "hooks": [["type": "command", "command": command]],
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try encodedJSON(root)
    }

    public static func uninstallingClaude(in data: Data, command: String) throws -> Data {
        var root = try jsonRoot(data)
        guard var hooks = root["hooks"] as? [String: Any] else { return try encodedJSON(root) }
        for event in claudeEvents {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.filter { !claudeGroupContains($0, command: command) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try encodedJSON(root)
    }

    public static func claudeHooksInstalled(in data: Data?, command: String) -> Bool {
        guard let root = try? jsonRoot(data), let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return claudeEvents.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains(where: { claudeGroupContains($0, command: command) })
        }
    }

    public static func installingCursor(in data: Data?, command: String) throws -> Data {
        var root = try jsonRoot(data)
        root["version"] = root["version"] ?? 1
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if root["hooks"] != nil, root["hooks"] as? [String: Any] == nil { throw IntegrationConfigError.incompatibleShape }
        for event in cursorEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            if hooks[event] != nil, hooks[event] as? [[String: Any]] == nil { throw IntegrationConfigError.incompatibleShape }
            if !entries.contains(where: { $0["command"] as? String == command }) {
                entries.append(["command": command])
            }
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return try encodedJSON(root)
    }

    public static func uninstallingCursor(in data: Data, command: String) throws -> Data {
        var root = try jsonRoot(data)
        guard var hooks = root["hooks"] as? [String: Any] else { return try encodedJSON(root) }
        for event in cursorEvents {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = entries.filter { $0["command"] as? String != command }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try encodedJSON(root)
    }

    public static func installingGemini(in data: Data?, command: String) throws -> Data {
        try installingCommandHooks(
            in: data,
            command: command,
            events: geminiEvents,
            includeVersion: false,
            timeout: 5_000
        )
    }

    public static func uninstallingGemini(in data: Data, command: String) throws -> Data {
        try uninstallingCommandHooks(in: data, command: command, events: geminiEvents)
    }

    public static func geminiHooksInstalled(in data: Data?, command: String) -> Bool {
        commandHooksInstalled(in: data, command: command, events: geminiEvents)
    }

    public static func installingTrae(in data: Data?, command: String) throws -> Data {
        try installingCommandHooks(
            in: data,
            command: command,
            events: traeEvents,
            includeVersion: true,
            timeout: 5
        )
    }

    public static func uninstallingTrae(in data: Data, command: String) throws -> Data {
        try uninstallingCommandHooks(in: data, command: command, events: traeEvents)
    }

    public static func traeHooksInstalled(in data: Data?, command: String) -> Bool {
        commandHooksInstalled(in: data, command: command, events: traeEvents)
    }

    public static func installingCodexHooks(in data: Data?, command: String) throws -> Data {
        var root = try jsonRoot(data)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if root["hooks"] != nil, root["hooks"] as? [String: Any] == nil { throw IntegrationConfigError.incompatibleShape }

        for event in codexEvents {
            var groups = hooks[event] as? [[String: Any]] ?? []
            if hooks[event] != nil, hooks[event] as? [[String: Any]] == nil { throw IntegrationConfigError.incompatibleShape }
            guard !groups.contains(where: { commandGroupContains($0, command: command) }) else { continue }
            // Codex caps SessionEnd hook timeouts at three seconds. The
            // local relay is best-effort, so its documented one-second
            // default is sufficient and keeps the generated file valid.
            let timeout = event == "SessionEnd" ? 1 : 5
            groups.append([
                "hooks": [["type": "command", "command": command, "timeout": timeout]],
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try encodedJSON(root)
    }

    public static func uninstallingCodexHooks(in data: Data, command: String) throws -> Data {
        var root = try jsonRoot(data)
        guard var hooks = root["hooks"] as? [String: Any] else { return try encodedJSON(root) }
        for event in codexEvents {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.filter { !commandGroupContains($0, command: command) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try encodedJSON(root)
    }

    public static func codexHooksInstalled(in data: Data?, command: String) -> Bool {
        guard let root = try? jsonRoot(data), let hooks = root["hooks"] as? [String: Any] else { return false }
        return codexEvents.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains(where: { commandGroupContains($0, command: command) })
        }
    }

    public static func installingCodex(in text: String, commandArray: String) throws -> CodexIntegrationPlan {
        let block = "# Perch integration\nnotify = \(commandArray)\n"
        if text.hasPrefix("# Perch integration\n") {
            return CodexIntegrationPlan(updatedText: text, previousNotifier: nil)
        }

        if let range = topLevelNotifyRange(in: text) {
            let originalBlock = String(text[range])
            guard let previous = parseNotifierArguments(from: originalBlock), !previous.isEmpty else {
                throw IntegrationConfigError.existingCodexNotifier
            }
            let encoded = Data(originalBlock.utf8).base64EncodedString()
            let replacement = "# Perch integration\n# Perch previous notify: \(encoded)\nnotify = \(commandArray)\n"
            var updated = text
            updated.replaceSubrange(range, with: replacement)
            return CodexIntegrationPlan(updatedText: updated, previousNotifier: previous)
        }
        return CodexIntegrationPlan(updatedText: text.isEmpty ? block : block + "\n" + text, previousNotifier: nil)
    }

    public static func uninstallingCodex(in text: String, commandArray: String) -> String {
        guard text.hasPrefix("# Perch integration\n") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return text }

        var previousBlock: String?
        var notifyLineIndex = 1
        if lines[1].hasPrefix("# Perch previous notify: ") {
            let encoded = lines[1].dropFirst("# Perch previous notify: ".count)
            if let data = Data(base64Encoded: String(encoded)) {
                previousBlock = String(data: data, encoding: .utf8)
            }
            notifyLineIndex = 2
        }
        guard lines.indices.contains(notifyLineIndex), lines[notifyLineIndex].hasPrefix("notify = ") else { return text }
        let remainderLines = lines.dropFirst(notifyLineIndex + 1)
        var remainder = remainderLines.joined(separator: "\n")
        if previousBlock == nil, remainder.hasPrefix("\n") { remainder.removeFirst() }
        return (previousBlock ?? "") + remainder
    }

    private static func jsonRoot(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw IntegrationConfigError.invalidJSON
            }
            return root
        } catch let error as IntegrationConfigError {
            throw error
        } catch {
            throw IntegrationConfigError.invalidJSON
        }
    }

    private static func encodedJSON(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    private static func claudeGroupContains(_ group: [String: Any], command: String) -> Bool {
        commandGroupContains(group, command: command)
    }

    private static func commandGroupContains(_ group: [String: Any], command: String) -> Bool {
        guard let commands = group["hooks"] as? [[String: Any]] else { return false }
        return commands.contains { $0["type"] as? String == "command" && $0["command"] as? String == command }
    }

    private static func installingCommandHooks(
        in data: Data?,
        command: String,
        events: [String],
        includeVersion: Bool,
        timeout: Int
    ) throws -> Data {
        var root = try jsonRoot(data)
        if includeVersion {
            root["version"] = root["version"] ?? 1
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if root["hooks"] != nil, root["hooks"] as? [String: Any] == nil {
            throw IntegrationConfigError.incompatibleShape
        }
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            if hooks[event] != nil, hooks[event] as? [[String: Any]] == nil {
                throw IntegrationConfigError.incompatibleShape
            }
            if let groupIndex = groups.firstIndex(where: { commandGroupContains($0, command: command) }) {
                var group = groups[groupIndex]
                var commands = group["hooks"] as? [[String: Any]] ?? []
                for commandIndex in commands.indices
                where commands[commandIndex]["type"] as? String == "command"
                    && commands[commandIndex]["command"] as? String == command {
                    commands[commandIndex]["timeout"] = timeout
                }
                group["hooks"] = commands
                groups[groupIndex] = group
            } else {
                groups.append([
                    "matcher": "",
                    "hooks": [["type": "command", "command": command, "timeout": timeout]],
                ])
            }
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try encodedJSON(root)
    }

    private static func uninstallingCommandHooks(
        in data: Data,
        command: String,
        events: [String]
    ) throws -> Data {
        var root = try jsonRoot(data)
        guard var hooks = root["hooks"] as? [String: Any] else { return try encodedJSON(root) }
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let kept = groups.filter { !commandGroupContains($0, command: command) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
        if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
        return try encodedJSON(root)
    }

    private static func commandHooksInstalled(
        in data: Data?,
        command: String,
        events: [String]
    ) -> Bool {
        guard let root = try? jsonRoot(data), let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        return events.allSatisfy { event in
            guard let groups = hooks[event] as? [[String: Any]] else { return false }
            return groups.contains(where: { commandGroupContains($0, command: command) })
        }
    }

    private static func topLevelNotifyRange(in text: String) -> Range<String.Index>? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let tableRegex = try? NSRegularExpression(pattern: "(?m)^\\s*\\[") else {
            return nil
        }
        let tableStart = tableRegex.firstMatch(in: text, range: fullRange)?.range.location ?? fullRange.length
        let topLevelRange = NSRange(location: 0, length: tableStart)
        guard let notifyRegex = try? NSRegularExpression(
            pattern: "(?ms)^\\s*notify\\s*=\\s*\\[.*?\\]\\s*\\n?"
        ) else {
            return nil
        }
        guard let match = notifyRegex.firstMatch(in: text, range: topLevelRange) else { return nil }
        return Range(match.range, in: text)
    }

    private static func parseNotifierArguments(from block: String) -> [String]? {
        guard let open = block.firstIndex(of: "["), let close = block.lastIndex(of: "]"), open < close else { return nil }
        var json = String(block[open...close])
        guard let trailingComma = try? NSRegularExpression(pattern: ",\\s*]") else {
            return nil
        }
        json = trailingComma.stringByReplacingMatches(
            in: json,
            range: NSRange(json.startIndex..<json.endIndex, in: json),
            withTemplate: "]"
        )
        guard let data = json.data(using: .utf8),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return values
    }
}
