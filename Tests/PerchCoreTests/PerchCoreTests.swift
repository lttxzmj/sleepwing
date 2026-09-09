import CryptoKit
import Foundation
import Testing
@testable import PerchCore

@Test func integrationFilesUseLeastPrivilegePermissions() {
    #expect(IntegrationFilePermissions.token == 0o600)
    #expect(IntegrationFilePermissions.configuration == 0o600)
    #expect(IntegrationFilePermissions.executable == 0o755)
}

@Test func integrationTokensFailClosedAndCompareExactly() {
    let token = String(repeating: "a1", count: IntegrationTokenPolicy.randomByteCount)
    #expect(IntegrationTokenPolicy.isValid(token))
    #expect(!IntegrationTokenPolicy.isValid(""))
    #expect(!IntegrationTokenPolicy.isValid(String(repeating: "0", count: 63)))
    #expect(!IntegrationTokenPolicy.isValid(String(repeating: "G", count: 64)))
    #expect(IntegrationTokenPolicy.securelyMatches(token, expected: token))
    #expect(
        !IntegrationTokenPolicy.securelyMatches(
            String(repeating: "b2", count: IntegrationTokenPolicy.randomByteCount),
            expected: token
        )
    )
    #expect(!IntegrationTokenPolicy.securelyMatches("", expected: ""))
}

@Test func providerBrandIdentityMatchesCurrentHostProducts() {
    #expect(AgentProvider.codex.brandName == "ChatGPT")
    #expect(AgentProvider.codex.applicationBundleNames.first == "ChatGPT.app")
    #expect(AgentProvider.codex.applicationBundleNames.contains("Codex.app"))
    #expect(AgentProvider.opencode.brandName == "OpenCode")
    #expect(AgentProvider.gemini.brandName == "Gemini CLI")
    #expect(AgentProvider.pi.brandName == "Pi")
    #expect(AgentProvider.trae.applicationBundleNames.contains("Trae CN.app"))
    #expect(AgentProvider.gemini.applicationBundleNames.isEmpty)
}

@Test func perchPetSkillCodexEntryOnlyAppearsWhenCodexIsDetected() {
    #expect(!PerchPetSkillInstaller.shouldShowCodexCreation(detectedProviders: []))
    #expect(
        !PerchPetSkillInstaller.shouldShowCodexCreation(
            detectedProviders: [.claude, .cursor]
        )
    )
    #expect(
        PerchPetSkillInstaller.shouldShowCodexCreation(
            detectedProviders: [.claude, .codex]
        )
    )
}

@Test func perchPetSkillUsesUniversalLocationAndClaudeCompatibilityLocation() {
    let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    let general = PerchPetSkillInstaller.destinationURLs(
        homeDirectory: home,
        detectedProviders: [.codex, .cursor, .gemini, .opencode, .trae]
    )
    #expect(general.map(\.path) == ["/Users/tester/.agents/skills/perch-pet"])

    let withClaude = PerchPetSkillInstaller.destinationURLs(
        homeDirectory: home,
        detectedProviders: [.claude, .codex]
    )
    #expect(
        withClaude.map(\.path) == [
            "/Users/tester/.agents/skills/perch-pet",
            "/Users/tester/.claude/skills/perch-pet",
        ]
    )
}

@Test func perchPetSkillInstallerCopiesAndUpdatesOnlyManagedSkill() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "perch-skill-test-\(UUID().uuidString)",
        isDirectory: true
    )
    defer { try? fileManager.removeItem(at: root) }
    let source = root.appendingPathComponent("source/perch-pet", isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    try fileManager.createDirectory(at: source, withIntermediateDirectories: true)
    try Data("---\nname: perch-pet\ndescription: Test\n---\nversion one\n".utf8)
        .write(to: source.appendingPathComponent("SKILL.md"))

    let first = try PerchPetSkillInstaller.install(
        sourceURL: source,
        homeDirectory: home,
        detectedProviders: [.codex],
        fileManager: fileManager
    )
    #expect(first.installedURLs.count == 1)
    let installedSkill = first.installedURLs[0].appendingPathComponent("SKILL.md")
    #expect(try String(contentsOf: installedSkill, encoding: .utf8).contains("version one"))

    try Data("---\nname: perch-pet\ndescription: Test\n---\nversion two\n".utf8)
        .write(to: source.appendingPathComponent("SKILL.md"), options: .atomic)
    _ = try PerchPetSkillInstaller.install(
        sourceURL: source,
        homeDirectory: home,
        detectedProviders: [.codex],
        fileManager: fileManager
    )
    #expect(try String(contentsOf: installedSkill, encoding: .utf8).contains("version two"))

    try Data("---\nname: someone-else\ndescription: Test\n---\n".utf8)
        .write(to: installedSkill, options: .atomic)
    #expect(throws: PerchPetSkillInstallError.unmanagedDestination) {
        _ = try PerchPetSkillInstaller.install(
            sourceURL: source,
            homeDirectory: home,
            detectedProviders: [.codex],
            fileManager: fileManager
        )
    }
}

@Test func customPetPackagesRequireTheCodexV2Contract() {
    #expect(throws: Never.self) {
        try CustomPetPackagePolicy.validate(
            id: "quiet-fox",
            displayName: "Quiet Fox",
            spriteVersionNumber: 2,
            spritesheetPath: "spritesheet.webp",
            manifestBytes: 1_024,
            spritesheetBytes: 2_000_000,
            pixelWidth: 1_536,
            pixelHeight: 2_288,
            hasAlpha: true
        )
    }
    #expect(throws: CustomPetPackageValidationError.unsupportedSpriteVersion) {
        try CustomPetPackagePolicy.validate(
            id: "quiet-fox",
            displayName: "Quiet Fox",
            spriteVersionNumber: 1,
            spritesheetPath: "spritesheet.webp",
            manifestBytes: 1_024,
            spritesheetBytes: 2_000_000,
            pixelWidth: 1_536,
            pixelHeight: 1_872,
            hasAlpha: true
        )
    }
    #expect(throws: CustomPetPackageValidationError.invalidSpritesheetPath) {
        try CustomPetPackagePolicy.validate(
            id: "quiet-fox",
            displayName: "Quiet Fox",
            spriteVersionNumber: 2,
            spritesheetPath: "../spritesheet.webp",
            manifestBytes: 1_024,
            spritesheetBytes: 2_000_000,
            pixelWidth: 1_536,
            pixelHeight: 2_288,
            hasAlpha: true
        )
    }
    #expect(CustomPetPackagePolicy.isValidID("perch-cat"))
    #expect(!CustomPetPackagePolicy.isValidID("Perch Cat"))
}

@Test func customPetPackageSizesAreRejectedBeforeDecoding() {
    #expect(throws: CustomPetPackageValidationError.manifestTooLarge) {
        try CustomPetPackagePolicy.validateManifestSize(
            CustomPetPackagePolicy.maximumManifestBytes + 1
        )
    }
    #expect(throws: CustomPetPackageValidationError.spritesheetTooLarge) {
        try CustomPetPackagePolicy.validateSpritesheetSize(
            CustomPetPackagePolicy.maximumSpritesheetBytes + 1
        )
    }
    #expect(throws: Never.self) {
        try CustomPetPackagePolicy.validateManifestSize(
            CustomPetPackagePolicy.maximumManifestBytes
        )
        try CustomPetPackagePolicy.validateSpritesheetSize(
            CustomPetPackagePolicy.maximumSpritesheetBytes
        )
    }
    #expect(throws: CustomPetPackageValidationError.displayNameTooLong) {
        try CustomPetPackagePolicy.validateDisplayText(
            displayName: String(repeating: "p", count: 65),
            description: ""
        )
    }
    #expect(throws: CustomPetPackageValidationError.descriptionTooLong) {
        try CustomPetPackagePolicy.validateDisplayText(
            displayName: "Perch",
            description: String(repeating: "p", count: 241)
        )
    }
}

@Test func customPetVisualQAAcceptsOnlyPassingBoundedPackagerEvidence() {
    let digest = String(repeating: "a", count: 64)
    let valid = Data("""
    {
      "ok": true,
      "contract": "perch-motion-v2",
      "spriteVersionNumber": 2,
      "visualQA": {
        "status": "passed",
        "evidenceType": "hatch-pet-run-summary",
        "evidenceSHA256": "\(digest)"
      }
    }
    """.utf8)
    #expect(throws: Never.self) {
        try CustomPetVisualQAPolicy.validate(valid)
    }

    let failed = Data("""
    {
      "ok": true,
      "contract": "perch-motion-v2",
      "spriteVersionNumber": 2,
      "visualQA": {
        "status": "not-reviewed",
        "evidenceType": "host-review",
        "evidenceSHA256": "\(digest)"
      }
    }
    """.utf8)
    #expect(throws: CustomPetVisualQAValidationError.failedReview) {
        try CustomPetVisualQAPolicy.validate(failed)
    }

    let oversized = Data(
        repeating: 0x20,
        count: CustomPetPackagePolicy.maximumManifestBytes + 1
    )
    #expect(throws: CustomPetVisualQAValidationError.invalidSummary) {
        try CustomPetVisualQAPolicy.validate(oversized)
    }
}

@Test func codexPetV2ContractKeepsExpectedGeometryAndRows() {
    #expect(PetSpriteContract.spriteVersionNumber == 2)
    #expect(PetSpriteContract.columns == 8)
    #expect(PetSpriteContract.rows == 11)
    #expect(PetSpriteContract.cellWidth == 192)
    #expect(PetSpriteContract.cellHeight == 208)
    #expect(PetSpriteContract.atlasWidth == 1_536)
    #expect(PetSpriteContract.atlasHeight == 2_288)

    let expectedRows: [PetAnimationState: Int] = [
        .idle: 0,
        .runningRight: 1,
        .runningLeft: 2,
        .waving: 3,
        .jumping: 4,
        .failed: 5,
        .waiting: 6,
        .running: 7,
        .review: 8,
    ]
    #expect(Set(expectedRows.keys) == Set(PetAnimationState.allCases))
    for (state, row) in expectedRows {
        let animation = PetSpriteContract.animation(for: state)
        #expect(animation.row == row)
        #expect((1 ... PetSpriteContract.columns).contains(animation.frameCount))
    }
}

@Test func petSpriteFingerprintsChangeOnlyWhenAFileRevisionChanges() {
    let bundled = PetSpriteSourceFingerprint(resourceName: "perch-cat")
    #expect(bundled.stableSourceKey == "bundle:perch-cat")
    #expect(bundled.revisionKey == bundled.stableSourceKey)

    let first = PetSpriteSourceFingerprint(
        resourceName: "",
        filePath: "/tmp/pet/spritesheet.png",
        modificationTime: 10,
        fileSize: 2_048
    )
    let same = PetSpriteSourceFingerprint(
        resourceName: "",
        filePath: "/tmp/pet/spritesheet.png",
        modificationTime: 10,
        fileSize: 2_048
    )
    let updated = PetSpriteSourceFingerprint(
        resourceName: "",
        filePath: "/tmp/pet/spritesheet.png",
        modificationTime: 11,
        fileSize: 2_048
    )
    #expect(first == same)
    #expect(first.stableSourceKey == updated.stableSourceKey)
    #expect(first.revisionKey != updated.revisionKey)
}

@Test func petSpriteCacheIndexEvictsTheLeastRecentlyUsedSource() {
    var index = PetSpriteCacheIndex(capacity: 2)
    #expect(index.touch("cat").isEmpty)
    #expect(index.touch("bird").isEmpty)
    #expect(index.touch("cat").isEmpty)
    #expect(index.sourceKeys == ["bird", "cat"])
    #expect(index.touch("custom") == ["bird"])
    #expect(index.sourceKeys == ["cat", "custom"])
}

@Test func petSpriteCachePolicyIsBounded() {
    #expect(PetSpriteCachePolicy.maximumTrackedSources > 1)
    #expect(
        PetSpriteCachePolicy.maximumAtlasCount
            <= PetSpriteCachePolicy.maximumTrackedSources
    )
    #expect(
        PetSpriteCachePolicy.maximumFrameCount
            < PetSpriteContract.rows
                * PetSpriteContract.columns
                * PetSpriteCachePolicy.maximumTrackedSources
    )
    #expect(PetSpriteCachePolicy.atlasByteCost > PetSpriteCachePolicy.frameByteCost)
}

@Test func codexPetAnimationFramesFollowDeclaredTiming() {
    let idle = PetSpriteContract.animation(for: .idle)
    #expect(idle.frameCount == 6)
    #expect(idle.frameIndex(at: 0) == 0)
    #expect(idle.frameIndex(at: 0.899) == 0)
    #expect(idle.frameIndex(at: 0.900) == 1)
    #expect(idle.frameIndex(at: idle.duration) == 0)

    let waving = PetSpriteContract.animation(for: .waving)
    #expect(waving.frameCount == 4)
    #expect(waving.frameIndex(at: 1.259) == 2)
    #expect(waving.frameIndex(at: 1.261) == 3)
    #expect(waving.duration >= 2.5)
    #expect(waving.playback == .onceHoldLast)
    #expect(waving.frameIndex(at: waving.duration + 10) == waving.frameCount - 1)
    #expect(idle.nextFrameBoundary(after: 0) == 0.9)
    #expect(idle.nextFrameBoundary(after: 0.9) == 1.04)
    #expect(waving.nextFrameBoundary(after: waving.duration + 10) == nil)
}

@Test func persistentPetStatesHaveCalmLoopCadence() {
    let persistentStates: [PetAnimationState] = [
        .idle,
        .waiting,
        .running,
        .review,
    ]

    for state in persistentStates {
        let animation = PetSpriteContract.animation(for: state)
        #expect(
            animation.duration >= 1.8,
            "\(state.rawValue) should not machine-loop at a distracting sub-second cadence."
        )
        #expect(
            animation.frameDurations.last ?? 0 >= 0.5,
            "\(state.rawValue) should rest at the end of its gesture before repeating."
        )
    }
}

@Test func transientPetStatesPlayOnceAndHoldTheirResolution() {
    for state in [PetAnimationState.waving, .jumping, .failed] {
        let animation = PetSpriteContract.animation(for: state)
        #expect(animation.playback == .onceHoldLast)
        #expect(animation.frameIndex(at: animation.duration * 2) == animation.frameCount - 1)
    }

    // The celebration is one deliberate pass, not a sprint: the original
    // 1.8-second arc read as fast-forward next to its caption.
    let jump = PetSpriteContract.animation(for: .jumping)
    #expect(jump.duration >= 3)

    // Everything that shows text against the celebration derives its window
    // from the same constant, sized to outlast visible motion by only a
    // brief settle — the held landing frame is not motion and must not
    // stretch the caption.
    #expect(jump.motionDuration < jump.activeDuration)
    #expect(PetSpriteContract.celebrationWindow > jump.motionDuration)
    #expect(PetSpriteContract.celebrationWindow < jump.motionDuration + 1)
    #expect(PetSpriteContract.celebrationWindow < jump.activeDuration)
}

@Test func boundedReplayPlaysItsPassesThenHoldsTheLastFrame() {
    // Not used by a built-in row today, but part of the playback vocabulary:
    // a fixed number of passes, then the resolution holds.
    let row = PetAnimationRow(
        state: .jumping,
        row: 4,
        frameDurations: [0.2, 0.3, 0.5],
        playback: .repeatHoldLast(passes: 2)
    )
    #expect(row.activeDuration == 2.0)
    #expect(row.frameIndex(at: 1.05) == 0, "the second pass replays from the top")
    #expect(row.frameIndex(at: 2.5) == row.frameCount - 1)
    #expect(row.nextFrameBoundary(after: 1.05) != nil)
    #expect(row.nextFrameBoundary(after: 2.01) == nil)
}

@Test func pointerDirectionsUseTheFullV2LookAtlasWithDeadZoneAndHysteresis() {
    #expect(PetLookDirection.resolve(deltaX: 0, deltaY: 20) == nil)

    let up = PetLookDirection.resolve(deltaX: 0, deltaY: 100)
    let right = PetLookDirection.resolve(deltaX: 100, deltaY: 0)
    let down = PetLookDirection.resolve(deltaX: 0, deltaY: -100)
    let left = PetLookDirection.resolve(deltaX: -100, deltaY: 0)

    #expect(up == PetLookDirection(index: 0))
    #expect(right == PetLookDirection(index: 4))
    #expect(down == PetLookDirection(index: 8))
    #expect(left == PetLookDirection(index: 12))
    #expect(up?.row == 9)
    #expect(down?.row == 10)

    let stillUp = PetLookDirection.resolve(
        deltaX: 24,
        deltaY: 100,
        current: up
    )
    #expect(stillUp == up)
}

