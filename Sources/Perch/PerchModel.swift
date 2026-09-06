import AppKit
import AVFoundation
import Combine
import Speech
import os
import ServiceManagement
import os
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import PerchCore

private let voiceLogger = Logger(subsystem: "app.sleepwing.Perch", category: "pet-voice")
/// Phase transitions were invisible in production, which left "the pet
/// disagrees with my agent" impossible to reproduce after the fact. Provider,
/// phase, and counts only — never a label, path, or anything the session said.
private let stateLogger = Logger(subsystem: "app.sleepwing.Perch", category: "agent-state")

enum ReminderCopyMoment: Equatable {
    case activeWork
    case neutral
}

struct CompanionReminder: Identifiable, Equatable {
    let id: UUID
    let recordID: UUID?
    let kind: ReminderKind
    let qualifyingMinutes: Int
    var moment: ReminderCopyMoment
    var message: String
}

struct ProviderActivitySummary: Identifiable, Equatable {
    let provider: AgentProvider
    let workingCount: Int
    let attentionCount: Int
    let failureCount: Int

    var id: AgentProvider { provider }
}

struct ProviderWorkSummary: Identifiable, Equatable {
    let provider: AgentProvider
    let seconds: TimeInterval

    var id: AgentProvider { provider }
}

struct ReminderKindSummary: Identifiable, Equatable {
    let kind: ReminderKind
    let shown: Int
    let completed: Int

    var id: ReminderKind { kind }
    var completionRate: Double? {
        shown > 0 ? Double(completed) / Double(shown) : nil
    }
}

struct AgentTaskSummary: Identifiable, Equatable {
    let key: AgentSessionKey
    let provider: AgentProvider
    let phase: AgentPhase
    let ordinal: Int
    let startedAt: Date
    let phaseStartedAt: Date
    let isMuted: Bool
    let isSignalStale: Bool
    let taskLabel: String?
    let taskLabelKind: AgentTaskLabelKind?
    let resumeURL: String?

    var id: AgentSessionKey { key }
}

enum DiagnosticExportState: Equatable {
    case idle
    case success(String)
    case failed(String)
}

