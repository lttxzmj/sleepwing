import Darwin
import Foundation
import os
import PerchCore

private let rpcLogger = Logger(subsystem: "app.sleepwing.Perch", category: "pet-chat")

/// Keeps one warm `pi --mode rpc` subprocess for pet chat. Every
/// exchange starts a fresh RPC session (`new_session`) because the
/// model-side prompt already inlines persona and recent transcript —
/// identical semantics to the one-shot CLI, minus the node cold start
/// per message. The channel is conversation-only (`--no-tools`,
/// `--no-session`), the process idles out after a few minutes, and
/// every failure path resolves nil so the caller falls back to the
/// one-shot invocation.
final class PiRpcChatClient: @unchecked Sendable {
    static let shared = PiRpcChatClient()

    private enum Phase {
        case idle
        case awaitingNewSession(String)
        case awaitingPromptAccept(String)
        case awaitingSettle
        case awaitingText(String)
    }

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var buffer = Data()
    private var phase: Phase = .idle
    private var pending: CheckedContinuation<String?, Never>?
    private var pendingPrompt: String?
    private var requestCounter = 0
    private var attempt = 0
    private var idleShutdown: DispatchWorkItem?
    private let idleTimeout: TimeInterval = 180

    func prewarm(binaryPath: String) {
        lock.lock()
        _ = ensureProcessLocked(binaryPath: binaryPath)
        scheduleIdleShutdownLocked()
        lock.unlock()
    }

    /// Single-flight: a second concurrent request resolves nil instead
    /// of interleaving frames on one stdin.
    func reply(
        binaryPath: String,
        prompt: String,
        timeout: TimeInterval
    ) async -> String? {
        // NSLock is unavailable in async bodies; the locked sections
        // live in synchronous helpers instead.
        guard let generation = beginRequest(
            binaryPath: binaryPath,
            prompt: prompt
        ) else { return nil }
        let text = await withCheckedContinuation { continuation in
            lock.lock()
            pending = continuation
            let id = nextIDLocked()
            phase = .awaitingNewSession(id)
            lock.unlock()
            send(PiRpcProtocol.encodeNewSession(id: id))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expire(generation: generation)
            }
        }
        requestFinished()
        return text
    }

    private func beginRequest(binaryPath: String, prompt: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard pending == nil, case .idle = phase,
              ensureProcessLocked(binaryPath: binaryPath) else { return nil }
        attempt += 1
        pendingPrompt = prompt
        return attempt
    }

    private func requestFinished() {
        lock.lock()
        scheduleIdleShutdownLocked()
        lock.unlock()
    }

    /// Safe from any thread; also invoked at app termination.
    func shutdown() {
        lock.lock()
        let continuation = pending
        resetPendingLocked()
        terminateLocked()
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    // MARK: - Process

    private func ensureProcessLocked(binaryPath: String) -> Bool {
        if let process, process.isRunning { return true }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--mode", "rpc", "--no-session", "--no-tools"]
        // Self-mark so Perch's own hooks drop this conversation plumbing.
        var environment = ProcessInfo.processInfo.environment
        environment[PetChatSpawnPolicy.environmentKey] = PetChatSpawnPolicy.environmentValue
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.consume(data)
        }
        process.terminationHandler = { [weak self] finished in
            rpcLogger.notice("pi rpc: exited \(finished.terminationStatus)")
            self?.handleProcessExit()
        }
        do {
            try process.run()
        } catch {
            rpcLogger.notice("pi rpc: failed to launch")
            return false
        }
        rpcLogger.notice("pi rpc: started")
        self.process = process
        stdinHandle = stdin.fileHandleForWriting
        buffer = Data()
        return true
    }

    private func terminateLocked() {
        idleShutdown?.cancel()
        idleShutdown = nil
        if let stdinHandle { try? stdinHandle.close() }
        if let process, process.isRunning { process.terminate() }
        process = nil
        stdinHandle = nil
        buffer = Data()
    }

    private func handleProcessExit() {
        lock.lock()
        let continuation = pending
        resetPendingLocked()
        process = nil
        stdinHandle = nil
        buffer = Data()
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    // MARK: - Protocol flow

    private func consume(_ data: Data) {
        var outgoing: [Data] = []
        var finished: (CheckedContinuation<String?, Never>, String?)?
        lock.lock()
        buffer.append(data)
        for record in PiRpcProtocol.drainRecords(from: &buffer) {
            guard let incoming = PiRpcProtocol.parse(record) else { continue }
            switch incoming {
            case let .response(id, command, success, text):
                switch phase {
                case let .awaitingNewSession(expected)
                    where command == "new_session" && id == expected:
                    if success, let prompt = pendingPrompt {
                        let promptID = nextIDLocked()
                        phase = .awaitingPromptAccept(promptID)
                        outgoing.append(
                            PiRpcProtocol.encodePrompt(id: promptID, message: prompt)
                        )
                    } else {
                        finished = pending.map { ($0, nil) }
                        resetPendingLocked()
                    }
                case let .awaitingPromptAccept(expected)
                    where command == "prompt" && id == expected:
                    if success {
                        phase = .awaitingSettle
                    } else {
                        finished = pending.map { ($0, nil) }
                        resetPendingLocked()
                    }
                case let .awaitingText(expected)
                    where command == "get_last_assistant_text" && id == expected:
                    let cleaned = text?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    finished = pending.map {
                        ($0, cleaned?.isEmpty == false ? cleaned : nil)
                    }
                    resetPendingLocked()
                default:
                    break
                }
            case .agentSettled:
                if case .awaitingSettle = phase {
                    let id = nextIDLocked()
                    phase = .awaitingText(id)
                    outgoing.append(PiRpcProtocol.encodeGetLastAssistantText(id: id))
                }
            }
        }
        lock.unlock()
        for record in outgoing { send(record) }
        if let finished { finished.0.resume(returning: finished.1) }
    }

    private func send(_ record: Data) {
        lock.lock()
        let handle = stdinHandle
        lock.unlock()
        guard let handle else { return }
        do {
            try handle.write(contentsOf: record)
        } catch {
            rpcLogger.notice("pi rpc: write failed, recycling")
            shutdown()
        }
    }

    private func expire(generation: Int) {
        lock.lock()
        guard attempt == generation, pending != nil else {
            lock.unlock()
            return
        }
        rpcLogger.notice("pi rpc: timed out, recycling")
        let continuation = pending
        resetPendingLocked()
        terminateLocked()
        lock.unlock()
        continuation?.resume(returning: nil)
    }

    private func resetPendingLocked() {
        pending = nil
        pendingPrompt = nil
        phase = .idle
    }

    private func scheduleIdleShutdownLocked() {
        idleShutdown?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.shutdownIfIdle() }
        idleShutdown = work
        DispatchQueue.global().asyncAfter(
            deadline: .now() + idleTimeout,
            execute: work
        )
    }

    private func shutdownIfIdle() {
        lock.lock()
        guard pending == nil else {
            lock.unlock()
            return
        }
        rpcLogger.notice("pi rpc: idle, shutting down")
        terminateLocked()
        lock.unlock()
    }

    private func nextIDLocked() -> String {
        requestCounter += 1
        return "req-\(requestCounter)"
    }
}
