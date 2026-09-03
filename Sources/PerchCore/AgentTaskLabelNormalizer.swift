import Foundation

/// Produces a short, human-readable label without letting paths, attachment
/// identifiers, or encoding artifacts leak into the task inbox.
public enum AgentTaskLabelNormalizer {
    public static func normalize(
        _ value: String?,
        kind: AgentTaskLabelKind
    ) -> String? {
        guard var candidate = value?.precomposedStringWithCanonicalMapping else {
            return nil
        }
        if kind == .prompt {
            candidate = promptCandidate(from: candidate) ?? ""
        }
        candidate = decodeEscapesIfNeeded(candidate)
        candidate = stripMarkdownPrefix(candidate)
        candidate = collapseWhitespace(candidate)
        candidate = stripConversationalPrefix(candidate)
        candidate = firstSentence(in: candidate)
        candidate = candidate.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "\"'“”‘’`")
            )
        )

        if kind == .prompt, isGenericContinuation(candidate) {
            return nil
        }
        guard isReadable(candidate, kind: kind) else { return nil }
        let maximumLength: Int
        switch kind {
        case .workspace: maximumLength = 32
        case .prompt: maximumLength = 42
        case .title: maximumLength = 48
        }
        let clipped = String(candidate.prefix(maximumLength))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clipped.isEmpty ? nil : clipped
    }

    private static func promptCandidate(from value: String) -> String? {
        let markers = [
            "## My request for Codex:",
            "My request for Codex:",
            "## 我的请求：",
            "我的请求：",
        ]
        var scoped = value
        for marker in markers {
            if let range = scoped.range(
                of: marker,
                options: [.caseInsensitive, .backwards]
            ) {
                scoped = String(scoped[range.upperBound...])
                break
            }
        }

        for rawLine in scoped.components(separatedBy: .newlines) {
            let line = stripMarkdownPrefix(rawLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !isMetadataLine(line) else { continue }
            return line
        }
        return nil
    }

    private static func isMetadataLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let metadataPrefixes = [
            "files mentioned by the user",
            "image name=",
            "<image",
            "</image",
            "![",
            "file://",
            "/users/",
            "/var/",
            "/private/",
            "codex-clipboard-",
        ]
        if metadataPrefixes.contains(where: lower.hasPrefix) {
            return true
        }
        let attachmentExtensions = [
            ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".pdf",
        ]
        return !line.contains(" ")
            && attachmentExtensions.contains(where: lower.hasSuffix)
    }

    private static func decodeEscapesIfNeeded(_ value: String) -> String {
        var result = value
        if result.contains("%"),
           let decoded = result.removingPercentEncoding,
           !decoded.contains("\u{FFFD}") {
            result = decoded
        }
        guard result.contains("\\u") || result.contains("\\n") else {
            return result
        }
        let literal = "\""
            + result
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            + "\""
        return (try? JSONDecoder().decode(String.self, from: Data(literal.utf8)))
            ?? result
    }

    private static func stripMarkdownPrefix(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first,
              first == "#" || first == ">" || first == "-" || first == "*" {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespaces)
        }
        if result.first?.isNumber == true,
           let delimiter = result.firstIndex(where: { $0 == "." || $0 == "、" }) {
            let prefix = result[..<delimiter]
            if prefix.allSatisfy(\.isNumber) {
                result = String(result[result.index(after: delimiter)...])
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func stripConversationalPrefix(_ value: String) -> String {
        let prefixes = [
            "请帮我", "请你", "麻烦你", "我希望你", "你帮我", "请",
            "please ", "can you ", "could you ",
        ]
        let lower = value.lowercased()
        for prefix in prefixes where lower.hasPrefix(prefix.lowercased()) {
            return String(value.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func firstSentence(in value: String) -> String {
        let terminators = CharacterSet(charactersIn: "。！？!?；;")
        guard let scalarIndex = value.unicodeScalars.firstIndex(where: {
            terminators.contains($0)
        }) else {
            return value
        }
        let boundary = scalarIndex.samePosition(in: value) ?? value.endIndex
        let sentence = String(value[..<boundary])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sentence.count >= 4 ? sentence : value
    }

    private static func isReadable(
        _ value: String,
        kind: AgentTaskLabelKind
    ) -> Bool {
        guard !value.isEmpty,
              !value.contains("\u{FFFD}"),
              !value.contains("\\u"),
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              })
        else {
            return false
        }

        let lower = value.lowercased()
        let invalidFragments = [
            "codex-clipboard-",
            "<image",
            "image name=",
            "file://",
            "/users/",
            "/private/",
            "/var/folders/",
            "â€",
            "ä½",
            "å¥",
            "æµ",
            "è¯",
        ]
        guard !invalidFragments.contains(where: lower.contains) else {
            return false
        }
        guard !lower.contains("://") else { return false }

        let scalars = value.unicodeScalars
        guard scalars.contains(where: {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }) else {
            return false
        }

        if !value.contains(" "),
           value.count >= 16 {
            let identifierCharacters = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "-_.")
            )
            let looksLikeIdentifier = scalars.allSatisfy(identifierCharacters.contains)
            let digitCount = scalars.filter(CharacterSet.decimalDigits.contains).count
            if looksLikeIdentifier && digitCount >= 4 {
                return false
            }
        }

        let fileExtensions = [
            ".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".pdf", ".jsonl",
        ]
        if !value.contains(" "),
           fileExtensions.contains(where: lower.hasSuffix) {
            return false
        }
        return true
    }

    private static func isGenericContinuation(_ value: String) -> Bool {
        let normalized = value
            .lowercased()
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: "。！？!?；;，,")
            ))
        let exactPhrases = [
            "继续", "下一步", "继续下一步", "那你继续", "你继续",
            "那你实现吧", "你实现吧", "实现吧", "执行吧", "开始吧",
            "可以", "好的", "很好", "没问题", "优化一下", "修复一下",
            "continue", "next", "next step", "go ahead", "do it",
            "sounds good", "ok", "okay",
        ]
        return exactPhrases.contains(normalized)
    }
}
