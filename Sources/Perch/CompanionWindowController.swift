import AppKit
import SwiftUI
import PerchCore
import os

private let dockLogger = Logger(subsystem: "app.sleepwing.Perch", category: "window-anchor")

/// Borderless windows refuse key status by default, which would make the
/// chat input field permanently unfocusable. Allowing key here is safe:
/// combined with `becomesKeyOnlyIfNeeded`, the panel only takes key when
/// a control that needs the keyboard (the chat field) is clicked.
private final class KeyableCompanionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class CompanionWindowController: NSObject, NSWindowDelegate {
    private static let frameKey = "PerchCompanionFrame"
    private static let framesByDisplayKey = "PerchCompanionFramesByDisplay"
    private static let preferredDisplayKey = "PerchCompanionPreferredDisplay"
    private let panel: NSPanel
    private let motionModel = CompanionMotionModel()
    private weak var model: PerchModel?
    private var lastSize: CompanionSize
    private var requestedVisible = false
    private var anchorTask: Task<Void, Never>?
    private var isProgrammaticMove = false
    private let frontmostTracker = FrontmostApplicationTracker()
    private var wasDocked = false
    private var dockPhase: DockPhase?
    private var pinnedWindowNumber: CGWindowID?
    private var pinnedProcessID: pid_t?
    private var pendingTargetSwitch: (pid: pid_t, since: Date)?
    private var userOverrideUntil: Date?
    private var lastDockDiagnostic: String?

    /// `fraction` is 0...1 along the target window's top edge (0 = left
    /// edge, 1 = right edge), not an absolute screen position, so the
    /// perched spot moves naturally with the window instead of needing a
    /// separate "follow the window" step.
    private enum DockPhase {
        case settled(fraction: CGFloat, nextRelocationAt: Date)
        case relocating(fromFraction: CGFloat, toFraction: CGFloat, startedAt: Date, duration: TimeInterval)
    }

