import PerchCore
import SwiftUI
import UniformTypeIdentifiers

struct CustomPetStudioView: View {
    @ObservedObject var model: PerchModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importingPetFolder = false
    @State private var personalityEditTarget: CustomPetDescriptor?
    @State private var personalityDraft = ""
    @State private var deleteTarget: CustomPetDescriptor?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    creationActions
                    petLibrary
                }
                .padding(24)
            }
        }
        // The settings window is fixed at 720×600; a sheet must stay
        // visibly smaller than its host or macOS clamps it against the
        // window edges. Content scrolls, so a fixed size is safe.
        .frame(width: 620, height: 520)
        .background(PerchTheme.palette(for: .custom).screenWash)
        .tint(PerchTheme.palette(for: .custom).accent)
        .task {
            model.refreshPetCreationCapabilities()
            model.refreshCustomPets()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            model.refreshCustomPets()
        }
        .fileImporter(
            isPresented: $importingPetFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            model.importCustomPetPackage(from: url)
        }
        .sheet(item: $personalityEditTarget) { pet in
            personalityEditor(pet)
        }
        .confirmationDialog(
            model.uiText("custom_pet.delete.confirm"),
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { pet in
            Button(model.uiText("custom_pet.action.delete"), role: .destructive) {
                model.deleteCustomPet(pet)
                deleteTarget = nil
            }
        } message: { _ in
            Text(model.uiText("custom_pet.delete.detail"))
        }
    }

    private func personalityEditor(_ pet: CustomPetDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.uiText("custom_pet.personality.title") + " · " + pet.displayName)
                .font(.headline)
            Text(model.uiText("custom_pet.personality.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $personalityDraft)
                .font(.system(size: 12))
                .frame(minHeight: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(PerchTheme.palette(for: .custom).hairline)
                )
            HStack {
                Spacer()
                Button(model.uiText("custom_pet.personality.cancel")) {
                    personalityEditTarget = nil
                }
                Button(model.uiText("custom_pet.personality.save")) {
                    model.updateCustomPetPersonality(pet, personality: personalityDraft)
                    personalityEditTarget = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "pawprint.circle.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(PerchTheme.palette(for: .custom).accent)
                .frame(width: 42, height: 42)
                .background(
                    PerchTheme.palette(for: .custom).selectedFill,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(model.uiText("custom_pet.studio.title"))
                    .font(.title3.weight(.semibold))
                Text(model.uiText("custom_pet.studio.subtitle"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.uiText("ui.done")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var creationActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.uiText("custom_pet.create.heading"))
                .font(.headline)
            photoCard
            ideaCard
            HStack(spacing: 10) {
                Label(model.uiText("custom_pet.create.note"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                Button(model.uiText("custom_pet.skill.copy")) {
                    model.copySkillInvocation()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            if let message = model.customPetStatusMessage {
                Label(
                    message,
                    systemImage: model.customPetStatusIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(
                    model.customPetStatusIsError
                        ? PerchTheme.danger
                        : PerchTheme.health
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var photoCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                cardGlyph("photo.on.rectangle.angled")
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.uiText("custom_pet.photo.title"))
                        .font(.subheadline.weight(.semibold))
                    Text(model.uiText("custom_pet.photo.detail"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(model.uiText("custom_pet.create.photo")) {
                    model.chooseReferencePhoto()
                }
                .buttonStyle(.borderedProminent)
            }
            if model.referenceArtURL != nil {
                Divider()
                Text(model.uiText("custom_pet.photo.agent_heading"))
                    .font(.caption.weight(.semibold))
                HStack(spacing: 12) {
                    Picker(
                        model.uiText("custom_pet.style.title"),
                        selection: $model.petCreationStyle
                    ) {
                        ForEach(PetCreationStyle.allCases, id: \.rawValue) { style in
                            Text(model.uiText("custom_pet.style.\(style.rawValue)"))
                                .tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer(minLength: 12)
                    agentMenu { provider in
                        model.createCustomPetFromReferenceArt(with: provider)
                    }
                }
            }
        }
        .padding(12)
        .perchCard(
            radius: 14,
            fill: Color(nsColor: .controlBackgroundColor).opacity(0.72),
            stroke: PerchTheme.palette(for: .custom).hairline
        )
    }

    private var ideaCard: some View {
        HStack(spacing: 12) {
            cardGlyph("doc.on.clipboard.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(model.uiText("custom_pet.idea.title"))
                    .font(.subheadline.weight(.semibold))
                Text(model.uiText("custom_pet.idea.detail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            agentMenu { provider in
                model.createCustomPetFromIdea(with: provider)
            }
        }
        .padding(12)
        .perchCard(
            radius: 14,
            fill: Color(nsColor: .controlBackgroundColor).opacity(0.72),
            stroke: PerchTheme.palette(for: .custom).hairline
        )
    }

    private func agentMenu(
        action: @escaping (AgentProvider?) -> Void
    ) -> some View {
        Menu {
            ForEach(model.petCreationAgents, id: \.self) { provider in
                Button(model.providerDisplayName(provider)) {
                    action(provider)
                }
            }
            if !model.petCreationAgents.isEmpty {
                Divider()
            }
            Button(model.uiText("custom_pet.agent.any")) {
                action(nil)
            }
        } label: {
            Text(model.uiText("custom_pet.agent.choose"))
        }
        .fixedSize()
    }

    private func cardGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(PerchTheme.palette(for: .custom).accent)
            .frame(width: 34, height: 34)
            .background(
                PerchTheme.palette(for: .custom).selectedFill,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }

    private var petLibrary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.uiText("custom_pet.library.heading"))
                        .font(.headline)
                    Text(model.uiText(
                        model.customPets.isEmpty
                            ? "custom_pet.library.empty_detail"
                            : "custom_pet.library.detail"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.uiText("custom_pet.create.import")) {
                    importingPetFolder = true
                }
                .controlSize(.small)
                Button {
                    model.refreshCustomPets()
                } label: {
                    Label(model.uiText("custom_pet.refresh"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            if model.customPets.isEmpty {
                emptyLibrary
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(model.customPets) { pet in
                        petRow(pet)
                    }
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 10) {
            Image(systemName: "pawprint")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(PerchTheme.palette(for: .custom).accent)
            Text(model.uiText("custom_pet.library.empty"))
                .font(.subheadline.weight(.semibold))
            Text(model.uiText("custom_pet.library.empty_hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .perchCard(
            radius: 14,
            fill: PerchTheme.palette(for: .custom).subtleFill,
            stroke: PerchTheme.palette(for: .custom).hairline
        )
    }

    private func petRow(_ pet: CustomPetDescriptor) -> some View {
        let isCurrent = model.companionRole == .custom
            && model.selectedCustomPetID == pet.id
        return HStack(spacing: 16) {
            CompanionCharacterView(
                role: .custom,
                state: .resting,
                diameter: 76,
                showsStateAccessory: false,
                motionEnabled: model.companionMotionEnabled && !reduceMotion,
                customSpriteURL: pet.spritesheetURL
            )
            .frame(width: 86, height: 86)
            .background(
                PerchTheme.palette(for: .custom).subtleFill,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text(pet.displayName)
                        .font(.subheadline.weight(.semibold))
                    sourceBadge(pet.origin)
                }
                Text(pet.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 12) {
                    validationLabel("custom_pet.validation.v2")
                    visualQAValidationLabel(pet.visualQAStatus)
                    validationLabel("custom_pet.validation.local")
                }
            }
            Spacer(minLength: 12)

            if isCurrent {
                Button(model.uiText("custom_pet.current")) {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            } else {
                Button(model.uiText(
                    pet.isInstalledInPerch ? "custom_pet.use" : "custom_pet.add"
                )) {
                    model.selectCustomPet(pet)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!pet.isReadyForInstall)
                .help(
                    pet.isReadyForInstall
                        ? ""
                        : model.uiText("custom_pet.validation.qa_required_help")
                )
            }
            Menu {
                Button(model.uiText("custom_pet.action.edit_personality")) {
                    // Show the effective default persona when the pet has
                    // none of its own, so editing starts from what is
                    // actually in use rather than a blank box.
                    personalityDraft = pet.personality
                        ?? model.uiText("smalltalk.persona.custom")
                    personalityEditTarget = pet
                }
                if pet.isInstalledInPerch {
                    Button(
                        model.uiText("custom_pet.action.delete"),
                        role: .destructive
                    ) {
                        deleteTarget = pet
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(14)
        .perchCard(
            radius: 14,
            fill: isCurrent
                ? PerchTheme.palette(for: .custom).selectedFill
                : Color(nsColor: .controlBackgroundColor).opacity(0.72),
            stroke: isCurrent
                ? PerchTheme.palette(for: .custom).accent.opacity(0.62)
                : PerchTheme.palette(for: .custom).hairline
        )
    }

    private func sourceBadge(_ origin: CustomPetDescriptor.Origin) -> some View {
        let key: String = switch origin {
        case .codex: "custom_pet.source.codex"
        case .perch: "custom_pet.source.perch"
        }
        return Text(model.uiText(key))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(PerchTheme.palette(for: .custom).accentDeep)
            .background(
                PerchTheme.palette(for: .custom).selectedFill,
                in: Capsule()
            )
    }

    private func validationLabel(_ key: String) -> some View {
        Label(model.uiText(key), systemImage: "checkmark.circle.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private func visualQAValidationLabel(
        _ status: CustomPetDescriptor.VisualQAStatus
    ) -> some View {
        let passed = status == .passed
        return Label(
            model.uiText(
                passed
                    ? "custom_pet.validation.qa_passed"
                    : "custom_pet.validation.qa_missing"
            ),
            systemImage: passed ? "checkmark.seal.fill" : "exclamationmark.circle"
        )
        .font(.caption2)
        .foregroundStyle(passed ? .secondary : PerchTheme.attention)
        .labelStyle(.titleAndIcon)
    }
}
