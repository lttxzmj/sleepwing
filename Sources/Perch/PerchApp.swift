import Charts
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications
import PerchCore

@main
struct PerchApp: App {
    @StateObject private var model = PerchModel.shared

    init() {
        PerchResources.linkDevelopmentLocalizations()
    }

    var body: some Scene {
#if PERCH_UI_TEST
        WindowGroup("Sleepwing UI Test") {
            SettingsView(model: model)
                .environment(\.locale, model.locale)
                .frame(minWidth: 720, minHeight: 600)
        }
#endif
        MenuBarExtra {
            PerchMenuView(model: model)
                .environment(\.locale, model.locale)
        } label: {
            Label {
                Text(model.menuBarLabelText)
            } icon: {
                Image(nsImage: PerchMenuBarIcon.image)
            }
            .accessibilityLabel(model.statusText)
            .help(model.statusText)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct PerchMenuView: View {
    @ObservedObject var model: PerchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CompanionCharacterView(
                    role: model.displayedCompanionRole,
                    state: model.companionPresentationState,
                    diameter: 50,
                    skin: model.companionSkin,
                    showsStateAccessory: false,
                    phase: model.phase,
                    motionEnabled: false,
                    customSpriteURL: model.customPetSpriteURL
                )
                .padding(3)
                .background(rolePalette.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(model.statusColor)
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(model.statusText).font(.headline)
                    }
                    if let detail = model.statusDetailText {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            if model.systemNotificationsSupported {
                if !model.notificationAuthorizationDetermined {
                    notificationInvitation
                } else if model.notificationAuthorizationGranted == false {
                    notificationWarning
                }
            }
            if !model.hookLostProviders.isEmpty {
                hookLostWarning
            }
            if model.codexNeedsActivation {
                codexActivationWarning
            }
            if !model.taskInbox.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("task.inbox.title")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(
                            model.uiText("task.inbox.count")
                                .replacingOccurrences(
                                    of: "{count}",
                                    with: String(model.activeSessionCount)
                                )
                        )
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    ForEach(Array(model.taskInbox.prefix(5))) { task in
                        taskRow(task)
                    }
                    if let notice = model.taskReturnNotice {
                        Text(notice)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .perchCard(radius: 12)
            }
            sleepProtectionQuickControl
            Divider()
            HStack(spacing: 8) {
                menuMetric("stats.today_recovered", value: model.todayWaitingText)
                menuMetric("stats.today_completed", value: "\(model.todayCompletedBreaks)")
                menuMetric("stats.weekly_completion", value: model.weeklyCompletionRateText)
            }
            Divider()
            HStack {
                Button("ui.settings") { presentSettings() }
                Button(model.uiText(model.companionVisible ? "ui.hide_companion" : "ui.show_companion")) {
                    model.companionVisible.toggle()
                }
                Spacer()
                // Explicit click opens the browser; the app itself still
                // makes no outbound requests. Zero telemetry means this
                // link is the only road user feedback can travel.
                Button("ui.feedback") {
                    NSWorkspace.shared.open(
                        URL(string: "https://github.com/lttxzmj/sleepwing/discussions")!
                    )
                }
                Button("ui.quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(rolePalette.screenWash)
        .tint(PerchTheme.brand)
        .task { await model.refreshNotificationAuthorization() }
    }

    private var rolePalette: PerchTheme.RolePalette {
        PerchTheme.palette(for: model.displayedCompanionRole)
    }

    private var sleepProtectionQuickControl: some View {
        HStack(spacing: 8) {
            Image(systemName: model.sleepProtectionActive ? "moon.zzz.fill" : "moon.zzz")
                .foregroundStyle(model.sleepProtectionActive ? PerchTheme.working : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.sleepProtectionActive ? model.uiText("sleep.menu_active") : model.uiText("settings.prevent_idle_sleep"))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if model.preventIdleSleepEnabled && !model.sleepProtectionActive {
                    Text(model.sleepProtectionStatusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $model.preventIdleSleepEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(9)
        .perchCard(
            radius: 10,
            fill: (model.sleepProtectionActive ? PerchTheme.working : Color.secondary)
                .opacity(model.sleepProtectionActive ? 0.08 : 0.05)
        )
    }

    private func menuMetric(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityColor(_ summary: ProviderActivitySummary) -> Color {
        if summary.failureCount > 0 { return PerchTheme.danger }
        if summary.attentionCount > 0 { return PerchTheme.attention }
        return PerchTheme.working
    }

    private func activityText(_ summary: ProviderActivitySummary) -> String {
        if summary.failureCount > 0 {
            return model.uiText("activity.error")
        }
        if summary.attentionCount > 0 {
            return model.uiText("activity.waiting")
        }
        return summary.workingCount > 1
            ? model.uiText("activity.running_count").replacingOccurrences(
                of: "{count}",
                with: String(summary.workingCount)
            )
            : model.uiText("activity.running")
    }

    private func taskRow(_ task: AgentTaskSummary) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(taskColor(task))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.taskTitle(task))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(model.taskStatusText(task))
                    .font(.caption2)
                    .foregroundStyle(task.isMuted ? .tertiary : .secondary)
            }
            Spacer(minLength: 6)
            if !task.isMuted, task.phase == .waitingForInput || task.phase == .failed {
                Button(model.taskReturnActionText(task)) {
                    model.focusTask(task)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }
            Button {
                model.toggleTaskMute(task)
            } label: {
                Image(systemName: task.isMuted ? "bell.fill" : "bell.slash")
            }
            .buttonStyle(.borderless)
            .help(model.uiText(task.isMuted ? "task.unmute" : "task.mute"))
            .accessibilityLabel(model.uiText(task.isMuted ? "task.unmute" : "task.mute"))
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

    private var notificationInvitation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("notification.optional_title", systemImage: "bell.badge")
                .font(.subheadline.weight(.semibold))
            Text("notification.optional_detail")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("notification.allow") {
                Task { await model.requestNotificationPermissionFromUser() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .perchCard()
    }

    private var notificationWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("notification.blocked_title", systemImage: "bell.slash.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(PerchTheme.danger)
            Text("notification.blocked_detail")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("settings.open_notification_settings") {
                model.openNotificationSettings()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .perchCard(fill: PerchTheme.danger.opacity(0.08))
    }

    private var hookLostWarning: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(model.hookLostWarningText, systemImage: "link.badge.plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PerchTheme.attention)
            Text("integration.hook_lost_detail")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .perchCard(radius: 10)
    }

    private var codexActivationWarning: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("integration.awaiting_first_event", systemImage: "link.badge.plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PerchTheme.attention)
            Text("integration.awaiting_first_event_detail")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .perchCard(radius: 10)
    }

    private func presentSettings() {
        // The window-style MenuBarExtra panel does not dismiss itself
        // when a button opens another window, so it would float over the
        // settings window it just spawned. `dismiss` handles it on
        // macOS 14+; the explicit close covers builds that ignore it.
        dismiss()
        for window in NSApp.windows
        where window.isVisible && String(describing: type(of: window))
            .localizedCaseInsensitiveContains("menubarextra") {
            window.close()
        }
        SettingsWindowPresenter.open(model: model)
    }
}

private enum SettingsTab: String, CaseIterable {
    case general
    case integrations
    case messages
    case statistics

    var titleKey: LocalizedStringKey {
        switch self {
        case .general: "tab.general"
        case .integrations: "tab.integrations"
        case .messages: "tab.messages"
        case .statistics: "tab.statistics"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: PerchModel
    @State private var showingPetStudio = false
    @State private var selectedTab = SettingsTab.general

    var body: some View {
        ZStack {
            PerchTheme.screenWash.ignoresSafeArea()
            if model.onboardingCompleted {
                VStack(spacing: 0) {
                    settingsHeader
                    Divider()

                    selectedSettingsView
                        .padding(16)
                }
            } else {
                OnboardingView(model: model)
            }
        }
        .tint(PerchTheme.brand)
        // The language switch lives on this screen, so the locale has to be
        // read here rather than snapshotted when the window was built:
        // otherwise literal keys stay in the old language while `uiText`
        // strings change under the user's cursor.
        .environment(\.locale, model.locale)
        .task { await model.refreshNotificationAuthorization() }
        .sheet(isPresented: $showingPetStudio) {
            CustomPetStudioView(model: model)
        }
    }

    private var rolePalette: PerchTheme.RolePalette {
        PerchTheme.palette(for: model.companionRole)
    }

    private var settingsHeader: some View {
        HStack {
            Spacer(minLength: 0)
            Picker("settings.navigation", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.titleKey).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var selectedSettingsView: some View {
        switch selectedTab {
        case .general:
            generalView
        case .integrations:
            integrationsView
        case .messages:
            messagesView
        case .statistics:
            statisticsView
        }
    }

    private var generalView: some View {
        Form {
            Section("settings.preferences") {
                Picker("settings.language", selection: $model.language) {
                    Text("language.system").tag(AppLanguage.system)
                    Text("language.english").tag(AppLanguage.english)
                    Text("language.chinese").tag(AppLanguage.simplifiedChinese)
                }
            }
            Section("settings.reminders") {
                Picker("settings.strategy", selection: $model.strategy) {
                    Text("strategy.hybrid").tag(ReminderStrategy.hybrid)
                    Text("strategy.agent").tag(ReminderStrategy.agentAware)
                    Text("strategy.after_completion").tag(ReminderStrategy.afterCompletion)
                    Text("strategy.timer").tag(ReminderStrategy.fixedTimer)
                    Text("strategy.crossover").tag(ReminderStrategy.crossover)
                }
                if model.strategy == .crossover {
                    LabeledContent(
                        "settings.today_arm",
                        value: model.uiText(model.activeStrategy == .agentAware ? "strategy.agent" : "strategy.after_completion")
                    )
                }
                Stepper(value: $model.thresholdMinutes, in: 1...10) {
                    LabeledContent("settings.threshold", value: "\(model.thresholdMinutes) min")
                }
                Stepper(value: $model.policy.hourlyLimit, in: 1...6) {
                    LabeledContent("settings.hourly_limit", value: "\(model.policy.hourlyLimit)")
                }
                Toggle("settings.quiet_hours", isOn: Binding(get: { model.quietHoursEnabled }, set: { model.quietHoursEnabled = $0 }))
                if model.quietHoursEnabled {
                    DatePicker("settings.quiet_start", selection: Binding(get: { model.quietStartDate }, set: { model.quietStartDate = $0 }), displayedComponents: .hourAndMinute)
                    DatePicker("settings.quiet_end", selection: Binding(get: { model.quietEndDate }, set: { model.quietEndDate = $0 }), displayedComponents: .hourAndMinute)
                }
            }
            Section("settings.agent_notifications") {
                Toggle("settings.agent_notify_attention", isOn: $model.agentAttentionNotificationsEnabled)
                Toggle("settings.agent_notify_completion", isOn: $model.agentCompletionNotificationsEnabled)
                Text("settings.agent_notifications_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("settings.agent_voice_attention", isOn: $model.agentAttentionVoiceEnabled)
                Text("settings.agent_voice_attention_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("settings.companion") {
                Toggle("settings.show_companion", isOn: $model.companionVisible)
                companionRoleSelector
                if model.companionRole == .sleepwing {
                    Picker("settings.companion_skin", selection: $model.companionSkin) {
                        Text("companion.skin.mist").tag(CompanionSkin.mist)
                        Text("companion.skin.midnight").tag(CompanionSkin.midnight)
                        Text("companion.skin.grove").tag(CompanionSkin.grove)
                    }
                    .pickerStyle(.segmented)
                }
                Picker("settings.companion_size", selection: $model.companionSize) {
                    Text("companion.size.small").tag(CompanionSize.small)
                    Text("companion.size.medium").tag(CompanionSize.medium)
                    Text("companion.size.large").tag(CompanionSize.large)
                }
                .pickerStyle(.segmented)
                Picker("settings.companion_layer", selection: $model.companionLayer) {
                    Text("companion.layer.floating").tag(CompanionLayer.floating)
                    Text("companion.layer.desktop").tag(CompanionLayer.desktop)
                }
                Toggle("settings.companion_fullscreen", isOn: $model.companionShowsOverFullScreen)
                Toggle("settings.companion_motion", isOn: $model.companionMotionEnabled)
                Toggle("settings.companion_chat", isOn: $model.companionChatEnabled)
                Picker("settings.companion_chat_engine", selection: $model.petChatEngine) {
                    Text("settings.chat_engine.library").tag(PetChatEngine.library)
                    Text("settings.chat_engine.onDevice").tag(PetChatEngine.onDevice)
                    Text("settings.chat_engine.agent").tag(PetChatEngine.agent)
                }
                .disabled(!model.companionChatEnabled)
                if model.petChatEngine == .agent {
                    Picker("settings.companion_chat_agent", selection: $model.petChatAgent) {
                        Text("settings.chat_agent.auto").tag(AgentProvider?.none)
                        ForEach(
                            PetChatAgentCommand.supportedProviders.filter(
                                model.detectedProviders.contains
                            ),
                            id: \.self
                        ) { provider in
                            Text(model.providerDisplayName(provider))
                                .tag(Optional(provider))
                        }
                    }
                    .disabled(!model.companionChatEnabled)
                    Text("settings.companion_chat_agent_warning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("settings.companion_window_anchor", isOn: $model.companionWindowAnchorEnabled)
                Text("settings.companion_window_anchor_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("settings.run_demo") {
                    model.runCompanionDemo()
                }
                .buttonStyle(.bordered)
                Toggle("settings.voice_bridge", isOn: $model.voiceBridgeEnabled)
                Text("settings.voice_bridge_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.voiceBridgeEnabled {
                    voiceReadinessRow
                    HStack {
                        Text("settings.voice_dispatch_dir")
                        Spacer()
                        Text(
                            model.voiceDispatchDirectory?.lastPathComponent
                                ?? model.uiText("settings.voice_dispatch_dir_home")
                        )
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        Button("settings.voice_dispatch_dir_choose") {
                            model.chooseVoiceDispatchDirectory()
                        }
                        if model.voiceDispatchDirectory != nil {
                            Button("settings.voice_dispatch_dir_clear") {
                                model.clearVoiceDispatchDirectory()
                            }
                        }
                    }
                    Text("settings.voice_dispatch_dir_detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("settings.system") {
                Toggle(
                    "settings.launch_at_login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                if model.launchAtLoginNeedsApproval {
                    HStack {
                        Text("settings.launch_at_login_approval")
                            .font(.caption)
                            .foregroundStyle(PerchTheme.attention)
                        Spacer()
                        Button("settings.open_login_items") {
                            model.openLoginItemsSettings()
                        }
                    }
                }
                if let error = model.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                Toggle("settings.prevent_idle_sleep", isOn: $model.preventIdleSleepEnabled)
                Text("settings.prevent_idle_sleep_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.preventIdleSleepEnabled {
                    Stepper(value: $model.idleSleepMaxHours, in: 1...12) {
                        LabeledContent("settings.idle_sleep_max_hours", value: "\(model.idleSleepMaxHours) h")
                    }
                    Label(model.sleepProtectionStatusText, systemImage: model.sleepProtectionActive ? "moon.zzz.fill" : "pause.circle")
                        .font(.caption)
                        .foregroundStyle(model.sleepProtectionActive ? PerchTheme.working : .secondary)
                }
            }
            Section("settings.notifications") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: notificationDeliverySymbol)
                        .font(.title3)
                        .foregroundStyle(notificationDeliveryColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(notificationDeliveryTitleKey)
                            .font(.subheadline.weight(.semibold))
                        Text(notificationDeliveryDetailKey)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if model.systemNotificationsSupported {
                        if !model.notificationAuthorizationDetermined {
                            Button("notification.allow") {
                                Task { await model.requestNotificationPermissionFromUser() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else if model.notificationAuthorizationGranted != true
                            || model.notificationAlertsEnabled == false {
                            Button("settings.open_notification_settings") {
                                model.openNotificationSettings()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var voiceReadinessRow: some View {
        HStack(spacing: 10) {
            switch model.voiceReadiness {
            case .unknown, .checking:
                ProgressView().controlSize(.small)
                Text("voice.state.checking").font(.caption)
            case .ready:
                Label("voice.state.ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(PerchTheme.health)
            case .speechDenied:
                Label("voice.state.speech_denied", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(PerchTheme.attention)
                Button("voice.remedy.permissions") { model.openVoiceRemedy() }
                    .controlSize(.small)
            case .micDenied:
                Label("voice.state.mic_denied", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(PerchTheme.attention)
                Button("voice.remedy.permissions") { model.openVoiceRemedy() }
                    .controlSize(.small)
            case .assetsMissing:
                Label("voice.state.assets", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(PerchTheme.attention)
                Button("voice.remedy.dictation") { model.openVoiceRemedy() }
                    .controlSize(.small)
            case .unsupported:
                Label("voice.state.unsupported", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                model.preflightVoice()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel("voice.recheck")
        }
    }

    private var companionRoleSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.companion_role")
                .font(.caption)
                .foregroundStyle(.secondary)
            // One uniform grid for built-ins and every installed custom
            // pet: identical card sizes, consistent wrapping.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240), spacing: 12)],
                spacing: 12
            ) {
                companionRoleButton(.sleepwing, title: "companion.role.sleepwing")
                companionRoleButton(.cat, title: "companion.role.cat")
                ForEach(model.customPets.filter(\.isInstalledInPerch)) { pet in
                    customPetRoleButton(pet)
                }
            }
            Button {
                showingPetStudio = true
            } label: {
                Label("custom_pet.studio.open", systemImage: "pawprint.circle")
            }
            .buttonStyle(.bordered)
            Text("custom_pet.studio.detail")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .task { model.refreshCustomPets() }
    }

    private func customPetRoleButton(_ pet: CustomPetDescriptor) -> some View {
        let selected = model.companionRole == .custom
            && model.selectedCustomPetID == pet.id
        return Button {
            model.selectCustomPet(pet)
        } label: {
            HStack(spacing: 12) {
                CompanionCharacterView(
                    role: .custom,
                    state: .resting,
                    diameter: 54,
                    skin: model.companionSkin,
                    showsStateAccessory: false,
                    motionEnabled: model.companionMotionEnabled,
                    customSpriteURL: pet.spritesheetURL
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(pet.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("custom_pet.badge.v2")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                PerchTheme.palette(for: .custom).selectedFill,
                                in: Capsule()
                            )
                    }
                    Text(pet.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(
                selected
                    ? PerchTheme.palette(for: .custom).accentDeep
                    : Color.primary
            )
            .background(
                selected
                    ? PerchTheme.palette(for: .custom).selectedFill
                    : PerchTheme.palette(for: .custom).subtleFill,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected
                            ? PerchTheme.palette(for: .custom).accent.opacity(0.72)
                            : PerchTheme.palette(for: .custom).hairline,
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func companionRoleButton(
        _ role: CompanionRole,
        title: LocalizedStringKey
    ) -> some View {
        let selected = model.companionRole == role
        return Button {
            model.companionRole = role
        } label: {
            HStack(spacing: 12) {
                CompanionCharacterView(
                    role: role,
                    state: .resting,
                    diameter: 54,
                    skin: model.companionSkin,
                    showsStateAccessory: false,
                    customSpriteURL: role == .custom ? model.customPetSpriteURL : nil
                )
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(model.uiText("companion.role.\(role.rawValue).personality"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 88)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? rolePalette.accentDeep : Color.primary)
            .background(
                selected
                    ? PerchTheme.palette(for: role).selectedFill
                    : PerchTheme.palette(for: role).subtleFill,
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        selected
                            ? PerchTheme.palette(for: role).accent.opacity(0.72)
                            : PerchTheme.palette(for: role).hairline,
                        lineWidth: selected ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var notificationDeliverySymbol: String {
        switch model.notificationHealthStage {
        case .undetermined: "bell.badge"
        case .blocked: "bell.slash.fill"
        case .alertsDisabled: "rectangle.slash"
        case .ready: "checkmark.circle.fill"
        }
    }

    private var notificationDeliveryColor: Color {
        switch model.notificationHealthStage {
        case .undetermined: PerchTheme.brand
        case .blocked: PerchTheme.danger
        case .alertsDisabled: PerchTheme.attention
        case .ready: PerchTheme.working
        }
    }

    private var notificationDeliveryTitleKey: LocalizedStringKey {
        switch model.notificationHealthStage {
        case .undetermined: "notification.delivery.not_determined"
        case .blocked: "notification.delivery.denied"
        case .alertsDisabled: "notification.delivery.alerts_disabled"
        case .ready: "notification.delivery.healthy"
        }
    }

    private var notificationDeliveryDetailKey: LocalizedStringKey {
        switch model.notificationHealthStage {
        case .undetermined: "notification.delivery.not_determined_detail"
        case .blocked: "notification.delivery.denied_detail"
        case .alertsDisabled: "notification.delivery.alerts_disabled_detail"
        case .ready: "notification.delivery.healthy_detail"
        }
    }

    private var integrationsView: some View {
        Form {
            Section {
                integrationHealthCard
            }
            Section {
                integrationRow(model.providerDisplayName(.codex), provider: .codex)
                integrationRow(model.providerDisplayName(.cursor), provider: .cursor)
                integrationRow(model.providerDisplayName(.claude), provider: .claude)
                integrationRow(model.providerDisplayName(.gemini), provider: .gemini)
                integrationRow(model.providerDisplayName(.opencode), provider: .opencode)
                integrationRow(model.providerDisplayName(.pi), provider: .pi)
                integrationRow(model.providerDisplayName(.trae), provider: .trae)
            } header: {
                Text("integration.tools_title")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("integration.tools_detail")
                    integrationReversibilityNote
                }
            }
            Section("integration.timer_mode") {
                HStack {
                    Image(systemName: "timer")
                        .foregroundStyle(PerchTheme.brand)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ChatGPT")
                            .font(.subheadline.weight(.semibold))
                        Text("integration.chatgpt_limit")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    capabilityBadge("integration.capability.timer")
                }
            }
            Section("settings.privacy") {
                Label("settings.privacy_detail", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var integrationHealthCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: integrationHealthSymbol)
                .font(.title2)
                .foregroundStyle(integrationHealthColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text("integration.check_title")
                    .font(.headline)
                Text(integrationHealthTitleKey)
                    .font(.subheadline.weight(.semibold))
                Text(integrationHealthDetailKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if model.hasInstalledIntegrations {
                if model.receiverReady {
                    Button("integration.check_all") {
                        model.verifyInstalledIntegrations()
                    }
                    .disabled(model.integrationHealthStage == .checking)
                } else {
                    Button("integration.retry_receiver") {
                        model.retryReceiverNow()
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    /// The reversibility promise, stated where install/remove happens:
    /// competitors have deleted users' unrelated hooks silently, and the
    /// trust cost of that class of accident is unrecoverable.
    private var integrationReversibilityNote: some View {
        Text("integration.reversibility_note")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var messagesView: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "heart.text.clipboard")
                        .font(.title3)
                        .foregroundStyle(PerchTheme.brand)
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("messages.title")
                            .font(.headline)
                        Text("messages.hint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("messages.behaviors_title") {
                ForEach(ReminderKind.allCases, id: \.self) { kind in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: reminderSymbol(kind))
                                .foregroundStyle(PerchTheme.brand)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.uiText("kind.\(kind.rawValue)"))
                                    .font(.subheadline.weight(.semibold))
                                Text(model.uiText("kind.\(kind.rawValue).detail"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle(
                                "",
                                isOn: Binding(
                                    get: { model.isReminderKindEnabled(kind) },
                                    set: { model.setReminderKind(kind, enabled: $0) }
                                )
                            )
                            .labelsHidden()
                            .help(model.uiText("messages.enable_help"))
                        }
                        TextField("messages.placeholder", text: Binding(
                        get: { model.reminderText(for: kind) },
                        set: { model.setReminderText($0, for: kind) }
                    ), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(2...4)
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("messages.preview")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(model.reminderPreview(for: kind))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Spacer()
                            if model.isReminderTextCustomized(kind) {
                                Button {
                                    model.resetReminderText(for: kind)
                                } label: {
                                    Label("messages.reset", systemImage: "arrow.counterclockwise")
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var statisticsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("stats.overview_title")
                        .font(.title2.bold())
                    Text("stats.overview_detail")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    metricCard(
                        "stats.today_recovered",
                        value: model.todayWaitingText,
                        detail: "stats.today_recovered_detail",
                        symbol: "clock.arrow.circlepath",
                        tint: PerchTheme.accent
                    )
                    metricCard(
                        "stats.today_completed",
                        value: "\(model.todayCompletedBreaks)",
                        detail: "stats.today_completed_detail",
                        symbol: "figure.cooldown",
                        tint: PerchTheme.health
                    )
                    metricCard(
                        "stats.weekly_completion",
                        value: model.weeklyCompletionRateText,
                        detail: "stats.weekly_completion_detail",
                        symbol: "chart.line.uptrend.xyaxis",
                        tint: PerchTheme.working
                    )
                }

                HStack(spacing: 12) {
                    guardrailCard(
                        "stats.tasks_today",
                        value: "\(model.todayCompletedAgentTasks)",
                        detail: "stats.tasks_today_detail"
                    )
                    guardrailCard(
                        "stats.tasks_week",
                        value: "\(model.weeklyCompletedAgentTasks)",
                        detail: "stats.tasks_week_detail"
                    )
                    guardrailCard(
                        "stats.tasks_active",
                        value: "\(model.activeSessionCount)",
                        detail: "stats.tasks_active_detail"
                    )
                }

                Text("stats.weekly_trend").font(.headline)
                Chart(model.weeklyPoints) { point in
                    BarMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Minutes", point.waitingMinutes)
                    )
                    .foregroundStyle(PerchTheme.brand.gradient)
                    .cornerRadius(4)
                }
                .chartYAxisLabel("stats.waiting_minutes")
                .frame(height: 150)

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("stats.health_actions", systemImage: "heart.text.clipboard")
                            .font(.headline)
                            .foregroundStyle(PerchTheme.health)
                        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                            ForEach(model.reminderKindSummaries) { summary in
                                GridRow {
                                    Label(
                                        model.uiText("kind.\(summary.kind.rawValue)"),
                                        systemImage: reminderSymbol(summary.kind)
                                    )
                                    .gridColumnAlignment(.leading)
                                    Text(
                                        model.uiText("stats.action_result")
                                            .replacingOccurrences(of: "{completed}", with: String(summary.completed))
                                            .replacingOccurrences(of: "{shown}", with: String(summary.shown))
                                    )
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(.trailing)
                                    Text(model.completionRateText(summary))
                                        .fontWeight(.semibold)
                                        .gridColumnAlignment(.trailing)
                                }
                                .font(.callout)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .perchCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Label("stats.ai_work_today", systemImage: "point.3.connected.trianglepath.dotted")
                            .font(.headline)
                            .foregroundStyle(PerchTheme.working)
                        if model.providerWorkSummaries.isEmpty {
                            Text("stats.no_ai_work")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.providerWorkSummaries) { summary in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(model.providerDisplayName(summary.provider))
                                        Spacer()
                                        Text(model.providerWorkText(summary.seconds))
                                            .foregroundStyle(.secondary)
                                    }
                                    ProgressView(
                                        value: summary.seconds,
                                        total: model.providerWorkSummaries.first?.seconds ?? summary.seconds
                                    )
                                    .tint(PerchTheme.working)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .perchCard()
                }

                HStack(spacing: 12) {
                    guardrailCard(
                        "stats.snooze_rate",
                        value: model.weeklySnoozeRateText,
                        detail: "stats.snooze_rate_detail"
                    )
                    guardrailCard(
                        "stats.attention_median",
                        value: model.medianAttentionResponseText,
                        detail: "stats.attention_median_detail"
                    )
                }

                VStack(alignment: .leading, spacing: 12) {
                    DisclosureGroup("stats.experiment_title") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("stats.current_arm").foregroundStyle(.secondary)
                                Spacer()
                                Text(model.uiText(model.currentExperimentArmKey)).fontWeight(.semibold)
                            }
                            if model.strategy == .crossover {
                                ProgressView(value: Double(min(7, model.experimentDaysObserved)), total: 7)
                                Text("\(model.experimentDaysObserved) / 7 \(model.uiText("stats.days"))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("stats.enable_crossover")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 12) {
                                experimentCard("strategy.agent", metrics: model.workingArmMetrics)
                                experimentCard("strategy.after_completion", metrics: model.completionArmMetrics)
                            }
                        }
                        .padding(.top, 8)
                    }
                }

                Text("stats.local_only").font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func metricCard(
        _ title: LocalizedStringKey,
        value: String,
        detail: LocalizedStringKey,
        symbol: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                Text(title)
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.medium))
            Text(value).font(.title2.weight(.bold))
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .perchCard()
        .overlay(alignment: .top) {
            Capsule()
                .fill(tint)
                .frame(height: 3)
                .padding(.horizontal, 12)
        }
    }

    private func guardrailCard(
        _ title: LocalizedStringKey,
        value: String,
        detail: LocalizedStringKey
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value).font(.title3.bold())
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .perchCard()
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

    private func experimentCard(_ titleKey: String, metrics: ReminderExperimentMetrics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.uiText(titleKey))
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("stats.shown").font(.caption2).foregroundStyle(.secondary)
                    Text("\(metrics.reminderCount)").font(.title3.bold())
                }
                Spacer()
                VStack(alignment: .leading, spacing: 2) {
                    Text("stats.completed_rate").font(.caption2).foregroundStyle(.secondary)
                    Text(model.completionRateText(metrics)).font(.title3.bold())
                }
            }
            LabeledContent("stats.average_opportunity", value: model.averageOpportunityText(metrics))
                .font(.caption)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .perchCard()
    }

    @ViewBuilder
    private func integrationRow(_ title: String, provider: AgentProvider) -> some View {
        let status = model.integrationStatuses[provider] ?? .notInstalled
        HStack(alignment: .center, spacing: 12) {
            ProviderBrandIcon(provider: provider, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(model.uiText("integration.provider.\(provider.rawValue).detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if status == .installed {
                installedStatusLabel(provider: provider)
                if model.verificationFailed(provider) {
                    Button("integration.retry_verification") { model.verifyIntegration(provider) }
                        .buttonStyle(.borderless)
                }
                Button("integration.remove", role: .destructive) {
                    model.toggleIntegration(provider)
                }
                .buttonStyle(.borderless)
            } else {
                Button("integration.install") { model.toggleIntegration(provider) }
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func installedStatusLabel(provider: AgentProvider) -> some View {
        if model.lifecycleConnected(provider) {
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                if let lastSeen = model.lastRealStateText(for: provider) {
                    Text(lastSeen)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if model.isVerifying(provider) {
            ProgressView().controlSize(.small)
        } else if model.verificationFailed(provider) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PerchTheme.danger)
                .font(.caption)
                .help(model.uiText("integration.verification_failed"))
        } else if model.relayVerified(provider) {
            Image(systemName: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(model.uiText("integration.local_verified"))
        } else {
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(model.uiText("integration.awaiting_first_event"))
        }
    }

    private var integrationHealthSymbol: String {
        switch model.integrationHealthStage {
        case .receiverUnavailable: "bolt.horizontal.circle"
        case .notConnected: "link.badge.plus"
        case .checking: "arrow.triangle.2.circlepath.circle"
        case .checkFailed: "exclamationmark.triangle.fill"
        case .awaitingRealState: "play.circle"
        case .live: "checkmark.seal.fill"
        }
    }

    private var integrationHealthColor: Color {
        switch model.integrationHealthStage {
        case .receiverUnavailable, .checkFailed: PerchTheme.danger
        case .notConnected: .secondary
        case .checking: PerchTheme.working
        case .awaitingRealState: PerchTheme.attention
        case .live: PerchTheme.working
        }
    }

    private var integrationHealthTitleKey: LocalizedStringKey {
        switch model.integrationHealthStage {
        case .receiverUnavailable: "integration.health.receiver_unavailable"
        case .notConnected: "integration.health.not_connected"
        case .checking: "integration.health.checking"
        case .checkFailed: "integration.health.failed"
        case .awaitingRealState: "integration.health.awaiting"
        case .live: "integration.health.live"
        }
    }

    private var integrationHealthDetailKey: LocalizedStringKey {
        switch model.integrationHealthStage {
        case .receiverUnavailable: "integration.health.receiver_unavailable_detail"
        case .notConnected: "integration.health.not_connected_detail"
        case .checking: "integration.health.checking_detail"
        case .checkFailed: "integration.health.failed_detail"
        case .awaitingRealState: "integration.health.awaiting_detail"
        case .live: "integration.health.live_detail"
        }
    }

    private func capabilityBadge(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.secondary.opacity(0.1), in: Capsule())
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: PerchModel
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                PerchBrandMark(size: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text("onboarding.title")
                        .font(.title.bold())
                    Text("brand.slogan")
                        .font(.headline)
                    Text("onboarding.subtitle")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<2, id: \.self) { index in
                        Capsule()
                            .fill(index == step ? PerchTheme.brand : Color.secondary.opacity(0.22))
                            .frame(width: index == step ? 22 : 7, height: 7)
                    }
                }
            }

            Group {
                switch step {
                case 0: chooseCompanion
                default: connectAgents
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            HStack {
                if step > 0 {
                    Button("onboarding.back") { step -= 1 }
                } else {
                    Button("onboarding.skip") { model.completeOnboarding() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if step < 1 {
                    Button("onboarding.next") { step += 1 }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("onboarding.finish") { model.completeOnboarding() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(30)
    }

    private var chooseCompanion: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("onboarding.choose_companion")
                .font(.headline)
            HStack(spacing: 14) {
                roleCard(.sleepwing, title: "companion.role.sleepwing")
                roleCard(.cat, title: "companion.role.cat")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.companion_size")
                    .font(.subheadline.weight(.medium))
                Picker("settings.companion_size", selection: $model.companionSize) {
                    Text("companion.size.small").tag(CompanionSize.small)
                    Text("companion.size.medium").tag(CompanionSize.medium)
                    Text("companion.size.large").tag(CompanionSize.large)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
            }
            Text("onboarding.drag_hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectAgents: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("onboarding.connect_agents")
                .font(.headline)
            if model.detectedProviders.isEmpty {
                Text("onboarding.none_detected")
                    .foregroundStyle(.secondary)
            } else {
                Label(model.detectedProvidersHeadline, systemImage: "sparkle.magnifyingglass")
                    .foregroundStyle(.secondary)
                Button(model.allDetectedProvidersConnected ? "onboarding.connected_detected" : "onboarding.connect_detected") {
                    model.connectDetectedIntegrations()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.allDetectedProvidersConnected)
            }
            VStack(spacing: 0) {
                ForEach(visibleOnboardingProviders, id: \.self) { provider in
                    onboardingIntegrationRow(model.providerDisplayName(provider), provider: provider)
                    if provider != visibleOnboardingProviders.last {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .perchCard(radius: 14)
            Text("integration.chatgpt_limit")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            companionOnlyChoice
        }
    }

    private var companionOnlyChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("onboarding.companion_only_title")
                .font(.subheadline.weight(.semibold))
            Text("onboarding.companion_only_detail")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("onboarding.companion_only_action") {
                model.strategy = .fixedTimer
                model.completeOnboarding()
            }
            .buttonStyle(.bordered)
        }
    }

    private var visibleOnboardingProviders: [AgentProvider] {
        let providers = model.detectedProviders.isEmpty
            ? Set(AgentProvider.allCases)
            : model.detectedProviders
        return providers.sorted { $0.rawValue < $1.rawValue }
    }

    private func roleCard(_ role: CompanionRole, title: LocalizedStringKey) -> some View {
        Button {
            model.companionRole = role
        } label: {
            HStack(spacing: 14) {
                CompanionCharacterView(
                    role: role,
                    state: .resting,
                    diameter: 58,
                    skin: model.companionSkin,
                    showsStateAccessory: false
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(model.uiText("companion.role.\(role.rawValue).personality"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 118)
            .foregroundStyle(
                model.companionRole == role
                    ? PerchTheme.palette(for: role).accentDeep
                    : .primary
            )
            .background(
                model.companionRole == role
                    ? PerchTheme.palette(for: role).selectedFill
                    : PerchTheme.palette(for: role).subtleFill,
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        model.companionRole == role
                            ? PerchTheme.palette(for: role).accent.opacity(0.7)
                            : PerchTheme.palette(for: role).hairline,
                        lineWidth: model.companionRole == role ? 1.5 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func onboardingIntegrationRow(_ title: String, provider: AgentProvider) -> some View {
        let status = model.integrationStatuses[provider] ?? .notInstalled
        return HStack(spacing: 12) {
            ProviderBrandIcon(provider: provider, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title).font(.subheadline.weight(.medium))
                    Text("integration.capability.live")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.1), in: Capsule())
                }
                switch status {
                case .installed:
                    if model.lifecycleConnected(provider) {
                        Text("integration.live").font(.caption).foregroundStyle(PerchTheme.working)
                    } else if model.isVerifying(provider) {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("integration.verifying")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else if model.verificationFailed(provider) {
                        Text("integration.verification_failed").font(.caption).foregroundStyle(PerchTheme.danger)
                    } else if model.relayVerified(provider) {
                        Text("integration.local_verified").font(.caption).foregroundStyle(PerchTheme.working)
                    } else {
                        Text("integration.awaiting_first_event").font(.caption).foregroundStyle(PerchTheme.attention)
                    }
                case .notInstalled:
                    Text("integration.not_installed").font(.caption).foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message).font(.caption).foregroundStyle(PerchTheme.danger)
                }
            }
            Spacer()
            HStack {
                if status == .installed, model.verificationFailed(provider) {
                    Button("integration.retry_verification") {
                        model.verifyIntegration(provider)
                    }
                }
                Button(status == .installed ? "integration.remove" : "integration.install") {
                    model.toggleIntegration(provider)
                }
            }
        }
        .padding(.vertical, 10)
    }
}