    init(model: PerchModel) {
        self.model = model
        lastSize = model.companionSize
        let size = Self.windowSize(for: model.companionSize)
        panel = KeyableCompanionPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.delegate = self
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CompanionView(model: model, motion: motionModel))
        apply(size: model.companionSize, layer: model.companionLayer)
        restoreFrame(defaultSize: size)
        motionModel.updatePanelFrame(panel.frame, detectMovement: false)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidBecomeAvailable),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidBecomeAvailable),
            name: NSWorkspace.screensDidWakeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidBecomeAvailable),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidBecomeAvailable),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        anchorTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.applyWindowAnchorIfNeeded()
                let delay = self?.anchorPollingDelay ?? .seconds(1)
                try? await Task.sleep(for: delay)
            }
        }
        if CommandLine.arguments.contains("--run-demo") {
            Task { @MainActor [weak model] in
                try? await Task.sleep(for: .seconds(2))
                model?.runCompanionDemo()
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--voice-sim"),
           CommandLine.arguments.indices.contains(index + 1) {
            let transcript = CommandLine.arguments[index + 1]
            Task { @MainActor [weak model] in
                await model?.runVoiceSimulation(transcript)
                exit(0)
            }
        }
    }

    deinit {
        anchorTask?.cancel()
    }

    func apply(size: CompanionSize, layer: CompanionLayer) {
        if size != lastSize {
            let oldFrame = panel.frame
            let newSize = Self.windowSize(for: size)
            let origin = NSPoint(
                x: oldFrame.midX - newSize.width / 2,
                y: oldFrame.midY - newSize.height / 2
            )
            let resized = NSRect(origin: origin, size: newSize)
            panel.setFrame(constrainedFrame(resized, to: panel.screen ?? NSScreen.main), display: true, animate: true)
            lastSize = size
            persistCurrentFrame()
        }
        switch layer {
        case .floating:
            panel.level = .floating
        case .desktop:
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        }
    }

    func setVisible(_ visible: Bool) {
        requestedVisible = visible
        if visible {
            recoverToVisibleScreen()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    func windowDidMove(_ notification: Notification) {
        motionModel.updatePanelFrame(panel.frame)
        // Docking beside an agent window moves the panel programmatically
        // every poll tick; only persist genuine user drags as the saved
        // position, or turning docking off would snap back to a stale spot.
        guard !isProgrammaticMove else { return }
        persistCurrentFrame()
        // A move that isn't ours must be the user picking the panel up;
        // back off from docking for a while instead of fighting their drag
        // on the very next poll tick.
        userOverrideUntil = Date().addingTimeInterval(15)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        persistCurrentFrame()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        persistPreferredDisplay()
        persistCurrentFrame()
    }

    @objc private func screenParametersDidChange() {
        recoverToVisibleScreen()
        restoreVisibilityIfNeeded()
    }

    @objc private func workspaceDidBecomeAvailable() {
        recoverToVisibleScreen()
        restoreVisibilityIfNeeded()
    }

    @objc private func workspaceWillSleep() {
        persistCurrentFrame()
    }

    private func restoreVisibilityIfNeeded() {
        guard requestedVisible else { return }
        panel.orderFrontRegardless()
    }

    private func persistCurrentFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
        guard let displayID = displayIdentifier(for: panel.screen) else { return }
        var frames = UserDefaults.standard.dictionary(forKey: Self.framesByDisplayKey) as? [String: String] ?? [:]
        frames[displayID] = NSStringFromRect(panel.frame)
        let activeIDs = Set(NSScreen.screens.compactMap(displayIdentifier))
        frames = frames.filter { activeIDs.contains($0.key) }
        UserDefaults.standard.set(frames, forKey: Self.framesByDisplayKey)
    }

    private func persistPreferredDisplay() {
        guard let displayID = displayIdentifier(for: panel.screen) else { return }
        UserDefaults.standard.set(displayID, forKey: Self.preferredDisplayKey)
    }

    private func restoreFrame(defaultSize: NSSize) {
        guard let targetScreen = preferredScreen() ?? primaryScreen() else { return }
        let displayID = displayIdentifier(for: targetScreen)
        let frames = UserDefaults.standard.dictionary(forKey: Self.framesByDisplayKey) as? [String: String]
        let savedForDisplay = displayID.flatMap { frames?[$0] }
        if let saved = savedForDisplay {
            let frame = NSRectFromString(saved)
            if frame.width > 0, frame.height > 0 {
                let restored = NSRect(origin: frame.origin, size: defaultSize)
                panel.setFrame(constrainedFrame(restored, to: targetScreen), display: false)
                persistPreferredDisplay()
                return
            }
        }
        let visible = targetScreen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: visible.maxX - defaultSize.width - 28, y: visible.minY + 28))
        persistPreferredDisplay()
    }

    private func recoverToVisibleScreen() {
        guard !NSScreen.screens.isEmpty else { return }
        let visibleFrames = NSScreen.screens.map(\.visibleFrame)
        let fallback = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let recovered = CompanionWindowPlacement.recoveredFrame(
            panel.frame,
            visibleFrames: visibleFrames,
            fallbackVisibleFrame: fallback
        )
        panel.setFrame(recovered, display: true)
        persistCurrentFrame()
    }

    private func constrainedFrame(_ frame: NSRect, to screen: NSScreen?) -> NSRect {
        guard let visible = screen?.visibleFrame else { return frame }
        return CompanionWindowPlacement.constrainedFrame(frame, to: visible)
    }

    /// Docks the panel on top of the working agent's window and lets it
    /// slowly patrol the window's top edge, rather than pinning it to a
    /// single fixed corner; leaves the panel exactly where it already is
    /// whenever no agent is working, no matching window is on screen, or
    /// the user recently moved the panel by hand.
    ///
    /// The target window is whichever app the user was last actually
    /// working in (tracked by `FrontmostApplicationTracker`), not a fixed
    /// per-provider app name — a CLI agent's real window is whatever
    /// terminal is hosting it, which Perch cannot know in advance.
    private func applyWindowAnchorIfNeeded() {
        if let userOverrideUntil, Date() < userOverrideUntil {
            logDockDiagnostic("anchor: paused, user moved the panel recently")
            return
        }
        guard requestedVisible else {
            logDockDiagnostic("anchor: skipped, companion is hidden")
            resetDockState()
            return
        }
        guard model?.shouldDockCompanionWindow == true else {
            logDockDiagnostic("anchor: inactive (setting off, or no verified agent is working)")
            resetDockState()
            return
        }
        guard let pid = frontmostTracker.lastOtherApplicationProcessID else {
            logDockDiagnostic("anchor: no other app has been frontmost yet")
            resetDockState()
            return
        }

        if pid != pinnedProcessID {
            // Require the new app to stay frontmost briefly before actually
            // switching targets, so a quick glance at another app doesn't
            // yank the companion away and back.
            if let pending = pendingTargetSwitch, pending.pid == pid {
                guard Date().timeIntervalSince(pending.since) >= Self.targetSwitchDebounce else { return }
                pendingTargetSwitch = nil
            } else {
                pendingTargetSwitch = (pid: pid, since: Date())
                return
            }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            logDockDiagnostic("anchor: target app changed to \(name)")
            pinnedWindowNumber = nil
            pinnedProcessID = pid
            dockPhase = nil
        } else {
            pendingTargetSwitch = nil
        }

        guard let anchored = AgentWindowAnchor.window(
            ownedByProcessID: pid,
            preferringWindowNumber: pinnedWindowNumber
        ) else {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
            logDockDiagnostic("anchor: no matching on-screen window found for \(name)")
            setDocked(false)
            pinnedWindowNumber = nil
            dockPhase = nil
            return
        }
        if pinnedWindowNumber != anchored.windowNumber {
            logDockDiagnostic("anchor: docked to window #\(anchored.windowNumber), frame \(anchored.frame)")
        }
        pinnedWindowNumber = anchored.windowNumber
        let targetFrame = anchored.frame

        let margin: CGFloat = 8
        let panelSize = panel.frame.size
        let travelMin = targetFrame.minX + margin
        let travelMax = max(travelMin, targetFrame.maxX - panelSize.width - margin)
        // The target's own screen, not the panel's current one — the panel
        // may currently sit on a different monitor than the window it's
        // about to dock beside.
        let targetScreen = NSScreen.screens.first(where: { $0.frame.intersects(targetFrame) })
            ?? panel.screen ?? NSScreen.main

        if dockPhase == nil {
            // A fresh dock, or a switch to a different app's window: fade to
            // the new spot instead of "walking" there. A walk only reads as
            // natural over a short, local distance; the previous window and
            // this one can be arbitrarily far apart, even on different
            // monitors, where no walking speed looks right.
            let origin = NSPoint(
                x: travelMin + (travelMax - travelMin) * Self.perchFraction,
                y: targetFrame.maxY
            )
            let constrained = constrainedFrame(NSRect(origin: origin, size: panelSize), to: targetScreen)
            fadeToPosition(constrained.origin)
            dockPhase = .settled(
                fraction: Self.perchFraction,
                nextRelocationAt: Date().addingTimeInterval(.random(in: 45...80))
            )
            setDocked(true)
            return
        }
        setDocked(true)

        guard let currentDockPhase = dockPhase else { return }
        let fraction: CGFloat
        switch currentDockPhase {
        case let .settled(settledFraction, nextRelocationAt):
            if Date() >= nextRelocationAt {
                let target = Self.nextPerchFraction()
                let distance = abs(target - settledFraction)
                dockPhase = .relocating(
                    fromFraction: settledFraction,
                    toFraction: target,
                    startedAt: Date(),
                    duration: max(1.6, min(4.5, Double(distance) * 6))
                )
                fraction = settledFraction
            } else {
                fraction = settledFraction
            }
        case let .relocating(fromFraction, toFraction, startedAt, duration):
            let raw = min(1, max(0, Date().timeIntervalSince(startedAt) / duration))
            // Ease in/out instead of constant speed, so a walk accelerates
            // away from and decelerates into a stop rather than starting
            // and ending abruptly.
            let eased = (1 - cos(raw * .pi)) / 2
            fraction = fromFraction + (toFraction - fromFraction) * eased
            if raw >= 1 {
                dockPhase = .settled(
                    fraction: toFraction,
                    nextRelocationAt: Date().addingTimeInterval(.random(in: 45...80))
                )
            }
        }

        let origin = NSPoint(
            x: travelMin + (travelMax - travelMin) * fraction,
            y: targetFrame.maxY
        )
        let constrained = constrainedFrame(NSRect(origin: origin, size: panelSize), to: targetScreen)
        guard constrained.origin != panel.frame.origin else { return }
        isProgrammaticMove = true
        panel.setFrameOrigin(constrained.origin)
        isProgrammaticMove = false
    }

    private static let targetSwitchDebounce: TimeInterval = 1.5

    /// Window discovery is comparatively expensive. Only an in-progress
    /// patrol needs animation-rate samples; a settled or inactive companion
    /// can poll much less often without feeling detached from the host window.
    private var anchorPollingDelay: Duration {
        guard requestedVisible, model?.shouldDockCompanionWindow == true else {
            return .seconds(1)
        }
        switch dockPhase {
        case .relocating:
            return .milliseconds(90)
        case .settled:
            return .milliseconds(500)
        case nil:
            return .milliseconds(250)
        }
    }

    private func resetDockState() {
        setDocked(false)
        pinnedWindowNumber = nil
        pinnedProcessID = nil
        pendingTargetSwitch = nil
        dockPhase = nil
    }

    private func fadeToPosition(_ origin: NSPoint) {
        isProgrammaticMove = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel.setFrameOrigin(origin)
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    self.panel.animator().alphaValue = 1
                }
                self.isProgrammaticMove = false
            }
        }
    }

    private func setDocked(_ docked: Bool) {
        guard wasDocked != docked else { return }
        wasDocked = docked
        model?.companionIsDocked = docked
    }

    /// Logs only on change so this can run every poll tick without
    /// spamming; check with `log stream --predicate 'subsystem == "app.sleepwing.Perch"'`.
    private func logDockDiagnostic(_ message: @autoclosure () -> String) {
        let text = message()
        guard text != lastDockDiagnostic else { return }
        lastDockDiagnostic = text
        dockLogger.notice("\(text, privacy: .public)")
    }

    /// Perches near the window's top-right most of the time (0.78...1.0),
    /// with an occasional fuller move along the edge for a little life.
    private static let perchFraction: CGFloat = 0.85

    private static func nextPerchFraction() -> CGFloat {
        Double.random(in: 0...1) < 0.7 ? CGFloat.random(in: 0.78...1.0) : CGFloat.random(in: 0...1)
    }

    private func displayIdentifier(for screen: NSScreen?) -> String? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue
    }

    private func preferredScreen() -> NSScreen? {
        guard let preferredID = UserDefaults.standard.string(forKey: Self.preferredDisplayKey) else {
            return nil
        }
        return NSScreen.screens.first { displayIdentifier(for: $0) == preferredID }
    }

    private func primaryScreen() -> NSScreen? {
        NSScreen.screens.first {
            abs($0.frame.minX) < 0.5 && abs($0.frame.minY) < 0.5
        } ?? NSScreen.screens.first
    }

    private static func windowSize(for size: CompanionSize) -> NSSize {
        switch size {
        // Height includes headroom for the tallest bubble (the voice
        // confirmation card); the panel is transparent, so the extra
        // space is invisible. Content is bottom-aligned, which keeps the
        // character anchored and lets bubbles grow upward — a card that
        // still overflows clips at its top, never at its buttons.
        case .small: NSSize(width: 220, height: 290)
        case .medium: NSSize(width: 270, height: 330)
        case .large: NSSize(width: 330, height: 380)
        }
    }
}