@Test func companionStateMapsToCodexPetSemantics() {
    #expect(PetSpriteContract.animationState(
        phase: .idle,
        presentation: .resting
    ) == .idle)
    #expect(PetSpriteContract.animationState(
        phase: .working,
        presentation: .working
    ) == .running)
    #expect(PetSpriteContract.animationState(
        phase: .working,
        presentation: .healthOpportunity
    ) == .review)
    #expect(PetSpriteContract.animationState(
        phase: .waitingForInput,
        presentation: .needsAttention
    ) == .waiting)
    #expect(PetSpriteContract.animationState(
        phase: .done,
        presentation: .celebrating
    ) == .jumping)
    #expect(PetSpriteContract.animationState(
        phase: .working,
        presentation: .healthNudge(.stand)
    ) == .waving)
    for kind in ReminderKind.allCases {
        #expect(PetSpriteContract.animationState(
            phase: .working,
            presentation: .healthNudge(kind)
        ) == .waving)
    }
    #expect(PetSpriteContract.animationState(
        phase: .failed,
        presentation: .resting
    ) == .failed)
}

@Test func diagnosticReportContainsOnlyBoundedOperationalFields() {
    let snapshot = PerchDiagnosticSnapshot(
        appVersion: "0.3",
        operatingSystemVersion: "macOS test",
        receiverReady: true,
        notificationHealth: .alertsDisabled,
        providers: [
            ProviderDiagnosticSnapshot(
                provider: .gemini,
                connectionStage: .awaitingRealState,
                lastRealEventAge: nil
            ),
            ProviderDiagnosticSnapshot(
                provider: .codex,
                connectionStage: .live,
                lastRealEventAge: 120
            ),
        ],
        workingTaskCount: 2,
        attentionTaskCount: 1,
        failedTaskCount: 0,
        todayReclaimedMinutes: 18,
        todayCompletedBreaks: 3,
        sevenDayReminderCount: 7
    )
    let report = DiagnosticReportRenderer.render(
        snapshot,
        generatedAt: Date(timeIntervalSince1970: 0)
    )

    #expect(report.contains("Privacy: contains no prompts, code, responses"))
    #expect(report.contains("Codex: verified by real task; last real event: 2 min ago"))
    #expect(report.contains("Gemini CLI: local connection ready; awaiting real task"))
    #expect(report.contains("Notifications: permission allowed; banners disabled"))
    #expect(report.contains("Working tasks: 2"))
    #expect(report.contains("Reclaimed today: 18 min"))
    #expect(!report.contains("session_id"))
    #expect(!report.contains("/Users/"))
}

@Test func notificationHealthDistinguishesPermissionFromVisibleAlerts() {
    #expect(NotificationHealthPolicy.stage(
        authorizationDetermined: false,
        authorizationGranted: nil,
        alertsEnabled: nil
    ) == .undetermined)
    #expect(NotificationHealthPolicy.stage(
        authorizationDetermined: true,
        authorizationGranted: false,
        alertsEnabled: false
    ) == .blocked)
    #expect(NotificationHealthPolicy.stage(
        authorizationDetermined: true,
        authorizationGranted: true,
        alertsEnabled: false
    ) == .alertsDisabled)
    #expect(NotificationHealthPolicy.stage(
        authorizationDetermined: true,
        authorizationGranted: true,
        alertsEnabled: true
    ) == .ready)
}

@Test func integrationEventRecencyUsesHumanScaleBoundaries() {
    let now = Date(timeIntervalSince1970: 100_000)
    #expect(IntegrationEventRecencyPolicy.recency(
        lastEventAt: now.addingTimeInterval(-59),
        now: now
    ) == .justNow)
    #expect(IntegrationEventRecencyPolicy.recency(
        lastEventAt: now.addingTimeInterval(-60),
        now: now
    ) == .minutes(1))
    #expect(IntegrationEventRecencyPolicy.recency(
        lastEventAt: now.addingTimeInterval(-3_599),
        now: now
    ) == .minutes(59))
    #expect(IntegrationEventRecencyPolicy.recency(
        lastEventAt: now.addingTimeInterval(-3_600),
        now: now
    ) == .hours(1))
    #expect(IntegrationEventRecencyPolicy.recency(
        lastEventAt: now.addingTimeInterval(-86_400),
        now: now
    ) == .days(1))
}

@Test func localReceiverRecoveryBacksOffAndResetsAfterSuccess() {
    var policy = LocalReceiverRecoveryPolicy()
    #expect(policy.registerFailure() == 1)
    #expect(policy.registerFailure() == 2)
    #expect(policy.registerFailure() == 4)
    #expect(policy.registerFailure() == 8)
    #expect(policy.registerFailure() == 8)
    #expect(policy.consecutiveFailures == 5)

    policy.registerReady()
    #expect(policy.consecutiveFailures == 0)
    #expect(policy.registerFailure() == 1)
}

@Test func companionBadgeColorsKeepWhiteSymbolsReadable() {
    for tone in CompanionSemanticTone.allCases {
        let background = CompanionVisualPalette.badgeBackground(for: tone)
        #expect(
            background.contrastRatio(with: .white) >= 4.5,
            "Badge tone \(tone) must keep its white state symbol readable."
        )
    }
}

@Test func integrationConnectionPolicyExplainsTheNextUserAction() {
    let disconnected = IntegrationConnectionSignals(
        isInstalled: false,
        isChecking: false,
        checkFailed: false,
        relayVerified: false,
        lifecycleConnected: false
    )
    let checking = IntegrationConnectionSignals(
        isInstalled: true,
        isChecking: true,
        checkFailed: false,
        relayVerified: false,
        lifecycleConnected: false
    )
    let failed = IntegrationConnectionSignals(
        isInstalled: true,
        isChecking: false,
        checkFailed: true,
        relayVerified: false,
        lifecycleConnected: false
    )
    let readyForTask = IntegrationConnectionSignals(
        isInstalled: true,
        isChecking: false,
        checkFailed: false,
        relayVerified: true,
        lifecycleConnected: false
    )
    let live = IntegrationConnectionSignals(
        isInstalled: true,
        isChecking: false,
        checkFailed: false,
        relayVerified: true,
        lifecycleConnected: true
    )

    #expect(IntegrationConnectionPolicy.stage(receiverReady: false, signals: live) == .receiverUnavailable)
    #expect(IntegrationConnectionPolicy.stage(receiverReady: true, signals: disconnected) == .notConnected)
    #expect(IntegrationConnectionPolicy.stage(receiverReady: true, signals: checking) == .checking)
    #expect(IntegrationConnectionPolicy.stage(receiverReady: true, signals: failed) == .checkFailed)
    #expect(IntegrationConnectionPolicy.stage(
        receiverReady: true,
        signals: IntegrationConnectionSignals(
            isInstalled: false,
            isChecking: false,
            checkFailed: true,
            relayVerified: false,
            lifecycleConnected: false
        )
    ) == .checkFailed)
    #expect(IntegrationConnectionPolicy.stage(receiverReady: true, signals: readyForTask) == .awaitingRealState)
    #expect(IntegrationConnectionPolicy.stage(receiverReady: true, signals: live) == .live)
}

@Test func overallIntegrationHealthKeepsUnfinishedConnectionsVisible() {
    #expect(IntegrationConnectionPolicy.overallStage(
        receiverReady: true,
        providerStages: [.live, .awaitingRealState, .notConnected]
    ) == .awaitingRealState)
    #expect(IntegrationConnectionPolicy.overallStage(
        receiverReady: true,
        providerStages: [.live, .checkFailed]
    ) == .checkFailed)
    #expect(IntegrationConnectionPolicy.overallStage(
        receiverReady: true,
        providerStages: [.live, .checking]
    ) == .checking)
    #expect(IntegrationConnectionPolicy.overallStage(
        receiverReady: true,
        providerStages: [.live, .live]
    ) == .live)
}

@Test func stateReducerIgnoresStaleEvents() {
    let start = Date(timeIntervalSince1970: 1_000)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .claude, sessionID: "a", phase: .working, timestamp: start))
    reducer.ingest(AgentEvent(provider: .claude, sessionID: "a", phase: .idle, timestamp: start.addingTimeInterval(-1)))
    #expect(reducer.aggregatePhase == .working)
}

@Test func sessionsFromDifferentProvidersDoNotCollide() {
    let now = Date(timeIntervalSince1970: 1_000)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .claude, sessionID: "same", phase: .working, timestamp: now))
    reducer.ingest(AgentEvent(provider: .cursor, sessionID: "same", phase: .waitingForInput, timestamp: now))
    #expect(reducer.sessions.count == 2)
    #expect(reducer.aggregatePhase == .waitingForInput)
}

@Test func taskInboxPrioritizesAttentionAndKeepsMutedTasksVisible() {
    let start = Date(timeIntervalSince1970: 1_000)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(
        provider: .cursor,
        sessionID: "working",
        phase: .working,
        timestamp: start,
        taskLabel: "Perch",
        taskLabelKind: .workspace
    ))
    reducer.ingest(AgentEvent(provider: .codex, sessionID: "waiting", phase: .working, timestamp: start))
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "waiting",
        phase: .waitingForInput,
        timestamp: start.addingTimeInterval(20)
    ))
    let muted = AgentSessionKey(provider: .codex, sessionID: "waiting")
    let visible = AgentTaskInbox.entries(sessions: reducer.sessions, mutedSessionKeys: [])
    let mutedEntries = AgentTaskInbox.entries(sessions: reducer.sessions, mutedSessionKeys: [muted])

    #expect(visible.map(\.key) == [muted, AgentSessionKey(provider: .cursor, sessionID: "working")])
    #expect(visible.last?.taskLabelKind == .workspace)
    #expect(mutedEntries.last?.key == muted)
    #expect(mutedEntries.last?.isMuted == true)
}

@Test func mutingAttentionDoesNotHideResumedWork() {
    let start = Date(timeIntervalSince1970: 1_000)
    let key = AgentSessionKey(provider: .codex, sessionID: "task")
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .codex, sessionID: "task", phase: .waitingForInput, timestamp: start))
    #expect(reducer.applyingAttentionMutes([key]).aggregatePhase == .idle)

    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "task",
        phase: .working,
        timestamp: start.addingTimeInterval(10)
    ))
    #expect(reducer.applyingAttentionMutes([key]).aggregatePhase == .working)
    #expect(reducer.applyingAttentionMutes([key]).isHealthOpportunityActive)
}

@Test func completionIsAnEdgeAndDoesNotHideOtherWork() {
    let now = Date(timeIntervalSince1970: 2_000)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .claude, sessionID: "a", phase: .working, timestamp: now))
    reducer.ingest(AgentEvent(provider: .cursor, sessionID: "b", phase: .working, timestamp: now))
    let completion = reducer.ingest(AgentEvent(provider: .cursor, sessionID: "b", phase: .done, timestamp: now.addingTimeInterval(1)))
    let duplicate = reducer.ingest(AgentEvent(provider: .cursor, sessionID: "b", phase: .done, timestamp: now.addingTimeInterval(2)))
    #expect(completion.didComplete)
    #expect(!duplicate.didComplete)
    #expect(reducer.aggregatePhase == .working)
}

@Test func companionPresentationUsesAttentionHealthAndCompletionPriority() {
    let start = Date(timeIntervalSince1970: 2_000)
    var presentation = CompanionPresentationReducer()

    #expect(presentation.derive(agentPhase: .working, at: start) == .working)
    #expect(presentation.derive(
        agentPhase: .working,
        healthReminder: .hydrate,
        at: start.addingTimeInterval(1)
    ) == .healthNudge(.hydrate))
    #expect(presentation.derive(
        agentPhase: .working,
        healthOpportunityCue: true,
        at: start.addingTimeInterval(1.5)
    ) == .healthOpportunity)
    #expect(presentation.derive(
        agentPhase: .waitingForInput,
        healthReminder: .hydrate,
        healthOpportunityCue: true,
        at: start.addingTimeInterval(2)
    ) == .needsAttention)
    #expect(presentation.derive(
        agentPhase: .working,
        completedEdge: true,
        at: start.addingTimeInterval(3)
    ) == .celebrating)
    #expect(presentation.derive(
        agentPhase: .working,
        activityResumed: true,
        at: start.addingTimeInterval(4)
    ) == .working)
    #expect(presentation.derive(
        agentPhase: .working,
        at: start.addingTimeInterval(7)
    ) == .working)
}

@Test func healthOpportunityLadderIsSilentThenSubtleThenReady() {
    let ladder = HealthOpportunityLadder(microCueThreshold: 60)

    #expect(ladder.stage(
        opportunityDuration: 59,
        isEligible: true,
        reminderThreshold: 180
    ) == .silent)
    #expect(ladder.stage(
        opportunityDuration: 60,
        isEligible: true,
        reminderThreshold: 180
    ) == .microCue)
    #expect(ladder.stage(
        opportunityDuration: 180,
        isEligible: true,
        reminderThreshold: 180
    ) == .reminderReady)
    #expect(ladder.stage(
        opportunityDuration: 120,
        isEligible: false,
        reminderThreshold: 180
    ) == .inactive)
}

@Test func waitingTakesPriorityAcrossSessions() {
    let now = Date(timeIntervalSince1970: 1_000)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .cursor, sessionID: "a", phase: .working, timestamp: now))
    reducer.ingest(AgentEvent(provider: .claude, sessionID: "b", phase: .waitingForInput, timestamp: now))
    #expect(reducer.aggregatePhase == .waitingForInput)
}

@Test func healthOpportunityCountsParallelWorkOnceAndPausesForAttention() {
    let start = Date(timeIntervalSince1970: 5_000)
    var reducer = AgentStateReducer()
    var clock = HealthOpportunityClock()

    reducer.ingest(AgentEvent(provider: .claude, sessionID: "a", phase: .working, timestamp: start))
    clock.transition(to: reducer, at: start)
    reducer.ingest(AgentEvent(provider: .cursor, sessionID: "b", phase: .working, timestamp: start.addingTimeInterval(60)))
    clock.transition(to: reducer, at: start.addingTimeInterval(60))
    for seconds in stride(from: 120, through: 600, by: 60) {
        clock.transition(to: reducer, at: start.addingTimeInterval(TimeInterval(seconds)))
    }
    #expect(clock.accumulated == 600)

    reducer.ingest(AgentEvent(provider: .cursor, sessionID: "b", phase: .waitingForInput, timestamp: start.addingTimeInterval(600)))
    clock.transition(to: reducer, at: start.addingTimeInterval(600))
    clock.transition(to: reducer, at: start.addingTimeInterval(900))
    #expect(clock.accumulated == 600)

    reducer.ingest(AgentEvent(provider: .cursor, sessionID: "b", phase: .idle, timestamp: start.addingTimeInterval(900)))
    clock.transition(to: reducer, at: start.addingTimeInterval(900))
    clock.transition(to: reducer, at: start.addingTimeInterval(960))
    #expect(clock.accumulated == 660)
}

@Test func healthOpportunityResetsAfterFiveIdleMinutes() {
    let start = Date(timeIntervalSince1970: 6_000)
    var reducer = AgentStateReducer()
    var clock = HealthOpportunityClock()
    reducer.ingest(AgentEvent(provider: .codex, sessionID: "a", phase: .working, timestamp: start))
    clock.transition(to: reducer, at: start)
    for seconds in stride(from: 60, through: 180, by: 60) {
        clock.transition(to: reducer, at: start.addingTimeInterval(TimeInterval(seconds)))
    }
    reducer.ingest(AgentEvent(provider: .codex, sessionID: "a", phase: .idle, timestamp: start.addingTimeInterval(180)))
    clock.transition(to: reducer, at: start.addingTimeInterval(180))
    clock.transition(to: reducer, at: start.addingTimeInterval(480))
    #expect(clock.accumulated == 0)
}

