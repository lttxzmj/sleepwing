import AVFoundation

/// Speaks short, already-localized status lines through the on-device
/// synthesizer.
///
/// Announcements queue rather than interrupt: cutting off the previous line
/// is how a busy moment ends up saying nothing useful. The backlog is capped
/// instead, because a pet that keeps talking after the moment has passed is
/// worse than one that skipped a line.
@MainActor
final class AgentVoiceAnnouncer: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var waiting = 0

    /// Beyond this, the oldest lines are stale anyway; the newest one
    /// replaces whatever is still queued.
    private static let backlogLimit = 2

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// `languageCode` nil means the system default voice, matching how
    /// the `.system` app language resolves localized text.
    func announce(_ text: String, languageCode: String?) {
        let utterance = AVSpeechUtterance(string: text)
        if let languageCode {
            utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
        }
        if waiting >= Self.backlogLimit {
            synthesizer.stopSpeaking(at: .immediate)
            waiting = 0
        }
        waiting += 1
        synthesizer.speak(utterance)
    }
}

extension AgentVoiceAnnouncer: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.waiting = max(0, (self?.waiting ?? 0) - 1) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.waiting = max(0, (self?.waiting ?? 0) - 1) }
    }
}
