import Foundation

public enum PerchPetSkillInstallError: Error, Equatable, Sendable {
    case sourceMissing
    case invalidSource
    case unmanagedDestination
    case cannotInstall
}

public struct PerchPetSkillInstallResult: Equatable, Sendable {
    public let installedURLs: [URL]

    public init(installedURLs: [URL]) {
        self.installedURLs = installedURLs
    }
}

public enum PerchPetSkillInstaller {
    public static func shouldShowCodexCreation(
        detectedProviders: Set<AgentProvider>
    ) -> Bool {
        detectedProviders.contains(.codex)
    }

    /// Which detected agents can host pet creation, in the stable
    /// presentation order of `AgentProvider.allCases`. Codex opens a
    /// prefilled task directly; every other agent receives the creation
    /// prompt via the clipboard.
    public static func creationAgents(
        detectedProviders: Set<AgentProvider>
    ) -> [AgentProvider] {
        AgentProvider.allCases.filter { detectedProviders.contains($0) }
    }

    public static func destinationURLs(
        homeDirectory: URL,
        detectedProviders: Set<AgentProvider>
    ) -> [URL] {
        var destinations = [
            homeDirectory
                .appendingPathComponent(".agents", isDirectory: true)
                .appendingPathComponent("skills", isDirectory: true)
                .appendingPathComponent("perch-pet", isDirectory: true),
        ]
        if detectedProviders.contains(.claude) {
            destinations.append(
                homeDirectory
                    .appendingPathComponent(".claude", isDirectory: true)
                    .appendingPathComponent("skills", isDirectory: true)
                    .appendingPathComponent("perch-pet", isDirectory: true)
            )
        }
        return destinations
    }

    public static func install(
        sourceURL: URL,
        homeDirectory: URL,
        detectedProviders: Set<AgentProvider>,
        fileManager: FileManager = .default
    ) throws -> PerchPetSkillInstallResult {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PerchPetSkillInstallError.sourceMissing
        }
        guard isManagedSkill(at: sourceURL, fileManager: fileManager) else {
            throw PerchPetSkillInstallError.invalidSource
        }

        let destinations = destinationURLs(
            homeDirectory: homeDirectory,
            detectedProviders: detectedProviders
        )
        do {
            for destination in destinations {
                try installManagedCopy(
                    sourceURL,
                    to: destination,
                    fileManager: fileManager
                )
            }
        } catch let error as PerchPetSkillInstallError {
            throw error
        } catch {
            throw PerchPetSkillInstallError.cannotInstall
        }
        return PerchPetSkillInstallResult(installedURLs: destinations)
    }

    private static func installManagedCopy(
        _ sourceURL: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destination.path),
           !isManagedSkill(at: destination, fileManager: fileManager) {
            throw PerchPetSkillInstallError.unmanagedDestination
        }

        let staging = parent.appendingPathComponent(
            ".perch-pet-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        let backup = parent.appendingPathComponent(
            ".perch-pet-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.copyItem(at: sourceURL, to: staging)

        var movedExisting = false
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: backup)
                movedExisting = true
            }
            try fileManager.moveItem(at: staging, to: destination)
            if movedExisting {
                try? fileManager.removeItem(at: backup)
            }
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                try? fileManager.removeItem(at: staging)
            }
            if movedExisting,
               !fileManager.fileExists(atPath: destination.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: destination)
            }
            throw error
        }
    }

    private static func isManagedSkill(
        at directory: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directory.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return false
        }
        let skillURL = directory.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: skillURL, encoding: .utf8) else {
            return false
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(12)
            .contains { $0.trimmingCharacters(in: .whitespaces) == "name: perch-pet" }
    }
}
