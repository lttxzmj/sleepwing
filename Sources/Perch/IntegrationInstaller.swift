import Foundation
import PerchCore
import Security

enum IntegrationInstallerSecurityError: Error {
    case secureRandomUnavailable
    case invalidToken
}

enum IntegrationStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case failed(String)

    var label: String {
        switch self {
        case .notInstalled: "Not installed"
        case .installed: "Installed"
        case let .failed(message): message
        }
    }
}

struct IntegrationInstaller {
    private static let maximumConfigurationBytes = 2 * 1024 * 1024
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let applicationSupport: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        homeDirectory = fileManager.homeDirectoryForCurrentUser
        applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    var tokenURL: URL {
        applicationSupport.appendingPathComponent("Perch/token", isDirectory: false)
    }

    var relayURL: URL {
        applicationSupport.appendingPathComponent("Perch/bin/perch-hook", isDirectory: false)
    }

    var sanitizerURL: URL {
        applicationSupport.appendingPathComponent("Perch/bin/perch-relay", isDirectory: false)
    }

    var codexWrapperURL: URL {
        applicationSupport.appendingPathComponent("Perch/bin/perch-codex-notify", isDirectory: false)
    }

    func detectedProviders() -> Set<AgentProvider> {
        Set(AgentProvider.allCases.filter(isProviderAvailable))
    }