@Test func healthOpportunityDoesNotCountAnUnobservedSleepGap() {
    let start = Date(timeIntervalSince1970: 6_500)
    var reducer = AgentStateReducer()
    var clock = HealthOpportunityClock(maximumContinuousInterval: 60)
    reducer.ingest(
        AgentEvent(
            provider: .codex,
            sessionID: "sleep",
            phase: .working,
            timestamp: start
        )
    )
    clock.transition(to: reducer, at: start)
    let elapsed = clock.transition(
        to: reducer,
        at: start.addingTimeInterval(8 * 60 * 60)
    )
    #expect(elapsed == 60)
    #expect(clock.accumulated == 60)
}

@Test func staleSessionsAreRemovedDeterministically() {
    let start = Date(timeIntervalSince1970: 7_000)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .claude, sessionID: "active", phase: .working, timestamp: start))
    reducer.ingest(AgentEvent(provider: .cursor, sessionID: "terminal", phase: .done, timestamp: start))
    let removed = reducer.cleanupStaleSessions(
        at: start.addingTimeInterval(301),
        activeTimeout: 600,
        terminalRetention: 300
    )
    #expect(removed == 1)
    #expect(reducer.sessions.count == 1)
    #expect(reducer.aggregatePhase == .working)
}

@Test func inactiveWorkingSessionsBecomeUnconfirmedBeforeFullTimeout() {
    let start = Date(timeIntervalSince1970: 7_500)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .pi, sessionID: "s1", phase: .working, timestamp: start))
    #expect(reducer.aggregatePhase == .working)

    // Before inactivity threshold: still working, not removed.
    reducer.cleanupStaleSessions(at: start.addingTimeInterval(599), inactivityTimeout: 600)
    #expect(reducer.aggregatePhase == .working)
    #expect(reducer.sessions.count == 1)

    // After inactivity threshold the UI must stop claiming the task is
    // running, while preserving it as an explicitly unconfirmed task.
    reducer.cleanupStaleSessions(at: start.addingTimeInterval(601), inactivityTimeout: 600)
    #expect(reducer.aggregatePhase == .idle)
    #expect(reducer.sessions.count == 1)
    #expect(reducer.sessions.values.first?.phase == .working)
    #expect(reducer.sessions.values.first?.isSignalStale == true)
    #expect(AgentTaskInbox.entries(sessions: reducer.sessions, mutedSessionKeys: []).first?.isSignalStale == true)

    // A fresh lifecycle event confirms that the same long task resumed.
    reducer.ingest(AgentEvent(
        provider: .pi,
        sessionID: "s1",
        phase: .working,
        timestamp: start.addingTimeInterval(700)
    ))
    #expect(reducer.aggregatePhase == .working)
    #expect(reducer.sessions.values.first?.isSignalStale == false)

    // Only the full active-session timeout removes an unconfirmed task.
    reducer.cleanupStaleSessions(
        at: start.addingTimeInterval(700 + 2 * 60 * 60 + 1),
        inactivityTimeout: 600
    )
    #expect(reducer.sessions.isEmpty)
}

@Test func reminderRequiresThresholdAndHonorsHourlyLimit() {
    let start = Date(timeIntervalSince1970: 10_000)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .claude, sessionID: "a", phase: .working, timestamp: start))
    var engine = ReminderEngine(policy: ReminderPolicy(waitingThreshold: 180, sameKindCooldown: 2_700, hourlyLimit: 1))

    #expect(engine.evaluate(state: reducer, at: start.addingTimeInterval(179)) == nil)
    let due = start.addingTimeInterval(180)
    let candidate = engine.evaluate(state: reducer, at: due)
    #expect(candidate?.kind == .hydrate)
    if let candidate { engine.record(candidate, at: due) }
    #expect(engine.records.first?.opportunityDuration == 180)
    #expect(engine.evaluate(state: reducer, at: due.addingTimeInterval(181)) == nil)
}

@Test func reminderRotationOnlyUsesEnabledHealthActions() {
    let now = Date(timeIntervalSince1970: 10_000)
    var engine = ReminderEngine(policy: ReminderPolicy(
        waitingThreshold: 60,
        sameKindCooldown: 0,
        hourlyLimit: 4
    ))
    let enabled: [ReminderKind] = [.eyes, .posture]

    let first = engine.evaluate(
        opportunityDuration: 120,
        at: now,
        eligibleKinds: enabled
    )
    #expect(first?.kind == .eyes)
    if let first {
        engine.record(first, at: now)
    }

    let second = engine.evaluate(
        opportunityDuration: 120,
        at: now.addingTimeInterval(61),
        eligibleKinds: enabled
    )
    #expect(second?.kind == .posture)
}

@Test func reminderHistoryRetentionDropsOldRecords() {
    let now = Date(timeIntervalSince1970: 20_000)
    var engine = ReminderEngine(
        records: [
            ReminderRecord(
                kind: .hydrate,
                triggeredAt: now.addingTimeInterval(-31 * 24 * 60 * 60)
            ),
            ReminderRecord(kind: .stand, triggeredAt: now),
        ]
    )
    engine.retainRecords(since: now.addingTimeInterval(-30 * 24 * 60 * 60))
    #expect(engine.records.count == 1)
    #expect(engine.records.first?.kind == .stand)
}

@Test func reminderDeliveryPrefersCompanionAndUsesVisibleSystemFallback() {
    let coordinator = ReminderDeliveryCoordinator()
    let companion = ReminderDeliveryContext(
        companionAvailable: true,
        systemNotificationAvailable: true,
        attentionRequired: false,
        quietHoursActive: false,
        reminderAlreadyVisible: false
    )
    #expect(coordinator.decision(for: companion) == .deliver(.companion))

    let fallback = ReminderDeliveryContext(
        companionAvailable: false,
        systemNotificationAvailable: true,
        attentionRequired: false,
        quietHoursActive: false,
        reminderAlreadyVisible: false
    )
    #expect(coordinator.decision(for: fallback) == .deliver(.systemNotification))
}

@Test func reminderDeliveryDefersForAttentionQuietHoursAndExistingReminder() {
    let coordinator = ReminderDeliveryCoordinator()
    func context(
        attention: Bool = false,
        quiet: Bool = false,
        active: Bool = false,
        companion: Bool = true,
        system: Bool = true
    ) -> ReminderDeliveryContext {
        ReminderDeliveryContext(
            companionAvailable: companion,
            systemNotificationAvailable: system,
            attentionRequired: attention,
            quietHoursActive: quiet,
            reminderAlreadyVisible: active
        )
    }

    #expect(coordinator.decision(for: context(attention: true)) == .deferred(.attentionRequired))
    #expect(coordinator.decision(for: context(quiet: true)) == .deferred(.quietHours))
    #expect(coordinator.decision(for: context(active: true)) == .deferred(.reminderAlreadyVisible))
    #expect(
        coordinator.decision(for: context(companion: false, system: false))
            == .deferred(.noAvailableChannel)
    )
}

@Test func reminderSnoozeHasOneDurableDueDelivery() {
    let now = Date(timeIntervalSince1970: 30_000)
    let recordID = UUID()
    var coordinator = ReminderDeliveryCoordinator()
    coordinator.scheduleSnooze(
        recordID: recordID,
        kind: .eyes,
        at: now
    )
    coordinator.scheduleSnooze(
        recordID: recordID,
        kind: .stand,
        at: now,
        interval: 120
    )

    #expect(coordinator.pendingSnoozes.count == 1)
    #expect(coordinator.dueSnooze(at: now.addingTimeInterval(119)) == nil)
    #expect(coordinator.dueSnooze(at: now.addingTimeInterval(120))?.kind == .stand)
    coordinator.markDelivered(recordID: recordID)
    #expect(coordinator.pendingSnoozes.isEmpty)
}

@Test func reminderSnoozeRetentionDropsOrphansAndExpiredDeliveries() {
    let now = Date(timeIntervalSince1970: 40_000)
    let validID = UUID()
    let orphanID = UUID()
    var coordinator = ReminderDeliveryCoordinator(pendingSnoozes: [
        PendingReminderDelivery(
            recordID: validID,
            kind: .hydrate,
            dueAt: now
        ),
        PendingReminderDelivery(
            recordID: orphanID,
            kind: .posture,
            dueAt: now
        ),
        PendingReminderDelivery(
            recordID: UUID(),
            kind: .breathe,
            dueAt: now.addingTimeInterval(-13 * 60 * 60)
        ),
    ])
    coordinator.retainPending(
        validRecordIDs: [validID],
        dueAfter: now.addingTimeInterval(-12 * 60 * 60)
    )
    #expect(coordinator.pendingSnoozes.map(\.recordID) == [validID])
}

@Test func reminderResponsePreservesSnoozeHistoryAfterCompletion() {
    let now = Date(timeIntervalSince1970: 50_000)
    let record = ReminderRecord(kind: .stand, triggeredAt: now)
    var engine = ReminderEngine(records: [record])

    engine.respond(to: record.id, with: .snoozed)
    engine.respond(to: record.id, with: .completed)

    #expect(engine.records.first?.response == .completed)
    #expect(engine.records.first?.snoozeCount == 1)
}

@Test func reminderExperimentAnalyzerComparesArmsAndAttentionMedian() {
    let now = Date(timeIntervalSince1970: 40_000)
    let records = [
        ReminderRecord(
            kind: .hydrate,
            triggeredAt: now,
            response: .completed,
            experimentArm: "agentAware",
            opportunityDuration: 180
        ),
        ReminderRecord(
            kind: .stand,
            triggeredAt: now,
            response: .skipped,
            experimentArm: "agentAware",
            opportunityDuration: 300
        ),
        ReminderRecord(
            kind: .eyes,
            triggeredAt: now,
            response: .completed,
            experimentArm: "afterCompletion",
            opportunityDuration: 240
        ),
    ]
    let working = ReminderExperimentAnalyzer.metrics(records: records, arm: "agentAware")
    let completed = ReminderExperimentAnalyzer.metrics(records: records, arm: "afterCompletion")
    let median = ReminderExperimentAnalyzer.medianAttentionResponse(records: [
        AttentionResponseRecord(provider: .codex, resolvedAt: now, duration: 10),
        AttentionResponseRecord(provider: .cursor, resolvedAt: now, duration: 30),
        AttentionResponseRecord(provider: .claude, resolvedAt: now, duration: 20),
        AttentionResponseRecord(provider: .opencode, resolvedAt: now, duration: 40),
    ])

    #expect(working.reminderCount == 2)
    #expect(working.completionRate == 0.5)
    #expect(working.averageOpportunityDuration == 240)
    #expect(completed.reminderCount == 1)
    #expect(completed.completionRate == 1)
    #expect(median == 25)
}

@Test func companionPlacementKeepsUsableFramesOnTheirBestDisplay() {
    let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
    let secondary = CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
    let frame = CGRect(x: -200, y: 40, width: 270, height: 255)

    let recovered = CompanionWindowPlacement.recoveredFrame(
        frame,
        visibleFrames: [primary, secondary],
        fallbackVisibleFrame: primary
    )

    #expect(recovered == CGRect(x: -270, y: 40, width: 270, height: 255))
}

@Test func companionPlacementRecoversMostlyOffscreenFramesToThePrimaryDisplay() {
    let primary = CGRect(x: 0, y: 25, width: 1_440, height: 875)
    let secondary = CGRect(x: 1_440, y: 0, width: 1_920, height: 1_080)
    let frame = CGRect(x: 3_300, y: 1_000, width: 270, height: 255)

    let recovered = CompanionWindowPlacement.recoveredFrame(
        frame,
        visibleFrames: [primary, secondary],
        fallbackVisibleFrame: primary
    )

    #expect(recovered == CGRect(x: 1_142, y: 53, width: 270, height: 255))
}

@Test func quietHoursMayCrossMidnight() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let quiet = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
    let late = calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 23))!
    let morning = calendar.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 8))!
    #expect(quiet.contains(late, calendar: calendar))
    #expect(!quiet.contains(morning, calendar: calendar))
}