private struct CompanionView: View {
    @ObservedObject var model: PerchModel
    @ObservedObject var motion: CompanionMotionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            if model.voicePendingAction != nil {
                voiceConfirmBubble
            } else if model.voiceListening || model.voiceFinalizing {
                listeningBubble
            } else if let receipt = model.voiceReceipt {
                voiceReceiptBubble(receipt)
            } else if let narration = model.companionNarration {
                narrationBubble(narration)
            } else if let chat = model.companionChatMessage {
                chatBubble(chat)
            } else if model.companionPhase == .waitingForInput {
                attentionBubble
            } else if let reminder = model.activeReminder {
                reminderBubble(reminder)
            } else if model.companionDetailsVisible {
                detailsBubble
            } else if model.companionPhase != .idle {
                statusBubble
            }
            CompanionCharacterView(
                role: model.displayedCompanionRole,
                state: model.companionPresentationState,
                diameter: petDiameter,
                skin: model.companionSkin,
                phase: model.companionPhase,
                motionEnabled: motionEnabled,
                dragDirection: motionEnabled ? motion.dragDirection : nil,
                lookDirection: shouldFollowPointer ? motion.lookDirection : nil,
                customSpriteURL: model.customPetSpriteURL
            )
            // A reply in flight reads as the pet thinking; the badge sits
            // on the head so it survives whichever bubble is showing.
            .overlay(alignment: .topTrailing) {
                if model.companionChatBusy {
                    ProgressView()
                        .controlSize(.small)
                        // A white halo instead of a badge disc: the daisy
                        // must stay readable over the sprite art without
                        // reading as another circular sticker.
                        .shadow(color: .white.opacity(0.9), radius: 2)
                        .shadow(color: .white.opacity(0.9), radius: 5)
                        .allowsHitTesting(false)
                        .accessibilityLabel(model.uiText("chat.thinking"))
                }
            }
            // Two stacked onTapGesture modifiers recognize double-clicks
            // unreliably on a movable borderless panel; an explicit
            // exclusive combination makes the double-click win.
            .gesture(
                TapGesture(count: 2)
                    .onEnded { model.companionPoked() }
                    .exclusively(
                        before: TapGesture().onEnded {
                            model.companionDetailsVisible.toggle()
                        }
                    )
            )
            // Push-to-talk: hold still for 0.4 s to start listening, and
            // the microphone lives exactly as long as the physical hold.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.4, maximumDistance: 4)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        if case .second(true, nil) = value {
                            model.beginVoiceCapture()
                        }
                    }
                    .onEnded { _ in
                        model.endVoiceCapture()
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sleepwing, \(model.companionStatusText)")
            .accessibilityHint(model.uiText("companion.open_status"))
            // Hidden while perched beside an agent window so the label
            // doesn't add visual footprint below the character and push it
            // further from the window's edge; an explicit tap for details
            // still shows it.
            if (model.companionPhase != .idle || model.companionDetailsVisible),
               !model.companionIsDocked || model.companionDetailsVisible {
                Text(model.activeProviderText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .tint(model.companionAccentColor)
        // Bubbles mix literal keys with `uiText`, and only the former go
        // through the environment. Reading the locale here — inside the
        // body, from the observed model — keeps both halves on the app's
        // chosen language and follows a change without rebuilding the panel.
        .environment(\.locale, model.locale)
        .accessibilityElement(children: .contain)
        .task {
            while !Task.isCancelled {
                if shouldFollowPointer {
                    motion.updatePointer()
                    try? await Task.sleep(for: .milliseconds(150))
                } else {
                    // Motion disabled, a reminder, or an active task should
                    // not keep sampling a global pointer that is not used.
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private var voiceConfirmBubble: some View {
        // A composer, not a confirmation form: dictation lands as
        // editable text, chips make chat-vs-dispatch explicit, and the
        // single send button is the confirmation — the same shape voice
        // input has in every composer-based product.
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                "",
                text: Binding(
                    get: { model.voicePendingAction?.message ?? "" },
                    set: { model.updateVoicePendingMessage($0) }
                ),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .lineLimit(1...4)
            .padding(6)
            .background(
                Color(nsColor: .textBackgroundColor).opacity(0.6),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            HStack(spacing: 6) {
                // One inferred destination, tappable to flip: a wrong
                // route is fixed in a single click without asking the
                // user to think in chat-vs-dispatch terms first.
                Button {
                    model.toggleVoicePendingMode()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.voicePendingAction?.mode == .dispatch
                            ? "paperplane.fill"
                            : "bubble.left.fill")
                            .font(.system(size: 9))
                        Text(model.voiceRouteText)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        if model.voiceRouteToggleAvailable {
                            Image(systemName: "arrow.2.squarepath")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    model.voicePendingAction?.mode == .dispatch
                        ? model.companionAccentColor
                        : .primary.opacity(0.75)
                )
                .disabled(!model.voiceRouteToggleAvailable)
                .accessibilityLabel(model.uiText("voice.confirm.route_toggle"))
                Spacer(minLength: 4)
                Button {
                    model.cancelVoiceAction()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.uiText("voice.confirm.cancel"))
                Button {
                    model.sendVoiceComposer()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    voiceComposerSendable ? model.companionAccentColor : .secondary
                )
                .disabled(!voiceComposerSendable)
                .accessibilityLabel(model.uiText("voice.confirm.send"))
            }
            if model.voicePendingAction?.mode == .dispatch,
               !model.voiceDispatchAgents.isEmpty {
                HStack(spacing: 6) {
                    Menu {
                        ForEach(model.voiceDispatchAgents, id: \.self) { provider in
                            Button(model.providerDisplayName(provider)) {
                                model.selectVoicePendingAgent(provider)
                            }
                        }
                    } label: {
                        Text(
                            model.voicePendingAction?.agent
                                .map(model.providerDisplayName)
                                ?? model.uiText("voice.confirm.pick_agent")
                        )
                    }
                    .controlSize(.mini)
                    .fixedSize()
                    if !model.voiceDispatchProjectChoices.isEmpty {
                        Menu {
                            ForEach(model.voiceDispatchProjectChoices, id: \.self) { url in
                                Button(url.lastPathComponent) {
                                    model.selectVoicePendingDirectory(url)
                                }
                            }
                        } label: {
                            Text(model.voicePendingAction?.directory?.lastPathComponent ?? "")
                        }
                        .controlSize(.mini)
                        .fixedSize()
                        if model.voicePendingContinueAvailable {
                            Menu {
                                Button(model.uiText("voice.confirm.mode.continue")) {
                                    model.selectVoicePendingContinues(true)
                                }
                                Button(model.uiText("voice.confirm.mode.fresh")) {
                                    model.selectVoicePendingContinues(false)
                                }
                            } label: {
                                Text(model.uiText(
                                    model.voicePendingAction?.continuesSession == true
                                        ? "voice.confirm.mode.continue"
                                        : "voice.confirm.mode.fresh"
                                ))
                            }
                            .controlSize(.mini)
                            .fixedSize()
                        }
                    }
                }
                if model.voiceDispatchProjectChoices.isEmpty {
                    Text(model.uiText("voice.confirm.cwd_home"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: bubbleMaxWidth)
        .bubbleChrome(accent: PerchTheme.attention, surface: model.companionSurfaceColor)
    }

    private var voiceComposerSendable: Bool {
        guard let action = model.voicePendingAction,
              !action.message
                  .trimmingCharacters(in: .whitespacesAndNewlines)
                  .isEmpty
        else { return false }
        return action.mode == .chat
            ? model.petChatSupportsFreeInput
            : action.agent != nil
    }

    private func voiceReceiptBubble(
        _ receipt: PerchModel.VoiceDispatchReceipt
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(receipt.message)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if receipt.resumeCommand != nil {
                    Button(model.uiText("voice.receipt.open")) {
                        model.openVoiceReceiptSession()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
                Button(model.uiText("voice.receipt.dismiss")) {
                    model.dismissVoiceReceipt()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: bubbleMaxWidth)
        .bubbleChrome(accent: PerchTheme.attention, surface: model.companionSurfaceColor)
    }

    private var listeningBubble: some View {
        HStack(spacing: 8) {
            if model.voiceFinalizing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "mic.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(PerchTheme.danger)
                    .symbolEffect(.pulse, options: .repeating)
            }
            Text(
                model.voiceTranscript.isEmpty
                    ? model.uiText("voice.listening")
                    : model.voiceTranscript
            )
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            if model.voiceListening {
                Button {
                    model.endVoiceCapture()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(PerchTheme.danger)
                .accessibilityLabel(model.uiText("voice.mic.stop"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .bubbleChrome(accent: PerchTheme.danger, surface: model.companionSurfaceColor)
    }

    /// Plain one-way narration (demo stage directions): text only, no
    /// input, no buttons; tap to dismiss.
    private func narrationBubble(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .bubbleChrome(
                accent: model.companionAccentColor,
                surface: model.companionSurfaceColor
            )
            .contentShape(Rectangle())
            .onTapGesture { model.dismissNarration() }
            .accessibilityLabel(message)
    }

    /// No close chrome, matching companion-bubble convention everywhere
    /// (and macOS notifications): the bubble auto-dismisses, a tap on the
    /// text closes it, and Escape closes it from the input field.
    private func chatBubble(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(message)
                .contentShape(Rectangle())
                .onTapGesture { model.dismissCompanionChat() }
            if model.companionPhase == .waitingForInput,
               let task = model.taskInbox.first(where: {
                   $0.phase == .waitingForInput && !$0.isMuted
               }) {
                Button(model.taskReturnActionText(task)) {
                    model.focusTask(task)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            if model.petChatSupportsFreeInput {
                CompanionChatInput(model: model)
                    .frame(maxWidth: .infinity)
            } else {
                Button(model.uiText("smalltalk.more")) {
                    model.companionChatAnother()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        // Conversation mode uses one fixed bubble width so the text block
        // and the input field share exactly the same edges; canned-line
        // mode hugs its content.
        .frame(
            width: model.petChatSupportsFreeInput ? chatBubbleWidth : nil,
            alignment: .leading
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .bubbleChrome(
            accent: model.companionAccentColor,
            surface: model.companionSurfaceColor
        )
    }

    private var statusBubble: some View {
        let accent = model.companionAccentColor
        return VStack(spacing: 2) {
            Text(model.companionStatusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let detail = model.statusDetailText {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary.opacity(0.66))
                    .lineLimit(2)
            }
        }
            .multilineTextAlignment(.center)
            // Hug the text like the narration bubble does: a maxWidth
            // frame would expand the pill to its cap even for a short
            // status, leaving it mostly empty. The window width already
            // bounds where long lines wrap.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .bubbleChrome(
                accent: model.companionPhase == .idle ? accent : stateColor,
                surface: model.companionSurfaceColor
            )
    }

    private func reminderBubble(_ reminder: CompanionReminder) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(model.uiText("kind.\(reminder.kind.rawValue)"), systemImage: reminderSymbol(reminder.kind))
                .font(.caption.weight(.semibold))
                .foregroundStyle(PerchTheme.health)
            Text(reminder.message)
                .font(.system(size: 12))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button(model.uiText("action.completed")) {
                    model.respondToCompanionReminder(.completed)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(model.uiText("action.completed"))
                Button(model.uiText("action.snooze")) {
                    model.respondToCompanionReminder(.snoozed)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(model.uiText("action.snooze"))
                Button(model.uiText("action.skip")) {
                    model.respondToCompanionReminder(.skipped)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.uiText("action.skip"))
            }
            .controlSize(.small)
        }
        .padding(11)
        .frame(maxWidth: bubbleMaxWidth, alignment: .leading)
        .bubbleChrome(
            accent: PerchTheme.health,
            surface: model.companionSurfaceColor,
            cornerRadius: 14
        )
        .accessibilityElement(children: .contain)
    }

    private var attentionBubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(model.companionStatusText, systemImage: "exclamationmark.bubble.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PerchTheme.attention)
            ForEach(model.taskInbox.filter {
                !$0.isMuted && ($0.phase == .waitingForInput || $0.phase == .failed)
            }.prefix(3)) { task in
                taskRow(task, allowsActions: true)
            }
        }
        .bubbleSurface(
            color: PerchTheme.attention,
            surface: model.companionSurfaceColor,
            maxWidth: bubbleMaxWidth
        )
        .accessibilityElement(children: .contain)
    }

    private var detailsBubble: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(model.companionStatusText)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(model.todayWaitingText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.providerActivitySummaries.isEmpty {
                Text(model.uiText("companion.no_active_agents"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.taskInbox.prefix(4)) { task in
                    taskRow(task, allowsActions: false)
                }
            }
        }
        .bubbleSurface(
            color: stateColor,
            surface: model.companionSurfaceColor,
            maxWidth: bubbleMaxWidth
        )
        .accessibilityElement(children: .contain)
    }

    private func providerRow(_ summary: ProviderActivitySummary, showWorking: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(
                    summary.failureCount > 0
                        ? PerchTheme.danger
                        : summary.attentionCount > 0
                            ? PerchTheme.attention
                            : PerchTheme.working
                )
                .frame(width: 6, height: 6)
            Text(model.providerDisplayName(summary.provider))
                .font(.caption2.weight(.medium))
            Spacer()
            if summary.failureCount > 0 {
                Text("\(summary.failureCount) \(model.uiText("companion.error_short"))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PerchTheme.danger)
            } else if summary.attentionCount > 0 {
                Text("\(summary.attentionCount) \(model.uiText("companion.attention_short"))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PerchTheme.attention)
            } else if showWorking {
                Text("\(summary.workingCount) \(model.uiText("companion.working_short"))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func taskRow(_ task: AgentTaskSummary, allowsActions: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(taskColor(task))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.taskTitle(task))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                Text(model.taskStatusText(task))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if allowsActions {
                Button(model.taskReturnActionText(task)) {
                    model.focusTask(task)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                Button {
                    model.toggleTaskMute(task)
                } label: {
                    Image(systemName: "bell.slash")
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .accessibilityLabel(model.uiText("task.mute"))
            } else if task.isMuted {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel(model.uiText("task.status.muted"))
            }
        }
    }

    private func taskColor(_ task: AgentTaskSummary) -> Color {
        if task.isMuted || task.isSignalStale { return .secondary.opacity(0.55) }
        switch task.phase {
        case .failed: return PerchTheme.danger
        case .waitingForInput: return PerchTheme.attention
        case .working: return PerchTheme.working
        case .idle, .done: return .secondary
        }
    }

    private var petDiameter: CGFloat {
        switch model.companionSize {
        case .small: 70
        case .medium: 88
        case .large: 108
        }
    }

    private var chatBubbleWidth: CGFloat {
        switch model.companionSize {
        case .small: 190
        case .medium: 230
        case .large: 280
        }
    }

    private var bubbleMaxWidth: CGFloat {
        switch model.companionSize {
        case .small: 190
        case .medium: 240
        case .large: 300
        }
    }

    private var motionEnabled: Bool { model.companionMotionEnabled && !reduceMotion }

    private var shouldFollowPointer: Bool {
        // Gate on the presentation state, not the raw agent phase: after a
        // task completes the phase can stay "done" for a long time while
        // the sprite is already resting — the companion should still feel
        // alive then, not frozen.
        motionEnabled
            && motion.dragDirection == nil
            && model.companionPresentationState == .resting
            && !model.companionDetailsVisible
            && model.activeReminder == nil
    }

    private func reminderSymbol(_ kind: ReminderKind) -> String {
        switch kind {
        case .hydrate: "drop.fill"
        case .stand: "figure.stand"
        case .eyes: "eye.fill"
        case .posture: "figure.seated.side"
        case .breathe: "wind"
        }
    }

    private var stateColor: Color {
        switch model.companionPhase {
        case .idle: model.codexNeedsActivation ? PerchTheme.attention : PerchTheme.resting
        case .working: PerchTheme.working
        case .waitingForInput: PerchTheme.attention
        case .failed: PerchTheme.danger
        case .done: PerchTheme.celebration
        }
    }

}

private struct CompanionChatInput: View {
    @ObservedObject var model: PerchModel
    @State private var text = ""

    var body: some View {
        HStack(spacing: 6) {
            TextField(
                model.uiText("smalltalk.input_placeholder"),
                text: $text
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .onSubmit(send)
            .onExitCommand { model.dismissCompanionChat() }
            .disabled(model.companionChatBusy)
            if model.companionChatBusy {
                ProgressView()
                    .controlSize(.small)
            } else if !text.isEmpty {
                // Typed drafts get the same dispatch path as voice: the
                // bolt stages the text in the composer, where target and
                // project are explicit before sending.
                Button {
                    model.beginDispatchComposer(with: text)
                    text = ""
                } label: {
                    Image(systemName: "bolt.circle.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.uiText("voice.confirm.dispatch"))
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.companionAccentColor)
            } else if model.voiceBridgeEnabled {
                // Click-to-toggle entry into the same capture the pet's
                // push-to-talk uses; the transcript bubble's stop button
                // ends it.
                Button {
                    model.beginVoiceCapture()
                } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(model.uiText("voice.mic.start"))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }

    private func send() {
        model.sendCompanionChat(text)
        text = ""
    }
}

private extension View {
    func bubbleSurface(color: Color, surface: Color, maxWidth: CGFloat) -> some View {
        padding(11)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .bubbleChrome(accent: color, surface: surface, cornerRadius: 14)
    }

    /// One shared recipe, tinted with the same warm role surface the
    /// menu-bar cards use: a bare gray material over an arbitrary desktop
    /// reads muddy and off-brand.
    func bubbleChrome(
        accent: Color,
        surface: Color,
        cornerRadius: CGFloat = 12
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(
            PerchTheme.adaptive(
                light: surface.opacity(0.72),
                dark: surface.opacity(0.16)
            ),
            in: shape
        )
        .background(.thickMaterial, in: shape)
        .overlay(shape.strokeBorder(accent.opacity(0.3), lineWidth: 1))
        .shadow(color: .black.opacity(0.1), radius: 8, y: 4)
    }
}