    func prepareRelay() throws {
        let supportDirectory = tokenURL.deletingLastPathComponent()
        let binDirectory = relayURL.deletingLastPathComponent()
        try ensurePrivateDirectory(supportDirectory)
        try ensurePrivateDirectory(binDirectory)
        if fileManager.fileExists(atPath: tokenURL.path) {
            try ensureRegularFile(tokenURL)
        }
        let currentToken = try? receiverToken()
        if currentToken == nil {
            var bytes = [UInt8](
                repeating: 0,
                count: IntegrationTokenPolicy.randomByteCount
            )
            guard SecRandomCopyBytes(
                kSecRandomDefault,
                bytes.count,
                &bytes
            ) == errSecSuccess else {
                throw IntegrationInstallerSecurityError.secureRandomUnavailable
            }
            let token = bytes.map { String(format: "%02x", $0) }.joined()
            try Data(token.utf8).write(to: tokenURL, options: .atomic)
        }
        try fileManager.setAttributes(
            [.posixPermissions: IntegrationFilePermissions.token],
            ofItemAtPath: tokenURL.path
        )
        guard let bundledSanitizerURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        if !filesMatch(sanitizerURL, bundledSanitizerURL) {
            if fileManager.fileExists(atPath: sanitizerURL.path) {
                try ensureRegularFile(sanitizerURL)
                try fileManager.removeItem(at: sanitizerURL)
            }
            try fileManager.copyItem(at: bundledSanitizerURL, to: sanitizerURL)
        }
        try fileManager.setAttributes(
            [.posixPermissions: IntegrationFilePermissions.executable],
            ofItemAtPath: sanitizerURL.path
        )
        if fileManager.fileExists(atPath: relayURL.path) {
            try ensureRegularFile(relayURL)
        }
        try relayScript.write(to: relayURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: IntegrationFilePermissions.executable],
            ofItemAtPath: relayURL.path
        )
        try upgradeManagedEventIntegrationsIfNeeded()
    }

    func receiverToken() throws -> String {
        let values = try tokenURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size <= 128 else {
            throw IntegrationInstallerSecurityError.invalidToken
        }
        let token = try String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard IntegrationTokenPolicy.isValid(token) else {
            throw IntegrationInstallerSecurityError.invalidToken
        }
        return token
    }

    func status(for provider: AgentProvider) -> IntegrationStatus {
        let command = hookCommand(provider)
        switch provider {
        case .claude:
            guard let data = try? configurationData(at: claudeSettingsURL) else { return .notInstalled }
            return IntegrationConfigEditor.claudeHooksInstalled(in: data, command: command)
                ? .installed
                : .notInstalled
        case .cursor:
            guard let data = try? configurationData(at: cursorSettingsURL) else { return .notInstalled }
            return String(decoding: data, as: UTF8.self).contains(command) ? .installed : .notInstalled
        case .codex:
            guard let text = try? configurationText(at: codexSettingsURL) else { return .notInstalled }
            let hooks = try? configurationData(at: codexHooksURL)
            return text.hasPrefix("# Perch integration\n") && IntegrationConfigEditor.codexHooksInstalled(in: hooks, command: hookCommand(.codex)) ? .installed : .notInstalled
        case .opencode:
            guard let text = try? configurationText(at: openCodePluginURL) else { return .notInstalled }
            return text.hasPrefix("// Perch integration\n") ? .installed : .notInstalled
        case .gemini:
            guard let data = try? configurationData(at: geminiSettingsURL) else { return .notInstalled }
            return IntegrationConfigEditor.geminiHooksInstalled(in: data, command: command)
                ? .installed
                : .notInstalled
        case .trae:
            return traeSettingsURLs.contains { url in
                guard let data = try? configurationData(at: url) else { return false }
                return IntegrationConfigEditor.traeHooksInstalled(in: data, command: command)
            } ? .installed : .notInstalled
        case .pi:
            guard let text = try? configurationText(at: piExtensionURL) else { return .notInstalled }
            return text.hasPrefix("// Perch integration\n") ? .installed : .notInstalled
        }
    }

    func upgradeCodexLifecycleIfNeeded() throws {
        guard let text = try? configurationText(at: codexSettingsURL),
              text.hasPrefix("# Perch integration\n") else { return }
        try prepareRelay()
        let current = try configurationDataIfPresent(at: codexHooksURL)
        let updated = try IntegrationConfigEditor.installingCodexHooks(in: current, command: hookCommand(.codex))
        try writeIfChanged(updated, to: codexHooksURL)
    }

    func upgradeClaudeLifecycleIfNeeded() throws {
        guard let current = try? configurationData(at: claudeSettingsURL),
              String(decoding: current, as: UTF8.self).contains(hookCommand(.claude)) else {
            return
        }
        try prepareRelay()
        let updated = try IntegrationConfigEditor.installingClaude(
            in: current,
            command: hookCommand(.claude)
        )
        try writeIfChanged(updated, to: claudeSettingsURL)
    }

    func install(_ provider: AgentProvider) throws {
        try prepareRelay()
        switch provider {
        case .claude:
            let current = try configurationDataIfPresent(at: claudeSettingsURL)
            let updated = try IntegrationConfigEditor.installingClaude(in: current, command: hookCommand(.claude))
            try write(updated, to: claudeSettingsURL)
        case .cursor:
            let current = try configurationDataIfPresent(at: cursorSettingsURL)
            let updated = try IntegrationConfigEditor.installingCursor(in: current, command: hookCommand(.cursor))
            try write(updated, to: cursorSettingsURL)
        case .codex:
            let current = try configurationTextIfPresent(at: codexSettingsURL) ?? ""
            if !current.hasPrefix("# Perch integration\n") {
                let plan = try IntegrationConfigEditor.installingCodex(in: current, commandArray: codexCommandArray)
                try prepareCodexWrapper(previousNotifier: plan.previousNotifier)
                try write(Data(plan.updatedText.utf8), to: codexSettingsURL)
            }
            let currentHooks = try configurationDataIfPresent(at: codexHooksURL)
            let updatedHooks = try IntegrationConfigEditor.installingCodexHooks(in: currentHooks, command: hookCommand(.codex))
            try writeIfChanged(updatedHooks, to: codexHooksURL)
        case .opencode:
            if let existing = try configurationTextIfPresent(at: openCodePluginURL),
               !existing.hasPrefix("// Perch integration\n") {
                throw IntegrationConfigError.existingOpenCodePlugin
            }
            let plugin = OpenCodePluginRenderer.render(relayPath: relayURL.path)
            try writeIfChanged(Data(plugin.utf8), to: openCodePluginURL)
        case .gemini:
            let current = try configurationDataIfPresent(at: geminiSettingsURL)
            let updated = try IntegrationConfigEditor.installingGemini(in: current, command: hookCommand(.gemini))
            try write(updated, to: geminiSettingsURL)
        case .trae:
            let url = preferredTraeSettingsURL
            let current = try configurationDataIfPresent(at: url)
            let updated = try IntegrationConfigEditor.installingTrae(in: current, command: hookCommand(.trae))
            try write(updated, to: url)
        case .pi:
            if let existing = try configurationTextIfPresent(at: piExtensionURL),
               !existing.hasPrefix("// Perch integration\n") {
                throw IntegrationConfigError.existingPiExtension
            }
            let extensionSource = PiExtensionRenderer.render(relayPath: relayURL.path)
            try writeIfChanged(Data(extensionSource.utf8), to: piExtensionURL)
            // Pi automatically discovers extension files in
            // ~/.pi/agent/extensions. Running `pi install` here would treat
            // this file as a package, mutate Pi's settings, and can block the
            // Perch settings window while Pi resolves it.
        }
    }

    func sendVerificationProbe(_ provider: AgentProvider) throws {
        try prepareRelay()
        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [relayURL.path, provider.rawValue]
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(IntegrationVerificationProbe.rawPayload(for: provider))
        try input.fileHandleForWriting.close()
    }

    func uninstall(_ provider: AgentProvider) throws {
        switch provider {
        case .claude:
            guard let current = try configurationDataIfPresent(at: claudeSettingsURL) else { return }
            let updated = try IntegrationConfigEditor.uninstallingClaude(in: current, command: hookCommand(.claude))
            try write(updated, to: claudeSettingsURL)
        case .cursor:
            guard let current = try configurationDataIfPresent(at: cursorSettingsURL) else { return }
            let updated = try IntegrationConfigEditor.uninstallingCursor(in: current, command: hookCommand(.cursor))
            try write(updated, to: cursorSettingsURL)
        case .codex:
            guard let current = try configurationTextIfPresent(at: codexSettingsURL) else { return }
            let updated = IntegrationConfigEditor.uninstallingCodex(in: current, commandArray: codexCommandArray)
            try write(Data(updated.utf8), to: codexSettingsURL)
            if let currentHooks = try configurationDataIfPresent(at: codexHooksURL) {
                let updatedHooks = try IntegrationConfigEditor.uninstallingCodexHooks(in: currentHooks, command: hookCommand(.codex))
                try writeIfChanged(updatedHooks, to: codexHooksURL)
            }
        case .opencode:
            guard let existing = try configurationTextIfPresent(at: openCodePluginURL),
                  existing.hasPrefix("// Perch integration\n") else { return }
            try fileManager.removeItem(at: openCodePluginURL)
        case .gemini:
            guard let current = try configurationDataIfPresent(at: geminiSettingsURL) else { return }
            let updated = try IntegrationConfigEditor.uninstallingGemini(in: current, command: hookCommand(.gemini))
            try write(updated, to: geminiSettingsURL)
        case .trae:
            for url in traeSettingsURLs {
                guard let current = try configurationDataIfPresent(at: url),
                      IntegrationConfigEditor.traeHooksInstalled(in: current, command: hookCommand(.trae)) else {
                    continue
                }
                let updated = try IntegrationConfigEditor.uninstallingTrae(in: current, command: hookCommand(.trae))
                try write(updated, to: url)
            }
        case .pi:
            guard let existing = try configurationTextIfPresent(at: piExtensionURL),
                  existing.hasPrefix("// Perch integration\n") else { return }
            try fileManager.removeItem(at: piExtensionURL)
        }
    }

    private var piExtensionURL: URL { homeDirectory.appendingPathComponent(".pi/agent/extensions/perch.ts") }
    private var claudeSettingsURL: URL { homeDirectory.appendingPathComponent(".claude/settings.json") }
    private var cursorSettingsURL: URL { homeDirectory.appendingPathComponent(".cursor/hooks.json") }
    private var codexSettingsURL: URL { homeDirectory.appendingPathComponent(".codex/config.toml") }
    private var codexHooksURL: URL { homeDirectory.appendingPathComponent(".codex/hooks.json") }
    private var openCodePluginURL: URL { homeDirectory.appendingPathComponent(".config/opencode/plugins/perch.ts") }
    private var geminiSettingsURL: URL { homeDirectory.appendingPathComponent(".gemini/settings.json") }
    private var traeSettingsURLs: [URL] {
        [
            homeDirectory.appendingPathComponent(".trae/hooks.json"),
            homeDirectory.appendingPathComponent(".trae-cn/hooks.json"),
        ]
    }
    private var preferredTraeSettingsURL: URL {
        let chinese = homeDirectory.appendingPathComponent(".trae-cn")
        return fileManager.fileExists(atPath: chinese.path) ? traeSettingsURLs[1] : traeSettingsURLs[0]
    }

    private func isProviderAvailable(_ provider: AgentProvider) -> Bool {
        let paths: [URL]
        switch provider {
        case .claude:
            paths = [
                homeDirectory.appendingPathComponent(".claude"),
                homeDirectory.appendingPathComponent(".local/bin/claude"),
                URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
                URL(fileURLWithPath: "/usr/local/bin/claude"),
            ]
        case .cursor:
            paths = [
                homeDirectory.appendingPathComponent(".cursor"),
                homeDirectory.appendingPathComponent("Applications/Cursor.app"),
                URL(fileURLWithPath: "/Applications/Cursor.app"),
            ]
        case .codex:
            paths = [
                homeDirectory.appendingPathComponent(".codex"),
                homeDirectory.appendingPathComponent(".local/bin/codex"),
                homeDirectory.appendingPathComponent("Applications/Codex.app"),
                URL(fileURLWithPath: "/Applications/Codex.app"),
                URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
                URL(fileURLWithPath: "/usr/local/bin/codex"),
            ]
        case .opencode:
            paths = [
                homeDirectory.appendingPathComponent(".config/opencode"),
                homeDirectory.appendingPathComponent(".opencode/bin/opencode"),
                homeDirectory.appendingPathComponent(".local/bin/opencode"),
                homeDirectory.appendingPathComponent("Applications/OpenCode.app"),
                URL(fileURLWithPath: "/Applications/OpenCode.app"),
                URL(fileURLWithPath: "/opt/homebrew/bin/opencode"),
                URL(fileURLWithPath: "/usr/local/bin/opencode"),
            ]
        case .gemini:
            paths = [
                homeDirectory.appendingPathComponent(".gemini"),
                homeDirectory.appendingPathComponent(".local/bin/gemini"),
                URL(fileURLWithPath: "/opt/homebrew/bin/gemini"),
                URL(fileURLWithPath: "/usr/local/bin/gemini"),
            ]
        case .trae:
            paths = [
                homeDirectory.appendingPathComponent(".trae"),
                homeDirectory.appendingPathComponent(".trae-cn"),
                homeDirectory.appendingPathComponent("Applications/TRAE.app"),
                URL(fileURLWithPath: "/Applications/TRAE.app"),
                homeDirectory.appendingPathComponent("Applications/Trae.app"),
                URL(fileURLWithPath: "/Applications/Trae.app"),
                homeDirectory.appendingPathComponent("Applications/Trae CN.app"),
                URL(fileURLWithPath: "/Applications/Trae CN.app"),
            ]
        case .pi:
            paths = [
                homeDirectory.appendingPathComponent(".pi/agent"),
                homeDirectory.appendingPathComponent(".local/bin/pi"),
                URL(fileURLWithPath: "/opt/homebrew/bin/pi"),
                URL(fileURLWithPath: "/usr/local/bin/pi"),
            ]
        }
        return paths.contains { fileManager.fileExists(atPath: $0.path) }
    }

    private func hookCommand(_ provider: AgentProvider) -> String {
        "/bin/sh \(shellQuoted(relayURL.path)) \(provider.rawValue)"
    }

    private var codexCommandArray: String {
        let values = ["/bin/sh", codexWrapperURL.path]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let quoted = values.map { value -> String in
            guard let data = try? encoder.encode(value) else { return "\"\"" }
            return String(decoding: data, as: UTF8.self)
        }
        return "[\(quoted.joined(separator: ", "))]"
    }

    private func prepareCodexWrapper(previousNotifier: [String]?) throws {
        var lines = [
            "#!/bin/sh",
            "payload=\"$1\"",
            "/bin/sh \(shellQuoted(relayURL.path)) codex \"$payload\"",
        ]
        if let previousNotifier, let executable = previousNotifier.first {
            let command = ([executable] + previousNotifier.dropFirst()).map(shellQuoted).joined(separator: " ")
            lines.append("\(command) \"$payload\"")
            lines.append("exit $?")
        } else {
            lines.append("exit 0")
        }
        if fileManager.fileExists(atPath: codexWrapperURL.path) {
            try ensureRegularFile(codexWrapperURL)
        }
        try (lines.joined(separator: "\n") + "\n").write(
            to: codexWrapperURL,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes(
            [.posixPermissions: IntegrationFilePermissions.executable],
            ofItemAtPath: codexWrapperURL.path
        )
    }

    private func write(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw IntegrationConfigError.unsafeConfiguration
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let suffix = UUID().uuidString.prefix(8)
            let backup = url.appendingPathExtension("perch-backup-\(formatter.string(from: .now))-\(suffix)")
            try fileManager.copyItem(at: url, to: backup)
            try fileManager.setAttributes(
                [.posixPermissions: IntegrationFilePermissions.configuration],
                ofItemAtPath: backup.path
            )
            pruneBackups(for: url, keep: 10)
        }
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: IntegrationFilePermissions.configuration],
            ofItemAtPath: url.path
        )
    }

    private func pruneBackups(for url: URL, keep: Int) {
        let directory = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".perch-backup-"
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ).filter({ candidate in
            guard candidate.lastPathComponent.hasPrefix(prefix),
                  let values = try? candidate.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ) else {
                return false
            }
            return values.isRegularFile == true
                && values.isSymbolicLink != true
        }) else { return }
        // Older Perch builds may have created backups using the user's umask.
        // Harden all managed backups whenever this configuration is touched,
        // including when the retention limit has not yet been reached.
        for backup in files {
            try? fileManager.setAttributes(
                [.posixPermissions: IntegrationFilePermissions.configuration],
                ofItemAtPath: backup.path
            )
        }
        guard files.count > keep else { return }
        let sorted = files.sorted { urlA, urlB in
            let dateA = (try? urlA.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? urlB.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA > dateB
        }
        for old in sorted.dropFirst(keep) {
            try? fileManager.removeItem(at: old)
        }
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try configurationDataIfPresent(at: url), existing == data { return }
        try write(data, to: url)
    }

    private func upgradeManagedEventIntegrationsIfNeeded() throws {
        if let existing = try? configurationText(at: openCodePluginURL),
           existing.hasPrefix("// Perch integration\n") {
            let plugin = OpenCodePluginRenderer.render(relayPath: relayURL.path)
            try writeIfChanged(Data(plugin.utf8), to: openCodePluginURL)
        }
        if let current = try? configurationData(at: geminiSettingsURL),
           IntegrationConfigEditor.geminiHooksInstalled(
               in: current,
               command: hookCommand(.gemini)
           ) {
            let updated = try IntegrationConfigEditor.installingGemini(
                in: current,
                command: hookCommand(.gemini)
            )
            try writeIfChanged(updated, to: geminiSettingsURL)
        }
        for url in traeSettingsURLs {
            guard let current = try? configurationData(at: url),
                  IntegrationConfigEditor.traeHooksInstalled(
                      in: current,
                      command: hookCommand(.trae)
                  ) else {
                continue
            }
            let updated = try IntegrationConfigEditor.installingTrae(
                in: current,
                command: hookCommand(.trae)
            )
            try writeIfChanged(updated, to: url)
        }
        if let existing = try? configurationText(at: piExtensionURL),
           existing.hasPrefix("// Perch integration\n") {
            let extensionSource = PiExtensionRenderer.render(relayPath: relayURL.path)
            try writeIfChanged(Data(extensionSource.utf8), to: piExtensionURL)
        }
    }

    private func configurationDataIfPresent(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try configurationData(at: url)
    }

    private func configurationTextIfPresent(at url: URL) throws -> String? {
        guard let data = try configurationDataIfPresent(at: url) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw IntegrationConfigError.unsafeConfiguration
        }
        return text
    }

    private func configurationText(at url: URL) throws -> String {
        let data = try configurationData(at: url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw IntegrationConfigError.unsafeConfiguration
        }
        return text
    }

    /// Provider configuration is untrusted local input. Bound it before JSON
    /// or TOML parsing, and never interpret a read failure as an empty file.
    private func configurationData(at url: URL) throws -> Data {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
        } catch {
            throw IntegrationConfigError.unsafeConfiguration
        }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= Self.maximumConfigurationBytes else {
            throw IntegrationConfigError.unsafeConfiguration
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw IntegrationConfigError.unsafeConfiguration
        }
        defer { try? handle.close() }
        var data = Data()
        let readLimit = Self.maximumConfigurationBytes + 1
        while data.count < readLimit {
            let chunk: Data
            do {
                guard let next = try handle.read(
                    upToCount: min(64 * 1024, readLimit - data.count)
                ), !next.isEmpty else {
                    break
                }
                chunk = next
            } catch {
                throw IntegrationConfigError.unsafeConfiguration
            }
            data.append(chunk)
        }
        guard data.count <= Self.maximumConfigurationBytes else {
            throw IntegrationConfigError.unsafeConfiguration
        }
        return data
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func filesMatch(_ first: URL, _ second: URL) -> Bool {
        guard let firstValues = try? first.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              let secondValues = try? second.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              firstValues.isRegularFile == true,
              firstValues.isSymbolicLink != true,
              secondValues.isRegularFile == true,
              secondValues.isSymbolicLink != true,
              firstValues.fileSize == secondValues.fileSize else {
            return false
        }
        return fileManager.contentsEqual(atPath: first.path, andPath: second.path)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw IntegrationConfigError.unsafeConfiguration
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        let finalValues = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard finalValues.isDirectory == true,
              finalValues.isSymbolicLink != true else {
            throw IntegrationConfigError.unsafeConfiguration
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    private func ensureRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw IntegrationConfigError.unsafeConfiguration
        }
    }

    private var bundledSanitizerURL: URL? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "PerchRelay") {
            return bundled
        }
        guard let executable = Bundle.main.executableURL else { return nil }
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("PerchRelay")
        return fileManager.fileExists(atPath: sibling.path) ? sibling : nil
    }

    private var relayScript: String {
        """
        #!/bin/sh
        \(PetChatSpawnPolicy.relayGuard)
        provider="$1"
        case "$provider" in
          claude|cursor|codex|opencode|gemini|trae|pi) ;;
          *) exit 0 ;;
        esac
        if [ "$#" -ge 2 ]; then
          canonical=$(\(shellQuoted(sanitizerURL.path)) "$provider" "$2" 2>/dev/null)
        else
          canonical=$(\(shellQuoted(sanitizerURL.path)) "$provider" 2>/dev/null)
        fi
        [ -n "$canonical" ] || exit 0
        token=$(cat \(shellQuoted(tokenURL.path)) 2>/dev/null)
        /usr/bin/curl --silent --connect-timeout 0.05 --max-time 0.35 --request POST \\
          --header 'Content-Type: application/json' \\
          --header "X-Perch-Token: $token" \\
          --data-binary "$canonical" \\
          "http://127.0.0.1:7534/v1/events/$provider" >/dev/null 2>&1 || true
        exit 0
        """
    }

}
