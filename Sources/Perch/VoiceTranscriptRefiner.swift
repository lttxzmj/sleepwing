import Foundation
import os
#if canImport(FoundationModels)
import FoundationModels
#endif

private let refinerLogger = Logger(subsystem: "app.sleepwing.Perch", category: "pet-voice")

/// On-device cleanup for voice transcripts before intent parsing: fixes
/// garbled homophones using the known vocabulary (agent and project
/// names) as anchors — "Purch" becomes "Perch" before the grammar ever
/// sees it. Falls back to the raw transcript when Apple Intelligence is
/// unavailable, slow, or produces something implausible; the editable
/// confirmation card remains the final gate either way. Nothing leaves
/// the machine.
enum VoiceTranscriptRefiner {
    static func refine(
        _ transcript: String,
        vocabulary: [String],
        timeout: TimeInterval = 3
    ) async -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else {
                return transcript
            }
            let instructions = """
            你是听写纠错器。修正语音转写里的错字和同音误听，保持原意、语种和长度，\
            不新增内容，不回答问题，不解释。已知专有名词：\
            \(vocabulary.joined(separator: "、"))。只输出修正后的文本。
            """
            let start = Date()
            let cleaned: String? = await withTaskGroup(of: String?.self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try? await session.respond(to: transcript)
                    return response?.content
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            let elapsed = Int(Date().timeIntervalSince(start) * 1000)
            guard let cleaned, !cleaned.isEmpty,
                  cleaned.count <= max(transcript.count * 2, transcript.count + 20)
            else {
                refinerLogger.notice("refiner: pass-through after \(elapsed)ms")
                return transcript
            }
            refinerLogger.notice("refiner: \(transcript.count)->\(cleaned.count) chars in \(elapsed)ms")
            return cleaned
        }
        #endif
        return transcript
    }
}
