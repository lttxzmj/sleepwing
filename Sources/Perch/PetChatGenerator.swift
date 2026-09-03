import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device small talk for the companion. Uses Apple's Foundation Models
/// framework when the system provides it (macOS 26+ with Apple
/// Intelligence enabled); otherwise callers keep the built-in library
/// line. Nothing here touches the network and no conversation is
/// persisted.
enum PetChatGenerator {
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    static func reply(
        persona: String,
        request: String,
        fallback: String
    ) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: persona)
                let response = try await session.respond(to: request)
                let text = response.content.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                return text.isEmpty ? fallback : text
            } catch {
                return fallback
            }
        }
        #endif
        return fallback
    }
}
