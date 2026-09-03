import AVFoundation
import os
import Speech

private let speechLogger = Logger(subsystem: "app.sleepwing.Perch", category: "pet-voice")

/// Push-to-talk speech capture: the microphone and recognizer live only
/// between `start` and `stop` — exactly the span of the user's physical
/// hold. Two on-device pipelines: on macOS 26 the SpeechAnalyzer /
/// SpeechTranscriber model (markedly better with casual speech) is
/// prepared during preflight and preferred; otherwise the legacy
/// SFSpeechRecognizer path with `requiresOnDeviceRecognition`. When the
/// system cannot recognize on-device, capture refuses to start rather
/// than falling back to a server. Nothing is written to disk.
///
/// Deliberately not @MainActor: the audio tap and recognition callbacks
/// arrive on system threads, and closures formed inside a MainActor type
/// inherit its isolation and trip the runtime's queue assertion. All
/// entry points are only ever called from the model on the main thread.
final class SpeechCaptureController {
    enum ProbeResult {
        case ready
        case assetsMissing
        case unsupported
    }

    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProbeResult, Never>?

        init(_ continuation: CheckedContinuation<ProbeResult, Never>) {
            self.continuation = continuation
        }

        func resume(_ result: ProbeResult) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }

    /// Readiness probe that never touches the microphone: synthetic
    /// silence is enough to make the recognizer load (or fail to load)
    /// its on-device model, so missing dictation assets surface at the
    /// moment the user enables the feature instead of mid-conversation.
    static func probeOnDeviceAssets(localeID: String) async -> ProbeResult {
        guard let recognizer = SFSpeechRecognizer(
            locale: Locale(identifier: localeID)
        ), recognizer.supportsOnDeviceRecognition else {
            return .unsupported
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        if let format = AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 8_000
        ) {
            buffer.frameLength = 8_000
            request.append(buffer)
        }
        request.endAudio()
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // The request has already ended its audio, so the task always
            // terminates on its own; the timeout only needs to resume.
            _ = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    let e = error as NSError
                    speechLogger.notice("probe: \(e.domain, privacy: .public)#\(e.code)")
                    once.resume(e.domain == "kLSRErrorDomain" ? .assetsMissing : .ready)
                } else if result?.isFinal == true {
                    once.resume(.ready)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) {
                once.resume(.ready)
            }
        }
    }

    enum CaptureFailure {
        case audioUnavailable
        case assetsMissing
    }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    // macOS 26 pipeline. Preparation runs in a static async context and
    // the results are adopted on the main thread, so the main-thread
    // callers of `start` always read a consistent trio; `modernSession`
    // is availability-erased storage.
    private var modernLocaleID: String?
    private var modernLocale: Locale?
    private var modernFormat: AVAudioFormat?
    private var modernSession: Any?

    /// Hands one tap buffer to AVAudioConverter's @Sendable input block.
    /// The block runs synchronously inside `convert(to:error:)` on the
    /// audio thread that created this box, so the unchecked marker is
    /// factually safe; the box exists only to satisfy the annotation.
    private final class ConverterFeed: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    @available(macOS 26.0, *)
    private final class ModernSession {
        private let analyzer: SpeechAnalyzer
        private let input: AsyncStream<AnalyzerInput>.Continuation
        private let resultsTask: Task<Void, Never>
        private let analysisTask: Task<Void, Never>

        init(
            analyzer: SpeechAnalyzer,
            input: AsyncStream<AnalyzerInput>.Continuation,
            resultsTask: Task<Void, Never>,
            analysisTask: Task<Void, Never>
        ) {
            self.analyzer = analyzer
            self.input = input
            self.resultsTask = resultsTask
            self.analysisTask = analysisTask
        }

        /// Mic released: close the input and let the analyzer finalize so
        /// trailing final results still reach the results loop.
        func finishInput() {
            input.finish()
            let analyzer = self.analyzer
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }

        func cancel() {
            input.finish()
            resultsTask.cancel()
            analysisTask.cancel()
            let analyzer = self.analyzer
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    func modernReady(localeID: String) -> Bool {
        modernLocaleID == localeID && modernLocale != nil && modernFormat != nil
    }

    /// Adopts a prepared macOS 26 pipeline; called on the main thread so
    /// `start` can consult the values synchronously.
    func adoptModernTranscriber(
        localeID: String, locale: Locale, format: AVAudioFormat
    ) {
        modernLocaleID = localeID
        modernLocale = locale
        modernFormat = format
    }

    /// Prepares the macOS 26 transcriber for a locale: support check,
    /// model-asset install (the same system mechanism dictation assets
    /// use), and the analyzer's preferred audio format. Returns nil when
    /// the legacy pipeline should be used instead.
    static func prepareModernTranscriber(
        localeID: String
    ) async -> (locale: Locale, format: AVAudioFormat)? {
        guard #available(macOS 26.0, *) else { return nil }
        guard SpeechTranscriber.isAvailable else { return nil }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: localeID)
        ) else { return nil }
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        var status = await AssetInventory.status(forModules: [transcriber])
        if status == .supported || status == .downloading {
            do {
                if let request = try await AssetInventory.assetInstallationRequest(
                    supporting: [transcriber]
                ) {
                    try await request.downloadAndInstall()
                }
                status = await AssetInventory.status(forModules: [transcriber])
            } catch {
                let e = error as NSError
                speechLogger.notice("modern assets: \(e.domain, privacy: .public)#\(e.code)")
            }
        }
        guard status == .installed else {
            speechLogger.notice("modern transcriber not installed for \(locale.identifier, privacy: .public)")
            return nil
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else { return nil }
        speechLogger.notice("modern transcriber ready: \(locale.identifier, privacy: .public)")
        return (locale, format)
    }

    @available(macOS 26.0, *)
    private func startModern(
        locale: Locale,
        format: AVAudioFormat,
        contextualStrings: [String],
        onPartial: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (CaptureFailure) -> Void
    ) {
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            // The modern pipeline's vocabulary bias: agent and project
            // names are exactly the tokens dispatch depends on. Local,
            // like the rest of recognition.
            let context = AnalysisContext()
            context.contextualStrings = [.general: contextualStrings]
            Task { try? await analyzer.setContext(context) }
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        speechLogger.notice("modern capture start: rate=\(inputFormat.sampleRate) -> \(format.sampleRate)")
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: format) else {
            Task { @MainActor in onFailure(.audioUnavailable) }
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            let ratio = format.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: capacity
            ) else { return }
            let feed = ConverterFeed(buffer)
            var conversionError: NSError?
            converter.convert(to: converted, error: &conversionError) { _, outStatus in
                guard let next = feed.take() else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return next
            }
            if conversionError == nil, converted.frameLength > 0 {
                continuation.yield(AnalyzerInput(buffer: converted))
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Task { @MainActor in onFailure(.audioUnavailable) }
            return
        }
        let resultsTask = Task {
            // Progressive transcription: finalized segments accumulate
            // and the volatile tail is re-spoken until it finalizes.
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    let piece = String(result.text.characters)
                    let text = finalized + piece
                    if result.isFinal { finalized = text }
                    speechLogger.notice("modern partial: \(text.count) chars final=\(result.isFinal)")
                    Task { @MainActor in onPartial(text) }
                }
            } catch {
                let e = error as NSError
                speechLogger.notice("modern recognition error: \(e.domain, privacy: .public)#\(e.code)")
            }
        }
        let analysisTask = Task {
            do {
                try await analyzer.start(inputSequence: stream)
            } catch {
                let e = error as NSError
                speechLogger.notice("modern analyzer error: \(e.domain, privacy: .public)#\(e.code)")
                Task { @MainActor in onFailure(.audioUnavailable) }
            }
        }
        modernSession = ModernSession(
            analyzer: analyzer,
            input: continuation,
            resultsTask: resultsTask,
            analysisTask: analysisTask
        )
    }

    static func supportsOnDevice(localeID: String) -> Bool {
        guard let recognizer = SFSpeechRecognizer(
            locale: Locale(identifier: localeID)
        ) else { return false }
        return recognizer.supportsOnDeviceRecognition
    }

    func start(
        localeID: String,
        contextualStrings: [String] = [],
        onPartial: @escaping @MainActor (String) -> Void,
        onFailure: @escaping @MainActor (CaptureFailure) -> Void
    ) {
        stop()
        if #available(macOS 26.0, *), modernReady(localeID: localeID),
           let modernLocale, let modernFormat {
            startModern(
                locale: modernLocale,
                format: modernFormat,
                contextualStrings: contextualStrings,
                onPartial: onPartial,
                onFailure: onFailure
            )
            return
        }
        guard let recognizer = SFSpeechRecognizer(
            locale: Locale(identifier: localeID)
        ), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            Task { @MainActor in onFailure(.audioUnavailable) }
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        // Domain words (agent names) the acoustic model would otherwise
        // mangle; the biasing happens inside the on-device recognizer,
        // so nothing leaves this Mac.
        request.contextualStrings = contextualStrings
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        speechLogger.notice("capture start: rate=\(format.sampleRate) ch=\(format.channelCount) onDevice=\(recognizer.supportsOnDeviceRecognition)")
        guard format.sampleRate > 0 else {
            Task { @MainActor in onFailure(.audioUnavailable) }
            return
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            Task { @MainActor in onFailure(.audioUnavailable) }
            return
        }
        task = recognizer.recognitionTask(with: request) { result, error in
            if let error {
                let e = error as NSError
                speechLogger.notice("recognition error: \(e.domain, privacy: .public)#\(e.code)")
                if e.domain == "kLSRErrorDomain" {
                    // The on-device model asset for this language is not
                    // installed; recognition cannot produce anything.
                    Task { @MainActor in onFailure(.assetsMissing) }
                }
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            speechLogger.notice("partial: \(text.count) chars final=\(result.isFinal)")
            Task { @MainActor in
                onPartial(text)
            }
        }
    }

    /// Stops the microphone but leaves the recognition task alive: final
    /// on-device results (especially Chinese) can trail the release by
    /// most of a second, and cancelling immediately would discard them.
    func finishAudio() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if #available(macOS 26.0, *),
           let session = modernSession as? ModernSession {
            session.finishInput()
            return
        }
        request?.endAudio()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if #available(macOS 26.0, *),
           let session = modernSession as? ModernSession {
            session.cancel()
            modernSession = nil
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
    }
}
