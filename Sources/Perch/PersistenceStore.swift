import Foundation
import PerchCore

enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }
    var locale: Locale {
        switch self {
        case .system: .current
        case .english: Locale(identifier: "en")
        case .simplifiedChinese: Locale(identifier: "zh-Hans")
        }
    }
}

enum ReminderStrategy: String, Codable, CaseIterable, Identifiable {
    case agentAware
    case afterCompletion
    case fixedTimer
    case crossover
    case hybrid

    var id: String { rawValue }
}

enum CompanionRole: String, CaseIterable, Identifiable, Codable {
    case sleepwing
    case cat
    case custom

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case Self.cat.rawValue, "tortoise":
            self = .cat
        case Self.custom.rawValue:
            self = .custom
        default:
            self = .sleepwing
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum CompanionSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }
}

enum CompanionSkin: String, Codable, CaseIterable, Identifiable {
    case mist
    case midnight
    case grove

    var id: String { rawValue }
}

enum CompanionLayer: String, Codable, CaseIterable, Identifiable {
    case floating
    case desktop

    var id: String { rawValue }
}

struct PersistedSnapshot: Codable {
    var policy: ReminderPolicy
    var records: [ReminderRecord]
    var pendingSnoozes: [PendingReminderDelivery]?
    var attentionResponses: [AttentionResponseRecord]?
    var experimentDayArms: [String: String]?
    var waitingDay: Date
    var waitingSeconds: TimeInterval
    var language: AppLanguage?
    var customMessages: [String: [String: String]]?
    var enabledReminderKinds: [String]?
    var waitingHistory: [String: TimeInterval]?
    var providerWorkHistory: [String: [String: TimeInterval]]?
    var completedTaskHistory: [String: [String: Int]]?
    var lastLifecycleEventAt: [String: Date]?
    var strategy: ReminderStrategy?
    var companionVisible: Bool?
    var companionRole: CompanionRole?
    var selectedCustomPetID: String?
    var companionArtVersion: Int?
    var companionSkin: CompanionSkin?
    var companionSize: CompanionSize?
    var companionLayer: CompanionLayer?
    var companionShowsOverFullScreen: Bool?
    var companionMotionEnabled: Bool?
    var companionWindowAnchorEnabled: Bool?
    var preventIdleSleepEnabled: Bool?
    var idleSleepMaxHours: Int?
    var companionChatEnabled: Bool?
    var companionChatUsesOnDeviceModel: Bool?
    var petChatEngine: String?
    var petChatAgent: String?
    var voiceBridgeEnabled: Bool?
    var voiceDispatchDirectory: String?
    var voiceDispatchLastProject: String?
    var onboardingCompleted: Bool?
    var agentAttentionNotificationsEnabled: Bool?
    var agentCompletionNotificationsEnabled: Bool?
    var agentAttentionVoiceEnabled: Bool?
    var agentSessions: [PersistedAgentSession]?
}

/// A live session carried across a restart so the pet does not forget what is
/// running the moment the app relaunches. Deliberately narrower than the
/// in-memory state: the task label and resume route stay in memory and expire
/// with the process, so nothing derived from the session's content is written
/// to disk. A restored task shows unnamed until its next event arrives.
struct PersistedAgentSession: Codable {
    var provider: String
    var sessionID: String
    var phase: String
    var startedAt: Date
    var phaseStartedAt: Date
    var lastEventAt: Date
}

struct PersistenceStore {
    private static let maximumSnapshotBytes = 2 * 1_024 * 1_024
    private let fileURL: URL
    private let fileManager: FileManager
    private let storageAvailable: Bool
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory = base.appendingPathComponent("Perch", isDirectory: true)
        let directoryIsSafe: Bool
        if fileManager.fileExists(atPath: directory.path) {
            let values = try? directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            directoryIsSafe = values?.isDirectory == true
                && values?.isSymbolicLink != true
        } else {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let values = try directory.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                directoryIsSafe = values.isDirectory == true
                    && values.isSymbolicLink != true
            } catch {
                directoryIsSafe = false
            }
        }
        storageAvailable = directoryIsSafe
        if directoryIsSafe {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
        fileURL = directory.appendingPathComponent("data.json")
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> PersistedSnapshot? {
        guard storageAvailable,
              let values = try? fileURL.resourceValues(
                  forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize <= Self.maximumSnapshotBytes,
              let data = boundedData(maximumBytes: Self.maximumSnapshotBytes) else {
            return nil
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
        return try? decoder.decode(PersistedSnapshot.self, from: data)
    }

    func save(_ snapshot: PersistedSnapshot) {
        guard storageAvailable,
              let data = try? encoder.encode(snapshot),
              data.count <= Self.maximumSnapshotBytes else { return }
        do {
            if fileManager.fileExists(atPath: fileURL.path) {
                let values = try fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    return
                }
            }
            try data.write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            return
        }
    }

    private func boundedData(maximumBytes: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        let readLimit = maximumBytes + 1
        while data.count < readLimit {
            let remaining = readLimit - data.count
            guard let chunk = try? handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data.count <= maximumBytes ? data : nil
    }
}