@Test func hookAdaptersMapCurrentLifecycleEvents() throws {
    let claude = try HookEventAdapter.adapt(provider: .claude, data: Data(#"{"hook_event_name":"Notification","notification_type":"permission_prompt","session_id":"c1"}"#.utf8))
    let claudePermission = try HookEventAdapter.adapt(provider: .claude, data: Data(#"{"hook_event_name":"PermissionRequest","session_id":"c1"}"#.utf8))
    let claudeFailure = try HookEventAdapter.adapt(provider: .claude, data: Data(#"{"hook_event_name":"StopFailure","error":"rate_limit","error_details":"private billing detail","session_id":"c1"}"#.utf8))
    let claudeInformationalNotification = try HookEventAdapter.adapt(provider: .claude, data: Data(#"{"hook_event_name":"Notification","notification_type":"auth_success","session_id":"c1"}"#.utf8))
    let cursor = try HookEventAdapter.adapt(provider: .cursor, data: Data(#"{"hook_event_name":"beforeSubmitPrompt","conversation_id":"x1"}"#.utf8))
    let codex = try HookEventAdapter.adapt(provider: .codex, data: Data(#"{"type":"agent-turn-complete","thread-id":"o1"}"#.utf8))
    let opencode = try HookEventAdapter.adapt(
        provider: .opencode,
        data: Data(#"{"type":"session.status","properties":{"sessionID":"oc1","status":{"type":"busy"}}}"#.utf8)
    )
    let gemini = try HookEventAdapter.adapt(
        provider: .gemini,
        data: Data(#"{"hook_event_name":"Notification","notification_type":"ToolPermission","session_id":"g1"}"#.utf8)
    )
    let trae = try HookEventAdapter.adapt(
        provider: .trae,
        data: Data(#"{"hook_event_name":"Notification","notification_type":"idle_prompt","session_id":"t1"}"#.utf8)
    )
    #expect(claude.phase == .waitingForInput)
    #expect(claudePermission.phase == .waitingForInput)
    #expect(claudeFailure.phase == .failed)
    #expect(claudeInformationalNotification.phase == .idle)
    #expect(cursor.phase == .working)
    #expect(codex.phase == .done)
    #expect(opencode.phase == .working)
    #expect(opencode.sessionID == "oc1")
    #expect(gemini.phase == .waitingForInput)
    #expect(trae.phase == .done)
}

@Test func geminiAndTraeLifecyclePayloadsAreReducedBeforeTransport() throws {
    let fixtures: [(AgentProvider, Data, AgentPhase)] = [
        (
            .gemini,
            Data(#"{"hook_event_name":"BeforeTool","session_id":"gemini-1","tool_input":{"command":"cat .env"},"prompt":"private"}"#.utf8),
            .working
        ),
        (
            .trae,
            Data(#"{"hook_event_name":"PreToolUse","session_id":"trae-1","tool_input":{"command":"cat .env"},"last_assistant_message":"private"}"#.utf8),
            .working
        ),
    ]

    for (provider, raw, expectedPhase) in fixtures {
        let canonical = try HookPayloadSanitizer.sanitize(
            provider: provider,
            rawData: raw,
            receivedAt: Date(timeIntervalSince1970: 42)
        )
        let event = try HookPayloadSanitizer.decodeCanonical(
            expectedProvider: provider,
            data: canonical
        )
        let object = try #require(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
        #expect(event.phase == expectedPhase)
        #expect(Set(object.keys) == ["provider", "session_id", "phase", "timestamp"])
        #expect(!String(decoding: canonical, as: UTF8.self).contains("cat .env"))
        #expect(!String(decoding: canonical, as: UTF8.self).contains("private"))
    }
}

@Test func claudeFailurePayloadIsReducedWithoutErrorContent() throws {
    let raw = Data(#"{"hook_event_name":"StopFailure","session_id":"claude-failed","error":"billing_error","error_details":"private account detail","last_assistant_message":"private error response"}"#.utf8)
    let canonical = try HookPayloadSanitizer.sanitize(
        provider: .claude,
        rawData: raw,
        receivedAt: Date(timeIntervalSince1970: 42)
    )
    let event = try HookPayloadSanitizer.decodeCanonical(
        expectedProvider: .claude,
        data: canonical
    )
    let encoded = String(decoding: canonical, as: UTF8.self)

    #expect(event.phase == .failed)
    #expect(!encoded.contains("private account detail"))
    #expect(!encoded.contains("private error response"))
    #expect(!encoded.contains("billing_error"))
}

@Test func openCodeOfficialEventsMapWithoutForwardingContent() throws {
    let permission = try HookEventAdapter.adapt(
        provider: .opencode,
        data: Data(#"{"type":"permission.asked","properties":{"sessionID":"oc1","permission":"bash","patterns":["secret"]}}"#.utf8)
    )
    let idle = try HookEventAdapter.adapt(
        provider: .opencode,
        data: Data(#"{"type":"session.idle","properties":{"sessionID":"oc1","output":"private response"}}"#.utf8)
    )
    let error = try HookEventAdapter.adapt(
        provider: .opencode,
        data: Data(#"{"type":"session.error","properties":{"sessionID":"oc1","error":{"message":"private failure"}}}"#.utf8)
    )
    let deleted = try HookEventAdapter.adapt(
        provider: .opencode,
        data: Data(#"{"type":"session.deleted","properties":{"info":{"id":"oc1","title":"private task"}}}"#.utf8)
    )

    #expect(permission.phase == .waitingForInput)
    #expect(permission.sessionID == "oc1")
    #expect(idle.phase == .done)
    #expect(error.phase == .failed)
    #expect(deleted.phase == .idle)
}

@Test func failedAgentSessionsNeedAttentionButExpireAsTerminalState() {
    let start = Date(timeIntervalSince1970: 8_000)
    var reducer = AgentStateReducer()
    let change = reducer.ingest(AgentEvent(
        provider: .opencode,
        sessionID: "failed",
        phase: .failed,
        timestamp: start
    ))

    #expect(!change.didComplete)
    #expect(reducer.aggregatePhase == .waitingForInput)
    #expect(reducer.hasActiveSessions)
    #expect(!reducer.isHealthOpportunityActive)
    #expect(reducer.cleanupStaleSessions(at: start.addingTimeInterval(299)) == 0)
    #expect(reducer.cleanupStaleSessions(at: start.addingTimeInterval(301)) == 1)
    #expect(reducer.aggregatePhase == .idle)
}

@Test func concurrentSessionEndDoesNotEraseAProviderFailure() {
    let start = Date(timeIntervalSince1970: 8_500)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(
        provider: .claude,
        sessionID: "failed",
        phase: .failed,
        timestamp: start
    ))
    reducer.ingest(AgentEvent(
        provider: .claude,
        sessionID: "failed",
        phase: .idle,
        timestamp: start.addingTimeInterval(0.1)
    ))

    #expect(reducer.sessions[AgentSessionKey(provider: .claude, sessionID: "failed")]?.phase == .failed)
    #expect(reducer.aggregatePhase == .waitingForInput)

    reducer.ingest(AgentEvent(
        provider: .claude,
        sessionID: "failed",
        phase: .working,
        timestamp: start.addingTimeInterval(1)
    ))
    #expect(reducer.sessions[AgentSessionKey(provider: .claude, sessionID: "failed")]?.phase == .working)
}

@Test func openCodePluginReducesEventsBeforeCallingRelay() {
    let plugin = OpenCodePluginRenderer.render(relayPath: #"/tmp/Perch "beta"/perch-hook"#)

    #expect(plugin.hasPrefix("// Perch integration\n"))
    #expect(plugin.contains(#"const relay = "/tmp/Perch \"beta\"/perch-hook""#))
    #expect(plugin.contains(#"type === "session.status""#))
    #expect(plugin.contains(#"type === "permission.asked""#))
    #expect(plugin.contains("hook_event_name: eventName"))
    #expect(plugin.contains("session_id: sessionID"))
    #expect(!plugin.contains("JSON.stringify(event)"))
    #expect(plugin.contains(#"spawn("/bin/sh", [relay, "opencode", payload]"#))
    #expect(plugin.contains("child.unref()"))
    #expect(plugin.contains("properties?.sessionID"))
    #expect(plugin.contains("properties?.info?.sessionID"))
    #expect(plugin.contains("properties?.part?.sessionID"))
    #expect(plugin.contains("|| activeSessionID"))
    #expect(plugin.contains(#"type === "message.updated" || type === "message.part.updated""#))
    #expect(plugin.contains("lastLivenessSentAt >= 30000"))
    #expect(plugin.contains("task_title: sessionLabels.get(sessionID)"))
    #expect(plugin.contains("cwd: process.cwd()"))
}

@Test func geminiAndTraeHookEditorsPreserveExistingConfigurationAndUninstallCleanly() throws {
    let geminiExisting = Data(#"{"theme":"Default","hooks":{"BeforeTool":[{"matcher":"shell","hooks":[{"type":"command","command":"existing"}]}]}}"#.utf8)
    let geminiInstalled = try IntegrationConfigEditor.installingGemini(
        in: geminiExisting,
        command: "perch gemini"
    )
    #expect(IntegrationConfigEditor.geminiHooksInstalled(in: geminiInstalled, command: "perch gemini"))
    let geminiObject = try #require(JSONSerialization.jsonObject(with: geminiInstalled) as? [String: Any])
    #expect(geminiObject["theme"] as? String == "Default")
    let geminiHooks = try #require(geminiObject["hooks"] as? [String: Any])
    let geminiBeforeTool = try #require(geminiHooks["BeforeTool"] as? [[String: Any]])
    let perchGeminiGroup = try #require(geminiBeforeTool.first { group in
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { $0["command"] as? String == "perch gemini" }
    })
    let perchGeminiHooks = try #require(perchGeminiGroup["hooks"] as? [[String: Any]])
    let perchGeminiCommand = try #require(
        perchGeminiHooks.first { $0["command"] as? String == "perch gemini" }
    )
    #expect(perchGeminiCommand["timeout"] as? Int == 5_000)
    let geminiRemoved = try IntegrationConfigEditor.uninstallingGemini(
        in: geminiInstalled,
        command: "perch gemini"
    )
    #expect(!IntegrationConfigEditor.geminiHooksInstalled(in: geminiRemoved, command: "perch gemini"))
    #expect(String(decoding: geminiRemoved, as: UTF8.self).contains("\"existing\""))

    let traeExisting = Data(#"{"version":1,"hooks":{"Stop":[{"hooks":[{"type":"command","command":"existing"}]}]}}"#.utf8)
    let traeInstalled = try IntegrationConfigEditor.installingTrae(
        in: traeExisting,
        command: "perch trae"
    )
    #expect(IntegrationConfigEditor.traeHooksInstalled(in: traeInstalled, command: "perch trae"))
    let traeRemoved = try IntegrationConfigEditor.uninstallingTrae(
        in: traeInstalled,
        command: "perch trae"
    )
    #expect(!IntegrationConfigEditor.traeHooksInstalled(in: traeRemoved, command: "perch trae"))
    #expect(String(decoding: traeRemoved, as: UTF8.self).contains("\"existing\""))
}

@Test func integrationVerificationProbesAreIdleAndContentFree() throws {
    for provider in AgentProvider.allCases {
        let raw = IntegrationVerificationProbe.rawPayload(for: provider)
        let canonical = try HookPayloadSanitizer.sanitize(
            provider: provider,
            rawData: raw,
            receivedAt: Date(timeIntervalSince1970: 10)
        )
        let event = try HookPayloadSanitizer.decodeCanonical(
            expectedProvider: provider,
            data: canonical
        )
        let object = try #require(JSONSerialization.jsonObject(with: canonical) as? [String: Any])

        #expect(event.phase == .idle)
        #expect(IntegrationVerificationProbe.matches(event))
        #expect(Set(object.keys) == ["provider", "session_id", "phase", "timestamp"])
        #expect(!String(decoding: canonical, as: UTF8.self).contains(IntegrationVerificationProbe.rawSessionID))
    }
}

@Test func idleSleepProtectionRequiresVerifiedWorkAndReleasesForPowerConditions() {
    let start = Date(timeIntervalSince1970: 20_000)
    var gate = IdleSleepProtectionGate(maximumContinuousDuration: 60)

    #expect(gate.evaluate(
        enabled: false,
        hasVerifiedWorkingAgent: true,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: false,
        at: start
    ) == .disabled)
    #expect(gate.evaluate(
        enabled: true,
        hasVerifiedWorkingAgent: false,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: false,
        at: start
    ) == .waitingForVerifiedWork)
    #expect(gate.evaluate(
        enabled: true,
        hasVerifiedWorkingAgent: true,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: false,
        at: start
    ) == .active)
    #expect(gate.evaluate(
        enabled: true,
        hasVerifiedWorkingAgent: true,
        isLowPowerModeEnabled: true,
        hasLowBatteryWarning: false,
        at: start.addingTimeInterval(10)
    ) == .pausedForLowPower)
    #expect(gate.evaluate(
        enabled: true,
        hasVerifiedWorkingAgent: true,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: true,
        at: start.addingTimeInterval(20)
    ) == .pausedForLowBattery)
}

@Test func idleSleepProtectionTimesOutUntilWorkEnds() {
    let start = Date(timeIntervalSince1970: 30_000)
    var gate = IdleSleepProtectionGate(maximumContinuousDuration: 60)

    #expect(gate.evaluate(
        enabled: true,
        hasVerifiedWorkingAgent: true,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: false,
        at: start
    ) == .active)
    #expect(gate.evaluate(
        enabled: true,
        hasVerifiedWorkingAgent: true,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: false,
        at: start.addingTimeInterval(60)
    ) == .timedOut)
    #expect(gate.evaluate(
        enabled: true,
        hasVerifiedWorkingAgent: true,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: false,
        at: start.addingTimeInterval(120)
    ) == .timedOut)
    #expect(gate.evaluate(
        enabled: true,
        hasVerifiedWorkingAgent: false,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: false,
        at: start.addingTimeInterval(121)
    ) == .waitingForVerifiedWork)
    #expect(gate.evaluate(
        enabled: true,
        hasVerifiedWorkingAgent: true,
        isLowPowerModeEnabled: false,
        hasLowBatteryWarning: false,
        at: start.addingTimeInterval(122)
    ) == .active)
}

@Test func codexLifecycleHooksMapWorkingWaitingAndDone() throws {
    let working = try HookEventAdapter.adapt(provider: .codex, data: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"o1"}"#.utf8))
    let waiting = try HookEventAdapter.adapt(provider: .codex, data: Data(#"{"hook_event_name":"PermissionRequest","session_id":"o1"}"#.utf8))
    let done = try HookEventAdapter.adapt(provider: .codex, data: Data(#"{"hook_event_name":"Stop","session_id":"o1"}"#.utf8))
    let subagentDone = try HookEventAdapter.adapt(provider: .codex, data: Data(#"{"hook_event_name":"SubagentStop","session_id":"o1"}"#.utf8))
    let sessionEnd = try HookEventAdapter.adapt(provider: .codex, data: Data(#"{"hook_event_name":"SessionEnd","session_id":"o1"}"#.utf8))
    #expect(working.phase == .working)
    #expect(working.sourceEventName == "userpromptsubmit")
    #expect(waiting.phase == .waitingForInput)
    #expect(done.phase == .done)
    #expect(subagentDone.phase == .working)
    #expect(sessionEnd.phase == .idle)
}

@Test func codexCompletionWaitsForAQuietWindowAndIsCancelledByResumedWork() {
    let start = Date(timeIntervalSince1970: 20_000)
    var gate = CodexCompletionGate()
    let stop = AgentEvent(
        provider: .codex,
        sessionID: "thread",
        phase: .done,
        timestamp: start,
        sourceEventName: "stop"
    )
    let resumed = AgentEvent(
        provider: .codex,
        sessionID: "thread",
        phase: .working,
        timestamp: start.addingTimeInterval(1),
        sourceEventName: "userpromptsubmit"
    )

    #expect(gate.route(stop) == nil)
    #expect(gate.pendingCount == 1)
    #expect(gate.route(resumed) == resumed)
    #expect(gate.pendingCount == 0)
    #expect(gate.drain(at: start.addingTimeInterval(10)).isEmpty)
}

@Test func codexCompletionBecomesFinalAfterTheGracePeriod() {
    let start = Date(timeIntervalSince1970: 30_000)
    let deadline = start.addingTimeInterval(CodexCompletionGate.defaultGracePeriod)
    var gate = CodexCompletionGate()
    let stop = AgentEvent(
        provider: .codex,
        sessionID: "thread",
        phase: .done,
        timestamp: start,
        sourceEventName: "agent-turn-complete"
    )

    #expect(gate.route(stop) == nil)
    #expect(gate.drain(at: deadline.addingTimeInterval(-0.01)).isEmpty)
    let finalized = gate.drain(at: deadline)
    #expect(finalized.count == 1)
    #expect(finalized.first?.phase == .done)
    #expect(finalized.first?.timestamp == deadline)
    #expect(gate.pendingCount == 0)
}

@Test func hookPayloadIsSanitizedBeforeTransport() throws {
    let timestamp = Date(timeIntervalSince1970: 10_000)
    let sensitive = Data(#"""
    {
      "hook_event_name":"PreToolUse",
      "session_id":"/Users/alice/secret-project",
      "prompt":"implement the unreleased feature",
      "tool_input":{"command":"cat .env"},
      "path":"/Users/alice/secret-project/.env",
      "response":"API_KEY=secret"
    }
    """#.utf8)
    let sanitized = try HookPayloadSanitizer.sanitize(provider: .claude, rawData: sensitive, receivedAt: timestamp)
    let text = String(decoding: sanitized, as: UTF8.self)
    #expect(!text.contains("secret-project"))
    #expect(!text.contains("unreleased"))
    #expect(!text.contains("cat .env"))
    #expect(!text.contains("API_KEY"))
    #expect(!text.contains("hook_event_name"))

    let decoded = try HookPayloadSanitizer.decodeCanonical(expectedProvider: .claude, data: sanitized)
    #expect(decoded.provider == .claude)
    #expect(decoded.phase == .working)
    #expect(decoded.timestamp == timestamp)
    #expect(decoded.sessionID.count == 32)
}

@Test func codexTransportKeepsOnlyProjectLabelAndExactLocalResumeRoute() throws {
    let raw = Data(#"""
    {
      "hook_event_name":"UserPromptSubmit",
      "session_id":"019f-thread-123",
      "cwd":"/Users/alice/Secret Parent/Perch",
      "prompt":"修复 Perch 任务跳转",
      "tool_input":{"command":"cat .env"}
    }
    """#.utf8)
    let canonical = try HookPayloadSanitizer.sanitize(
        provider: .codex,
        rawData: raw,
        receivedAt: Date(timeIntervalSince1970: 42)
    )
    let text = String(decoding: canonical, as: UTF8.self)
    let event = try HookPayloadSanitizer.decodeCanonical(
        expectedProvider: .codex,
        data: canonical
    )

    #expect(event.taskLabel == "修复 Perch 任务跳转")
    #expect(event.taskLabelKind == .prompt)
    #expect(event.resumeURL == "codex://threads/019f-thread-123")
    #expect(!text.contains("Secret Parent"))
    #expect(!text.contains("cat .env"))
    #expect(!text.contains(#""session_id":"019f-thread-123""#))
}

@Test func codexReturnRouteRejectsAmbiguousOrOversizedSessionIdentifiers() throws {
    for sessionID in [
        "../another-thread",
        "thread/another",
        "thread?unexpected=true",
        String(repeating: "a", count: 257),
    ] {
        let raw = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit",
            "session_id": sessionID,
            "prompt": "Review Perch",
        ])
        let canonical = try HookPayloadSanitizer.sanitize(
            provider: .codex,
            rawData: raw
        )
        let event = try HookPayloadSanitizer.decodeCanonical(
            expectedProvider: .codex,
            data: canonical
        )
        #expect(event.resumeURL == nil)
    }
}

@Test func canonicalTransportRejectsInjectedCodexReturnRoutes() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    for resumeURL in [
        "codex://threads/thread/another",
        "codex://threads/thread?unexpected=true",
        "codex://threads/thread%2Fanother",
        "codex://user@threads/thread",
    ] {
        let canonical = CanonicalAgentEvent(
            provider: .codex,
            sessionID: "opaque",
            phase: .waitingForInput,
            timestamp: Date(timeIntervalSince1970: 42),
            resumeURL: resumeURL
        )
        let event = try HookPayloadSanitizer.decodeCanonical(
            expectedProvider: .codex,
            data: encoder.encode(canonical)
        )
        #expect(event.resumeURL == nil)
    }
}

@Test func terminalHostedTaskCarriesExactTabRouteFromControllingTTY() throws {
    let raw = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "Stop",
        "session_id": "abc-123",
        "cwd": "/Users/alice/Projects/Perch",
    ])
    let canonical = try HookPayloadSanitizer.sanitize(
        provider: .claude,
        rawData: raw,
        controllingTTY: "ttys012"
    )
    let event = try HookPayloadSanitizer.decodeCanonical(
        expectedProvider: .claude,
        data: canonical
    )
    #expect(event.resumeURL == "perch-tty://ttys012")
}

@Test func terminalTabRouteRejectsNonDeviceTTYNames() throws {
    for tty in ["console", "ttys01; rm -rf", "../ttys001", "ttysabc", "ttys", ""] {
        let raw = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop",
            "session_id": "abc-123",
        ])
        let canonical = try HookPayloadSanitizer.sanitize(
            provider: .claude,
            rawData: raw,
            controllingTTY: tty
        )
        let event = try HookPayloadSanitizer.decodeCanonical(
            expectedProvider: .claude,
            data: canonical
        )
        #expect(event.resumeURL == nil)
    }
}

@Test func canonicalTransportRejectsInjectedTerminalTabRoutes() throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    for resumeURL in [
        "perch-tty://ttys001/extra",
        "perch-tty://ttys001?unexpected=true",
        "perch-tty://console",
        "perch-tty://user@ttys001",
        "codex://threads/thread",
        "file:///etc/passwd",
    ] {
        let canonical = CanonicalAgentEvent(
            provider: .claude,
            sessionID: "opaque",
            phase: .waitingForInput,
            timestamp: Date(timeIntervalSince1970: 42),
            resumeURL: resumeURL
        )
        let event = try HookPayloadSanitizer.decodeCanonical(
            expectedProvider: .claude,
            data: encoder.encode(canonical)
        )
        #expect(event.resumeURL == nil)
    }
}

@Test func detachedPluginRelaysFallBackToThePayloadTTY() throws {
    // OpenCode and pi spawn the relay detached (no controlling terminal),
    // so the hosting process ships its own tty in the payload; the exact
    // tab route must survive that path too.
    let raw = try JSONSerialization.data(withJSONObject: [
        "type": "session.status",
        "properties": ["sessionID": "oc1", "status": ["type": "busy"]],
        "tty": "ttys021",
    ])
    let canonical = try HookPayloadSanitizer.sanitize(
        provider: .opencode,
        rawData: raw,
        controllingTTY: nil
    )
    let event = try HookPayloadSanitizer.decodeCanonical(
        expectedProvider: .opencode,
        data: canonical
    )
    #expect(event.resumeURL == "perch-tty://ttys021")
}

@Test func processTTYOutranksPayloadTTYAndInvalidPayloadTTYIsRejected() throws {
    let both = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "Stop", "session_id": "s", "tty": "ttys999",
    ])
    let preferred = try HookPayloadSanitizer.decodeCanonical(
        expectedProvider: .claude,
        data: HookPayloadSanitizer.sanitize(
            provider: .claude, rawData: both, controllingTTY: "ttys001"
        )
    )
    #expect(preferred.resumeURL == "perch-tty://ttys001")

    for tty in ["console", "ttys01; rm -rf", "../ttys001", "/dev/ttys001", ""] {
        let raw = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "Stop", "session_id": "s", "tty": tty,
        ])
        let event = try HookPayloadSanitizer.decodeCanonical(
            expectedProvider: .claude,
            data: HookPayloadSanitizer.sanitize(
                provider: .claude, rawData: raw, controllingTTY: nil
            )
        )
        #expect(event.resumeURL == nil)
    }
}

@Test func codexKeepsThreadRouteEvenWhenHookRunsInsideATerminal() throws {
    let raw = try JSONSerialization.data(withJSONObject: [
        "hook_event_name": "UserPromptSubmit",
        "session_id": "019f-thread-123",
        "prompt": "Review Perch",
    ])
    let canonical = try HookPayloadSanitizer.sanitize(
        provider: .codex,
        rawData: raw,
        controllingTTY: "ttys004"
    )
    let event = try HookPayloadSanitizer.decodeCanonical(
        expectedProvider: .codex,
        data: canonical
    )
    #expect(event.resumeURL == "codex://threads/019f-thread-123")
}

@Test func taskLabelsExtractTheHumanRequestAndRejectAttachmentNoise() throws {
    let wrapped = """
    # Files mentioned by the user:
    ## codex-clipboard-7F9A0D2B-71C8-4B74-9A85-123456789012.png
    /var/folders/private/codex-clipboard.png

    ## My request for Codex:
    请帮我修复任务名称乱码的问题？并优化标题回退。
    """
    #expect(
        AgentTaskLabelNormalizer.normalize(wrapped, kind: .prompt)
            == "修复任务名称乱码的问题"
    )
    #expect(
        AgentTaskLabelNormalizer.normalize(
            "codex-clipboard-7F9A0D2B-71C8-4B74-9A85-123456789012.png",
            kind: .prompt
        ) == nil
    )
    #expect(
        AgentTaskLabelNormalizer.normalize(
            "019f893d-7085-7510-9c82-be7b4e954eec",
            kind: .title
        ) == nil
    )
    #expect(
        AgentTaskLabelNormalizer.normalize(
            "ä½ å¥½\u{FFFD}",
            kind: .prompt
        ) == nil
    )
    #expect(
        AgentTaskLabelNormalizer.normalize(
            "ä½ å¥½",
            kind: .prompt
        ) == nil
    )
    #expect(
        AgentTaskLabelNormalizer.normalize(
            "019f893d-7085-7510-9c82-be7b4e954eec",
            kind: .workspace
        ) == nil
    )
    #expect(
        AgentTaskLabelNormalizer.normalize("那你实现吧", kind: .prompt) == nil
    )
    #expect(
        AgentTaskLabelNormalizer.normalize("继续", kind: .prompt) == nil
    )
}

@Test func unreadableCodexPromptFallsBackToTheWorkspaceLabel() throws {
    let raw = Data(#"""
    {
      "hook_event_name":"UserPromptSubmit",
      "session_id":"019f-thread-456",
      "cwd":"/Users/alice/Projects/Perch",
      "prompt":"codex-clipboard-7F9A0D2B-71C8-4B74-9A85-123456789012.png"
    }
    """#.utf8)
    let canonical = try HookPayloadSanitizer.sanitize(
        provider: .codex,
        rawData: raw
    )
    let event = try HookPayloadSanitizer.decodeCanonical(
        expectedProvider: .codex,
        data: canonical
    )

    #expect(event.taskLabel == "Perch")
    #expect(event.taskLabelKind == .workspace)
}

@Test func taskMetadataSurvivesLaterContentFreeLifecycleEvents() {
    let start = Date(timeIntervalSince1970: 1_000)
    let key = AgentSessionKey(provider: .codex, sessionID: "opaque")
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "opaque",
        phase: .working,
        timestamp: start,
        taskLabel: "Perch",
        taskLabelKind: .workspace,
        resumeURL: "codex://threads/thread"
    ))
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "opaque",
        phase: .waitingForInput,
        timestamp: start.addingTimeInterval(1)
    ))

    #expect(reducer.sessions[key]?.taskLabel == "Perch")
    #expect(reducer.sessions[key]?.taskLabelKind == .workspace)
    #expect(reducer.sessions[key]?.resumeURL == "codex://threads/thread")
}

@Test func promptTaskNameReplacesWorkspaceButNotProviderTitle() {
    let start = Date(timeIntervalSince1970: 1_000)
    let key = AgentSessionKey(provider: .codex, sessionID: "opaque")
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "opaque",
        phase: .idle,
        timestamp: start,
        taskLabel: "Perch",
        taskLabelKind: .workspace
    ))
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "opaque",
        phase: .working,
        timestamp: start.addingTimeInterval(1),
        taskLabel: "修复任务跳转",
        taskLabelKind: .prompt
    ))
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "opaque",
        phase: .working,
        timestamp: start.addingTimeInterval(2),
        taskLabel: "Perch",
        taskLabelKind: .workspace
    ))

    #expect(reducer.sessions[key]?.taskLabel == "修复任务跳转")
    #expect(reducer.sessions[key]?.taskLabelKind == .prompt)
}

@Test func sessionTaskNameStaysStableAcrossLaterPromptTurns() {
    let start = Date(timeIntervalSince1970: 2_000)
    let key = AgentSessionKey(provider: .codex, sessionID: "stable")
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "stable",
        phase: .working,
        timestamp: start,
        taskLabel: "修复任务名称乱码",
        taskLabelKind: .prompt
    ))
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "stable",
        phase: .working,
        timestamp: start.addingTimeInterval(1),
        taskLabel: "增加发布前安全检查和回归测试覆盖",
        taskLabelKind: .prompt
    ))

    #expect(reducer.sessions[key]?.taskLabel == "修复任务名称乱码")
}

@Test func vagueInitialPromptMayUpgradeToASpecificSessionName() {
    let start = Date(timeIntervalSince1970: 3_000)
    let key = AgentSessionKey(provider: .codex, sessionID: "upgrade")
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "upgrade",
        phase: .working,
        timestamp: start,
        taskLabel: "修复问题",
        taskLabelKind: .prompt
    ))
    reducer.ingest(AgentEvent(
        provider: .codex,
        sessionID: "upgrade",
        phase: .working,
        timestamp: start.addingTimeInterval(1),
        taskLabel: "修复 Perch 的任务名称乱码问题",
        taskLabelKind: .prompt
    ))

    #expect(reducer.sessions[key]?.taskLabel == "修复 Perch 的任务名称乱码问题")
}

@Test func openCodeFailurePayloadIsReducedToAContentFreeFailedPhase() throws {
    let raw = Data(#"""
    {
      "type":"session.error",
      "properties":{
        "sessionID":"private-project-session",
        "error":{"message":"API key rejected in secret-project"}
      }
    }
    """#.utf8)
    let canonical = try HookPayloadSanitizer.sanitize(provider: .opencode, rawData: raw)
    let text = String(decoding: canonical, as: UTF8.self)

    #expect(!text.contains("private-project-session"))
    #expect(!text.contains("API key"))
    #expect(!text.contains("secret-project"))
    let decoded = try HookPayloadSanitizer.decodeCanonical(expectedProvider: .opencode, data: canonical)
    #expect(decoded.phase == .failed)
    #expect(decoded.sessionID.count == 32)
}

@Test func codexLifecycleHookEditorPreservesOtherHooks() throws {
    let command = "/bin/sh '/tmp/perch hook' codex"
    let existing = Data(#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"say existing"}]}]}}"#.utf8)
    let installed = try IntegrationConfigEditor.installingCodexHooks(in: existing, command: command)
    #expect(IntegrationConfigEditor.codexHooksInstalled(in: installed, command: command))
    #expect(String(decoding: installed, as: UTF8.self).contains("say existing"))
    #expect(String(decoding: installed, as: UTF8.self).contains("SessionEnd"))
    let root = try #require(JSONSerialization.jsonObject(with: installed) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    let sessionEndGroups = try #require(hooks["SessionEnd"] as? [[String: Any]])
    let sessionEndHandlers = try #require(sessionEndGroups.first?["hooks"] as? [[String: Any]])
    #expect(sessionEndHandlers.first?["timeout"] as? Int == 1)
    let removed = try IntegrationConfigEditor.uninstallingCodexHooks(in: installed, command: command)
    #expect(!IntegrationConfigEditor.codexHooksInstalled(in: removed, command: command))
    #expect(String(decoding: removed, as: UTF8.self).contains("say existing"))
}

@Test func httpParserHandlesSegmentedBodiesAndRejectsWrongRoutes() {
    let body = Data(#"{"hook_event_name":"Stop","session_id":"c1"}"#.utf8)
    let header = Data("POST /v1/events/claude HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
    #expect(HTTPEventRequestParser.parse(header) == .incomplete)
    #expect(HTTPEventRequestParser.parse(header + body) == .complete(provider: .claude, body: body, token: ""))

    let wrong = Data("POST /private HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
    #expect(HTTPEventRequestParser.parse(wrong) == .rejected(status: 404))
}

@Test func httpParserRejectsAmbiguousRequestFraming() {
    let duplicateLength = Data(
        "POST /v1/events/codex HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n".utf8
    )
    #expect(HTTPEventRequestParser.parse(duplicateLength) == .rejected(status: 400))

    let chunked = Data(
        "POST /v1/events/codex HTTP/1.1\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n".utf8
    )
    #expect(HTTPEventRequestParser.parse(chunked) == .rejected(status: 400))

    let trailingRequest = Data(
        "POST /v1/events/codex HTTP/1.1\r\nContent-Length: 0\r\n\r\nGET / HTTP/1.1\r\n\r\n".utf8
    )
    #expect(HTTPEventRequestParser.parse(trailingRequest) == .rejected(status: 400))

    let duplicateToken = Data(
        "POST /v1/events/codex HTTP/1.1\r\nContent-Length: 0\r\nX-Perch-Token: a\r\nX-Perch-Token: b\r\n\r\n".utf8
    )
    #expect(HTTPEventRequestParser.parse(duplicateToken) == .rejected(status: 400))
}

@Test func configEditorsPreserveUnrelatedHooksAndAreReversible() throws {
    let existingClaude = Data(#"{"theme":"dark","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#.utf8)
    let claudeInstalled = try IntegrationConfigEditor.installingClaude(in: existingClaude, command: "perch claude")
    let claudeText = String(decoding: claudeInstalled, as: UTF8.self)
    #expect(claudeText.contains("say done"))
    #expect(claudeText.contains("perch claude"))
    #expect(claudeText.contains("PermissionRequest"))
    #expect(claudeText.contains("StopFailure"))
    #expect(claudeText.contains("permission_prompt|idle_prompt|elicitation_dialog|agent_needs_input"))
    #expect(IntegrationConfigEditor.claudeHooksInstalled(in: claudeInstalled, command: "perch claude"))
    let claudeRemoved = try IntegrationConfigEditor.uninstallingClaude(in: claudeInstalled, command: "perch claude")
    #expect(String(decoding: claudeRemoved, as: UTF8.self).contains("say done"))
    #expect(!String(decoding: claudeRemoved, as: UTF8.self).contains("perch claude"))
    #expect(!IntegrationConfigEditor.claudeHooksInstalled(in: claudeRemoved, command: "perch claude"))

    let cursorInstalled = try IntegrationConfigEditor.installingCursor(in: Data(#"{"version":1}"#.utf8), command: "perch cursor")
    #expect(String(decoding: cursorInstalled, as: UTF8.self).contains("perch cursor"))
    let cursorRemoved = try IntegrationConfigEditor.uninstallingCursor(in: cursorInstalled, command: "perch cursor")
    #expect(!String(decoding: cursorRemoved, as: UTF8.self).contains("perch cursor"))
}

@Test func codexEditorChainsAndRestoresAnotherNotifier() throws {
    let existing = "notify = [\n  \"/existing/notifier\",\n  \"turn-ended\",\n]\n\n[tui]\nnotifications = true\n"
    let chained = try IntegrationConfigEditor.installingCodex(in: existing, commandArray: "[\"perch-wrapper\"]")
    #expect(chained.previousNotifier == ["/existing/notifier", "turn-ended"])
    #expect(chained.updatedText.hasPrefix("# Perch integration\n# Perch previous notify:"))
    #expect(chained.updatedText.contains("notify = [\"perch-wrapper\"]"))
    #expect(IntegrationConfigEditor.uninstallingCodex(in: chained.updatedText, commandArray: "[\"perch-wrapper\"]") == existing)

    let plain = try IntegrationConfigEditor.installingCodex(in: "model = \"gpt\"\n", commandArray: "[\"perch\"]")
    #expect(plain.previousNotifier == nil)
    #expect(plain.updatedText.contains("# Perch integration"))
    #expect(IntegrationConfigEditor.uninstallingCodex(in: plain.updatedText, commandArray: "[\"perch\"]") == "model = \"gpt\"\n")

    let sectioned = try IntegrationConfigEditor.installingCodex(in: "[tui]\nnotifications = true\n", commandArray: "[\"perch\"]")
    #expect(sectioned.updatedText.hasPrefix("# Perch integration\nnotify = [\"perch\"]"))
    #expect(sectioned.updatedText.contains("[tui]"))
}

@Test func codexCommandStringsMustNotUseJSONSlashEscapes() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let encoded = String(decoding: try! encoder.encode("/Users/test/Application Support/Perch"), as: UTF8.self)
    #expect(encoded == #""/Users/test/Application Support/Perch""#)
    #expect(!encoded.contains(#"\/"#))
}

@Test func piLifecycleWaitsUntilAgentSettles() throws {
    let started = try HookEventAdapter.adapt(
        provider: .pi,
        data: Data(#"{"hook_event_name":"AgentStart","session_id":"pi1"}"#.utf8)
    )
    let ended = try HookEventAdapter.adapt(
        provider: .pi,
        data: Data(#"{"hook_event_name":"AgentEnd","session_id":"pi1"}"#.utf8)
    )
    let settled = try HookEventAdapter.adapt(
        provider: .pi,
        data: Data(#"{"hook_event_name":"AgentSettled","session_id":"pi1"}"#.utf8)
    )
    let failed = try HookEventAdapter.adapt(
        provider: .pi,
        data: Data(#"{"hook_event_name":"AgentFailed","session_id":"pi2"}"#.utf8)
    )
    let turnStarted = try HookEventAdapter.adapt(
        provider: .pi,
        data: Data(#"{"hook_event_name":"TurnStart","session_id":"pi1"}"#.utf8)
    )
    let toolStarted = try HookEventAdapter.adapt(
        provider: .pi,
        data: Data(#"{"hook_event_name":"ToolExecutionStart","session_id":"pi1"}"#.utf8)
    )

    #expect(started.phase == .working)
    #expect(ended.phase == .working)
    #expect(settled.phase == .done)
    #expect(failed.phase == .failed)
    #expect(turnStarted.phase == .working)
    #expect(toolStarted.phase == .working)
}

@Test func piExtensionUsesSettledAsItsCompletionBoundary() {
    let extensionSource = PiExtensionRenderer.render(relayPath: #"/tmp/Perch "beta"/perch-hook"#)

    #expect(extensionSource.hasPrefix("// Perch integration\n"))
    #expect(extensionSource.contains(#"pi.on("agent_start""#))
    #expect(extensionSource.contains(#"pi.on("agent_end""#))
    #expect(extensionSource.contains(#"pi.on("agent_settled""#))
    #expect(extensionSource.contains(#"pi.on("session_shutdown""#))
    // Turn and tool boundaries keep long single-loop runs visibly working,
    // but they are throttled and never redefine the completion boundary.
    #expect(extensionSource.contains(#"pi.on("turn_start""#))
    #expect(extensionSource.contains(#"pi.on("tool_execution_start""#))
    #expect(extensionSource.contains("lastLivenessSentAt < 30000"))
    #expect(!extensionSource.contains(#"pi.on("turn_end""#))
    #expect(extensionSource.contains(#"assistant?.stopReason === "error""#))
    #expect(extensionSource.contains(#"lastRunFailed ? "AgentFailed" : "AgentSettled""#))
    #expect(!extensionSource.contains("errorMessage"))
    #expect(extensionSource.contains(#"[relay, "pi", payload]"#))
}

@Test func signatureFlourishesBelongToBuiltInCharactersOnly() {
    let bird = PetSignatureFlourish.flourish(
        forSpriteResource: "perch-sleepwing-bird-v2"
    )
    let cat = PetSignatureFlourish.flourish(
        forSpriteResource: "perch-crescent-cat-v2"
    )

    #expect(bird?.kind == .hop)
    #expect(cat?.kind == .settle)
    #expect(bird != cat)
    #expect(PetSignatureFlourish.flourish(forSpriteResource: "") == nil)
    #expect(PetSignatureFlourish.flourish(forSpriteResource: "quiet-fox") == nil)

    // Celebrations stay brief: both signature moves finish well inside the
    // celebration window.
    for flourish in [bird, cat].compactMap({ $0 }) {
        #expect(flourish.duration > 0)
        #expect(flourish.duration <= 1.5)
    }
}

@Test func referenceArtPlacementCentersTheSubjectWithEvenMargins() {
    let wide = ReferenceArtComposition.placement(
        subjectWidth: 2000,
        subjectHeight: 1000
    )
    let tall = ReferenceArtComposition.placement(
        subjectWidth: 500,
        subjectHeight: 1500
    )

    #expect(ReferenceArtComposition.placement(subjectWidth: 0, subjectHeight: 10) == nil)

    let side = ReferenceArtComposition.canvasSide
    let fraction = ReferenceArtComposition.subjectFraction
    for placement in [wide, tall].compactMap({ $0 }) {
        #expect(abs(placement.x * 2 + placement.width - side) < 0.001)
        #expect(abs(placement.y * 2 + placement.height - side) < 0.001)
        #expect(max(placement.width, placement.height) <= side * fraction + 0.001)
        #expect(placement.width > 0 && placement.height > 0)
    }
    // Aspect ratio is preserved for both orientations.
    #expect(abs((wide?.width ?? 0) / (wide?.height ?? 1) - 2) < 0.001)
    #expect(abs((tall?.height ?? 0) / (tall?.width ?? 1) - 3) < 0.001)
}

@Test func petCreationAgentsFollowStableOrderAndDetection() {
    let detected: Set<AgentProvider> = [.gemini, .claude, .codex]
    let agents = PerchPetSkillInstaller.creationAgents(detectedProviders: detected)

    #expect(agents == AgentProvider.allCases.filter { detected.contains($0) })
    #expect(PerchPetSkillInstaller.creationAgents(detectedProviders: []).isEmpty)
}

@Test func gazeInterestDecaysAndAutonomousGlancesStayBounded() {
    var engine = CompanionGazeEngine()
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    // A moving pointer beyond the dead zone engages the gaze.
    let engaged = engine.update(
        deltaX: 200, deltaY: 0, pointerMoved: true, at: t0, randomUnit: { 0 }
    )
    #expect(engaged != nil)

    // A stationary pointer holds attention only while interest lasts.
    let held = engine.update(
        deltaX: 200, deltaY: 0, pointerMoved: false,
        at: t0.addingTimeInterval(2), randomUnit: { 0 }
    )
    #expect(held == engaged)
    let bored = engine.update(
        deltaX: 200, deltaY: 0, pointerMoved: false,
        at: t0.addingTimeInterval(5), randomUnit: { 0 }
    )
    #expect(bored == nil)

    // An autonomous glance fires at its scheduled moment, then rests.
    let glance = engine.update(
        deltaX: 0, deltaY: 0, pointerMoved: false,
        at: t0.addingTimeInterval(12.1), randomUnit: { 0 }
    )
    #expect(glance != nil)
    let rested = engine.update(
        deltaX: 0, deltaY: 0, pointerMoved: false,
        at: t0.addingTimeInterval(14), randomUnit: { 0 }
    )
    #expect(rested == nil)

    // Pointer movement re-engages immediately.
    let reEngaged = engine.update(
        deltaX: 0, deltaY: 200, pointerMoved: true,
        at: t0.addingTimeInterval(15), randomUnit: { 0 }
    )
    #expect(reEngaged != nil)
}

@Test func petCreationStylesMapToDistinctHatchPresets() {
    #expect(PetCreationStyle.allCases.first == .faithful)
    #expect(PetCreationStyle.faithful.hatchStylePreset == "auto")
    #expect(PetCreationStyle.pixel.hatchStylePreset == "pixel")
    #expect(PetCreationStyle.toy3d.hatchStylePreset == "3d-toy")

    let presets = PetCreationStyle.allCases.map(\.hatchStylePreset)
    #expect(Set(presets).count == presets.count)
}

@Test func companionSmallTalkPrioritizesWaitingAndKeepsKeysStable() {
    let waiting = CompanionSmallTalk.Context(isWorking: true, isWaiting: true, hour: 12)
    #expect(CompanionSmallTalk.category(for: waiting) == .waiting)
    let night = CompanionSmallTalk.Context(isWorking: false, isWaiting: false, hour: 23)
    #expect(CompanionSmallTalk.category(for: night) == .restingNight)
    let day = CompanionSmallTalk.Context(isWorking: false, isWaiting: false, hour: 10)
    #expect(CompanionSmallTalk.category(for: day) == .resting)

    let key = CompanionSmallTalk.lineKey(role: "bird", context: day) { _ in 1 }
    #expect(key == "smalltalk.bird.resting.1")
    // Out-of-range variants clamp instead of producing a missing key.
    let clamped = CompanionSmallTalk.lineKey(role: "cat", context: waiting) { _ in 99 }
    #expect(clamped == "smalltalk.cat.waiting.0")
}

@Test func voiceIntentRecognizesStatusQuestionsInBothLanguages() {
    #expect(VoiceIntent.parse("现在什么状态") == .statusQuery)
    #expect(VoiceIntent.parse("跑完了吗？") == .statusQuery)
    #expect(VoiceIntent.parse("What's the status?") == .statusQuery)
    #expect(VoiceIntent.parse("is it finished") == .statusQuery)
    #expect(VoiceIntent.parse("帮我写个函数") == .unrecognized)
    #expect(VoiceIntent.parse("") == .unrecognized)
}

@Test func voiceIntentParsesDispatchInBothLanguages() {
    #expect(
        VoiceIntent.parse("派给 codex：跑一遍测试")
            == .dispatch(agentName: "codex", message: "跑一遍测试")
    )
    #expect(
        VoiceIntent.parse("告诉 pi 修复构建")
            == .dispatch(agentName: "pi", message: "修复构建")
    )
    #expect(
        VoiceIntent.parse("tell codex to run the tests")
            == .dispatch(agentName: "codex", message: "run the tests")
    )
    #expect(
        VoiceIntent.parse("新任务：整理文档")
            == .dispatch(agentName: nil, message: "整理文档")
    )
    // 派发优先于状态关键词：内容里含「状态」也是派发。
    #expect(
        VoiceIntent.parse("派给 gemini：查一下服务状态")
            == .dispatch(agentName: "gemini", message: "查一下服务状态")
    )
}

@Test func voiceIntentParsesPunctuationFreeTranscripts() {
    // 转写没有标点：分隔符不再是硬要求。
    #expect(
        VoiceIntent.parse("派给codex跑一遍测试")
            == .dispatch(agentName: "codex", message: "跑一遍测试")
    )
    #expect(
        VoiceIntent.parse("新任务整理文档")
            == .dispatch(agentName: nil, message: "整理文档")
    )
    #expect(
        VoiceIntent.parse("tell codex run the tests")
            == .dispatch(agentName: "codex", message: "run the tests")
    )
    // 常见同音/转写变体归一：派、P I → pi，克劳德 → claude。
    #expect(
        VoiceIntent.parse("告诉派修复构建")
            == .dispatch(agentName: "pi", message: "修复构建")
    )
    #expect(
        VoiceIntent.parse("交给 P I 跑一下测试")
            == .dispatch(agentName: "pi", message: "跑一下测试")
    )
    #expect(
        VoiceIntent.parse("让克劳德清理分支")
            == .dispatch(agentName: "claude", message: "清理分支")
    )
    // 动词后面跟的是人称代词时不硬当派发。
    #expect(VoiceIntent.parse("告诉我进度") == .statusQuery)
    #expect(VoiceIntent.parse("让我看看状态") == .statusQuery)
    #expect(VoiceIntent.parse("tell me the status") == .statusQuery)
}

@Test func voiceProjectMatchingToleratesTranscriptionGarble() {
    let projects = ["Perch", "lawpulse", "Proof Stack"]
    // 真实转写样本：Perch 被听成 Purch 也要命中。
    #expect(
        VoiceIntent.matchProjectName(
            in: "在 Purch项目的这个cesion中发送一个哈lo",
            candidates: projects
        ) == "Perch"
    )
    #expect(
        VoiceIntent.matchProjectName(
            in: "修一下 lawpulse 的登录",
            candidates: projects
        ) == "lawpulse"
    )
    #expect(
        VoiceIntent.matchProjectName(
            in: "proof stack 里跑一遍测试",
            candidates: projects
        ) == "Proof Stack"
    )
    // 没提到项目就不猜。
    #expect(VoiceIntent.matchProjectName(in: "整理文档", candidates: projects) == nil)
}

@Test func voiceDispatchInvocationsKeepSessionsAndStayWorkspaceScoped() {
    // 派发是真任务：pi 保留会话（可恢复、钩子可追踪，不带 --no-session），
    // codex 用工作区沙箱的自主模式，claude 允许工作区内编辑——永远
    // 不用绕过权限的开关；提示词永远是最后一个 argv 元素。
    let prompt = "run the tests"
    #expect(
        PetChatAgentCommand.dispatchInvocation(for: .pi, prompt: prompt)!
            == ("pi", ["-p", prompt])
    )
    #expect(
        PetChatAgentCommand.dispatchInvocation(for: .codex, prompt: prompt)!
            == ("codex", ["exec", "--full-auto", prompt])
    )
    #expect(
        PetChatAgentCommand.dispatchInvocation(for: .claude, prompt: prompt)!
            == ("claude", ["-p", "--permission-mode", "acceptEdits", prompt])
    )
    #expect(
        PetChatAgentCommand.dispatchInvocation(for: .gemini, prompt: prompt)!
            == ("gemini", ["-p", prompt])
    )
    #expect(
        PetChatAgentCommand.dispatchInvocation(for: .opencode, prompt: prompt)!
            == ("opencode", ["run", prompt])
    )
    for provider in PetChatAgentCommand.supportedProviders {
        let arguments = PetChatAgentCommand.dispatchInvocation(
            for: provider, prompt: prompt
        )!.arguments
        #expect(arguments.last == prompt)
        #expect(!arguments.contains("--no-session"))
        #expect(!arguments.contains("--dangerously-skip-permissions"))
        #expect(!arguments.contains("--yolo"))
    }
}

@Test func dispatchHandlesReopenTheSessionWhereTheWorkLives() {
    // 新会话：铸确定句柄（pi --session-id 实测创建即用）；
    // 接续：会话就是目录里最近那个，--continue 即可重开。
    let fresh = PetChatAgentCommand.dispatchHandle(
        for: .pi, continued: false, sessionID: "abc-123"
    )
    #expect(fresh?.arguments == ["--session-id", "abc-123"])
    #expect(fresh?.resumeCommand == "pi --session-id 'abc-123'")
    #expect(
        PetChatAgentCommand.dispatchHandle(for: .pi, continued: true, sessionID: "x")
            == PetChatAgentCommand.DispatchHandle(
                arguments: [], resumeCommand: "pi --continue"
            )
    )
    #expect(
        PetChatAgentCommand.dispatchHandle(for: .claude, continued: false, sessionID: "x")?
            .resumeCommand == "claude --continue"
    )
    // 未核实的 CLI 不给句柄：回执不带跳转，不伪造可恢复性。
    #expect(PetChatAgentCommand.dispatchHandle(for: .codex, continued: false, sessionID: "x") == nil)
    #expect(PetChatAgentCommand.dispatchHandle(for: .opencode, continued: true, sessionID: "x") == nil)
}

@Test func voiceContinuationDispatchResumesOnlyVerifiedCLIs() {
    // 「继续干活」类消息识别为接续意图。
    #expect(VoiceIntent.isContinuation("继续把测试跑完"))
    #expect(VoiceIntent.isContinuation("顺便把 lint 也过一遍"))
    #expect(VoiceIntent.isContinuation("刚才的 diff 再看一眼"))
    #expect(VoiceIntent.isContinuation("keep going with the refactor"))
    #expect(!VoiceIntent.isContinuation("整理文档"))

    // 只有核实过无头 continue 旗标的 CLI 才接续；其余回落新会话。
    let prompt = "把测试跑完"
    #expect(
        PetChatAgentCommand.continueDispatchInvocation(for: .pi, prompt: prompt)!
            == ("pi", ["-p", "--continue", prompt])
    )
    #expect(
        PetChatAgentCommand.continueDispatchInvocation(for: .claude, prompt: prompt)!
            == ("claude", ["-p", "--continue", "--permission-mode", "acceptEdits", prompt])
    )
    #expect(PetChatAgentCommand.continueDispatchInvocation(for: .codex, prompt: prompt) == nil)
    #expect(PetChatAgentCommand.continueDispatchInvocation(for: .gemini, prompt: prompt) == nil)
    #expect(PetChatAgentCommand.continueDispatchInvocation(for: .opencode, prompt: prompt) == nil)
}

@Test func petChatAgentCommandsCoverOnlyHeadlessCLIs() {
    #expect(PetChatAgentCommand.supportedProviders == [.claude, .codex, .gemini, .opencode, .pi])

    let claude = PetChatAgentCommand.invocation(for: .claude, prompt: "hi there")
    #expect(claude?.binary == "claude")
    #expect(claude?.arguments == ["-p", "hi there"])
    let pi = PetChatAgentCommand.invocation(for: .pi, prompt: "hi")
    #expect(pi?.arguments == ["-p", "--no-session", "--no-tools", "hi"])
    #expect(PetChatAgentCommand.invocation(for: .trae, prompt: "x") == nil)

    // Prompts travel as argv values, never through a shell string.
    let codex = PetChatAgentCommand.invocation(for: .codex, prompt: "a \"quoted\" prompt")
    #expect(codex?.arguments.last == "a \"quoted\" prompt")
}

@Test func piRpcProtocolFramesAndParsesTheChatHandshake() {
    // 编码：一行一个 JSON 记录，LF 结尾，提示词作为 JSON 值携带。
    let prompt = PiRpcProtocol.encodePrompt(id: "req-2", message: "你好\n换行")
    #expect(prompt.last == 0x0A)
    let decoded = try? JSONSerialization.jsonObject(
        with: prompt.dropLast()
    ) as? [String: String]
    #expect(decoded == ["id": "req-2", "type": "prompt", "message": "你好\n换行"])

    // 分帧：只按 LF 切，容忍 CRLF，半条记录留在缓冲区。
    var buffer = Data(
        "{\"type\":\"agent_settled\"}\r\n{\"type\":\"response\",\"command\":\"prompt\",\"success\":true,\"id\":\"req-2\"}\n{\"par".utf8
    )
    let records = PiRpcProtocol.drainRecords(from: &buffer)
    #expect(records.count == 2)
    #expect(String(data: buffer, encoding: .utf8) == "{\"par")
    #expect(PiRpcProtocol.parse(records[0]) == .agentSettled)
    #expect(
        PiRpcProtocol.parse(records[1])
            == .response(id: "req-2", command: "prompt", success: true, text: nil)
    )

    // 取文案：data.text 缺省与 null 都要安全。
    let text = Data(
        "{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":\"喵\"}}".utf8
    )
    #expect(
        PiRpcProtocol.parse(text)
            == .response(
                id: nil,
                command: "get_last_assistant_text",
                success: true,
                text: "喵"
            )
    )
    let nullText = Data(
        "{\"type\":\"response\",\"command\":\"get_last_assistant_text\",\"success\":true,\"data\":{\"text\":null}}".utf8
    )
    #expect(
        PiRpcProtocol.parse(nullText)
            == .response(
                id: nil,
                command: "get_last_assistant_text",
                success: true,
                text: nil
            )
    )
    // 事件流里的其他类型跳过。
    #expect(PiRpcProtocol.parse(Data("{\"type\":\"message_update\"}".utf8)) == nil)
}

@Test func petChatTextIsBoundedBeforeItReachesAnAgentOrTheUI() {
    let long = "  " + String(repeating: "猫", count: 9_000) + "  "
    #expect(PetChatTextPolicy.input(long).count == 500)
    #expect(PetChatTextPolicy.reply(long).count == 600)
    #expect(PetChatTextPolicy.agentPrompt(long).count == 8_000)
    #expect(PetChatTextPolicy.input("   ").isEmpty)
    #expect(PetChatTextPolicy.retainedExchangeCount == 3)
}

@Test func petChatAutoChoicePrefersTheMostRecentlyUsedAgent() {
    let now = Date()
    let pick = PetChatAgentCommand.preferredAgent(
        detected: [.claude, .pi, .gemini],
        lastRealEventAt: [
            .claude: now.addingTimeInterval(-3600),
            .pi: now.addingTimeInterval(-60),
        ]
    )
    #expect(pick == .pi)

    // No activity yet: fall back to the stable order; no supported
    // candidate at all: nil.
    #expect(PetChatAgentCommand.preferredAgent(
        detected: [.gemini], lastRealEventAt: [:]
    ) == .gemini)
    #expect(PetChatAgentCommand.preferredAgent(
        detected: [.trae], lastRealEventAt: [:]
    ) == nil)
}

@Test
func petChatSpawnPolicyMarksChatAndGuardsRelay() {
    #expect(PetChatSpawnPolicy.environmentKey == "PERCH_CHAT")
    #expect(PetChatSpawnPolicy.relayGuard.contains("\"${PERCH_CHAT}\" = \"1\""))
    #expect(PetChatSpawnPolicy.relayGuard.hasSuffix("exit 0; fi"))
}

@Test
func terminalHostPolicyResolvesTheUsersTerminalAndItsHandOff() {
    // The terminal the user last activated wins over the default handler.
    #expect(TerminalHostPolicy.resolve(
        runningBundleIDs: ["com.apple.Terminal", "com.googlecode.iterm2"],
        lastActivatedBundleID: "com.googlecode.iterm2",
        defaultHandlerBundleID: "com.apple.Terminal"
    ) == "com.googlecode.iterm2")
    // A single running known terminal is the user's terminal; other
    // running apps are ignored.
    #expect(TerminalHostPolicy.resolve(
        runningBundleIDs: ["org.alacritty", "com.apple.dt.Xcode"],
        lastActivatedBundleID: nil,
        defaultHandlerBundleID: nil
    ) == "org.alacritty")
    // Ambiguity falls back to the running default handler; a terminal
    // that is not running never wins.
    #expect(TerminalHostPolicy.resolve(
        runningBundleIDs: ["com.apple.Terminal", "org.alacritty"],
        lastActivatedBundleID: nil,
        defaultHandlerBundleID: "com.apple.Terminal"
    ) == "com.apple.Terminal")
    #expect(TerminalHostPolicy.resolve(
        runningBundleIDs: [],
        lastActivatedBundleID: "com.googlecode.iterm2",
        defaultHandlerBundleID: nil
    ) == nil)
    // Launch templates substitute the directory and command; Warp is
    // honestly unsupported rather than mislaunched; unknown apps are nil.
    #expect(TerminalHostPolicy.launch(
        bundleID: "com.github.wez.wezterm",
        directory: "/tmp/proj",
        command: "pi --session-id 'x'"
    ) == .appArguments([
        "start", "--cwd", "/tmp/proj",
        "--", "/bin/zsh", "-lc", "pi --session-id 'x'",
    ]))
    #expect(TerminalHostPolicy.launch(
        bundleID: "dev.warp.Warp-Stable",
        directory: "/",
        command: "true"
    ) == .unsupported)
    #expect(TerminalHostPolicy.launch(
        bundleID: "com.example.notaterminal",
        directory: "/",
        command: "true"
    ) == nil)
}

@Test func stateReducerFlagsAttentionEdgesOnce() {
    let start = Date(timeIntervalSince1970: 3_000)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .claude, sessionID: "a", phase: .working, timestamp: start))
    let edge = reducer.ingest(AgentEvent(
        provider: .claude,
        sessionID: "a",
        phase: .waitingForInput,
        timestamp: start.addingTimeInterval(1)
    ))
    let escalated = reducer.ingest(AgentEvent(
        provider: .claude,
        sessionID: "a",
        phase: .failed,
        timestamp: start.addingTimeInterval(2)
    ))
    reducer.ingest(AgentEvent(
        provider: .claude,
        sessionID: "a",
        phase: .working,
        timestamp: start.addingTimeInterval(3)
    ))
    let second = reducer.ingest(AgentEvent(
        provider: .claude,
        sessionID: "a",
        phase: .waitingForInput,
        timestamp: start.addingTimeInterval(4)
    ))
    #expect(edge.didRequestAttention)
    #expect(!edge.didComplete)
    #expect(!escalated.didRequestAttention)
    #expect(second.didRequestAttention)
}

@Test func agentActivityNotificationPolicySuppressionOrder() {
    var policy = AgentActivityNotificationPolicy()
    let now = Date(timeIntervalSince1970: 5_000)
    func context(
        enabled: Bool = true,
        available: Bool = true,
        quiet: Bool = false,
        muted: Bool = false,
        frontmost: Bool = false,
        idle: TimeInterval? = nil
    ) -> AgentActivityNotificationContext {
        AgentActivityNotificationContext(
            enabled: enabled,
            channelAvailable: available,
            quietHoursActive: quiet,
            sessionMuted: muted,
            hostAppFrontmost: frontmost,
            inputIdleSeconds: idle
        )
    }
    #expect(policy.decision(kind: .attention, provider: .claude, context: context(enabled: false), at: now)
        == .suppressed(.disabled))
    #expect(policy.decision(kind: .attention, provider: .claude, context: context(available: false), at: now)
        == .suppressed(.channelUnavailable))
    #expect(policy.decision(kind: .attention, provider: .claude, context: context(quiet: true), at: now)
        == .suppressed(.quietHours))
    #expect(policy.decision(kind: .attention, provider: .claude, context: context(muted: true), at: now)
        == .suppressed(.sessionMuted))
    #expect(policy.decision(kind: .attention, provider: .claude, context: context(frontmost: true), at: now)
        == .suppressed(.hostAppFrontmost))
    #expect(policy.decision(
        kind: .attention,
        provider: .claude,
        context: context(frontmost: true, idle: 30),
        at: now
    ) == .suppressed(.hostAppFrontmost))
    // A frontmost app with an idle keyboard no longer counts as watching.
    #expect(policy.decision(
        kind: .attention,
        provider: .claude,
        context: context(frontmost: true, idle: AgentActivityNotificationPolicy.presenceIdleThreshold),
        at: now
    ) == .deliver)
    #expect(policy.decision(kind: .attention, provider: .claude, context: context(), at: now) == .deliver)
}

@Test func agentActivityNotificationPolicyCollapsesCompletionBursts() {
    var policy = AgentActivityNotificationPolicy()
    let now = Date(timeIntervalSince1970: 6_000)
    let context = AgentActivityNotificationContext(
        enabled: true,
        channelAvailable: true,
        quietHoursActive: false,
        sessionMuted: false,
        hostAppFrontmost: false
    )
    #expect(policy.decision(kind: .completion, provider: .claude, context: context, at: now) == .deliver)
    #expect(policy.decision(kind: .completion, provider: .claude, context: context, at: now.addingTimeInterval(10))
        == .suppressed(.burstWindow))
    #expect(policy.decision(kind: .completion, provider: .cursor, context: context, at: now.addingTimeInterval(10))
        == .deliver)
    #expect(policy.decision(kind: .attention, provider: .claude, context: context, at: now.addingTimeInterval(11))
        == .deliver)
    #expect(policy.decision(kind: .completion, provider: .claude, context: context, at: now.addingTimeInterval(31))
        == .deliver)
}

// MARK: - Localization catalogue

/// The repository root, derived from this file's location. The localization
/// catalogues live in the app target's resources, which the core test target
/// cannot import, so they are read from disk instead.
private func perchRepositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func perchStringsCatalogue(_ language: String) throws -> (entries: [String: String], duplicates: [String]) {
    let url = perchRepositoryRoot()
        .appending(path: "Sources/Perch/Resources/\(language).lproj/Localizable.strings")
    let text = try String(contentsOf: url, encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*=\s*"(.*)"\s*;\s*$"#)
    var entries: [String: String] = [:]
    var duplicates: [String] = []
    for line in text.components(separatedBy: .newlines) {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern.firstMatch(in: line, range: range),
              let keyRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else { continue }
        let key = String(line[keyRange])
        if entries[key] != nil { duplicates.append(key) }
        entries[key] = String(line[valueRange])
    }
    return (entries, duplicates)
}

private func perchPlaceholders(in value: String) throws -> Set<String> {
    let pattern = try NSRegularExpression(pattern: #"\{[a-zA-Z_]+\}"#)
    let range = NSRange(value.startIndex..., in: value)
    return Set(pattern.matches(in: value, range: range).compactMap {
        Range($0.range, in: value).map { String(value[$0]) }
    })
}

/// AGENTS.md makes "Chinese and English strings updated together" a release
/// gate, but nothing enforced it: a key added to one catalogue and forgotten
/// in the other ships as a raw key on screen for half the users.
@Test func localizationCataloguesStayInSync() throws {
    let en = try perchStringsCatalogue("en")
    let zh = try perchStringsCatalogue("zh-Hans")

    #expect(en.duplicates.isEmpty, "duplicate English keys: \(en.duplicates)")
    #expect(zh.duplicates.isEmpty, "duplicate Chinese keys: \(zh.duplicates)")

    let missingChinese = en.entries.keys.filter { zh.entries[$0] == nil }.sorted()
    let missingEnglish = zh.entries.keys.filter { en.entries[$0] == nil }.sorted()
    #expect(missingChinese.isEmpty, "translated into English only: \(missingChinese)")
    #expect(missingEnglish.isEmpty, "translated into Chinese only: \(missingEnglish)")

    let blank = (en.entries.merging(zh.entries) { a, _ in a })
        .filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        .keys.sorted()
    #expect(blank.isEmpty, "empty values render as nothing at all: \(blank)")

    // A translation that drops a placeholder silently loses the substituted
    // agent, count, or duration it was written around.
    for (key, english) in en.entries {
        guard let chinese = zh.entries[key] else { continue }
        let left = try perchPlaceholders(in: english)
        let right = try perchPlaceholders(in: chinese)
        #expect(left == right, "\(key) placeholders differ: en \(left.sorted()) vs zh \(right.sorted())")
    }
}

/// Scans the SwiftUI surface for the two ways a key reaches the user as raw
/// text: a key that was never defined, and a key built with string
/// interpolation. The latter is the quieter trap — `Text("kind.\(kind)")`
/// looks up `kind.%@`, misses, and paints the assembled key on screen.
@Test func viewsOnlyReferenceDefinedLocalizationKeys() throws {
    let en = try perchStringsCatalogue("en").entries
    let sources = perchRepositoryRoot().appending(path: "Sources/Perch")
    let constructors = try NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_.])(?:Text|Toggle|Button|Section|LabeledContent|Label|Picker|Stepper|DatePicker|TextField|Link|Menu|navigationTitle|help)\(\s*"([^"]*)""#
    )
    let accessibility = try NSRegularExpression(
        pattern: #"\.accessibility(?:Label|Hint)\(\s*"([^"]*)""#
    )
    let keyShaped = try NSRegularExpression(pattern: #"^[a-z][a-z0-9_]*\."#)

    var undefined: [String] = []
    var interpolated: [String] = []
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" } ?? []
    #expect(!files.isEmpty, "found no SwiftUI sources to scan")

    for file in files {
        let text = try String(contentsOf: file, encoding: .utf8)
        for (number, line) in text.components(separatedBy: .newlines).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            let range = NSRange(line.startIndex..., in: line)
            let literals = (constructors.matches(in: line, range: range)
                + accessibility.matches(in: line, range: range))
                .compactMap { Range($0.range(at: 1), in: line).map { String(line[$0]) } }
            for literal in literals {
                let shape = NSRange(literal.startIndex..., in: literal)
                guard keyShaped.firstMatch(in: literal, range: shape) != nil else { continue }
                let where_ = "\(file.lastPathComponent):\(number + 1) \(literal)"
                if literal.contains(#"\("# ) {
                    interpolated.append(where_)
                } else if en[literal] == nil {
                    undefined.append(where_)
                }
            }
        }
    }
    #expect(undefined.isEmpty, "keys with no entry in the catalogue: \(undefined)")
    #expect(
        interpolated.isEmpty,
        "interpolated keys resolve to the literal text, not a translation: \(interpolated)"
    )
}

/// Literal keys in SwiftUI resolve through the environment's locale, while
/// `model.uiText` resolves through the chosen language directly. A root that
/// forgets the environment renders half its bubble in the system language and
/// the other half in the user's pick.
@Test func swiftUIRootsFollowTheChosenLanguage() throws {
    let roots = [
        "Sources/Perch/CompanionWindowController.swift",
        "Sources/Perch/PerchApp.swift",
    ]
    for root in roots {
        let text = try String(
            contentsOf: perchRepositoryRoot().appending(path: root),
            encoding: .utf8
        )
        #expect(
            text.contains(#"environment(\.locale, model.locale)"#),
            "\(root) hosts literal keys without pinning the app's language"
        )
    }
}

private func perchInfoPlistStrings(_ language: String) throws -> [String: String] {
    let url = perchRepositoryRoot()
        .appending(path: "Sources/Perch/Resources/\(language).lproj/InfoPlist.strings")
    let text = try String(contentsOf: url, encoding: .utf8)
    let pattern = try NSRegularExpression(pattern: #"^\s*"([^"]+)"\s*=\s*"(.*)"\s*;\s*$"#)
    var entries: [String: String] = [:]
    for line in text.components(separatedBy: .newlines) {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = pattern.firstMatch(in: line, range: range),
              let key = Range(match.range(at: 1), in: line),
              let value = Range(match.range(at: 2), in: line) else { continue }
        entries[String(line[key])] = String(line[value])
    }
    return entries
}

private func perchContainsHanCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
}

/// The microphone and speech prompts are drawn by macOS, not by Perch, so
/// they are localized through `InfoPlist.strings` rather than the catalogue
/// the rest of the app uses — which is how they escaped review and shipped
/// with English and Chinese concatenated into one sentence.
@Test func systemPermissionPromptsAreLocalizedOnePerLanguage() throws {
    let plistURL = perchRepositoryRoot().appending(path: "Packaging/Info.plist")
    let raw = try Data(contentsOf: plistURL)
    let plist = try PropertyListSerialization.propertyList(from: raw, format: nil) as? [String: Any]
    let info = try #require(plist)
    let usageKeys = info.keys.filter { $0.hasSuffix("UsageDescription") }.sorted()
    #expect(!usageKeys.isEmpty, "no usage descriptions found to check")

    let english = try perchInfoPlistStrings("en")
    let chinese = try perchInfoPlistStrings("zh-Hans")

    for key in usageKeys {
        // The bundle falls back to Info.plist for the development region, so
        // its copy has to be English alone.
        let fallback = info[key] as? String ?? ""
        #expect(
            !perchContainsHanCharacters(fallback),
            "\(key) in Info.plist mixes languages; translations belong in InfoPlist.strings"
        )
        let englishValue = try #require(english[key], "\(key) missing from en.lproj/InfoPlist.strings")
        let chineseValue = try #require(chinese[key], "\(key) missing from zh-Hans.lproj/InfoPlist.strings")
        #expect(!perchContainsHanCharacters(englishValue), "\(key) English prompt contains Chinese")
        #expect(perchContainsHanCharacters(chineseValue), "\(key) Chinese prompt is not translated")
    }
}

@Test func aTrailingSessionEndDoesNotSettleAHeldFailure() {
    var reducer = AgentStateReducer()
    let start = Date(timeIntervalSince1970: 7_000)
    let key = AgentSessionKey(provider: .pi, sessionID: "s1")

    _ = reducer.ingest(AgentEvent(provider: .pi, sessionID: "s1", phase: .working, timestamp: start))
    let failed = reducer.ingest(
        AgentEvent(provider: .pi, sessionID: "s1", phase: .failed, timestamp: start.addingTimeInterval(1))
    )
    #expect(failed.didRequestAttention)
    #expect(!failed.didSettle)

    // Providers dispatch the failure and the session-end hook concurrently.
    // The reducer holds the failure; anything the app retires on shutdown —
    // the user's mute, above all — has to be held with it.
    let trailingIdle = reducer.ingest(
        AgentEvent(provider: .pi, sessionID: "s1", phase: .idle, timestamp: start.addingTimeInterval(2))
    )
    #expect(!trailingIdle.didSettle, "a swallowed session end must not read as settled")
    #expect(reducer.sessions[key]?.phase == .failed)

    var clean = AgentStateReducer()
    _ = clean.ingest(AgentEvent(provider: .pi, sessionID: "s2", phase: .working, timestamp: start))
    let done = clean.ingest(
        AgentEvent(provider: .pi, sessionID: "s2", phase: .done, timestamp: start.addingTimeInterval(1))
    )
    #expect(done.didSettle)
    #expect(done.didComplete)
}

@Test func voiceAnnouncementsMergeInsteadOfTalkingOverEachOther() {
    var queue = AgentVoiceAnnouncementQueue()
    #expect(queue.flush() == .nothing)

    queue.enqueue(provider: .pi, isFailure: false, taskLabel: "fix login")
    #expect(queue.flush() == .one(provider: .pi, isFailure: false, taskLabel: "fix login"))
    #expect(queue.isEmpty, "flushing hands the asks over exactly once")

    // One agent asking twice is still one agent standing there, and an
    // escalation to failure is never spoken back down to a plain wait.
    queue.enqueue(provider: .pi, isFailure: false, taskLabel: "fix login")
    queue.enqueue(provider: .pi, isFailure: true)
    #expect(queue.flush() == .one(provider: .pi, isFailure: true, taskLabel: "fix login"))

    for provider in [AgentProvider.pi, .claude, .codex, .gemini] {
        queue.enqueue(provider: provider, isFailure: provider == .codex)
    }
    // The list is trimmed for listenability; the count still tells the truth.
    #expect(queue.flush() == .several(named: [.pi, .claude, .codex], total: 4, includesFailure: true))
}

@Test func restoredSessionsSurviveARestartButNotAReboot() {
    let boot = Date(timeIntervalSince1970: 100_000)
    let beforeBoot = AgentSessionKey(provider: .claude, sessionID: "yesterday")
    let afterBoot = AgentSessionKey(provider: .pi, sessionID: "running")
    let saved: [AgentSessionKey: SessionState] = [
        beforeBoot: SessionState(
            provider: .claude,
            phase: .working,
            phaseStartedAt: boot.addingTimeInterval(-3_600),
            lastEventAt: boot.addingTimeInterval(-3_600)
        ),
        afterBoot: SessionState(
            provider: .pi,
            phase: .working,
            phaseStartedAt: boot.addingTimeInterval(60),
            lastEventAt: boot.addingTimeInterval(60)
        ),
    ]

    var reducer = AgentStateReducer()
    reducer.restore(saved, notBefore: boot)
    #expect(reducer.sessions[beforeBoot] == nil, "a session last heard from before boot cannot still run")
    #expect(reducer.sessions[afterBoot]?.phase == .working)
    #expect(reducer.aggregatePhase == .working, "a restart must not make the pet forget live work")

    // The inactivity clock keeps running from the last real event rather than
    // restarting at launch, so a session that went quiet before the restart
    // still expires on schedule instead of looking fresh forever.
    reducer.cleanupStaleSessions(at: boot.addingTimeInterval(60 + 29 * 60))
    #expect(reducer.aggregatePhase == .working)
    reducer.cleanupStaleSessions(at: boot.addingTimeInterval(60 + 31 * 60))
    #expect(reducer.aggregatePhase == .idle)
    #expect(reducer.sessions[afterBoot]?.isSignalStale == true)
}

@Test func aLongSilentToolRunIsStillTreatedAsWork() {
    // Providers report liveness per turn and per tool launch. One long tool
    // run — a full test suite — is silent throughout, and the pet used to
    // call it dead ten minutes in while it was still going.
    let start = Date(timeIntervalSince1970: 200_000)
    var reducer = AgentStateReducer()
    reducer.ingest(AgentEvent(provider: .pi, sessionID: "build", phase: .working, timestamp: start))
    reducer.cleanupStaleSessions(at: start.addingTimeInterval(20 * 60))
    #expect(reducer.aggregatePhase == .working)
    #expect(reducer.sessions.values.first?.isSignalStale == false)
}

@Test func proLicenseRoundTripsAndFailsClosed() throws {
    let key = Curve25519.Signing.PrivateKey()
    let issued = Date(timeIntervalSince1970: 1_790_000_000)
    let file = try ProLicense.issue(
        email: "buyer@example.com", order: "LS-1234", issued: issued,
        privateKey: key
    )
    let license = ProLicense.verify(
        fileData: file, publicKey: key.publicKey.rawRepresentation
    )
    #expect(license?.edition == .pro)
    #expect(license?.email == "buyer@example.com")
    #expect(license?.order == "LS-1234")
    #expect(license?.issued == issued)

    // A different vendor key must not validate the same file.
    let stranger = Curve25519.Signing.PrivateKey()
    #expect(ProLicense.verify(
        fileData: file, publicKey: stranger.publicKey.rawRepresentation
    ) == nil)

    // Any byte-level tampering with the envelope breaks the signature.
    var tampered = file
    tampered[file.count / 2] ^= 0x01
    #expect(ProLicense.verify(
        fileData: tampered, publicKey: key.publicKey.rawRepresentation
    ) == nil)

    // Garbage, emptiness, and oversized files all fail closed.
    #expect(ProLicense.verify(
        fileData: Data(), publicKey: key.publicKey.rawRepresentation
    ) == nil)
    #expect(ProLicense.verify(
        fileData: Data(repeating: 0x7b, count: ProLicense.maximumFileSize + 1),
        publicKey: key.publicKey.rawRepresentation
    ) == nil)
}

@Test func proLicenseRejectsInvalidFieldsEvenWhenCorrectlySigned() throws {
    let key = Curve25519.Signing.PrivateKey()
    // A signed payload with an unknown edition must not verify: the
    // signature proves origin, the field checks prove meaning.
    let payload = try JSONEncoder().encode([
        "edition": "ultimate", "email": "a@b.c", "order": "1",
        "issued": ISO8601DateFormatter().string(from: .now),
    ])
    let envelope = try JSONEncoder().encode([
        "payload": payload.base64EncodedString(),
        "signature": (try key.signature(for: payload)).base64EncodedString(),
    ])
    #expect(ProLicense.verify(
        fileData: envelope, publicKey: key.publicKey.rawRepresentation
    ) == nil)
}

// Fixtures drawn from real failures shipped by competing agent watchers
// (clawd-on-desk #952/#992, vibe-notch #98): a watcher that misreports
// "done" or flips "waiting" back to "working" loses the user's trust
// permanently. These lock Sleepwing's protections against that class.
@Test func lateToolEventsCannotOverrideAnAttentionState() {
    var reducer = AgentStateReducer()
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    reducer.ingest(AgentEvent(
        provider: .claude, sessionID: "s", phase: .working, timestamp: start
    ))
    reducer.ingest(AgentEvent(
        provider: .claude, sessionID: "s", phase: .waitingForInput,
        timestamp: start.addingTimeInterval(10)
    ))
    // A tool event generated before the ask but delivered after it must
    // not flip the session back to working (vibe-notch #98's regression).
    reducer.ingest(AgentEvent(
        provider: .claude, sessionID: "s", phase: .working,
        timestamp: start.addingTimeInterval(5)
    ))
    #expect(reducer.sessions.values.first?.phase == .waitingForInput)
    #expect(reducer.aggregatePhase == .waitingForInput)
}

@Test func attentionOutranksParallelWorkInTheAggregate() {
    // While one session waits on the user, other running sessions must
    // not dilute the aggregate into "working" — the user's next action
    // is answering, not watching (clawd-on-desk #992's flapping).
    var reducer = AgentStateReducer()
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    reducer.ingest(AgentEvent(
        provider: .claude, sessionID: "asks", phase: .waitingForInput, timestamp: start
    ))
    reducer.ingest(AgentEvent(
        provider: .codex, sessionID: "runs", phase: .working,
        timestamp: start.addingTimeInterval(1)
    ))
    reducer.ingest(AgentEvent(
        provider: .codex, sessionID: "runs", phase: .working,
        timestamp: start.addingTimeInterval(30)
    ))
    #expect(reducer.aggregatePhase == .waitingForInput)
}

@Test func companionYieldsFullScreenUntilAttentionIsNeeded() {
    // Attention-priority over full-screen apps: yield while agents work
    // (the pet over a video is a top competitor complaint), surface the
    // moment an agent actually needs the user, honor the opt-in always.
    for phase in [AgentPhase.idle, .working, .done] {
        #expect(!CompanionWindowPlacement.joinsFullScreenSpaces(
            showsOverFullScreen: false, phase: phase
        ))
    }
    for phase in [AgentPhase.waitingForInput, .failed] {
        #expect(CompanionWindowPlacement.joinsFullScreenSpaces(
            showsOverFullScreen: false, phase: phase
        ))
    }
    #expect(CompanionWindowPlacement.joinsFullScreenSpaces(
        showsOverFullScreen: true, phase: .idle
    ))
}

@Test func resumedSessionsReactivateWithoutDoubleCelebration() {
    // Competitors lose resumed sessions (their pets stay asleep while
    // real work continues). A later event on a completed session must
    // reactivate it — and completion must have fired exactly once.
    var reducer = AgentStateReducer()
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    reducer.ingest(AgentEvent(
        provider: .claude, sessionID: "r", phase: .working, timestamp: start
    ))
    let completion = reducer.ingest(AgentEvent(
        provider: .claude, sessionID: "r", phase: .done,
        timestamp: start.addingTimeInterval(60)
    ))
    #expect(completion.didComplete)
    let resumed = reducer.ingest(AgentEvent(
        provider: .claude, sessionID: "r", phase: .working,
        timestamp: start.addingTimeInterval(120)
    ))
    #expect(!resumed.didComplete)
    #expect(reducer.sessions.values.first?.phase == .working)
    #expect(reducer.aggregatePhase == .working)
}

@Test func atlasContractStaysInsideTheMemoryBudget() {
    // A competitor shipped 1.5 GB of duplicate decoded sprites. Our
    // decoded atlas cost is fixed by the contract; this pins it so a
    // future contract change cannot silently inflate the budget.
    let bytesPerAtlas = PetSpriteContract.atlasWidth
        * PetSpriteContract.atlasHeight * 4
    #expect(bytesPerAtlas <= 15 * 1024 * 1024)
}

@Test func hookLossWarnsOnlyAfterProofOfLife() {
    // "Installed but silently dead" is the top complaint class in this
    // category. Warning requires prior real events, so fresh installs
    // stay quiet about tools the user never connected — and an in-app
    // uninstall clears the proof, leaving only external removal to warn.
    #expect(IntegrationHealthPolicy.lostHooks(
        everConnected: [.claude, .cursor], installed: [.cursor]
    ) == [.claude])
    #expect(IntegrationHealthPolicy.lostHooks(
        everConnected: [], installed: []
    ).isEmpty)
    #expect(IntegrationHealthPolicy.lostHooks(
        everConnected: [.pi], installed: [.pi, .codex]
    ).isEmpty)
}

@Test func subagentStopReadsAsOngoingWorkNeverAsCompletion() throws {
    // Competitors let subagent events impersonate the main task (false
    // celebrations, false errors pulling users back to a healthy run).
    // A finished subagent means the parent is still working — this pins
    // that mapping so no subagent event can ever celebrate or recall.
    let event = try HookEventAdapter.adapt(
        provider: .claude,
        data: Data(#"{"hook_event_name":"SubagentStop","session_id":"s1"}"#.utf8)
    )
    #expect(event.phase == .working)
}

@Test func lateCodexPermissionHookCannotCancelAGatedCompletionOrFakeAnAsk() {
    // User-reported phantom: the pet said Codex needed approval, but the
    // ChatGPT app had nothing to approve and the state would not clear.
    // Root cause: hooks arrive out of order; a pre-Stop PermissionRequest
    // delivered after the turn's Stop used to cancel the gated completion
    // and leave the session stuck in waitingForInput for hours.
    var gate = CodexCompletionGate()
    let start = Date(timeIntervalSince1970: 1_790_000_000)
    let stop = AgentEvent(
        provider: .codex, sessionID: "t", phase: .done,
        timestamp: start, sourceEventName: "stop"
    )
    #expect(gate.route(stop) == nil)
    #expect(gate.pendingCount == 1)

    // The late ask is dropped and the completion survives.
    let lateAsk = AgentEvent(
        provider: .codex, sessionID: "t", phase: .waitingForInput,
        timestamp: start.addingTimeInterval(0.3),
        sourceEventName: "permissionrequest"
    )
    #expect(gate.route(lateAsk) == nil)
    #expect(gate.pendingCount == 1)
    let drained = gate.drain(at: start.addingTimeInterval(6))
    #expect(drained.count == 1)
    #expect(drained.first?.phase == .done)

    // A genuine new ask still gets through: the new turn's working events
    // clear the gate before the ask arrives.
    let stop2 = AgentEvent(
        provider: .codex, sessionID: "t", phase: .done,
        timestamp: start.addingTimeInterval(10), sourceEventName: "stop"
    )
    #expect(gate.route(stop2) == nil)
    let newTurn = AgentEvent(
        provider: .codex, sessionID: "t", phase: .working,
        timestamp: start.addingTimeInterval(11),
        sourceEventName: "userpromptsubmit"
    )
    #expect(gate.route(newTurn)?.phase == .working)
    #expect(gate.pendingCount == 0)
    let genuineAsk = AgentEvent(
        provider: .codex, sessionID: "t", phase: .waitingForInput,
        timestamp: start.addingTimeInterval(12),
        sourceEventName: "permissionrequest"
    )
    #expect(gate.route(genuineAsk)?.phase == .waitingForInput)
}