@MainActor
final class PerchModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// UserNotifications throws NSInternalInconsistencyException when the
    /// process has no real app bundle — exactly what a bare `swift run`
    /// binary is. Every notification-center access funnels through this
    /// guard so the dev binary still runs; reminders then stay in-app.
    private static let systemNotificationsAvailable =
        Bundle.main.bundleIdentifier != nil

    /// UI gate: notification invitations and warnings are meaningless in
    /// the bare dev binary, where authorization can never be requested.
    var systemNotificationsSupported: Bool { Self.systemNotificationsAvailable }

    static let shared = PerchModel()

    @Published private(set) var phase: AgentPhase = .idle
    @Published private(set) var presentationState: CompanionPresentationState = .resting
    @Published var policy = ReminderPolicy() {
        didSet {
            engine.policy = policy
            if listener != nil { needsPersist = true }
        }
    }
    @Published private(set) var todayWaiting: TimeInterval = 0
    @Published private(set) var records: [ReminderRecord] = []
    @Published private(set) var attentionResponses: [AttentionResponseRecord] = []
    @Published private(set) var experimentDayArms: [String: String] = [:]
    @Published private(set) var integrationStatuses: [AgentProvider: IntegrationStatus] = [:]
    @Published private(set) var detectedProviders: Set<AgentProvider> = []
    @Published var language: AppLanguage = .system {
        didSet {
            if listener != nil {
                configureNotificationCategories()
                needsPersist = true
            }
        }
    }
    @Published var customMessages: [String: [String: String]] = [:] {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var enabledReminderKinds: Set<ReminderKind> = Set(ReminderKind.allCases) {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var strategy: ReminderStrategy = .agentAware {
        didSet {
            if activeStrategy == .fixedTimer { fixedPeriodStartedAt = .now }
            if listener != nil {
                recordExperimentArmForToday()
                needsPersist = true
            }
        }
    }
    @Published private(set) var waitingHistory: [String: TimeInterval] = [:]
    @Published private(set) var providerWorkHistory: [String: [String: TimeInterval]] = [:]
    @Published private(set) var completedTaskHistory: [String: [String: Int]] = [:]
    @Published private(set) var mutedSessionKeys: Set<AgentSessionKey> = []
    @Published private(set) var notificationAuthorizationGranted: Bool?
    @Published private(set) var notificationAuthorizationDetermined = false
    @Published private(set) var notificationAlertsEnabled: Bool?
    @Published private(set) var notificationSoundsEnabled: Bool?
    @Published private(set) var diagnosticExportState: DiagnosticExportState = .idle
    @Published private(set) var customPets: [CustomPetDescriptor] = []
    @Published private(set) var customPetStatusMessage: String?
    @Published private(set) var referenceArtURL: URL?
    @Published var petCreationStyle: PetCreationStyle = .faithful
    @Published private(set) var companionChatMessage: String?
    @Published private(set) var demoPresentationState: CompanionPresentationState?
    private var demoTask: Task<Void, Never>?
    @Published private(set) var companionNarration: String?
    private var narrationDismissTask: Task<Void, Never>?
    /// Where voice-dispatched tasks start their agent CLI. Unset means
    /// the home directory — workable for status chat, useless for real
    /// work, which is why the card shows the target folder.
    @Published var voiceDispatchDirectory: URL? {
        didSet { if listener != nil { needsPersist = true } }
    }

    /// The project inside the workspace root the user last dispatched
    /// to; preselected on the next card so consecutive dispatches stay
    /// in one project without re-picking.
    private var voiceDispatchLastProjectPath: String? {
        didSet { if listener != nil { needsPersist = true } }
    }

    @Published var voiceBridgeEnabled = false {
        didSet {
            if listener != nil {
                needsPersist = true
                if voiceBridgeEnabled {
                    preflightVoice()
                } else {
                    voiceReadiness = .unknown
                }
            }
        }
    }

    enum VoiceReadiness: Equatable {
        case unknown
        case checking
        case ready
        case speechDenied
        case micDenied
        case assetsMissing
        case unsupported
    }

    @Published private(set) var voiceReadiness: VoiceReadiness = .unknown
    @Published private(set) var voiceListening = false
    @Published private(set) var voiceFinalizing = false
    @Published private(set) var voiceTranscript = ""

    /// One staged voice utterance awaiting the user's decision on the
    /// composer. An editable draft plus explicit chips for chat vs
    /// dispatch, target agent, and project — voice and typing share it,
    /// parsing only prefills, and the send button is the one
    /// confirmation before anything leaves this Mac.
    struct VoicePendingAction: Equatable {
        /// Send semantics; the parsed verb only preselects.
        enum Mode: Equatable { case chat, dispatch }
        var message: String
        var agent: AgentProvider?
        var directory: URL?
        var continuesSession: Bool = false
        var mode: Mode = .chat
    }

    /// Post-dispatch receipt: one bounded line plus a jump to where the
    /// work actually lives. The pet is a messenger, not a terminal.
    struct VoiceDispatchReceipt: Equatable {
        var message: String
        var resumeCommand: String?
        var directory: URL?
    }

    @Published private(set) var voiceReceipt: VoiceDispatchReceipt?
    private var voiceReceiptDismissTask: Task<Void, Never>?

    @Published private(set) var voicePendingAction: VoicePendingAction?
    private let speechCapture = SpeechCaptureController()
    private var companionChatDismissTask: Task<Void, Never>?
    private var companionChatTranscript: [(user: String, pet: String)] = []
    @Published private(set) var customPetStatusIsError = false
    @Published private(set) var taskReturnNotice: String?
    @Published private(set) var receiverReady = false
    @Published private(set) var lifecycleConnectedProviders: Set<AgentProvider> = []
    @Published private(set) var lastLifecycleEventAt: [AgentProvider: Date] = [:]
    @Published private(set) var relayVerifiedProviders: Set<AgentProvider> = []
    @Published private(set) var verifyingProviders: Set<AgentProvider> = []
    @Published private(set) var verificationFailedProviders: Set<AgentProvider> = []
    @Published private(set) var opportunityStage: HealthOpportunityStage = .inactive
    @Published var companionVisible = true {
        didSet {
            companionController?.setVisible(companionVisible)
            if listener != nil { needsPersist = true }
        }
    }
    @Published var companionRole: CompanionRole = .sleepwing {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var selectedCustomPetID: String? = nil {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var companionSkin: CompanionSkin = .mist {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var companionSize: CompanionSize = .medium {
        didSet {
            companionController?.apply(size: companionSize, layer: companionLayer)
            if listener != nil { needsPersist = true }
        }
    }
    @Published var companionLayer: CompanionLayer = .floating {
        didSet {
            companionController?.apply(size: companionSize, layer: companionLayer)
            if listener != nil { needsPersist = true }
        }
    }
    @Published var companionWindowAnchorEnabled = false {
        didSet { if listener != nil { needsPersist = true } }
    }
    /// Off by default: the pet yields full-screen apps and surfaces over
    /// them only while an agent needs the user (attention-priority).
    @Published var companionShowsOverFullScreen = false {
        didSet {
            updateCompanionSpaceBehavior()
            if listener != nil { needsPersist = true }
        }
    }

    private func updateCompanionSpaceBehavior() {
        companionController?.applySpaceBehavior(
            joinsFullScreen: CompanionWindowPlacement.joinsFullScreenSpaces(
                showsOverFullScreen: companionShowsOverFullScreen,
                phase: phase
            )
        )
    }
    @Published var companionMotionEnabled = true {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var companionChatEnabled = true {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var agentAttentionNotificationsEnabled = true {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var agentCompletionNotificationsEnabled = true {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var agentAttentionVoiceEnabled = false {
        didSet { if listener != nil { needsPersist = true } }
    }
    private var agentActivityNotificationPolicy = AgentActivityNotificationPolicy()
    private let agentVoiceAnnouncer = AgentVoiceAnnouncer()
    private var agentVoiceAnnouncementQueue = AgentVoiceAnnouncementQueue()
    private var agentVoiceAnnouncementTask: Task<Void, Never>?
    private var voiceFollowUpTasks: [AgentSessionKey: Task<Void, Never>] = [:]
    @Published var petChatEngine: PetChatEngine = .onDevice {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published var petChatAgent: AgentProvider? = nil {
        didSet { if listener != nil { needsPersist = true } }
    }
    @Published private(set) var companionChatBusy = false
    @Published var preventIdleSleepEnabled = false {
        didSet {
            if listener != nil {
                updateSleepProtection()
                needsPersist = true
            }
        }
    }
    @Published var idleSleepMaxHours = 4 {
        didSet {
            sleepProtectionGate.maximumContinuousDuration = TimeInterval(idleSleepMaxHours) * 60 * 60
            if listener != nil {
                updateSleepProtection()
                needsPersist = true
            }
        }
    }
    @Published private(set) var sleepProtectionState: IdleSleepProtectionState = .disabled
    @Published private(set) var activeReminder: CompanionReminder?
    /// Set by CompanionWindowController while the panel is perched beside
    /// a working agent's window; not persisted, purely transient UI state.
    @Published var companionIsDocked = false
    @Published var companionDetailsVisible = false
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginNeedsApproval = false
    @Published private(set) var launchAtLoginError: String?
    @Published var onboardingCompleted = false {
        didSet { if listener != nil { needsPersist = true } }
    }

    private var reducer = AgentStateReducer()
    private var codexCompletionGate = CodexCompletionGate()
    private var presentationReducer = CompanionPresentationReducer()
    private var opportunityClock = HealthOpportunityClock()
    private let opportunityLadder = HealthOpportunityLadder()
    private var sleepProtectionGate = IdleSleepProtectionGate()
    private var reminderDeliveryCoordinator = ReminderDeliveryCoordinator()
    private let sleepProtectionController = IdleSleepProtectionController()
    private var engine = ReminderEngine()
    private var listener: LocalEventServer?
    private var receiverRetryTask: Task<Void, Never>?
    private var receiverRecoveryPolicy = LocalReceiverRecoveryPolicy()
    private var receiverGeneration = UUID()
    private var tickTask: Task<Void, Never>?
    private let persistence = PersistenceStore()
    private let integrationInstaller = IntegrationInstaller()
    private var waitingDay = Date()
    private var fixedPeriodStartedAt = Date()
    private var activationObserver: NSObjectProtocol?
    private var powerStateObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var sessionActivityObservers: [NSObjectProtocol] = []
    private var workspaceSessionActive = true
    private var companionController: CompanionWindowController?
    private var lastEventProvider: AgentProvider?
    private var celebrationTask: Task<Void, Never>?
    private var codexCompletionTask: Task<Void, Never>?
    private var verificationTasks: [AgentProvider: Task<Void, Never>] = [:]
    private var customPetRefreshTask: Task<Void, Never>?
    private var attentionStartedAt: [AgentSessionKey: Date] = [:]
    private var taskOrdinals: [AgentSessionKey: Int] = [:]
    private var nextTaskOrdinal: [AgentProvider: Int] = [:]
    private var activityAccountingAt = Date()
    private var needsPersist = false
    override init() {
        super.init()
        if let saved = persistence.load() {
            let retentionCutoff = Calendar.current.date(
                byAdding: .day,
                value: -30,
                to: .now
            ) ?? .distantPast
            let retainedRecords = saved.records.filter {
                $0.triggeredAt >= retentionCutoff
            }
            policy = saved.policy
            records = retainedRecords
            var restoredCoordinator = ReminderDeliveryCoordinator(
                pendingSnoozes: saved.pendingSnoozes ?? []
            )
            restoredCoordinator.retainPending(
                validRecordIDs: Set(retainedRecords.map(\.id)),
                dueAfter: Date.now.addingTimeInterval(-12 * 60 * 60)
            )
            reminderDeliveryCoordinator = restoredCoordinator
            attentionResponses = saved.attentionResponses ?? []
            experimentDayArms = saved.experimentDayArms ?? [:]
            waitingDay = saved.waitingDay
            todayWaiting = Calendar.current.isDateInToday(saved.waitingDay) ? saved.waitingSeconds : 0
            engine = ReminderEngine(policy: saved.policy, records: retainedRecords)
            language = saved.language ?? .system
            customMessages = Self.normalizedCustomMessages(saved.customMessages ?? [:])
            if let savedKinds = saved.enabledReminderKinds {
                let restored = Set(savedKinds.compactMap(ReminderKind.init(rawValue:)))
                enabledReminderKinds = restored.isEmpty ? Set(ReminderKind.allCases) : restored
            }
            waitingHistory = saved.waitingHistory ?? [:]
            providerWorkHistory = saved.providerWorkHistory ?? [:]
            completedTaskHistory = saved.completedTaskHistory ?? [:]
            lastLifecycleEventAt = Dictionary(uniqueKeysWithValues:
                (saved.lastLifecycleEventAt ?? [:]).compactMap { key, value in
                    AgentProvider(rawValue: key).map { ($0, value) }
                }
            )
            strategy = saved.strategy ?? .agentAware
            companionVisible = saved.companionVisible ?? true
            companionRole = (saved.companionArtVersion ?? 0) < 2
                ? .cat
                : (saved.companionRole ?? .sleepwing)
            selectedCustomPetID = saved.selectedCustomPetID
            companionSkin = saved.companionSkin ?? .mist
            companionSize = saved.companionSize ?? .medium
            companionLayer = saved.companionLayer ?? .floating
            companionShowsOverFullScreen = saved.companionShowsOverFullScreen ?? false
            companionMotionEnabled = saved.companionMotionEnabled ?? true
            companionWindowAnchorEnabled = saved.companionWindowAnchorEnabled ?? false
            preventIdleSleepEnabled = saved.preventIdleSleepEnabled ?? false
            companionChatEnabled = saved.companionChatEnabled ?? true
            petChatEngine = saved.petChatEngine.flatMap(PetChatEngine.init(rawValue:))
                ?? ((saved.companionChatUsesOnDeviceModel ?? true) ? .onDevice : .library)
            petChatAgent = saved.petChatAgent.flatMap(AgentProvider.init(rawValue:))
            voiceBridgeEnabled = saved.voiceBridgeEnabled ?? false
            voiceDispatchDirectory = saved.voiceDispatchDirectory
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
            voiceDispatchLastProjectPath = saved.voiceDispatchLastProject
            idleSleepMaxHours = saved.idleSleepMaxHours ?? 4
            onboardingCompleted = saved.onboardingCompleted ?? false
            agentAttentionNotificationsEnabled = saved.agentAttentionNotificationsEnabled ?? true
            agentCompletionNotificationsEnabled = saved.agentCompletionNotificationsEnabled ?? true
            agentAttentionVoiceEnabled = saved.agentAttentionVoiceEnabled ?? false
            // A restart used to wipe every running session, so the pet went
            // quiet while the agents it was watching kept working.
            restoreAgentSessions(saved.agentSessions ?? [])
        }
        if voiceBridgeEnabled {
            // Property observers don't fire during init, so a restored
            // session runs the voice preflight here — otherwise the
            // macOS 26 pipeline would never be prepared after a relaunch.
            preflightVoice()
        }
        if let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           TerminalHostPolicy.isKnownTerminal(frontID) {
            lastActivatedTerminalBundleID = frontID
        }
        // Passive signal for "the user's terminal": remember the known
        // terminal the user most recently brought to the front.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let bundleID = (note.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication)?.bundleIdentifier
            guard let bundleID, TerminalHostPolicy.isKnownTerminal(bundleID)
            else { return }
            Task { @MainActor in
                self?.lastActivatedTerminalBundleID = bundleID
            }
        }
        refreshCustomPets()
        Task { @MainActor [weak self] in await self?.start() }
    }

    var thresholdMinutes: Int {
        get { Int(policy.waitingThreshold / 60) }
        set { policy.waitingThreshold = TimeInterval(newValue * 60); engine.policy = policy }
    }

    var menuBarSymbol: String {
        switch companionPhase {
        case .idle: "cat"
        case .working: "cat.fill"
        case .waitingForInput: "exclamationmark.bubble.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle.fill"
        }
    }

    var menuBarLabelText: String {
        switch companionPresentationState {
        case .needsAttention:
            if attentionSessionCount > 1 {
                return replace(
                    localizedString("menubar.needs_attention_count"),
                    values: ["count": String(attentionSessionCount)]
                )
            }
            return replace(
                localizedString("menubar.provider_waiting"),
                values: ["provider": activeProviderText]
            )
        case .working, .healthOpportunity:
            if workingProviders.count > 1 {
                return replace(
                    localizedString("menubar.running_count"),
                    values: ["count": String(activeSessionCount)]
                )
            }
            return replace(
                localizedString("menubar.provider_running"),
                values: [
                    "provider": activeProviderText,
                    "minutes": String(max(1, Int(longestWorkingDuration / 60))),
                ]
            )
        case .healthNudge:
            return localizedString("menubar.health_nudge")
        case .celebrating:
            return localizedString("menubar.completed")
        case .resting:
            let minutes = Int(todayWaiting / 60)
            if minutes > 0 {
                return replace(
                    localizedString("menubar.recovered"),
                    values: ["minutes": String(minutes)]
                )
            }
            return localizedString("menubar.watching")
        }
    }

    var statusColor: Color {
        switch companionPhase {
        case .idle: .secondary
        case .working: PerchTheme.working
        case .waitingForInput: PerchTheme.attention
        case .failed: PerchTheme.danger
        case .done: PerchTheme.celebration
        }
    }

    var companionAccentColor: Color {
        PerchTheme.palette(for: displayedCompanionRole).accent
    }

    var companionSurfaceColor: Color {
        PerchTheme.palette(for: displayedCompanionRole).surface
    }
    /// Never show an implementation placeholder while a saved custom pet is
    /// still being discovered (or if its package disappears). The selected
    /// built-in cat is the calm visual fallback until discovery resolves.
    var displayedCompanionRole: CompanionRole {
        companionRole == .custom && customPetSpriteURL == nil
            ? .cat
            : companionRole
    }
    var selectedCustomPet: CustomPetDescriptor? {
        guard let selectedCustomPetID else { return nil }
        return customPets.first { $0.id == selectedCustomPetID }
    }
    var customPetSpriteURL: URL? {
        selectedCustomPet?.spritesheetURL
    }
    var codexCustomPetsCount: Int {
        customPets.filter { $0.origin == .codex }.count
    }

    var statusText: String { userStatusTitle }
    var statusDetailText: String? { userStatusDetail }
    var companionPhase: AgentPhase { phase }
    var companionPresentationState: CompanionPresentationState {
        demoPresentationState ?? presentationState
    }
    var codexLifecycleConnected: Bool { lifecycleConnectedProviders.contains(.codex) }
    func lifecycleConnected(_ provider: AgentProvider) -> Bool {
        lifecycleConnectedProviders.contains(provider)
    }
    func relayVerified(_ provider: AgentProvider) -> Bool {
        relayVerifiedProviders.contains(provider)
    }
    func isVerifying(_ provider: AgentProvider) -> Bool {
        verifyingProviders.contains(provider)
    }
    func verificationFailed(_ provider: AgentProvider) -> Bool {
        verificationFailedProviders.contains(provider)
    }
    func integrationConnectionStage(for provider: AgentProvider) -> IntegrationConnectionStage {
        let status = integrationStatuses[provider] ?? .notInstalled
        let configurationFailed: Bool
        if case .failed = status {
            configurationFailed = true
        } else {
            configurationFailed = false
        }
        return IntegrationConnectionPolicy.stage(
            receiverReady: receiverReady,
            signals: IntegrationConnectionSignals(
                isInstalled: status == .installed,
                isChecking: isVerifying(provider),
                checkFailed: configurationFailed || verificationFailed(provider),
                relayVerified: relayVerified(provider),
                lifecycleConnected: lifecycleConnected(provider)
            )
        )
    }
    var integrationHealthStage: IntegrationConnectionStage {
        IntegrationConnectionPolicy.overallStage(
            receiverReady: receiverReady,
            providerStages: AgentProvider.allCases.map(integrationConnectionStage)
        )
    }
    var hasInstalledIntegrations: Bool {
        AgentProvider.allCases.contains { integrationStatuses[$0] == .installed }
    }
    var codexNeedsActivation: Bool {
        integrationStatuses[.codex] == .installed
            && !codexLifecycleConnected
            && lifecycleConnectedProviders.isEmpty
    }
    var sleepProtectionActive: Bool {
        sleepProtectionState == .active
    }
    var notificationHealthStage: NotificationHealthStage {
        NotificationHealthPolicy.stage(
            authorizationDetermined: notificationAuthorizationDetermined,
            authorizationGranted: notificationAuthorizationGranted,
            alertsEnabled: notificationAlertsEnabled
        )
    }
    var diagnosticExportStatusText: String? {
        switch diagnosticExportState {
        case .idle:
            return nil
        case let .success(filename):
            return replace(
                localizedString("diagnostics.success"),
                values: ["filename": filename]
            )
        case .failed:
            return localizedString("diagnostics.failed")
        }
    }
    var sleepProtectionStatusKey: String {
        switch sleepProtectionState {
        case .disabled: "sleep.status.disabled"
        case .waitingForVerifiedWork: "sleep.status.waiting"
        case .active: "sleep.status.active"
        case .pausedForLowPower: "sleep.status.low_power"
        case .pausedForLowBattery: "sleep.status.low_battery"
        case .timedOut: "sleep.status.timed_out"
        }
    }
    var sleepProtectionStatusText: String {
        guard sleepProtectionState == .timedOut else { return uiText(sleepProtectionStatusKey) }
        return replace(localizedString(sleepProtectionStatusKey), values: ["hours": "\(idleSleepMaxHours)"])
    }
    var companionStatusText: String {
        userStatusTitle
    }
    var activeSessionCount: Int {
        reducer.sessions.values.filter {
            ($0.phase == .working && !$0.isSignalStale)
                || $0.phase == .waitingForInput
                || $0.phase == .failed
        }.count
    }
    var attentionSessionCount: Int {
        effectiveReducer.sessions.values.filter {
            $0.phase == .waitingForInput || $0.phase == .failed
        }.count
    }
    var taskInbox: [AgentTaskSummary] {
        AgentTaskInbox.entries(
            sessions: reducer.sessions,
            mutedSessionKeys: mutedSessionKeys
        ).map { entry in
            AgentTaskSummary(
                key: entry.key,
                provider: entry.provider,
                phase: entry.phase,
                ordinal: taskOrdinals[entry.key] ?? 1,
                startedAt: entry.startedAt,
                phaseStartedAt: entry.phaseStartedAt,
                isMuted: entry.isMuted,
                isSignalStale: entry.isSignalStale,
                taskLabel: entry.taskLabel,
                taskLabelKind: entry.taskLabelKind,
                resumeURL: entry.resumeURL
            )
        }
    }
    var actionableTaskCount: Int {
        taskInbox.filter { !$0.isMuted }.count
    }
    func taskTitle(_ task: AgentTaskSummary) -> String {
        guard let label = task.taskLabel, !label.isEmpty else {
            return replace(
                localizedString("task.unnamed"),
                values: ["provider": providerDisplayName(task.provider)]
            )
        }
        let duplicateCount = taskInbox.filter {
            $0.provider == task.provider && $0.taskLabel == label
        }.count
        if task.taskLabelKind == .workspace {
            let key = duplicateCount > 1
                ? "task.workspace_numbered"
                : "task.workspace"
            return replace(
                localizedString(key),
                values: [
                    "label": label,
                    "provider": providerDisplayName(task.provider),
                    "number": String(task.ordinal),
                ]
            )
        }
        let key = duplicateCount > 1 ? "task.named_numbered" : "task.named"
        return replace(
            localizedString(key),
            values: [
                "label": label,
                "provider": providerDisplayName(task.provider),
                "number": String(task.ordinal),
            ]
        )
    }
    func taskStatusText(_ task: AgentTaskSummary, now: Date = .now) -> String {
        if task.isMuted { return localizedString("task.status.muted") }
        if task.isSignalStale { return localizedString("task.status.signal_stale") }
        switch task.phase {
        case .failed:
            return localizedString("task.status.failed")
        case .waitingForInput:
            return localizedString("task.status.waiting")
        case .working:
            let minutes = Int(max(0, now.timeIntervalSince(task.startedAt)) / 60)
            if minutes < 1 { return localizedString("task.status.started") }
            return replace(
                localizedString("task.status.running"),
                values: ["minutes": String(minutes)]
            )
        case .idle, .done:
            return localizedString("task.status.finished")
        }
    }
    func toggleTaskMute(_ task: AgentTaskSummary) {
        let now = Date()
        _ = opportunityClock.transition(to: effectiveReducer, at: now)
        if mutedSessionKeys.contains(task.key) {
            mutedSessionKeys.remove(task.key)
        } else {
            mutedSessionKeys.insert(task.key)
        }
        _ = opportunityClock.transition(to: effectiveReducer, at: now)
        updateOpportunityStage()
        refreshPresentation(at: now)
    }
    @discardableResult
    func focusTask(_ task: AgentTaskSummary) -> Bool {
        if let value = task.resumeURL,
           let url = URL(string: value),
           NSWorkspace.shared.open(url) {
            taskReturnNotice = replace(
                localizedString("task.opened_exact"),
                values: ["task": taskTitle(task)]
            )
            return true
        }
        let activated = focusProvider(task.provider)
        taskReturnNotice = activated
            ? replace(
                localizedString("task.opened_provider_only"),
                values: ["provider": providerDisplayName(task.provider)]
            )
            : replace(
                localizedString("task.open_failed"),
                values: ["provider": providerDisplayName(task.provider)]
            )
        return activated
    }
    func taskReturnActionText(_ task: AgentTaskSummary) -> String {
        if task.resumeURL != nil {
            return localizedString("task.open_exact")
        }
        return replace(
            localizedString("task.open_provider"),
            values: ["provider": providerDisplayName(task.provider)]
        )
    }
    var providerActivitySummaries: [ProviderActivitySummary] {
        AgentProvider.allCases.compactMap { provider in
            let sessions = reducer.sessions.values.filter { $0.provider == provider }
            let working = sessions.filter { $0.phase == .working && !$0.isSignalStale }.count
            let attention = sessions.filter { $0.phase == .waitingForInput }.count
            let failures = sessions.filter { $0.phase == .failed }.count
            guard working + attention + failures > 0 else { return nil }
            return ProviderActivitySummary(
                provider: provider,
                workingCount: working,
                attentionCount: attention,
                failureCount: failures
            )
        }
    }
    var activeProviderText: String {
        let providers = Set(reducer.sessions.values.filter {
            ($0.phase == .working && !$0.isSignalStale)
                || $0.phase == .waitingForInput
                || $0.phase == .failed
        }.map(\.provider))
        if providers.count > 1 { return providerList(providers) }
        guard let provider = providers.first
            ?? (phase == .done ? lastEventProvider : nil)
            ?? (codexNeedsActivation ? .codex : nil) else {
            return "Sleepwing"
        }
        return providerDisplayName(provider)
    }
    func providerDisplayName(_ provider: AgentProvider) -> String {
        provider.brandName
    }

    func lastRealStateText(for provider: AgentProvider, now: Date = .now) -> String? {
        guard let date = lastLifecycleEventAt[provider] else { return nil }
        switch IntegrationEventRecencyPolicy.recency(lastEventAt: date, now: now) {
        case .justNow:
            return localizedString("integration.last_seen.just_now")
        case let .minutes(minutes):
            return replace(
                localizedString("integration.last_seen.minutes"),
                values: ["count": String(minutes)]
            )
        case let .hours(hours):
            return replace(
                localizedString("integration.last_seen.hours"),
                values: ["count": String(hours)]
            )
        case let .days(days):
            return replace(
                localizedString("integration.last_seen.days"),
                values: ["count": String(days)]
            )
        }
    }

    @discardableResult
    func focusAttentionProvider() -> Bool {
        if let task = taskInbox.first(where: {
            !$0.isMuted && ($0.phase == .waitingForInput || $0.phase == .failed)
        }) {
            return focusTask(task)
        }
        guard let provider = attentionProviders.first else { return false }
        return focusProvider(provider)
    }

    private func providerHostApps(
        _ provider: AgentProvider
    ) -> (appNames: [String], terminalHosted: Bool) {
        switch provider {
        case .claude: (["Claude"], true)
        case .cursor: (["Cursor"], false)
        case .codex: (["ChatGPT", "Codex"], false)
        case .opencode: (["OpenCode", "opencode"], true)
        case .gemini: ([], true)
        case .trae: (["TRAE", "Trae", "TRAE CN", "Trae CN"], false)
        case .pi: ([], true)
        }
    }

    private func providerHostAppFrontmost(_ provider: AgentProvider) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        let (appNames, terminalHosted) = providerHostApps(provider)
        if let name = front.localizedName,
           appNames.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        // Any known terminal counts as "watching" a terminal-hosted
        // session; per-window attribution is not knowable from lifecycle
        // metadata alone.
        if terminalHosted, let bundleID = front.bundleIdentifier,
           TerminalHostPolicy.isKnownTerminal(bundleID) {
            return true
        }
        return false
    }

    @discardableResult
    private func focusProvider(_ provider: AgentProvider) -> Bool {
        let (appNames, terminalHosted) = providerHostApps(provider)
        let running = NSWorkspace.shared.runningApplications
        for name in appNames {
            if let application = running.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(name) == true
            }) {
                return application.activate(options: [.activateAllWindows])
            }
        }
        guard terminalHosted else { return false }
        // The terminal the user actually uses outranks any fixed
        // candidate order.
        if let bundleID = lastActivatedTerminalBundleID,
           let application = running.first(where: {
               $0.bundleIdentifier == bundleID
           }) {
            return application.activate(options: [.activateAllWindows])
        }
        for name in ["Terminal", "iTerm2", "Warp"] {
            if let application = running.first(where: {
                $0.localizedName?.localizedCaseInsensitiveContains(name) == true
            }) {
                return application.activate(options: [.activateAllWindows])
            }
        }
        return false
    }

    private var userStatusTitle: String {
        if presentationState == .resting, codexNeedsActivation {
            return localizedString("integration.awaiting_first_event_short")
        }
        switch presentationState {
        case .resting:
            return localizedString(lifecycleConnectedProviders.isEmpty ? "status.watching" : "status.done")
        case .working, .healthOpportunity:
            return localizedString("status.working")
        case .healthNudge:
            return localizedString("status.health_nudge")
        case .needsAttention:
            let providers = attentionProviders
            if attentionSessionCount > 1 {
                return replace(
                    localizedString("status.waiting_count"),
                    values: ["count": String(attentionSessionCount)]
                )
            }
            if let provider = providers.first {
                if failureProviders.contains(provider) {
                    return replace(
                        localizedString("status.failed_provider"),
                        values: ["provider": providerDisplayName(provider)]
                    )
                }
                return replace(
                    localizedString("status.waiting_provider"),
                    values: ["provider": providerDisplayName(provider)]
                )
            }
            return localizedString("status.waiting_for_input")
        case .celebrating:
            if let lastEventProvider {
                return replace(
                    localizedString(companionRole == .custom
                        ? "status.completed_provider"
                        : "status.completed_provider.\(companionRole.rawValue)"),
                    values: ["provider": providerDisplayName(lastEventProvider)]
                )
            }
            return localizedString(companionRole == .custom
                ? "status.done"
                : "status.celebrating_fallback.\(companionRole.rawValue)")
        }
    }

    private var userStatusDetail: String? {
        if presentationState == .resting, codexNeedsActivation {
            return localizedString("integration.awaiting_first_event_detail")
        }
        switch presentationState {
        case .resting:
            if lifecycleConnectedProviders.isEmpty {
                return localizedString("companion.role.\(companionRole.rawValue).idle")
            }
            if todayCompletedBreaks > 0 {
                return replace(
                    localizedString("companion.role.\(companionRole.rawValue).continuity"),
                    values: [
                        "count": String(todayCompletedBreaks),
                        "minutes": String(Int(todayWaiting / 60)),
                    ]
                )
            }
            return replace(
                localizedString("status.detail.recovered_today"),
                values: ["minutes": String(Int(todayWaiting / 60))]
            )
        case .working, .healthOpportunity:
            if opportunityStage == .microCue {
                return localizedString("status.detail.micro_cue")
            }
            let providers = workingProviders
            guard !providers.isEmpty else {
                return localizedString("companion.role.\(companionRole.rawValue).working")
            }
            let names = providerList(Set(providers))
            let longest = longestWorkingDuration
            if longest < 60 {
                return replace(
                    localizedString("status.detail.sources_just_started"),
                    values: ["providers": names]
                )
            }
            let ambientKeys = [
                "status.detail.ambient.eyes",
                "status.detail.ambient.shoulders",
                "status.detail.ambient.water",
                "status.detail.ambient.breathe",
            ]
            let ambientKey = ambientKeys[Int(longest / 60) % ambientKeys.count]
            return replace(
                localizedString(ambientKey),
                values: [
                    "providers": names,
                    "minutes": String(max(1, Int(longest / 60))),
                ]
            )
        case .healthNudge:
            return activeReminder?.message
        case .needsAttention:
            if !failureProviders.isEmpty {
                return localizedString("status.detail.failed")
            }
            let workingCount = reducer.sessions.values.filter {
                $0.phase == .working && !$0.isSignalStale
            }.count
            if workingCount > 0 {
                return replace(
                    localizedString("status.detail.other_working"),
                    values: ["count": String(workingCount)]
                )
            }
            return localizedString("status.detail.return_to_agent")
        case .celebrating:
            let providers = workingProviders
            if !providers.isEmpty {
                return replace(
                    localizedString("status.detail.still_running"),
                    values: ["providers": providerList(Set(providers))]
                )
            }
            return localizedString("companion.role.\(companionRole.rawValue).complete")
        }
    }

    private var workingProviders: [AgentProvider] {
        Array(Set(reducer.sessions.values.filter {
            $0.phase == .working && !$0.isSignalStale
        }.map(\.provider)))
            .sorted { $0.rawValue < $1.rawValue }
    }

    /// True while the user has opted in and a verified agent session is
    /// working. Deliberately provider-agnostic: a CLI agent's actual window
    /// is whichever terminal app is hosting it (iTerm, Terminal.app, Warp,
    /// or anything else), not a fixed per-provider app name, so docking
    /// follows the last app the user was actually working in instead.
    var shouldDockCompanionWindow: Bool {
        companionWindowAnchorEnabled && !workingProviders.isEmpty
    }

    private var attentionProviders: [AgentProvider] {
        Array(Set(effectiveReducer.sessions.values.filter {
            $0.phase == .waitingForInput || $0.phase == .failed
        }.map(\.provider)))
            .sorted { $0.rawValue < $1.rawValue }
    }

    private var failureProviders: Set<AgentProvider> {
        Set(effectiveReducer.sessions.values.filter { $0.phase == .failed }.map(\.provider))
    }

    private var effectiveReducer: AgentStateReducer {
        reducer.applyingAttentionMutes(mutedSessionKeys)
    }

    private var longestWorkingDuration: TimeInterval {
        reducer.sessions.values
            .filter { $0.phase == .working && !$0.isSignalStale }
            .map { max(0, Date().timeIntervalSince($0.phaseStartedAt)) }
            .max() ?? 0
    }

    private func providerList(_ providers: Set<AgentProvider>) -> String {
        let separator = resolvedLanguageCode == "zh-Hans" ? "、" : ", "
        return providers
            .sorted { $0.rawValue < $1.rawValue }
            .map(providerDisplayName)
            .joined(separator: separator)
    }

    private func replace(_ template: String, values: [String: String]) -> String {
        values.reduce(template) { result, value in
            result.replacingOccurrences(of: "{\(value.key)}", with: value.value)
        }
    }

    func completeOnboarding() {
        activeReminder = nil
        refreshPresentation()
        onboardingCompleted = true
        // The first minute must show value before any agent is connected:
        // a clearly-labeled theater run of the real states. It never touches
        // the task inbox or statistics, and any real event cancels it.
        runCompanionDemo()
    }

    private static let demoLogger = Logger(
        subsystem: "app.sleepwing.Perch",
        category: "pet-demo"
    )

    func runCompanionDemo() {
        demoTask?.cancel()
        demoTask = Task { [weak self] in
            guard let self else { return }
            Self.demoLogger.notice("demo: started")
            self.presentNarration(self.localizedString("demo.intro"), for: 5)
            self.demoPresentationState = .working
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self.demoPresentationState = .healthOpportunity
            self.presentNarration(self.localizedString("demo.health"), for: 4)
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self.demoPresentationState = .celebrating
            // The caption and the celebrating state hold exactly as long as
            // the animation stays in motion, so the demo never shows a
            // frozen pet under a live caption.
            let celebration = PetSpriteContract.celebrationWindow
            self.presentNarration(self.localizedString("demo.done"), for: celebration)
            try? await Task.sleep(for: .seconds(celebration))
            self.demoPresentationState = nil
            guard !Task.isCancelled else { return }
            self.presentNarration(self.localizedString("demo.outro"), for: 8)
            Self.demoLogger.notice("demo: finished")
        }
    }

    private func cancelCompanionDemo() {
        guard demoTask != nil || demoPresentationState != nil else { return }
        demoTask?.cancel()
        demoTask = nil
        demoPresentationState = nil
        dismissNarration()
    }

    /// Narration is one-way stage direction (the demo talking about the
    /// pet), deliberately separate from the chat channel so it never
    /// carries an input field or reply chrome.
    private func presentNarration(_ text: String, for seconds: Double) {
        companionNarration = text
        narrationDismissTask?.cancel()
        narrationDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds + 1))
            guard !Task.isCancelled else { return }
            self?.companionNarration = nil
        }
    }

    private var voiceHoldActive = false

    /// Live signal for terminal resolution: the known terminal the user
    /// most recently activated.
    private var lastActivatedTerminalBundleID: String?

    func beginVoiceCapture() {
        guard voiceBridgeEnabled, !voiceListening, !voiceFinalizing else { return }
        voiceHoldActive = true
        Task { [weak self] in
            // TCC callbacks arrive on their own queue; a plain closure
            // formed in a MainActor context inherits that isolation and
            // trips the runtime's queue assertion. @Sendable opts out, and
            // the continuation hops us safely back here.
            let speechStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status)
                }
            }
            guard let self else { return }
            guard speechStatus == .authorized else {
                self.presentVoiceNotice("voice.denied")
                return
            }
            let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
            guard micGranted else {
                self.presentVoiceNotice("voice.denied")
                return
            }
            // Permission dialogs outlive the physical hold; never start
            // the microphone unless the user is still holding.
            guard self.voiceHoldActive else {
                self.presentVoiceNotice("voice.ready")
                return
            }
            self.startVoiceListening()
        }
    }

    func endVoiceCapture() {
        voiceHoldActive = false
        guard voiceListening else { return }
        speechCapture.finishAudio()
        voiceListening = false
        // Keep the transcript bubble up while trailing recognizer results
        // and refinement finish; dropping it and presenting the composer a
        // beat later reads as a flicker.
        voiceFinalizing = true
        Task { [weak self] in
            // Final on-device results trail the release by up to a beat.
            try? await Task.sleep(for: .milliseconds(900))
            guard let self else { return }
            self.speechCapture.stop()
            let text = self.voiceTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                self.voiceTranscript = ""
                self.voiceFinalizing = false
                voiceLogger.notice("voice: empty transcript after release")
                self.presentVoiceNotice("voice.nothing")
                return
            }
            let refined = await VoiceTranscriptRefiner.refine(
                text,
                vocabulary: self.voiceRecognitionVocabulary
            )
            self.voiceTranscript = ""
            self.voiceFinalizing = false
            self.handleVoiceTranscript(refined)
        }
    }

    private func handleVoiceTranscript(_ text: String) {
        let intent = VoiceIntent.parse(text)
        voiceLogger.notice("voice: \(text.count) chars, intent=\(String(describing: intent).prefix(12), privacy: .public)")
        switch intent {
        case .statusQuery:
            presentCompanionChat(voiceStatusSummary)
        case let .dispatch(agentName, message):
            stageVoiceDispatch(agentName: agentName, message: message)
        case .unrecognized:
            stageVoiceUndecided(text)
        }
    }

    /// Headless harness for `--voice-sim "<transcript>"`: runs the full
    /// intent → card → dry-run dispatch chain against the real detected
    /// agents and prints the outcome, so voice regressions die here
    /// instead of on a human tester. Never executes a dispatch.
    func runVoiceSimulation(_ transcript: String) async {
        detectedProviders = IntegrationInstaller().detectedProviders()
        print("voice-sim transcript: \(transcript)")
        let refined = await VoiceTranscriptRefiner.refine(
            transcript,
            vocabulary: voiceRecognitionVocabulary
        )
        if refined != transcript {
            print("voice-sim refined: \(refined)")
        }
        print("voice-sim intent: \(VoiceIntent.parse(refined))")
        handleVoiceTranscript(refined)
        if let action = voicePendingAction {
            let agent = action.agent.map(providerDisplayName) ?? "-"
            print(
                "voice-sim card: agent=\(agent)"
                    + " dir=\(action.directory?.lastPathComponent ?? "-")"
                    + " continues=\(action.continuesSession)"
                    + " mode=\(String(describing: action.mode))"
                    + " message=\(action.message)"
            )
            if let provider = action.agent {
                let invocation = action.continuesSession
                    ? PetChatAgentCommand.continueDispatchInvocation(
                        for: provider, prompt: action.message
                    ) ?? PetChatAgentCommand.dispatchInvocation(
                        for: provider, prompt: action.message
                    )
                    : PetChatAgentCommand.dispatchInvocation(
                        for: provider, prompt: action.message
                    )
                let cwd = action.directory ?? voiceDispatchWorkingDirectory
                if let invocation {
                    print(
                        "voice-sim dispatch(dry): \(invocation.binary) "
                            + invocation.arguments.joined(separator: " ")
                            + " [cwd=\(cwd?.lastPathComponent ?? "~")]"
                    )
                }
                if let handle = PetChatAgentCommand.dispatchHandle(
                    for: provider,
                    continued: action.continuesSession,
                    sessionID: "«uuid»"
                ) {
                    print("voice-sim resume: \(handle.resumeCommand)")
                }
            }
        } else if let chat = companionChatMessage {
            print("voice-sim chat: \(chat)")
        } else {
            print("voice-sim card: none")
        }
    }

    private func startVoiceListening() {
        let localeID = resolvedLanguageCode == "zh-Hans" ? "zh-CN" : "en-US"
        guard speechCapture.modernReady(localeID: localeID)
            || SpeechCaptureController.supportsOnDevice(localeID: localeID) else {
            presentVoiceNotice("voice.unsupported")
            return
        }
        voiceTranscript = ""
        voiceListening = true
        speechCapture.start(
            localeID: localeID,
            contextualStrings: voiceRecognitionVocabulary,
            onPartial: { [weak self] text in
                self?.voiceTranscript = text
            },
            onFailure: { [weak self] failure in
                guard let self else { return }
                self.voiceListening = false
                self.speechCapture.stop()
                self.presentVoiceNotice(
                    failure == .assetsMissing ? "voice.assets" : "voice.unsupported"
                )
            }
        )
    }

    private func presentVoiceNotice(_ key: String) {
        presentNarration(localizedString(key), for: 6)
    }

    /// Runs the whole permission-and-assets flow the moment the user
    /// enables voice — dialogs pop right away instead of surprising the
    /// first hold — and reports live readiness under the toggle.
    func preflightVoice() {
        guard voiceBridgeEnabled else {
            voiceReadiness = .unknown
            return
        }
        voiceReadiness = .checking
        Task { [weak self] in
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in
                    continuation.resume(returning: status)
                }
            }
            guard let self else { return }
            guard speech == .authorized else {
                self.voiceReadiness = .speechDenied
                return
            }
            let mic = await AVCaptureDevice.requestAccess(for: .audio)
            guard mic else {
                self.voiceReadiness = .micDenied
                return
            }
            let locale = self.resolvedLanguageCode == "zh-Hans" ? "zh-CN" : "en-US"
            // Prefer the macOS 26 transcriber — markedly better with
            // casual speech. Its model asset arrives through the same
            // system mechanism as dictation's; the dictation-asset probe
            // below only gates the legacy fallback.
            if let prepared = await SpeechCaptureController.prepareModernTranscriber(
                localeID: locale
            ) {
                self.speechCapture.adoptModernTranscriber(
                    localeID: locale,
                    locale: prepared.locale,
                    format: prepared.format
                )
                self.voiceReadiness = .ready
                return
            }
            switch await SpeechCaptureController.probeOnDeviceAssets(localeID: locale) {
            case .ready: self.voiceReadiness = .ready
            case .assetsMissing: self.voiceReadiness = .assetsMissing
            case .unsupported: self.voiceReadiness = .unsupported
            }
        }
    }

    /// One-click deep link to exactly the pane that fixes the current
    /// readiness problem. Enabling dictation and downloading its model is
    /// a system-owned step that apps cannot perform; landing on the right
    /// pane is the best the platform allows.
    func openVoiceRemedy() {
        let target: String? = switch voiceReadiness {
        case .speechDenied:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .micDenied:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .assetsMissing:
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Dictation"
        default:
            nil
        }
        if let target, let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Domain words the on-device recognizer otherwise mangles: the
    /// detected agent names are exactly the tokens dispatch parsing
    /// depends on. Biasing happens inside the local recognizer only.
    private var voiceRecognitionVocabulary: [String] {
        var terms = ["Sleepwing", "Perch"]
        for provider in PetChatAgentCommand.supportedProviders
        where detectedProviders.contains(provider) {
            terms.append(provider.rawValue)
            let display = providerDisplayName(provider)
            if !terms.contains(display) { terms.append(display) }
        }
        for project in voiceDispatchProjectChoices.prefix(13) {
            let name = project.lastPathComponent
            if !terms.contains(name) { terms.append(name) }
        }
        return terms
    }

    /// Where voice-dispatched work runs. A stale or deleted setting
    /// falls back to the home directory instead of failing the dispatch.
    var voiceDispatchWorkingDirectory: URL? {
        guard let directory = voiceDispatchDirectory else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: directory.path, isDirectory: &isDirectory
        ), isDirectory.boolValue else { return nil }
        return directory
    }

    /// Dispatch targets inside the configured workspace root: the root
    /// itself first, then its recently modified project folders. A root
    /// that is itself a repository is the single choice.
    var voiceDispatchProjectChoices: [URL] {
        guard let root = voiceDispatchWorkingDirectory else { return [] }
        let fileManager = FileManager.default
        if fileManager.fileExists(
            atPath: root.appendingPathComponent(".git").path
        ) {
            return [root]
        }
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        let entries = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        let projects = entries
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            }
            .sorted { first, second in
                let firstDate = (try? first.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                let secondDate = (try? second.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ).contentModificationDate) ?? .distantPast
                return firstDate > secondDate
            }
        return [root] + projects.prefix(12)
    }

    /// The project a spoken task most likely means: a name mentioned in
    /// the message wins (with transcription-garble tolerance), then the
    /// last dispatched project, then the workspace root.
    private func defaultVoiceDispatchProject(for message: String) -> URL? {
        let choices = voiceDispatchProjectChoices
        guard !choices.isEmpty else { return nil }
        if let name = VoiceIntent.matchProjectName(
            in: message,
            candidates: choices.dropFirst().map(\.lastPathComponent)
        ), let match = choices.first(where: { $0.lastPathComponent == name }) {
            return match
        }
        if let last = voiceDispatchLastProjectPath,
           let match = choices.first(where: { $0.path == last }) {
            return match
        }
        // The workspace root is a last resort: a task without project
        // context is exactly how dispatch failed in practice, so the
        // most recently modified project comes first.
        return choices.dropFirst().first ?? choices.first
    }

    private func voiceContinueSupported(_ provider: AgentProvider?) -> Bool {
        guard let provider else { return false }
        return PetChatAgentCommand.continueDispatchInvocation(
            for: provider, prompt: "x"
        ) != nil
    }

    var voicePendingContinueAvailable: Bool {
        voiceContinueSupported(voicePendingAction?.agent)
    }

    func selectVoicePendingContinues(_ value: Bool) {
        voicePendingAction?.continuesSession = value && voicePendingContinueAvailable
    }

    func selectVoicePendingDirectory(_ url: URL) {
        voicePendingAction?.directory = url
    }

    func selectVoicePendingMode(_ mode: VoicePendingAction.Mode) {
        voicePendingAction?.mode = mode
    }

    /// One send button; the mode chip decides what sending means.
    func sendVoiceComposer() {
        switch voicePendingAction?.mode {
        case .dispatch: confirmVoiceDispatch()
        case .chat: confirmVoiceChat()
        case nil: break
        }
    }

    /// The typed path into the same composer: dispatch is not
    /// voice-only.
    func beginDispatchComposer(with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stageVoiceDispatch(agentName: nil, message: trimmed)
    }

    func chooseVoiceDispatchDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = voiceDispatchDirectory
        if panel.runModal() == .OK, let url = panel.url {
            voiceDispatchDirectory = url
        }
    }

    func clearVoiceDispatchDirectory() {
        voiceDispatchDirectory = nil
    }

    /// A misheard or unknown agent name degrades to the default agent on
    /// the confirmation card — never to a dropped message; the card's
    /// agent menu is where the user corrects the target.
    private func stageVoiceDispatch(agentName: String?, message: String) {
        let target = matchVoiceAgent(agentName) ?? resolvedPetChatAgent
        guard target != nil || petChatSupportsFreeInput else {
            presentVoiceNotice("voice.no_agent")
            return
        }
        voicePendingAction = VoicePendingAction(
            message: message,
            agent: target,
            directory: defaultVoiceDispatchProject(for: message),
            continuesSession: VoiceIntent.isContinuation(message)
                && voiceContinueSupported(target),
            mode: .dispatch
        )
    }

    /// Without a dispatch verb the intent is not guessed: the card offers
    /// dispatch and chat side by side and the user picks. One exception:
    /// a continuation ask (「继续把…跑一遍」) is about resuming agent work
    /// by definition — defaulting it to chat would send the instruction to
    /// the pet's small talk on a reflexive tap of send.
    private func stageVoiceUndecided(_ text: String) {
        let agent = resolvedPetChatAgent
        guard agent != nil || petChatSupportsFreeInput else {
            presentCompanionChat(localizedString("voice.only_status"))
            return
        }
        let continues = VoiceIntent.isContinuation(text) && voiceContinueSupported(agent)
        let mode: VoicePendingAction.Mode = if continues && agent != nil {
            .dispatch
        } else {
            petChatSupportsFreeInput ? .chat : .dispatch
        }
        voicePendingAction = VoicePendingAction(
            message: text,
            agent: agent,
            directory: defaultVoiceDispatchProject(for: text),
            continuesSession: continues,
            mode: mode
        )
    }

    /// Matches only against the user's detected, supported agents; an
    /// unnamed dispatch falls back to the agent the user designated in
    /// Settings. Perch never substitutes its own preference. Exact
    /// matches win before substring fuzz, and one-character tokens never
    /// fuzzy-match ("p" must not pick opencode).
    private func matchVoiceAgent(_ name: String?) -> AgentProvider? {
        guard let name, !name.isEmpty else { return resolvedPetChatAgent }
        let token = VoiceIntent.canonicalAgentToken(name)
        let candidates = PetChatAgentCommand.supportedProviders
            .filter(detectedProviders.contains)
        if let exact = candidates.first(where: { provider in
            provider.rawValue == token
                || providerDisplayName(provider).lowercased() == token
        }) {
            return exact
        }
        guard token.count >= 2 else { return nil }
        return candidates.first { provider in
            let display = providerDisplayName(provider).lowercased()
            return display.contains(token)
                || token.contains(provider.rawValue)
        }
    }

    func confirmVoiceDispatch() {
        guard let action = voicePendingAction, let provider = action.agent else {
            return
        }
        let message = action.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        voicePendingAction = nil
        let name = providerDisplayName(provider)
        let directory = action.directory ?? voiceDispatchWorkingDirectory
        voiceDispatchLastProjectPath = action.directory?.path
        let handle = PetChatAgentCommand.dispatchHandle(
            for: provider,
            continued: action.continuesSession,
            sessionID: UUID().uuidString.lowercased()
        )
        Task { [weak self] in
            let started = await AgentChatRunner.dispatch(
                provider: provider,
                prompt: message,
                workingDirectory: directory,
                continuesSession: action.continuesSession,
                extraArguments: handle?.arguments ?? [],
                onExit: { [weak self] status in
                    Task { @MainActor [weak self] in
                        self?.presentVoiceReceipt(
                            agentName: name,
                            directory: directory,
                            success: status == 0,
                            resumeCommand: handle?.resumeCommand
                        )
                    }
                }
            )
            guard let self else { return }
            self.presentNarration(
                self.replace(
                    self.localizedString(
                        started ? "voice.dispatched" : "voice.dispatch_failed"
                    ),
                    values: ["agent": name]
                ),
                for: 8
            )
        }
    }

    func confirmVoiceChat() {
        guard let action = voicePendingAction else { return }
        let message = action.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        voicePendingAction = nil
        sendCompanionChat(message)
    }

    func cancelVoiceAction() {
        voicePendingAction = nil
    }

    private func presentVoiceReceipt(
        agentName: String,
        directory: URL?,
        success: Bool,
        resumeCommand: String?
    ) {
        let project = directory?.lastPathComponent
            ?? localizedString("voice.receipt.home")
        voiceReceipt = VoiceDispatchReceipt(
            message: replace(
                localizedString(success ? "voice.receipt.done" : "voice.receipt.failed"),
                values: ["agent": agentName, "project": project]
            ),
            resumeCommand: resumeCommand,
            directory: directory
        )
        voiceReceiptDismissTask?.cancel()
        voiceReceiptDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            self?.voiceReceipt = nil
        }
    }

    func dismissVoiceReceipt() {
        voiceReceiptDismissTask?.cancel()
        voiceReceiptDismissTask = nil
        voiceReceipt = nil
    }

    /// Opens the dispatched session where it lives: a .command script
    /// (login shell, so the user's PATH applies) that cds into the
    /// project and resumes the exact session in the user's resolved
    /// terminal. Local file, local command — nothing leaves the machine.
    func openVoiceReceiptSession() {
        guard let receipt = voiceReceipt,
              let command = receipt.resumeCommand else { return }
        let directory = receipt.directory
            ?? FileManager.default.homeDirectoryForCurrentUser
        let quotedPath = "'"
            + directory.path.replacingOccurrences(of: "'", with: "'\\''")
            + "'"
        let script = "#!/bin/zsh -l\ncd \(quotedPath) && exec \(command)\n"
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let binDirectory = base.appendingPathComponent("Perch/bin", isDirectory: true)
        let file = binDirectory.appendingPathComponent("resume-session.command")
        do {
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true
            )
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: file.path
            )
        } catch {
            voiceLogger.notice("receipt: failed to write resume script")
            return
        }
        openResumeScript(file, directory: directory, command: command)
        dismissVoiceReceipt()
    }

    /// Hands the resume script to the user's terminal — resolved from
    /// live signals (last activated known terminal, the running set, the
    /// default handler), never a hardcoded app — using whichever hand-off
    /// that terminal supports. Anything unresolved falls back to the
    /// system default .command handler.
    private func openResumeScript(
        _ file: URL,
        directory: URL,
        command: String
    ) {
        let workspace = NSWorkspace.shared
        let runningIDs = workspace.runningApplications
            .compactMap(\.bundleIdentifier)
        let handlerID = workspace.urlForApplication(toOpen: file)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        guard
            let choice = TerminalHostPolicy.resolve(
                runningBundleIDs: runningIDs,
                lastActivatedBundleID: lastActivatedTerminalBundleID,
                defaultHandlerBundleID: handlerID
            ),
            let appURL = workspace.urlForApplication(
                withBundleIdentifier: choice
            ),
            let strategy = TerminalHostPolicy.launch(
                bundleID: choice,
                directory: directory.path,
                command: command
            )
        else {
            workspace.open(file)
            return
        }
        switch strategy {
        case .commandFile:
            workspace.open(
                [file],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if error != nil {
                    Task { @MainActor in NSWorkspace.shared.open(file) }
                }
            }
        case let .appArguments(arguments):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            configuration.createsNewApplicationInstance = true
            workspace.openApplication(
                at: appURL,
                configuration: configuration
            ) { _, error in
                if error != nil {
                    Task { @MainActor in NSWorkspace.shared.open(file) }
                }
            }
        case .unsupported:
            workspace.open(file)
        }
    }

    func updateVoicePendingMessage(_ text: String) {
        voicePendingAction?.message = text
    }

    func selectVoicePendingAgent(_ provider: AgentProvider) {
        voicePendingAction?.agent = provider
        // A provider without a verified continue flag must not pretend
        // it will resume anything.
        if !voiceContinueSupported(provider) {
            voicePendingAction?.continuesSession = false
        }
    }

    /// The composer states one inferred destination instead of asking the
    /// user to pick a mode; tapping it flips between the two routes.
    var voiceRouteText: String {
        guard let action = voicePendingAction else { return "" }
        if action.mode == .chat {
            return localizedString("voice.confirm.route_chat")
        }
        guard let agent = action.agent else {
            return localizedString("voice.confirm.pick_agent")
        }
        let name = providerDisplayName(agent)
        guard let directory = action.directory else {
            return replace(
                localizedString("voice.confirm.route_dispatch_bare"),
                values: ["agent": name]
            )
        }
        return replace(
            localizedString("voice.confirm.route_dispatch"),
            values: ["agent": name, "project": directory.lastPathComponent]
        )
    }

    var voiceRouteToggleAvailable: Bool {
        guard let action = voicePendingAction else { return false }
        return action.mode == .chat
            ? !voiceDispatchAgents.isEmpty
            : petChatSupportsFreeInput
    }

    func toggleVoicePendingMode() {
        guard let action = voicePendingAction, voiceRouteToggleAvailable
        else { return }
        selectVoicePendingMode(action.mode == .chat ? .dispatch : .chat)
    }

    var voiceDispatchAgents: [AgentProvider] {
        PetChatAgentCommand.supportedProviders.filter(detectedProviders.contains)
    }

    var voiceStatusSummary: String {
        let working = taskInbox.filter { $0.phase == .working && !$0.isMuted }.count
        let waiting = taskInbox.filter { $0.phase == .waitingForInput && !$0.isMuted }.count
        if working == 0, waiting == 0 {
            return localizedString("voice.status.none")
        }
        return replace(
            localizedString("voice.status.summary"),
            values: ["working": "\(working)", "waiting": "\(waiting)"]
        )
    }

    func dismissNarration() {
        narrationDismissTask?.cancel()
        narrationDismissTask = nil
        companionNarration = nil
    }
    var todayWaitingText: String { "\(Int(todayWaiting / 60)) min" }
    var todayReminderCount: Int { records.filter { Calendar.current.isDateInToday($0.triggeredAt) }.count }
    var responseRateText: String {
        let todayRecords = records.filter { Calendar.current.isDateInToday($0.triggeredAt) }
        guard !todayRecords.isEmpty else { return "—" }
        let completed = todayRecords.filter { $0.response == .completed }.count
        return "\(Int((Double(completed) / Double(todayRecords.count)) * 100))%"
    }
    var todayCompletedBreaks: Int {
        records.filter {
            Calendar.current.isDateInToday($0.triggeredAt) && $0.response == .completed
        }.count
    }
    var todayCompletedAgentTasks: Int {
        (completedTaskHistory[dayKey(.now)] ?? [:]).values.reduce(0, +)
    }
    var weeklyCompletedAgentTasks: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -6, to: .now) ?? .distantPast
        return completedTaskHistory.reduce(into: 0) { total, entry in
            guard let date = Self.dayFormatter.date(from: entry.key), date >= cutoff else { return }
            total += entry.value.values.reduce(0, +)
        }
    }
    var weeklyReminderCount: Int { recentWeekRecords.count }
    var weeklyCompletedBreaks: Int {
        recentWeekRecords.filter { $0.response == .completed }.count
    }
    var weeklyCompletionRateText: String {
        guard weeklyReminderCount > 0 else { return "—" }
        return "\(Int((Double(weeklyCompletedBreaks) / Double(weeklyReminderCount) * 100).rounded()))%"
    }
    var weeklySnoozeRateText: String {
        guard weeklyReminderCount > 0 else { return "—" }
        let snoozed = recentWeekRecords.filter {
            ($0.snoozeCount ?? 0) > 0 || $0.response == .snoozed
        }.count
        return "\(Int((Double(snoozed) / Double(weeklyReminderCount) * 100).rounded()))%"
    }
    var reminderKindSummaries: [ReminderKindSummary] {
        ReminderKind.allCases.map { kind in
            let kindRecords = recentWeekRecords.filter { $0.kind == kind }
            return ReminderKindSummary(
                kind: kind,
                shown: kindRecords.count,
                completed: kindRecords.filter { $0.response == .completed }.count
            )
        }
    }
    var providerWorkSummaries: [ProviderWorkSummary] {
        let key = dayKey(.now)
        let secondsByProvider = providerWorkHistory[key] ?? [:]
        return AgentProvider.allCases.compactMap { provider in
            let seconds = secondsByProvider[provider.rawValue] ?? 0
            return seconds > 0 ? ProviderWorkSummary(provider: provider, seconds: seconds) : nil
        }
        .sorted { $0.seconds > $1.seconds }
    }
    func providerWorkText(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return "\(minutes) \(localizedString("unit.minutes"))"
    }
    func completionRateText(_ summary: ReminderKindSummary) -> String {
        guard let rate = summary.completionRate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }

    var locale: Locale { language.locale }
    var quietHoursEnabled: Bool {
        get { policy.quietHours.startMinute != policy.quietHours.endMinute }
        set {
            if newValue, !quietHoursEnabled {
                policy.quietHours = QuietHours(startMinute: 12 * 60, endMinute: 13 * 60)
            } else if !newValue {
                policy.quietHours = QuietHours()
            }
        }
    }
    var quietStartDate: Date {
        get { date(forMinute: policy.quietHours.startMinute) }
        set { policy.quietHours.startMinute = minuteOfDay(newValue) }
    }
    var quietEndDate: Date {
        get { date(forMinute: policy.quietHours.endMinute) }
        set { policy.quietHours.endMinute = minuteOfDay(newValue) }
    }
    var activeStrategy: ReminderStrategy {
        guard strategy == .crossover else { return strategy }
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        return day.isMultiple(of: 2) ? .agentAware : .afterCompletion
    }

    var currentExperimentArmKey: String {
        switch activeStrategy {
        case .afterCompletion: "strategy.after_completion"
        case .fixedTimer: "strategy.timer"
        case .agentAware, .crossover: "strategy.agent"
        case .hybrid: "strategy.hybrid"
        }
    }

    var experimentDaysObserved: Int {
        min(7, experimentDayArms.count)
    }

    var workingArmMetrics: ReminderExperimentMetrics {
        ReminderExperimentAnalyzer.metrics(
            records: recentExperimentRecords,
            arm: ReminderStrategy.agentAware.rawValue
        )
    }

    var completionArmMetrics: ReminderExperimentMetrics {
        ReminderExperimentAnalyzer.metrics(
            records: recentExperimentRecords,
            arm: ReminderStrategy.afterCompletion.rawValue
        )
    }

    var medianAttentionResponseText: String {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        let recent = attentionResponses.filter { $0.resolvedAt >= cutoff }
        guard let duration = ReminderExperimentAnalyzer.medianAttentionResponse(records: recent) else {
            return "—"
        }
        if duration < 60 {
            return "\(Int(duration.rounded())) \(localizedString("unit.seconds"))"
        }
        return "\(Int((duration / 60).rounded())) \(localizedString("unit.minutes"))"
    }

    func completionRateText(_ metrics: ReminderExperimentMetrics) -> String {
        guard let rate = metrics.completionRate else { return "—" }
        return "\(Int((rate * 100).rounded()))%"
    }

    func averageOpportunityText(_ metrics: ReminderExperimentMetrics) -> String {
        guard let duration = metrics.averageOpportunityDuration else { return "—" }
        return "\(max(1, Int((duration / 60).rounded()))) \(localizedString("unit.minutes"))"
    }

    private var recentWeekRecords: [ReminderRecord] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        return records.filter { $0.triggeredAt >= cutoff }
    }
    private var recentExperimentRecords: [ReminderRecord] { recentWeekRecords }

    var weeklyPoints: [DailyPoint] {
        let calendar = Calendar.current
        return (0..<7).reversed().compactMap { offset -> DailyPoint? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: .now) else { return nil }
            let key = dayKey(date)
            let reminders = records.filter { calendar.isDate($0.triggeredAt, inSameDayAs: date) }
            return DailyPoint(date: calendar.startOfDay(for: date), waitingMinutes: (waitingHistory[key] ?? 0) / 60, reminders: reminders.count)
        }
    }

    func start() async {
        guard listener == nil else { return }
        refreshLaunchAtLoginStatus()
        let integrationInventory = await Task.detached(priority: .utility) {
            let installer = IntegrationInstaller()
            try? installer.upgradeClaudeLifecycleIfNeeded()
            try? installer.upgradeCodexLifecycleIfNeeded()
            return (
                statuses: Dictionary(
                    uniqueKeysWithValues: AgentProvider.allCases.map {
                        ($0, installer.status(for: $0))
                    }
                ),
                detected: installer.detectedProviders()
            )
        }.value
        integrationStatuses = integrationInventory.statuses
        detectedProviders = integrationInventory.detected
        if Self.systemNotificationsAvailable {
            UNUserNotificationCenter.current().delegate = self
            configureNotificationCategories()
        }
        installActivationObserver()
        installPowerStateObserver()
        installSessionActivityObservers()
        installTerminationObserver()
        await refreshNotificationAuthorization()
        startEventReceiver()
        let companion = CompanionWindowController(model: self)
        companionController = companion
        companion.apply(size: companionSize, layer: companionLayer)
        updateCompanionSpaceBehavior()
        companion.setVisible(companionVisible)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                await self?.refreshNotificationAuthorization()
                self?.tick()
            }
        }
        updateSleepProtection()
        recordExperimentArmForToday()
        persist()
        if !onboardingCompleted
            || CommandLine.arguments.contains("--show-settings")
            || Bundle.main.object(forInfoDictionaryKey: "PerchShowSettingsOnLaunch") as? Bool == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                SettingsWindowPresenter.open(
                    model: self,
                    placement: .primaryDisplay
                )
            }
        }
    }

    func toggleIntegration(_ provider: AgentProvider) {
        do {
            if integrationStatuses[provider] == .installed {
                try integrationInstaller.uninstall(provider)
                clearIntegrationVerification(provider)
            } else {
                try integrationInstaller.install(provider)
            }
            refreshIntegrationStatuses()
            if integrationStatuses[provider] == .installed {
                verifyIntegration(provider)
            }
        } catch IntegrationConfigError.existingCodexNotifier {
            integrationStatuses[provider] = .failed(localizedString("integration.existing_notifier"))
        } catch IntegrationConfigError.existingOpenCodePlugin {
            integrationStatuses[provider] = .failed(localizedString("integration.existing_opencode_plugin"))
        } catch IntegrationConfigError.existingPiExtension {
            integrationStatuses[provider] = .failed(localizedString("integration.existing_pi_extension"))
        } catch IntegrationConfigError.unsafeConfiguration {
            integrationStatuses[provider] = .failed(localizedString("integration.unsafe_configuration"))
        } catch {
            integrationStatuses[provider] = .failed(error.localizedDescription)
        }
    }

    func connectDetectedIntegrations() {
        var failures: [AgentProvider: String] = [:]
        var installed: Set<AgentProvider> = []
        for provider in detectedProviders where integrationStatuses[provider] != .installed {
            do {
                try integrationInstaller.install(provider)
                installed.insert(provider)
            } catch IntegrationConfigError.existingCodexNotifier {
                failures[provider] = localizedString("integration.existing_notifier")
            } catch IntegrationConfigError.existingOpenCodePlugin {
                failures[provider] = localizedString("integration.existing_opencode_plugin")
            } catch IntegrationConfigError.existingPiExtension {
                failures[provider] = localizedString("integration.existing_pi_extension")
            } catch IntegrationConfigError.unsafeConfiguration {
                failures[provider] = localizedString("integration.unsafe_configuration")
            } catch {
                failures[provider] = error.localizedDescription
            }
        }
        refreshIntegrationStatuses()
        for (provider, message) in failures {
            integrationStatuses[provider] = .failed(message)
        }
        for provider in installed where integrationStatuses[provider] == .installed {
            verifyIntegration(provider)
        }
    }

    func verifyIntegration(_ provider: AgentProvider) {
        guard integrationStatuses[provider] == .installed else { return }
        verificationTasks[provider]?.cancel()
        verificationFailedProviders.remove(provider)
        relayVerifiedProviders.remove(provider)
        verifyingProviders.insert(provider)
        guard receiverReady else {
            verifyingProviders.remove(provider)
            verificationFailedProviders.insert(provider)
            return
        }
        do {
            try integrationInstaller.sendVerificationProbe(provider)
        } catch {
            verifyingProviders.remove(provider)
            verificationFailedProviders.insert(provider)
            return
        }
        verificationTasks[provider] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            if self.verifyingProviders.remove(provider) != nil {
                self.verificationFailedProviders.insert(provider)
            }
            self.verificationTasks[provider] = nil
        }
    }

    func verifyInstalledIntegrations() {
        for provider in AgentProvider.allCases where integrationStatuses[provider] == .installed {
            verifyIntegration(provider)
        }
    }

    func retryReceiverNow() {
        receiverRetryTask?.cancel()
        receiverRetryTask = nil
        startEventReceiver()
    }

    private func clearIntegrationVerification(_ provider: AgentProvider) {
        verificationTasks[provider]?.cancel()
        verificationTasks[provider] = nil
        verifyingProviders.remove(provider)
        relayVerifiedProviders.remove(provider)
        verificationFailedProviders.remove(provider)
        lifecycleConnectedProviders.remove(provider)
        updateSleepProtection()
    }

    var detectedProvidersText: String {
        providerList(detectedProviders)
    }

    var detectedProvidersHeadline: String {
        replace(
            localizedString("onboarding.detected"),
            values: ["providers": detectedProvidersText]
        )
    }

    var allDetectedProvidersConnected: Bool {
        !detectedProviders.isEmpty
            && detectedProviders.allSatisfy { integrationStatuses[$0] == .installed }
    }

    private func refreshIntegrationStatuses() {
        integrationStatuses = Dictionary(uniqueKeysWithValues: AgentProvider.allCases.map { ($0, integrationInstaller.status(for: $0)) })
        detectedProviders = integrationInstaller.detectedProviders()
    }

    private func startEventReceiver() {
        receiverRetryTask?.cancel()
        receiverRetryTask = nil
        listener?.stop()
        receiverReady = false

        let generation = UUID()
        receiverGeneration = generation
        let token: String
        do {
            try integrationInstaller.prepareRelay()
            token = try integrationInstaller.receiverToken()
        } catch {
            handleReceiverState(.unavailable, generation: generation)
            return
        }
        let server = LocalEventServer(
            onEvent: { [weak self] event in
                Task { @MainActor in self?.ingest(event) }
            },
            onStateChange: { [weak self] state in
                Task { @MainActor in
                    self?.handleReceiverState(state, generation: generation)
                }
            },
            expectedToken: token
        )
        listener = server
        do {
            try server.start()
        } catch {
            handleReceiverState(.unavailable, generation: generation)
        }
    }

    private func handleReceiverState(_ state: LocalEventServerState, generation: UUID) {
        guard generation == receiverGeneration else { return }
        switch state {
        case .ready:
            let becameReady = !receiverReady
            receiverReady = true
            receiverRecoveryPolicy.registerReady()
            receiverRetryTask?.cancel()
            receiverRetryTask = nil
            if becameReady {
                verifyInstalledIntegrations()
            }
        case .unavailable:
            receiverReady = false
            listener?.stop()
            listener = nil
            let delay = receiverRecoveryPolicy.registerFailure()
            receiverRetryTask?.cancel()
            receiverRetryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.startEventReceiver()
            }
        }
    }

    func requestNotificationPermissionFromUser() async {
        guard Self.systemNotificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        configureNotificationCategories()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshNotificationAuthorization()
    }

    private func installActivationObserver() {
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.refreshNotificationAuthorization() }
            }
        }
    }

    private func installPowerStateObserver() {
        guard powerStateObserver == nil else { return }
        powerStateObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateSleepProtection()
            }
        }
    }

    /// Property changes only flag `needsPersist` and wait for the next 15-second
    /// tick to write, so a change made just before quitting could otherwise be
    /// lost; flush unconditionally when the app is about to terminate.
    private func installTerminationObserver() {
        guard terminationObserver == nil else { return }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main guarantees this runs on the main thread, and
            // termination must flush synchronously before the process exits,
            // so hop back onto the main actor without deferring to a Task.
            MainActor.assumeIsolated {
                self?.persist()
            }
            // The warm pi RPC child would otherwise outlive the app.
            PiRpcChatClient.shared.shutdown()
        }
    }

    private func installSessionActivityObservers() {
        guard sessionActivityObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        sessionActivityObservers = [
            center.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.workspaceSessionActive = false
                    self?.moveActiveReminderToSystemNotificationIfNeeded()
                }
            },
            center.addObserver(
                forName: NSWorkspace.sessionDidBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.workspaceSessionActive = true
                }
            },
        ]
    }

    private func configureNotificationCategories() {
        guard Self.systemNotificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let completed = UNNotificationAction(identifier: "completed", title: localizedString("action.completed"))
        let snoozed = UNNotificationAction(identifier: "snoozed", title: localizedString("action.snooze"))
        let skipped = UNNotificationAction(identifier: "skipped", title: localizedString("action.skip"))
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: HealthReminderNotification.category,
                actions: [completed, snoozed, skipped],
                intentIdentifiers: [],
                options: [.customDismissAction]
            ),
            UNNotificationCategory(
                identifier: AgentActivityNotification.category,
                actions: [],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    private func ingest(_ event: AgentEvent) {
        if IntegrationVerificationProbe.matches(event) {
            verificationTasks[event.provider]?.cancel()
            verificationTasks[event.provider] = nil
            verifyingProviders.remove(event.provider)
            verificationFailedProviders.remove(event.provider)
            relayVerifiedProviders.insert(event.provider)
            return
        }
        accountProviderActivity(at: event.timestamp)
        _ = opportunityClock.transition(to: effectiveReducer, at: event.timestamp)
        lifecycleConnectedProviders.insert(event.provider)
        lastLifecycleEventAt[event.provider] = event.timestamp
        if event.phase != .idle {
            cancelCompanionDemo()
            lastEventProvider = event.provider
        }
        guard let event = codexCompletionGate.route(event) else {
            scheduleCodexCompletionDrain()
            return
        }
        scheduleCodexCompletionDrain()
        applyLifecycleEvent(event)
    }

    private func applyLifecycleEvent(_ event: AgentEvent) {
        let sessionKey = AgentSessionKey(provider: event.provider, sessionID: event.sessionID)
        if taskOrdinals[sessionKey] == nil {
            let ordinal = nextTaskOrdinal[event.provider, default: 0] + 1
            nextTaskOrdinal[event.provider] = ordinal
            taskOrdinals[sessionKey] = ordinal
        }
        let isStale = reducer.sessions[sessionKey].map { event.timestamp < $0.lastEventAt } ?? false
        let wasMuted = mutedSessionKeys.contains(sessionKey)
        let phaseBefore = reducer.sessions[sessionKey]?.phase
        let change = reducer.ingest(event)
        let phaseAfter = reducer.sessions[sessionKey]?.phase
        if phaseBefore != phaseAfter {
            // Live sessions are part of what a restart has to remember, so a
            // transition has to reach disk like any other durable change.
            needsPersist = true
        }
        if phaseBefore != phaseAfter || isStale {
            stateLogger.debug("""
                \(event.provider.rawValue, privacy: .public) \
                \(phaseBefore?.rawValue ?? "none", privacy: .public) -> \
                \(phaseAfter?.rawValue ?? "none", privacy: .public) \
                (event \(event.phase.rawValue, privacy: .public)\
                \(isStale ? ", out of order" : "", privacy: .public)); \
                pet \(self.effectiveReducer.aggregatePhase.rawValue, privacy: .public), \
                \(self.reducer.sessions.count, privacy: .public) sessions
                """)
        }
        // Ask the reducer whether the session actually settled rather than
        // trusting the event's own phase: it holds a failure through the
        // trailing session-end event, and dropping the mute here would flip
        // the pet straight back to the failure the user just silenced.
        if !isStale, change.didSettle {
            mutedSessionKeys.remove(sessionKey)
        }
        if !isStale {
            handleAgentActivityNotificationEdges(
                for: event,
                change: change,
                sessionKey: sessionKey,
                wasMuted: wasMuted
            )
        }
        if change.didComplete {
            let key = dayKey(event.timestamp)
            var counts = completedTaskHistory[key] ?? [:]
            counts[event.provider.rawValue, default: 0] += 1
            completedTaskHistory[key] = counts
        }
        if !isStale {
            trackAttentionResponse(for: event, key: sessionKey)
        }
        _ = opportunityClock.transition(to: effectiveReducer, at: event.timestamp)
        updateOpportunityStage()
        updateSleepProtection(at: event.timestamp)
        synchronizeActiveReminderContext()

        let activityResumed = event.phase == .working
        if activityResumed {
            celebrationTask?.cancel()
            celebrationTask = nil
        }
        refreshPresentation(
            completedEdge: change.didComplete,
            activityResumed: activityResumed,
            at: event.timestamp
        )
        if (activeStrategy == .afterCompletion || activeStrategy == .hybrid),
           change.didComplete,
           effectiveReducer.aggregatePhase == .idle {
            triggerPostCompletionReminder(at: event.timestamp)
        }
        if effectiveReducer.aggregatePhase == .waitingForInput {
            celebrationTask?.cancel()
        } else if change.didComplete {
            celebrationTask?.cancel()
            celebrationTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(PetSpriteContract.celebrationWindow))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.refreshPresentation()
                }
            }
        }
    }

    private func scheduleCodexCompletionDrain(at now: Date = .now) {
        codexCompletionTask?.cancel()
        guard let deadline = codexCompletionGate.nextDeadline() else {
            codexCompletionTask = nil
            return
        }
        let delay = max(0, deadline.timeIntervalSince(now))
        codexCompletionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.codexCompletionTask = nil
            let due = self.codexCompletionGate.drain(at: .now)
            for event in due {
                self.applyLifecycleEvent(event)
            }
            self.scheduleCodexCompletionDrain()
        }
    }

    private func tick() {
        let now = Date()
        accountProviderActivity(at: now)
        recordExperimentArmForToday()
        if !Calendar.current.isDate(waitingDay, inSameDayAs: now) {
            waitingDay = now
            todayWaiting = 0
        }
        if reducer.cleanupStaleSessions(at: now) > 0 { needsPersist = true }
        let retainedKeys = Set(reducer.sessions.keys)
        mutedSessionKeys.formIntersection(retainedKeys)
        taskOrdinals = taskOrdinals.filter { retainedKeys.contains($0.key) }
        let retainedProviders = Set(retainedKeys.map(\.provider))
        nextTaskOrdinal = nextTaskOrdinal.filter { retainedProviders.contains($0.key) }
        attentionStartedAt = attentionStartedAt.filter { key, _ in
            reducer.sessions[key]?.phase == .waitingForInput
        }
        updateSleepProtection(at: now)
        let opportunityElapsed = opportunityClock.transition(to: effectiveReducer, at: now)
        updateOpportunityStage()
        synchronizeActiveReminderContext()
        refreshPresentation(at: now)
        todayWaiting += max(0, min(opportunityElapsed, 30))
        waitingHistory[dayKey(now)] = todayWaiting
        if handleDueSnooze(at: now) {
            needsPersist = true
            persist()
            return
        }
        var evaluationPolicy = policy
        if activeStrategy == .fixedTimer {
            evaluationPolicy.waitingThreshold = 45 * 60
        } else if activeStrategy == .afterCompletion {
            if needsPersist { persist() }
            return
        } else {
            guard effectiveReducer.isHealthOpportunityActive else {
                if needsPersist { persist() }
                return
            }
        }
        engine.policy = evaluationPolicy
        guard case let .deliver(channel) = reminderDeliveryCoordinator.decision(
            for: reminderDeliveryContext(at: now)
        ) else {
            if needsPersist { persist() }
            return
        }
        guard let candidate = engine.evaluate(
            opportunityDuration: {
                if activeStrategy == .fixedTimer {
                    return now.timeIntervalSince(fixedPeriodStartedAt)
                }
                return opportunityClock.accumulated
            }(),
            at: now,
            eligibleKinds: orderedEnabledReminderKinds
        ) else {
            if needsPersist { persist() }
            return
        }
        let record = engine.record(candidate, at: now, experimentArm: activeStrategy.rawValue)
        if activeStrategy == .fixedTimer {
            fixedPeriodStartedAt = now
        } else {
            opportunityClock.reset(at: now, state: effectiveReducer)
            updateOpportunityStage()
        }
        records = engine.records
        needsPersist = true
        persist()
        let qualifyingMinutes = Int(candidate.qualifyingDuration / 60)
        let moment: ReminderCopyMoment = activeStrategy == .fixedTimer
            ? .neutral
            : .activeWork
        deliverReminder(
            kind: candidate.kind,
            recordID: record.id,
            message: reminderMessage(
                for: candidate.kind,
                minutes: qualifyingMinutes,
                moment: moment
            ),
            qualifyingMinutes: qualifyingMinutes,
            moment: moment,
            channel: channel,
            at: record.triggeredAt
        )
    }

    private func deliverReminder(
        kind: ReminderKind,
        recordID: UUID,
        message: String,
        qualifyingMinutes: Int,
        moment: ReminderCopyMoment,
        channel: ReminderDeliveryChannel,
        at now: Date
    ) {
        switch channel {
        case .companion:
            activeReminder = CompanionReminder(
                id: recordID,
                recordID: recordID,
                kind: kind,
                qualifyingMinutes: qualifyingMinutes,
                moment: moment,
                message: message
            )
            refreshPresentation(at: now)
        case .systemNotification:
            sendSystemNotification(
                kind: kind,
                recordID: recordID,
                message: message
            )
        }
    }

    private func sendSystemNotification(
        kind: ReminderKind,
        recordID: UUID,
        message: String
    ) {
        let content = UNMutableNotificationContent()
        content.title = notificationTitle(for: kind)
        content.body = message
        content.categoryIdentifier = HealthReminderNotification.category
        content.userInfo = [HealthReminderNotification.recordIDKey: recordID.uuidString]
        content.sound = .default
        guard Self.systemNotificationsAvailable else { return }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: recordID.uuidString,
            content: content,
            trigger: nil
        ))
    }

    /// Wire-format constants shared by the notification category, the
    /// posted content, and the tap handler. Keeping them in one place is
    /// what guarantees a posted banner can always be routed back.
    private enum AgentActivityNotification {
        static let category = "agent-activity"
        static let providerKey = "agentProvider"
        static let sessionIDKey = "agentSessionID"
    }

    /// Same contract as `AgentActivityNotification`: the category and
    /// userInfo key must match between registration, the posted content,
    /// and the response handler.
    private enum HealthReminderNotification {
        static let category = "health-reminder"
        static let recordIDKey = "recordID"
    }

    private func agentActivityNotificationIdentifier(
        _ kind: AgentActivityNotificationKind,
        key: AgentSessionKey
    ) -> String {
        "agent-\(kind.rawValue)-\(key.provider.rawValue)-\(key.sessionID)"
    }

    private func handleAgentActivityNotificationEdges(
        for event: AgentEvent,
        change: AgentStateChange,
        sessionKey: AgentSessionKey,
        wasMuted: Bool
    ) {
        if event.phase == .working || event.phase == .idle || event.phase == .done {
            voiceFollowUpTasks[sessionKey]?.cancel()
            voiceFollowUpTasks[sessionKey] = nil
        }
        if Self.systemNotificationsAvailable,
           event.phase == .working || event.phase == .idle || event.phase == .done {
            // The ask is resolved; an unseen banner would only report
            // stale state.
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: [
                    agentActivityNotificationIdentifier(.attention, key: sessionKey),
                ]
            )
        }
        let kind: AgentActivityNotificationKind
        if change.didComplete {
            kind = .completion
        } else if change.didRequestAttention {
            kind = .attention
        } else {
            return
        }
        let quietHoursActive = policy.quietHours.contains(event.timestamp)
        let hostAppFrontmost = providerHostAppFrontmost(event.provider)
        let inputIdleSeconds = systemInputIdleSeconds
        if Self.systemNotificationsAvailable {
            let bannerContext = AgentActivityNotificationContext(
                enabled: kind == .completion
                    ? agentCompletionNotificationsEnabled
                    : agentAttentionNotificationsEnabled,
                channelAvailable:
                    notificationAuthorizationGranted == true
                    && notificationAlertsEnabled == true,
                quietHoursActive: quietHoursActive,
                sessionMuted: wasMuted,
                hostAppFrontmost: hostAppFrontmost,
                inputIdleSeconds: inputIdleSeconds
            )
            if agentActivityNotificationPolicy.decision(
                kind: kind,
                provider: event.provider,
                context: bannerContext,
                at: event.timestamp
            ) == .deliver {
                postAgentActivityNotification(kind: kind, for: event, sessionKey: sessionKey)
            }
        }
        // Spoken announcements are their own opt-in channel: they reach
        // the user off-screen where banners cannot, and they work even
        // without notification authorization.
        if kind == .attention {
            let voiceContext = AgentActivityNotificationContext(
                enabled: agentAttentionVoiceEnabled,
                channelAvailable: true,
                quietHoursActive: quietHoursActive,
                sessionMuted: wasMuted,
                hostAppFrontmost: hostAppFrontmost,
                inputIdleSeconds: inputIdleSeconds
            )
            if agentActivityNotificationPolicy.decision(
                kind: .attention,
                provider: event.provider,
                context: voiceContext,
                at: event.timestamp
            ) == .deliver {
                enqueueVoiceAnnouncement(
                    provider: event.provider,
                    isFailure: event.phase == .failed,
                    taskLabel: reducer.sessions[sessionKey]?.taskLabel
                )
                scheduleVoiceFollowUp(for: sessionKey, announcementsSoFar: 1)
            }
        }
    }

    /// The bounded re-announcement ladder for one unresolved ask. Every
    /// follow-up re-checks phase and presence at fire time; the first
    /// suppression — the user came back, quiet hours began, the session
    /// was muted or resolved — ends the ladder for good.
    private func scheduleVoiceFollowUp(
        for sessionKey: AgentSessionKey,
        announcementsSoFar: Int
    ) {
        voiceFollowUpTasks[sessionKey]?.cancel()
        guard announcementsSoFar < AgentActivityNotificationPolicy.voiceMaxAnnouncements else {
            voiceFollowUpTasks[sessionKey] = nil
            return
        }
        voiceFollowUpTasks[sessionKey] = Task { [weak self] in
            try? await Task.sleep(
                for: .seconds(AgentActivityNotificationPolicy.voiceRepeatInterval)
            )
            guard !Task.isCancelled else { return }
            self?.deliverVoiceFollowUp(for: sessionKey, announcementsSoFar: announcementsSoFar)
        }
    }

    private func deliverVoiceFollowUp(
        for sessionKey: AgentSessionKey,
        announcementsSoFar: Int
    ) {
        voiceFollowUpTasks[sessionKey] = nil
        guard let session = reducer.sessions[sessionKey],
              session.phase == .waitingForInput || session.phase == .failed else {
            return
        }
        let now = Date.now
        let context = AgentActivityNotificationContext(
            enabled: agentAttentionVoiceEnabled,
            channelAvailable: true,
            quietHoursActive: policy.quietHours.contains(now),
            sessionMuted: mutedSessionKeys.contains(sessionKey),
            hostAppFrontmost: providerHostAppFrontmost(sessionKey.provider),
            inputIdleSeconds: systemInputIdleSeconds
        )
        guard agentActivityNotificationPolicy.decision(
            kind: .attention,
            provider: sessionKey.provider,
            context: context,
            at: now
        ) == .deliver else { return }
        enqueueVoiceAnnouncement(
            provider: sessionKey.provider,
            isFailure: session.phase == .failed,
            taskLabel: session.taskLabel
        )
        scheduleVoiceFollowUp(for: sessionKey, announcementsSoFar: announcementsSoFar + 1)
    }

    /// Agents that stop within this window are announced as one sentence.
    /// Long enough that a parallel run reads as a single moment, short
    /// enough that the pet still answers promptly to a lone ask.
    private static let voiceAnnouncementCoalescingWindow = Duration.seconds(2)

    private func enqueueVoiceAnnouncement(
        provider: AgentProvider,
        isFailure: Bool,
        taskLabel: String? = nil
    ) {
        agentVoiceAnnouncementQueue.enqueue(
            provider: provider,
            isFailure: isFailure,
            taskLabel: taskLabel
        )
        guard agentVoiceAnnouncementTask == nil else { return }
        agentVoiceAnnouncementTask = Task { [weak self] in
            try? await Task.sleep(for: Self.voiceAnnouncementCoalescingWindow)
            self?.flushVoiceAnnouncements()
        }
    }

    private func flushVoiceAnnouncements() {
        agentVoiceAnnouncementTask = nil
        guard let line = voiceAnnouncementLine(for: agentVoiceAnnouncementQueue.flush()) else {
            return
        }
        agentVoiceAnnouncer.announce(line, languageCode: speechLanguageCode)
    }

    private func voiceAnnouncementLine(
        for summary: AgentVoiceAnnouncementQueue.Summary
    ) -> String? {
        switch summary {
        case .nothing:
            return nil
        case let .one(provider, isFailure, taskLabel):
            // Spoken form is deliberately fuller than the banner title: a
            // sentence survives being half-heard from another room.
            let key = isFailure ? "voice.agent.failed" : "voice.agent.waiting"
            var line = replace(
                localizedString(key),
                values: ["provider": providerDisplayName(provider)]
            )
            if let taskLabel, !taskLabel.isEmpty {
                line += " " + replace(
                    localizedString("voice.agent.task"),
                    values: ["task": taskLabel]
                )
            }
            return line
        case let .several(named, total, includesFailure):
            let key = includesFailure
                ? "voice.announce.several_failure"
                : "voice.announce.several"
            return replace(
                localizedString(key),
                values: [
                    "count": String(total),
                    "providers": named
                        .map(providerDisplayName)
                        .joined(separator: localizedString("voice.announce.join")),
                ]
            )
        }
    }

    /// Local read of the session-wide keyboard/mouse idle time; needs no
    /// permissions and sees no content. nil when the any-input event type
    /// cannot be formed, which the policy treats as "recently active".
    private var systemInputIdleSeconds: TimeInterval? {
        guard let anyInput = CGEventType(rawValue: ~0) else { return nil }
        return CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInput
        )
    }

    /// nil lets the synthesizer keep the system default voice, matching
    /// how the `.system` app language resolves localized text.
    private var speechLanguageCode: String? {
        switch language {
        case .english: "en-US"
        case .simplifiedChinese: "zh-CN"
        case .system: nil
        }
    }

    private func postAgentActivityNotification(
        kind: AgentActivityNotificationKind,
        for event: AgentEvent,
        sessionKey: AgentSessionKey
    ) {
        let content = UNMutableNotificationContent()
        let titleKey = switch kind {
        case .completion:
            "notification.agent.completed.title"
        case .attention:
            event.phase == .failed
                ? "notification.agent.failed.title"
                : "notification.agent.waiting.title"
        }
        content.title = replace(
            localizedString(titleKey),
            values: ["provider": providerDisplayName(event.provider)]
        )
        // Only the bounded local task label may appear; never prompts,
        // code, tool I/O, or paths.
        if let label = reducer.sessions[sessionKey]?.taskLabel, !label.isEmpty {
            content.body = label
        } else {
            content.body = localizedString(kind == .completion
                ? "notification.agent.completed.body"
                : "notification.agent.attention.body")
        }
        content.categoryIdentifier = AgentActivityNotification.category
        content.threadIdentifier = AgentActivityNotification.category
        content.userInfo = [
            AgentActivityNotification.providerKey: event.provider.rawValue,
            AgentActivityNotification.sessionIDKey: event.sessionID,
        ]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: agentActivityNotificationIdentifier(kind, key: sessionKey),
            content: content,
            trigger: nil
        ))
    }

    private func handleAgentActivityNotificationTap(
        provider: AgentProvider,
        sessionID: String?
    ) {
        if let sessionID {
            let key = AgentSessionKey(provider: provider, sessionID: sessionID)
            if let task = taskInbox.first(where: { $0.key == key }) {
                _ = focusTask(task)
                return
            }
            if let resumeURL = reducer.sessions[key]?.resumeURL,
               let url = URL(string: resumeURL),
               NSWorkspace.shared.open(url) {
                return
            }
        }
        _ = focusProvider(provider)
    }

    private func triggerPostCompletionReminder(at now: Date) {
        guard case let .deliver(channel) = reminderDeliveryCoordinator.decision(
            for: reminderDeliveryContext(at: now)
        ) else {
            if needsPersist { persist() }
            return
        }
        engine.policy = policy
        guard let candidate = engine.evaluate(
            opportunityDuration: opportunityClock.accumulated,
            at: now,
            eligibleKinds: orderedEnabledReminderKinds
        ) else {
            if needsPersist { persist() }
            return
        }
        let record = engine.record(candidate, at: now, experimentArm: activeStrategy.rawValue)
        opportunityClock.reset(at: now, state: effectiveReducer)
        updateOpportunityStage()
        records = engine.records
        needsPersist = true
        persist()
        let qualifyingMinutes = Int(candidate.qualifyingDuration / 60)
        deliverReminder(
            kind: candidate.kind,
            recordID: record.id,
            message: reminderMessage(
                for: candidate.kind,
                minutes: qualifyingMinutes,
                moment: .neutral
            ),
            qualifyingMinutes: qualifyingMinutes,
            moment: .neutral,
            channel: channel,
            at: record.triggeredAt
        )
    }

    private func handleDueSnooze(at now: Date) -> Bool {
        guard let pending = reminderDeliveryCoordinator.dueSnooze(at: now) else {
            return false
        }
        guard records.contains(where: { $0.id == pending.recordID }) else {
            reminderDeliveryCoordinator.cancel(recordID: pending.recordID)
            return true
        }
        guard case let .deliver(channel) = reminderDeliveryCoordinator.decision(
            for: reminderDeliveryContext(at: now)
        ) else {
            return true
        }
        reminderDeliveryCoordinator.markDelivered(recordID: pending.recordID)
        deliverReminder(
            kind: pending.kind,
            recordID: pending.recordID,
            message: localizedString("reminder.snoozed"),
            qualifyingMinutes: 0,
            moment: .neutral,
            channel: channel,
            at: now
        )
        return true
    }

    private func reminderDeliveryContext(at now: Date) -> ReminderDeliveryContext {
        ReminderDeliveryContext(
            companionAvailable: companionVisible && workspaceSessionActive,
            systemNotificationAvailable:
                notificationAuthorizationGranted == true
                && notificationAlertsEnabled == true,
            attentionRequired: effectiveReducer.aggregatePhase == .waitingForInput,
            quietHoursActive: policy.quietHours.contains(now),
            reminderAlreadyVisible: activeReminder != nil
        )
    }

    private func moveActiveReminderToSystemNotificationIfNeeded() {
        guard !workspaceSessionActive,
              notificationAuthorizationGranted == true,
              notificationAlertsEnabled == true,
              let reminder = activeReminder else {
            return
        }
        activeReminder = nil
        refreshPresentation()
        sendSystemNotification(
            kind: reminder.kind,
            recordID: reminder.recordID ?? reminder.id,
            message: reminder.message
        )
    }

    private func persist() {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        engine.retainRecords(since: cutoff)
        records = engine.records
        reminderDeliveryCoordinator.retainPending(
            validRecordIDs: Set(records.map(\.id)),
            dueAfter: Date.now.addingTimeInterval(-12 * 60 * 60)
        )
        waitingHistory = waitingHistory.filter { key, _ in
            guard let date = Self.dayFormatter.date(from: key) else { return false }
            return date >= cutoff
        }
        providerWorkHistory = providerWorkHistory.filter { key, _ in
            guard let date = Self.dayFormatter.date(from: key) else { return false }
            return date >= cutoff
        }
        completedTaskHistory = completedTaskHistory.filter { key, _ in
            guard let date = Self.dayFormatter.date(from: key) else { return false }
            return date >= cutoff
        }
        attentionResponses = attentionResponses.filter { $0.resolvedAt >= cutoff }
        experimentDayArms = experimentDayArms.filter { key, _ in
            guard let date = Self.dayFormatter.date(from: key) else { return false }
            return date >= cutoff
        }
        persistence.save(PersistedSnapshot(
            policy: policy,
            records: records,
            pendingSnoozes: reminderDeliveryCoordinator.pendingSnoozes,
            attentionResponses: attentionResponses,
            experimentDayArms: experimentDayArms,
            waitingDay: waitingDay,
            waitingSeconds: todayWaiting,
            language: language,
            customMessages: customMessages,
            enabledReminderKinds: orderedEnabledReminderKinds.map(\.rawValue),
            waitingHistory: waitingHistory,
            providerWorkHistory: providerWorkHistory,
            completedTaskHistory: completedTaskHistory,
            lastLifecycleEventAt: Dictionary(uniqueKeysWithValues:
                lastLifecycleEventAt.map { ($0.key.rawValue, $0.value) }
            ),
            strategy: strategy,
            companionVisible: companionVisible,
            companionRole: companionRole,
            selectedCustomPetID: selectedCustomPetID,
            companionArtVersion: 2,
            companionSkin: companionSkin,
            companionSize: companionSize,
            companionLayer: companionLayer,
            companionShowsOverFullScreen: companionShowsOverFullScreen,
            companionMotionEnabled: companionMotionEnabled,
            companionWindowAnchorEnabled: companionWindowAnchorEnabled,
            preventIdleSleepEnabled: preventIdleSleepEnabled,
            idleSleepMaxHours: idleSleepMaxHours,
            companionChatEnabled: companionChatEnabled,
            petChatEngine: petChatEngine.rawValue,
            petChatAgent: petChatAgent?.rawValue,
            voiceBridgeEnabled: voiceBridgeEnabled,
            voiceDispatchDirectory: voiceDispatchDirectory?.path,
            voiceDispatchLastProject: voiceDispatchLastProjectPath,
            onboardingCompleted: onboardingCompleted,
            agentAttentionNotificationsEnabled: agentAttentionNotificationsEnabled,
            agentCompletionNotificationsEnabled: agentCompletionNotificationsEnabled,
            agentAttentionVoiceEnabled: agentAttentionVoiceEnabled,
            agentSessions: persistableAgentSessions
        ))
    }

    /// Only sessions that are still asking something of the user are worth
    /// carrying across a restart; terminal ones have already been counted.
    private var persistableAgentSessions: [PersistedAgentSession] {
        reducer.sessions.compactMap { key, session in
            guard !session.phase.isTerminal else { return nil }
            return PersistedAgentSession(
                provider: key.provider.rawValue,
                sessionID: key.sessionID,
                phase: session.phase.rawValue,
                startedAt: session.startedAt,
                phaseStartedAt: session.phaseStartedAt,
                lastEventAt: session.lastEventAt
            )
        }
    }

    /// Sessions last heard from before the machine booted cannot still be
    /// running, whatever they claimed on the way down.
    private static var systemBootTime: Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }

    private func restoreAgentSessions(_ saved: [PersistedAgentSession]) {
        var restored: [AgentSessionKey: SessionState] = [:]
        for entry in saved {
            guard let provider = AgentProvider(rawValue: entry.provider),
                  let phase = AgentPhase(rawValue: entry.phase),
                  !phase.isTerminal else { continue }
            restored[AgentSessionKey(provider: provider, sessionID: entry.sessionID)] = SessionState(
                provider: provider,
                phase: phase,
                startedAt: entry.startedAt,
                phaseStartedAt: entry.phaseStartedAt,
                lastEventAt: entry.lastEventAt
            )
        }
        reducer.restore(restored, notBefore: Self.systemBootTime ?? .distantPast)
    }

    private func accountProviderActivity(at now: Date) {
        let elapsed = max(0, min(now.timeIntervalSince(activityAccountingAt), 30))
        activityAccountingAt = now
        guard elapsed > 0 else { return }
        let providers = Set(reducer.sessions.values.filter {
            $0.phase == .working && !$0.isSignalStale
        }.map(\.provider))
        guard !providers.isEmpty else { return }
        let key = dayKey(now)
        var totals = providerWorkHistory[key] ?? [:]
        for provider in providers {
            totals[provider.rawValue, default: 0] += elapsed
        }
        providerWorkHistory[key] = totals
    }

    private func trackAttentionResponse(for event: AgentEvent, key: AgentSessionKey) {
        if event.phase == .waitingForInput {
            if attentionStartedAt[key] == nil {
                attentionStartedAt[key] = event.timestamp
            }
            return
        }
        guard let startedAt = attentionStartedAt.removeValue(forKey: key) else { return }
        let duration = event.timestamp.timeIntervalSince(startedAt)
        guard duration >= 0, duration <= 2 * 60 * 60 else { return }
        attentionResponses.append(AttentionResponseRecord(
            provider: event.provider,
            resolvedAt: event.timestamp,
            duration: duration
        ))
    }

    private func recordExperimentArmForToday() {
        guard strategy == .crossover else { return }
        experimentDayArms[dayKey(.now)] = activeStrategy.rawValue
    }

    private func updateSleepProtection(at now: Date = .now) {
        // An interactive session alternates between working and waiting
        // for the user; both mean the session is live, and users expect the
        // screen to stay on for the whole session, not only the working
        // half. Power safeguards and the hours cap still apply.
        let hasVerifiedWorkingAgent = reducer.sessions.values.contains { session in
            ((session.phase == .working && !session.isSignalStale)
                || session.phase == .waitingForInput)
                && lifecycleConnectedProviders.contains(session.provider)
        }
        sleepProtectionState = sleepProtectionGate.evaluate(
            enabled: preventIdleSleepEnabled,
            hasVerifiedWorkingAgent: hasVerifiedWorkingAgent,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            hasLowBatteryWarning: IdleSleepProtectionController.hasLowBatteryWarning,
            at: now
        )
        sleepProtectionController.update(
            shouldPreventIdleSystemSleep: sleepProtectionState == .active
        )
    }

    func generateDiagnosticReport() {
        let now = Date()
        let providerDiagnostics = AgentProvider.allCases.map { provider in
            ProviderDiagnosticSnapshot(
                provider: provider,
                connectionStage: integrationConnectionStage(for: provider),
                lastRealEventAge: lastLifecycleEventAt[provider].map {
                    max(0, now.timeIntervalSince($0))
                }
            )
        }
        let activity = providerActivitySummaries
        let snapshot = PerchDiagnosticSnapshot(
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "development",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            receiverReady: receiverReady,
            notificationHealth: notificationHealthStage,
            providers: providerDiagnostics,
            workingTaskCount: activity.reduce(0) { $0 + $1.workingCount },
            attentionTaskCount: activity.reduce(0) { $0 + $1.attentionCount },
            failedTaskCount: activity.reduce(0) { $0 + $1.failureCount },
            todayReclaimedMinutes: Int(todayWaiting / 60),
            todayCompletedBreaks: todayCompletedBreaks,
            sevenDayReminderCount: weeklyReminderCount
        )
        do {
            let fileManager = FileManager.default
            let base = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            let directory = base
                .appendingPathComponent("Perch", isDirectory: true)
                .appendingPathComponent("Diagnostics", isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let directoryValues = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard directoryValues.isDirectory == true,
                  directoryValues.isSymbolicLink != true else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = directory.appendingPathComponent(
                "perch-diagnostic-\(formatter.string(from: now)).txt"
            )
            try DiagnosticReportRenderer.render(
                snapshot,
                generatedAt: now
            ).write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            cleanUpDiagnostics(in: directory, keep: 10)
            diagnosticExportState = .success(url.lastPathComponent)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            diagnosticExportState = .failed(error.localizedDescription)
        }
    }

    private func cleanUpDiagnostics(in directory: URL, keep: Int) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]
        ).filter({ candidate in
            guard candidate.lastPathComponent.hasPrefix("perch-diagnostic-"),
                  candidate.pathExtension == "txt",
                  let values = try? candidate.resourceValues(
                      forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ) else {
                return false
            }
            return values.isRegularFile == true
                && values.isSymbolicLink != true
        }) else { return }
        guard files.count > keep else { return }
        let sorted = files.sorted { urlA, urlB in
            let dateA = (try? urlA.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dateB = (try? urlB.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return dateA > dateB
        }
        for url in sorted.dropFirst(keep) {
            try? fileManager.removeItem(at: url)
        }
    }

    func respondToCompanionReminder(_ response: ReminderResponse) {
        guard let reminder = activeReminder else { return }
        activeReminder = nil
        refreshPresentation()
        guard let recordID = reminder.recordID else { return }
        applyReminderResponse(recordID: recordID, response: response)
    }

    func reminderText(for kind: ReminderKind) -> String {
        let code = resolvedLanguageCode
        if let custom = customMessages[code]?[kind.rawValue], !custom.isEmpty { return custom }
        return localizedString(
            "reminder.\(companionRole.rawValue).\(kind.rawValue)"
        )
    }

    func reminderPreview(for kind: ReminderKind) -> String {
        render(
            reminderText(for: kind),
            minutes: max(3, thresholdMinutes),
            providers: []
        )
    }

    func isReminderTextCustomized(_ kind: ReminderKind) -> Bool {
        let code = resolvedLanguageCode
        guard let custom = customMessages[code]?[kind.rawValue], !custom.isEmpty else {
            return false
        }
        return custom != localizedString(
            "reminder.\(companionRole.rawValue).\(kind.rawValue)"
        )
    }

    func isReminderKindEnabled(_ kind: ReminderKind) -> Bool {
        enabledReminderKinds.contains(kind)
    }

    func setReminderKind(_ kind: ReminderKind, enabled: Bool) {
        if enabled {
            enabledReminderKinds.insert(kind)
        } else if enabledReminderKinds.count > 1 {
            enabledReminderKinds.remove(kind)
        }
    }

    func uiText(_ key: String) -> String { localizedString(key) }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?app.sleepwing.Perch") else { return }
        NSWorkspace.shared.open(url)
    }

    func refreshCustomPets() {
        customPetRefreshTask?.cancel()
        customPetRefreshTask = Task { [weak self] in
            let discovery = Task.detached(priority: .utility) {
                CustomPetLibrary.discover()
            }
            let discovered = await withTaskCancellationHandler {
                await discovery.value
            } onCancel: {
                discovery.cancel()
            }
            guard !Task.isCancelled, let self else { return }
            self.customPets = discovered
            if self.companionRole == .custom, self.selectedCustomPet == nil {
                self.companionRole = .cat
                self.selectedCustomPetID = nil
            }
            self.customPetRefreshTask = nil
        }
    }

    func refreshPetCreationCapabilities() {
        refreshIntegrationStatuses()
    }

    var showsCodexPetCreation: Bool {
        PerchPetSkillInstaller.shouldShowCodexCreation(
            detectedProviders: detectedProviders
        )
    }

    func importCustomPetPackage(from sourceURL: URL) {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        do {
            let candidate = try CustomPetLibrary.load(
                directoryURL: sourceURL,
                origin: .codex,
                requiresMatchingFolderName: false
            )
            try installAndSelectCustomPet(candidate)
        } catch let error as CustomPetLibraryError {
            presentCustomPetError(error)
        } catch {
            presentCustomPetError(.cannotSave)
        }
    }

    func installAndSelectCustomPet(_ pet: CustomPetDescriptor) throws {
        let installed = pet.isInstalledInPerch
            ? pet
            : try CustomPetLibrary.install(pet)
        if let index = customPets.firstIndex(where: { $0.id == installed.id }) {
            customPets[index] = installed
        } else {
            customPets.append(installed)
        }
        customPets.sort {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        // Make the newly installed package available synchronously so the
        // selected companion cannot disappear while background discovery is
        // still checking Perch and agent-owned package folders.
        selectedCustomPetID = installed.id
        companionRole = .custom
        refreshCustomPets()
        customPetStatusMessage = replace(
            localizedString("custom_pet.status.selected"),
            values: ["name": installed.displayName]
        )
        customPetStatusIsError = false
        objectWillChange.send()
    }

    func selectCustomPet(_ pet: CustomPetDescriptor) {
        do {
            try installAndSelectCustomPet(pet)
        } catch let error as CustomPetLibraryError {
            presentCustomPetError(error)
        } catch {
            presentCustomPetError(.cannotSave)
        }
    }

    func updateCustomPetPersonality(_ pet: CustomPetDescriptor, personality: String) {
        let trimmed = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let installed = pet.isInstalledInPerch ? pet : try CustomPetLibrary.install(pet)
            _ = try CustomPetLibrary.updatePersonality(
                petID: installed.id,
                personality: trimmed.isEmpty ? nil : trimmed
            )
            refreshCustomPets()
            customPetStatusMessage = replace(
                localizedString("custom_pet.status.personality_saved"),
                values: ["name": installed.displayName]
            )
            customPetStatusIsError = false
        } catch {
            presentCustomPetError(.cannotSave)
        }
    }

    func deleteCustomPet(_ pet: CustomPetDescriptor) {
        do {
            try CustomPetLibrary.uninstall(petID: pet.id)
            refreshCustomPets()
            customPetStatusMessage = replace(
                localizedString("custom_pet.status.deleted"),
                values: ["name": pet.displayName]
            )
            customPetStatusIsError = false
        } catch {
            presentCustomPetError(.cannotSave)
        }
    }

    func installPerchPetSkill() {
        _ = installBundledPerchPetSkill()
    }

    func createCustomPetInCodex() {
        guard showsCodexPetCreation else { return }
        guard installBundledPerchPetSkill() else { return }
        var components = URLComponents(string: "codex://new")
        components?.queryItems = [
            URLQueryItem(
                name: "prompt",
                value: localizedString("custom_pet.codex_prompt")
            ),
        ]
        guard let url = components?.url, NSWorkspace.shared.open(url) else {
            customPetStatusMessage = localizedString("custom_pet.error.codex")
            customPetStatusIsError = true
            return
        }
        customPetStatusMessage = localizedString("custom_pet.status.codex_opened")
        customPetStatusIsError = false
    }

    func copyCustomPetPromptToClipboard() {
        guard installBundledPerchPetSkill() else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(localizedString("custom_pet.generic_prompt"), forType: .string)
        customPetStatusMessage = localizedString("custom_pet.status.prompt_copied")
        customPetStatusIsError = false
    }

    var petCreationAgents: [AgentProvider] {
        PerchPetSkillInstaller.creationAgents(detectedProviders: detectedProviders)
    }

    func createCustomPetFromReferenceArt(with provider: AgentProvider?) {
        guard let referenceArtURL else { return }
        guard installBundledPerchPetSkill() else { return }
        let prompt = replace(
            localizedString("custom_pet.photo_prompt"),
            values: [
                "path": referenceArtURL.path,
                "style": localizedString("custom_pet.style.\(petCreationStyle.rawValue).prompt"),
            ]
        )
        if provider == .codex {
            openCodexCreationTask(prompt: prompt)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        if let provider {
            customPetStatusMessage = replace(
                localizedString("custom_pet.status.prompt_copied_for"),
                values: ["agent": providerDisplayName(provider)]
            )
        } else {
            customPetStatusMessage = localizedString("custom_pet.status.prompt_copied")
        }
        customPetStatusIsError = false
    }

    func companionPoked() {
        guard companionChatEnabled else { return }
        let context = CompanionSmallTalk.Context(
            isWorking: companionPhase == .working,
            isWaiting: companionPhase == .waitingForInput,
            hour: Calendar.current.component(.hour, from: Date())
        )
        let roleToken = companionRoleToken
        let fallback = localizedString(
            CompanionSmallTalk.lineKey(role: roleToken, context: context)
        )
        presentCompanionChat(fallback)
        if petChatEngine == .agent, let agent = resolvedPetChatAgent {
            AgentChatRunner.prewarm(provider: agent)
        }
        guard effectivePetChatEngine == .onDevice, PetChatGenerator.isAvailable else { return }
        let facts = companionChatFacts
        let persona = companionChatPersona
        let request = replace(
            localizedString("smalltalk.request"),
            values: ["facts": facts]
        )
        Task { [weak self] in
            let reply = await PetChatGenerator.reply(
                persona: persona,
                request: request,
                fallback: fallback
            )
            guard let self, self.companionChatMessage == fallback else { return }
            self.presentCompanionChat(reply)
        }
    }

    func dismissCompanionChat() {
        companionChatDismissTask?.cancel()
        companionChatTranscript.removeAll()
        companionChatMessage = nil
    }

    private var companionRoleToken: String {
        switch companionRole {
        case .sleepwing: "bird"
        case .cat: "cat"
        default: "custom"
        }
    }

    /// A custom pet can carry its own first-person personality in its
    /// manifest; when present it becomes the chat persona, so an imported
    /// character talks like itself instead of a generic pet.
    private var companionChatPersona: String {
        if companionRole == .custom,
           let personality = selectedCustomPet?.personality,
           !personality.isEmpty {
            return personality
        }
        return localizedString("smalltalk.persona.\(companionRoleToken)")
    }

    private var companionChatFacts: String {
        if companionPhase == .waitingForInput {
            return "an agent task is waiting for the user's input"
        }
        if companionPhase == .working {
            return "an agent task is running while the user rests"
        }
        let hour = Calendar.current.component(.hour, from: Date())
        return "no agent tasks right now, local hour \(hour)"
    }

    /// The configured engine degrades to whatever this Mac can actually
    /// do right now, instead of silently collapsing into canned lines:
    /// on-device first when the OS provides it, then the user's own agent,
    /// then the library.
    var effectivePetChatEngine: PetChatEngine {
        switch petChatEngine {
        case .library:
            return .library
        case .onDevice:
            if PetChatGenerator.isAvailable { return .onDevice }
            return resolvedPetChatAgent != nil ? .agent : .library
        case .agent:
            if resolvedPetChatAgent != nil { return .agent }
            return PetChatGenerator.isAvailable ? .onDevice : .library
        }
    }

    var petChatSupportsFreeInput: Bool {
        guard companionChatEnabled else { return false }
        return effectivePetChatEngine != .library
    }

    var resolvedPetChatAgent: AgentProvider? {
        if let petChatAgent,
           PetChatAgentCommand.supportedProviders.contains(petChatAgent) {
            return petChatAgent
        }
        return PetChatAgentCommand.preferredAgent(
            detected: detectedProviders,
            lastRealEventAt: lastLifecycleEventAt
        )
    }

    func companionChatAnother() {
        guard companionChatEnabled else { return }
        let context = CompanionSmallTalk.Context(
            isWorking: companionPhase == .working,
            isWaiting: companionPhase == .waitingForInput,
            hour: Calendar.current.component(.hour, from: Date())
        )
        presentCompanionChat(localizedString(
            CompanionSmallTalk.lineKey(role: companionRoleToken, context: context)
        ))
    }

    func sendCompanionChat(_ text: String) {
        let trimmed = PetChatTextPolicy.input(text)
        guard !trimmed.isEmpty, !companionChatBusy, petChatSupportsFreeInput else { return }
        let persona = companionChatPersona
        let transcript = companionChatTranscript.suffix(3)
            .map { "User: \($0.user)\nPet: \($0.pet)" }
            .joined(separator: "\n")
        let request = replace(
            localizedString("smalltalk.chat_request"),
            values: [
                "facts": companionChatFacts,
                "transcript": transcript.isEmpty ? "-" : transcript,
                "message": trimmed,
            ]
        )
        let engine = effectivePetChatEngine
        let agent = resolvedPetChatAgent
        companionChatBusy = true
        companionChatDismissTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            // A hung engine must never leave the spinner running forever:
            // whatever finishes first wins, and the timeout arm returns nil
            // so the fallback line is shown instead.
            let reply: String? = await Self.race(seconds: 40) {
                switch engine {
                case .onDevice:
                    let generated = await PetChatGenerator.reply(
                        persona: persona,
                        request: request,
                        fallback: ""
                    )
                    return generated.isEmpty ? nil : generated
                case .agent:
                    guard let agent else { return nil }
                    return await AgentChatRunner.reply(
                        provider: agent,
                        prompt: persona + "\n\n" + request
                    )
                case .library:
                    return nil
                }
            }
            let final = PetChatTextPolicy.reply(
                reply ?? self.localizedString("smalltalk.chat_unavailable")
            )
            self.companionChatTranscript.append((user: trimmed, pet: final))
            if self.companionChatTranscript.count > PetChatTextPolicy.retainedExchangeCount {
                self.companionChatTranscript.removeFirst(
                    self.companionChatTranscript.count - PetChatTextPolicy.retainedExchangeCount
                )
            }
            self.companionChatBusy = false
            self.presentCompanionChat(final)
        }
    }

    private static func race(
        seconds: Double,
        _ operation: @escaping @Sendable () async -> String?
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func presentCompanionChat(_ text: String) {
        companionChatMessage = text
        companionChatDismissTask?.cancel()
        companionChatDismissTask = Task { [weak self] in
            let delay: Double = self?.petChatSupportsFreeInput == true ? 24 : 9
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.companionChatMessage = nil
        }
    }

    func copySkillInvocation() {
        guard installBundledPerchPetSkill() else { return }
        let localizedName = resolvedLanguageCode == "zh-Hans"
            ? "SKILL.zh-Hans.md"
            : "SKILL.md"
        var candidate = bundledPerchPetSkillURL?.appendingPathComponent(localizedName)
        if let url = candidate, !FileManager.default.fileExists(atPath: url.path) {
            candidate = bundledPerchPetSkillURL?.appendingPathComponent("SKILL.md")
        }
        guard let skillURL = candidate,
            let content = try? String(contentsOf: skillURL, encoding: .utf8) else {
            customPetStatusMessage = localizedString("custom_pet.error.skill_missing")
            customPetStatusIsError = true
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)
        customPetStatusMessage = localizedString("custom_pet.status.skill_copied")
        customPetStatusIsError = false
    }

    func createCustomPetFromIdea(with provider: AgentProvider?) {
        guard installBundledPerchPetSkill() else { return }
        if provider == .codex {
            openCodexCreationTask(prompt: localizedString("custom_pet.codex_prompt"))
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(localizedString("custom_pet.generic_prompt"), forType: .string)
        if let provider {
            customPetStatusMessage = replace(
                localizedString("custom_pet.status.prompt_copied_for"),
                values: ["agent": providerDisplayName(provider)]
            )
        } else {
            customPetStatusMessage = localizedString("custom_pet.status.prompt_copied")
        }
        customPetStatusIsError = false
    }

    /// Opening the deep link alone is not enough: long prompts can arrive
    /// truncated or the task can open empty, so the full prompt (including
    /// any reference-art path) is always placed on the clipboard as well.
    private func openCodexCreationTask(prompt: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(prompt, forType: .string)
        var components = URLComponents(string: "codex://new")
        components?.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
        if let url = components?.url, NSWorkspace.shared.open(url) {
            customPetStatusMessage = localizedString("custom_pet.status.codex_opened")
            customPetStatusIsError = false
        } else {
            customPetStatusMessage = localizedString("custom_pet.error.codex")
            customPetStatusIsError = true
        }
    }

    func chooseReferencePhoto() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.createReferenceArtFromPhoto(url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    func createReferenceArtFromPhoto(_ sourceURL: URL) {
        customPetStatusMessage = localizedString("custom_pet.status.photo_working")
        customPetStatusIsError = false
        Task { [weak self] in
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed { sourceURL.stopAccessingSecurityScopedResource() }
                }
                do {
                    let outputDirectory = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Downloads", isDirectory: true)
                        .appendingPathComponent("Sleepwing Reference Art", isDirectory: true)
                    return .success(try PhotoReferenceArtMaker.makeReferenceArt(
                        from: sourceURL,
                        outputDirectory: outputDirectory
                    ))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self else { return }
            switch result {
            case let .success(outputURL):
                self.referenceArtURL = outputURL
                NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                self.customPetStatusMessage = self.localizedString("custom_pet.status.photo_ready")
                self.customPetStatusIsError = false
            case .failure(PhotoReferenceArtError.unreadableImage):
                self.customPetStatusMessage = self.localizedString("custom_pet.error.photo_read")
                self.customPetStatusIsError = true
            case .failure(PhotoReferenceArtError.noSubjectFound):
                self.customPetStatusMessage = self.localizedString("custom_pet.error.photo_subject")
                self.customPetStatusIsError = true
            case .failure:
                self.customPetStatusMessage = self.localizedString("custom_pet.error.photo_save")
                self.customPetStatusIsError = true
            }
        }
    }

    @discardableResult
    private func installBundledPerchPetSkill() -> Bool {
        guard let sourceURL = bundledPerchPetSkillURL else {
            customPetStatusMessage = localizedString("custom_pet.error.skill_missing")
            customPetStatusIsError = true
            return false
        }
        do {
            _ = try PerchPetSkillInstaller.install(
                sourceURL: sourceURL,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                detectedProviders: detectedProviders
            )
            customPetStatusMessage = localizedString("custom_pet.status.skill_installed")
            customPetStatusIsError = false
            return true
        } catch PerchPetSkillInstallError.unmanagedDestination {
            customPetStatusMessage = localizedString("custom_pet.error.skill_conflict")
        } catch {
            customPetStatusMessage = localizedString("custom_pet.error.skill_install")
        }
        customPetStatusIsError = true
        return false
    }

    private var bundledPerchPetSkillURL: URL? {
        guard let resourceURL = PerchResources.bundle.resourceURL else { return nil }
        let skillURL = resourceURL
            .appendingPathComponent("Skills", isDirectory: true)
            .appendingPathComponent("perch-pet", isDirectory: true)
        return FileManager.default.fileExists(
            atPath: skillURL.appendingPathComponent("SKILL.md").path
        ) ? skillURL : nil
    }

    private func presentCustomPetError(_ error: CustomPetLibraryError) {
        let key: String
        switch error {
        case .missingManifest:
            key = "custom_pet.error.missing_manifest"
        case .invalidManifest:
            key = "custom_pet.error.invalid_manifest"
        case .missingSpritesheet:
            key = "custom_pet.error.missing_spritesheet"
        case .missingVisualQA:
            key = "custom_pet.error.missing_visual_qa"
        case .invalidVisualQA:
            key = "custom_pet.error.invalid_visual_qa"
        case .symbolicLink:
            key = "custom_pet.error.symbolic_link"
        case .cannotSave:
            key = "custom_pet.error.save"
        case let .validation(validationError):
            switch validationError {
            case .invalidID:
                key = "custom_pet.error.id"
            case .emptyDisplayName:
                key = "custom_pet.error.name"
            case .displayNameTooLong:
                key = "custom_pet.error.name_length"
            case .descriptionTooLong:
                key = "custom_pet.error.description_length"
            case .manifestTooLarge:
                key = "custom_pet.error.manifest_size"
            case .spritesheetTooLarge:
                key = "custom_pet.error.spritesheet_size"
            case .unsupportedSpriteVersion:
                key = "custom_pet.error.version"
            case .invalidSpritesheetPath:
                key = "custom_pet.error.path"
            case .incorrectDimensions:
                key = "custom_pet.error.dimensions"
            case .missingTransparency:
                key = "custom_pet.error.transparency"
            }
        }
        customPetStatusMessage = localizedString(key)
        customPetStatusIsError = true
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func setReminderText(_ text: String, for kind: ReminderKind) {
        let code = resolvedLanguageCode
        var messages = customMessages[code] ?? [:]
        if text == localizedString("reminder.\(kind.rawValue)") {
            messages.removeValue(forKey: kind.rawValue)
        } else {
            messages[kind.rawValue] = text
        }
        customMessages[code] = messages
    }

    func resetReminderText(for kind: ReminderKind) {
        let code = resolvedLanguageCode
        customMessages[code]?.removeValue(forKey: kind.rawValue)
    }

    private var resolvedLanguageCode: String {
        switch language {
        case .english: "en"
        case .simplifiedChinese: "zh-Hans"
        case .system: Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-Hans" : "en"
        }
    }

    private func localizedString(_ key: String) -> String {
        let resourceBundle = PerchResources.bundle
        guard let path = resourceBundle.path(forResource: resolvedLanguageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return resourceBundle.localizedString(forKey: key, value: key, table: nil)
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private func reminderMessage(
        for kind: ReminderKind,
        minutes: Int,
        moment: ReminderCopyMoment
    ) -> String {
        switch moment {
        case .activeWork:
            return render(
                reminderText(for: kind),
                minutes: minutes,
                providers: Set(workingProviders)
            )
        case .neutral:
            return render(
                localizedString("reminder.neutral.\(kind.rawValue)"),
                minutes: minutes,
                providers: []
            )
        }
    }

    private func synchronizeActiveReminderContext() {
        guard var reminder = activeReminder, reminder.moment == .activeWork else {
            return
        }
        let moment: ReminderCopyMoment = workingProviders.isEmpty ? .neutral : .activeWork
        reminder.moment = moment
        reminder.message = reminderMessage(
            for: reminder.kind,
            minutes: reminder.qualifyingMinutes,
            moment: moment
        )
        activeReminder = reminder
    }

    private func render(
        _ template: String,
        minutes: Int,
        providers active: Set<AgentProvider>? = nil
    ) -> String {
        let active = active ?? Set(reducer.sessions.values.filter {
            $0.phase == .working && !$0.isSignalStale
        }.map(\.provider))
        let providers: String
        if !active.isEmpty {
            providers = providerList(active)
        } else {
            providers = localizedString("companion.multiple_agents")
        }
        return template
            .replacingOccurrences(of: "%d", with: String(minutes))
            .replacingOccurrences(of: "{minutes}", with: String(minutes))
            .replacingOccurrences(of: "{provider}", with: providers)
    }

    private var orderedEnabledReminderKinds: [ReminderKind] {
        ReminderKind.allCases.filter(enabledReminderKinds.contains)
    }

    private func notificationTitle(for kind: ReminderKind) -> String {
        localizedString("notification.title.\(kind.rawValue)")
    }

    private static func normalizedCustomMessages(
        _ messages: [String: [String: String]]
    ) -> [String: [String: String]] {
        messages.mapValues { entries in
            entries.reduce(into: [String: String]()) { result, entry in
                let text = entry.value
                let isLegacyGeneratedCopy = text.contains("%d")
                    || text.range(of: "Agent", options: [.caseInsensitive]) != nil
                    || text.contains("水杯比它还闲")
                if !isLegacyGeneratedCopy {
                    result[entry.key] = text
                }
            }
        }
    }

    func refreshNotificationAuthorization() async {
        guard Self.systemNotificationsAvailable else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationAuthorizationDetermined = settings.authorizationStatus != .notDetermined
        notificationAuthorizationGranted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        notificationAlertsEnabled = settings.alertSetting == .enabled
        notificationSoundsEnabled = settings.soundSetting == .enabled
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func minuteOfDay(_ date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private func date(forMinute minute: Int) -> Date {
        Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
    }

    private func dayKey(_ date: Date) -> String { Self.dayFormatter.string(from: date) }
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let recordID = (userInfo[HealthReminderNotification.recordIDKey] as? String).flatMap(UUID.init)
        let agentProvider = (userInfo[AgentActivityNotification.providerKey] as? String)
            .flatMap(AgentProvider.init(rawValue:))
        let agentSessionID = userInfo[AgentActivityNotification.sessionIDKey] as? String
        let action = response.actionIdentifier
        Task { @MainActor [weak self] in
            guard let self else { completionHandler(); return }
            if let recordID {
                await self.handleNotificationResponse(recordID: recordID, action: action)
            } else if let agentProvider, action == UNNotificationDefaultActionIdentifier {
                self.handleAgentActivityNotificationTap(
                    provider: agentProvider,
                    sessionID: agentSessionID
                )
            }
            completionHandler()
        }
    }

    private func handleNotificationResponse(recordID: UUID, action: String) async {
        let result: ReminderResponse
        switch action {
        case "completed": result = .completed
        case "snoozed": result = .snoozed
        case UNNotificationDismissActionIdentifier, "skipped": result = .skipped
        default: return
        }
        if activeReminder?.recordID == recordID {
            activeReminder = nil
            refreshPresentation()
        }
        applyReminderResponse(recordID: recordID, response: result)
    }

    private func applyReminderResponse(recordID: UUID, response result: ReminderResponse) {
        let reminderKind = records.first(where: { $0.id == recordID })?.kind ?? .hydrate
        engine.respond(to: recordID, with: result)
        records = engine.records
        if result == .snoozed {
            reminderDeliveryCoordinator.scheduleSnooze(
                recordID: recordID,
                kind: reminderKind,
                at: .now
            )
        } else {
            reminderDeliveryCoordinator.cancel(recordID: recordID)
        }
        needsPersist = true
        persist()
    }

    private func refreshPresentation(
        completedEdge: Bool = false,
        activityResumed: Bool = false,
        at now: Date = .now
    ) {
        let effectiveReducer = effectiveReducer
        presentationState = presentationReducer.derive(
            agentPhase: effectiveReducer.aggregatePhase,
            completedEdge: completedEdge,
            activityResumed: activityResumed,
            healthReminder: activeReminder?.kind,
            healthOpportunityCue: opportunityStage == .microCue,
            at: now
        )
        if effectiveReducer.hasFailedSessions {
            phase = .failed
            updateCompanionSpaceBehavior()
            return
        }
        switch presentationState {
        case .resting:
            phase = .idle
        case .working, .healthOpportunity:
            phase = .working
        case .healthNudge:
            phase = effectiveReducer.aggregatePhase == .working ? .working : .idle
        case .needsAttention:
            phase = .waitingForInput
        case .celebrating:
            phase = .done
        }
        updateCompanionSpaceBehavior()
    }

    private func updateOpportunityStage() {
        guard activeStrategy == .agentAware || activeStrategy == .hybrid else {
            opportunityStage = .inactive
            return
        }
        opportunityStage = opportunityLadder.stage(
            opportunityDuration: opportunityClock.accumulated,
            isEligible: effectiveReducer.isHealthOpportunityActive,
            reminderThreshold: policy.waitingThreshold
        )
    }

    private func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled || status == .requiresApproval
        launchAtLoginNeedsApproval = status == .requiresApproval
    }
}

struct DailyPoint: Identifiable {
    let date: Date
    let waitingMinutes: Double
    let reminders: Int
    var id: Date { date }
}
