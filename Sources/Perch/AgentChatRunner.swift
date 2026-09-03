import Foundation
import Darwin
import os
import PerchCore

private let chatLogger = Logger(subsystem: "app.sleepwing.Perch", category: "pet-chat")

/// Runs a one-shot, in-character chat reply through the user's own agent
/// CLI. This engine only runs when the user explicitly selects "My agent"
/// in Settings: the typed message is processed by that agent under its
/// provider's own terms, while Perch itself still opens no network
/// connection and stores nothing.
enum AgentChatRunner {
    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var truncated = false

        func set(_ newData: Data, truncated: Bool) {
            lock.lock()
            data = newData
            self.truncated = truncated
            lock.unlock()
        }

        func get() -> (data: Data, truncated: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, truncated)
        }
    }

    private final class BinaryPathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String: String] = [:]

        func path(for name: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            return paths[name]
        }

        func store(_ path: String, for name: String) {
            lock.lock()
            paths[name] = path
            lock.unlock()
        }
    }

    private static let binaryPaths = BinaryPathCache()
    private static let maximumReplyBytes = 128 * 1024

    /// Resolving through a login shell costs seconds; warm the cache the
    /// moment the chat bubble opens so sending feels immediate.
    static func prewarm(provider: AgentProvider) {
        guard let invocation = PetChatAgentCommand.invocation(
            for: provider,
            prompt: ""
        ) else { return }
        DispatchQueue.global(qos: .utility).async {
            guard let binaryPath = resolveBinary(invocation.binary) else { return }
            if provider == .pi {
                PiRpcChatClient.shared.prewarm(binaryPath: binaryPath)
            }
        }
    }

    static func reply(
        provider: AgentProvider,
        prompt: String,
        timeout: TimeInterval = 35
    ) async -> String? {
        let prompt = PetChatTextPolicy.agentPrompt(prompt)
        guard !prompt.isEmpty else { return nil }
        guard let invocation = PetChatAgentCommand.invocation(
            for: provider,
            prompt: prompt
        ) else { return nil }
        guard let binaryPath = resolveBinary(invocation.binary) else {
            chatLogger.notice("agent chat: \(invocation.binary, privacy: .public) not found in login shell PATH")
            return nil
        }
        if provider == .pi {
            if let text = await PiRpcChatClient.shared.reply(
                binaryPath: binaryPath,
                prompt: prompt,
                timeout: timeout
            ) {
                return text
            }
            chatLogger.notice("agent chat: pi rpc unavailable, using one-shot")
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                process.arguments = invocation.arguments
                // Self-mark so Perch's own hooks drop this conversation
                // plumbing; only real dispatches should reach the inbox.
                var environment = ProcessInfo.processInfo.environment
                environment[PetChatSpawnPolicy.environmentKey] = PetChatSpawnPolicy.environmentValue
                process.environment = environment
                process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
                // A pipe-connected stdin can make CLIs wait for input that
                // never comes; a full stdout pipe would deadlock the child.
                process.standardInput = FileHandle.nullDevice
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    chatLogger.notice("agent chat: failed to launch \(invocation.binary, privacy: .public)")
                    continuation.resume(returning: nil)
                    return
                }
                let output = OutputBox()
                let readGroup = DispatchGroup()
                readGroup.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let capture = drain(
                        stdout.fileHandleForReading,
                        keepingAtMost: maximumReplyBytes
                    )
                    output.set(capture.data, truncated: capture.truncated)
                    readGroup.leave()
                }
                readGroup.enter()
                DispatchQueue.global(qos: .utility).async {
                    // Always drain stderr so a verbose CLI cannot block on a
                    // full pipe. Perch intentionally does not retain it.
                    _ = drain(stderr.fileHandleForReading, keepingAtMost: 0)
                    readGroup.leave()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        chatLogger.notice("agent chat: \(invocation.binary, privacy: .public) timed out after \(Int(timeout))s, terminating")
                        process.terminate()
                        let processIdentifier = process.processIdentifier
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            if process.isRunning {
                                chatLogger.error("agent chat: \(invocation.binary, privacy: .public) ignored termination; killing")
                                _ = Darwin.kill(processIdentifier, SIGKILL)
                            }
                        }
                    }
                }
                process.waitUntilExit()
                readGroup.wait()
                let capture = output.get()
                let outputData = capture.data
                let status = process.terminationStatus
                chatLogger.notice("agent chat: \(invocation.binary, privacy: .public) exited \(status), \(outputData.count) bytes")
                guard status == 0, !capture.truncated else {
                    if capture.truncated {
                        chatLogger.error("agent chat: output exceeded \(maximumReplyBytes) bytes")
                    }
                    continuation.resume(returning: nil)
                    return
                }
                let text = String(data: outputData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text?.isEmpty == false ? text : nil)
            }
        }
    }

    /// Continues reading after the retained prefix is full. This both bounds
    /// memory and keeps the child process from deadlocking on a full pipe.
    private static func drain(
        _ handle: FileHandle,
        keepingAtMost maximumBytes: Int
    ) -> (data: Data, truncated: Bool) {
        var retained = Data()
        var truncated = false
        while true {
            let chunk: Data
            do {
                guard let next = try handle.read(upToCount: 16 * 1024),
                      !next.isEmpty else { break }
                chunk = next
            } catch {
                break
            }
            let available = max(0, maximumBytes - retained.count)
            if available > 0 {
                retained.append(chunk.prefix(available))
            }
            if chunk.count > available {
                truncated = true
            }
        }
        return (retained, truncated)
    }

    /// Fire-and-forget task dispatch: launches the user-designated
    /// agent's CLI and returns as soon as the process starts. The
    /// companion's receipt reports success or failure on exit; the work
    /// itself stays in the agent's own session, reachable through the
    /// dispatch handle — the pet is a messenger, not a terminal.
    static func dispatch(
        provider: AgentProvider,
        prompt: String,
        workingDirectory: URL? = nil,
        continuesSession: Bool = false,
        extraArguments: [String] = [],
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) async -> Bool {
        let invocation = continuesSession
            ? PetChatAgentCommand.continueDispatchInvocation(for: provider, prompt: prompt)
                ?? PetChatAgentCommand.dispatchInvocation(for: provider, prompt: prompt)
            : PetChatAgentCommand.dispatchInvocation(for: provider, prompt: prompt)
        guard let invocation, let binaryPath = resolveBinary(invocation.binary) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binaryPath)
                var arguments = invocation.arguments
                if !extraArguments.isEmpty, !arguments.isEmpty {
                    // The prompt is always the final argv element.
                    arguments.insert(
                        contentsOf: extraArguments,
                        at: arguments.count - 1
                    )
                }
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                    ?? FileManager.default.homeDirectoryForCurrentUser
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { finished in
                    chatLogger.notice("voice dispatch: \(invocation.binary, privacy: .public) exited \(finished.terminationStatus)")
                    onExit?(finished.terminationStatus)
                }
                do {
                    try process.run()
                    continuation.resume(returning: true)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }
    }

    /// Agent CLIs are installed into the user's shell PATH, which a GUI
    /// app does not inherit; a login shell resolves the real location.
    /// Binary names come from `PetChatAgentCommand` constants only.
    private static func resolveBinary(_ name: String) -> String? {
        if let cached = binaryPaths.path(for: name) { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v " + name]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = OutputBox()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let capture = drain(stdout.fileHandleForReading, keepingAtMost: 4 * 1024)
            output.set(capture.data, truncated: capture.truncated)
            readGroup.leave()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if process.isRunning {
                process.terminate()
                let processIdentifier = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if process.isRunning {
                        _ = Darwin.kill(processIdentifier, SIGKILL)
                    }
                }
            }
        }
        process.waitUntilExit()
        readGroup.wait()
        let capture = output.get()
        guard process.terminationStatus == 0, !capture.truncated else { return nil }
        let path = String(
            data: capture.data,
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, !path.isEmpty else { return nil }
        binaryPaths.store(path, for: name)
        return path
    }
}
