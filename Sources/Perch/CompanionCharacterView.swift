import PerchCore
import SwiftUI

struct CompanionCharacterView: View {
    let role: CompanionRole
    let state: CompanionPresentationState
    let diameter: CGFloat
    let skin: CompanionSkin
    let showsStateAccessory: Bool
    let phase: AgentPhase
    let motionEnabled: Bool
    let dragDirection: PetDragDirection?
    let lookDirection: PetLookDirection?
    let customSpriteURL: URL?

    init(
        role: CompanionRole,
        state: CompanionPresentationState,
        diameter: CGFloat,
        skin: CompanionSkin = .mist,
        showsStateAccessory: Bool = true,
        phase: AgentPhase = .idle,
        motionEnabled: Bool = false,
        dragDirection: PetDragDirection? = nil,
        lookDirection: PetLookDirection? = nil,
        customSpriteURL: URL? = nil
    ) {
        self.role = role
        self.state = state
        self.diameter = diameter
        self.skin = skin
        self.showsStateAccessory = showsStateAccessory
        self.phase = phase
        self.motionEnabled = motionEnabled
        self.dragDirection = dragDirection
        self.lookDirection = lookDirection
        self.customSpriteURL = customSpriteURL
    }

    var body: some View {
        ZStack {
            if !usesSpriteAtlas {
                legacyBackground
            }

            characterImage
                .frame(
                    width: usesSpriteAtlas ? diameter * 1.12 : diameter * 0.9,
                    height: usesSpriteAtlas ? diameter * 1.12 : diameter * 0.9
                )
                // The rebuilt success rows animate the celebration in the
                // atlas itself; the old transform-layer hop must not run on
                // top of it — stacked vertical motions read as mush.
                .dragLanding(dragDirection, active: motionEnabled)
                .modifier(StateTransitionModifier(
                    state: state,
                    active: motionEnabled
                ))

            if showsStateAccessory && !usesSpriteAtlas {
                stateAccessory
                    .offset(x: diameter * 0.35, y: -diameter * 0.34)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var legacyBackground: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [skinPalette.surfaceTop, skinPalette.surfaceBottom],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.72), lineWidth: max(1, diameter * 0.014))
            )
            .overlay(
                Circle()
                    .strokeBorder(accessoryColor.opacity(0.18), lineWidth: max(1, diameter * 0.018))
            )
            .shadow(
                color: skinPalette.shadow.opacity(0.22),
                radius: diameter * 0.12,
                y: diameter * 0.065
            )
    }

    // Celebration plays from the atlas success row. The old video overlay
    // was cropped to the atlas cell's window, which amputated the raised
    // paws mid-stretch; the atlas frames carry the full pose.
    @ViewBuilder
    private var characterImage: some View {
        if role == .cat {
            PetSpriteAtlasView(
                resourceName: "perch-crescent-cat-v2",
                state: PetSpriteContract.animationState(
                    phase: phase,
                    presentation: state
                ),
                diameter: diameter * 1.12,
                motionEnabled: motionEnabled,
                fallbackSymbol: "cat.fill",
                dragDirection: dragDirection,
                lookDirection: lookDirection
            )
        } else if role == .sleepwing {
            PetSpriteAtlasView(
                resourceName: "perch-sleepwing-bird-v2",
                state: PetSpriteContract.animationState(
                    phase: phase,
                    presentation: state
                ),
                diameter: diameter * 1.12,
                motionEnabled: motionEnabled,
                fallbackSymbol: "bird.fill",
                dragDirection: dragDirection,
                lookDirection: lookDirection
            )
        } else if role == .custom, let customSpriteURL {
            PetSpriteAtlasView(
                resourceName: "",
                sourceURL: customSpriteURL,
                state: PetSpriteContract.animationState(
                    phase: phase,
                    presentation: state
                ),
                diameter: diameter * 1.12,
                motionEnabled: motionEnabled,
                fallbackSymbol: "pawprint.fill",
                dragDirection: dragDirection,
                lookDirection: lookDirection
            )
        } else {
            Image(systemName: "pawprint.fill")
                .font(.system(size: diameter * 0.42, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var stateAccessory: some View {
        Image(systemName: accessorySymbol)
            .font(.system(size: diameter * 0.125, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: diameter * 0.27, height: diameter * 0.27)
            .background(accessoryColor, in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: max(1, diameter * 0.018))
            )
            .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
            .accessibilityHidden(true)
    }

    private var signatureFlourish: PetSignatureFlourish? {
        switch role {
        case .sleepwing:
            PetSignatureFlourish.flourish(forSpriteResource: "perch-sleepwing-bird-v2")
        case .cat:
            PetSignatureFlourish.flourish(forSpriteResource: "perch-crescent-cat-v2")
        default:
            nil
        }
    }

    private var usesSpriteAtlas: Bool {
        role == .cat || role == .sleepwing || (role == .custom && customSpriteURL != nil)
    }

    private var accessorySymbol: String {
        switch state {
        case .resting: "moon.zzz.fill"
        case .working: "chevron.left.forwardslash.chevron.right"
        case .healthOpportunity: "figure.walk"
        case .needsAttention: "exclamationmark"
        case .celebrating: "sparkles"
        case let .healthNudge(kind):
            switch kind {
            case .hydrate: "drop.fill"
            case .stand: "figure.stand"
            case .eyes: "eye.fill"
            case .posture: "figure.seated.side"
            case .breathe: "wind"
            }
        }
    }

    private var accessoryColor: Color {
        PerchTheme.color(for: accessoryTone)
    }

    private var accessoryTone: CompanionSemanticTone {
        switch state {
        case .resting:
            .resting
        case .working:
            .working
        case .healthOpportunity:
            .health
        case .needsAttention, .healthNudge:
            .attention
        case .celebrating:
            .celebration
        }
    }

    private var skinPalette: CharacterSkinPalette {
        switch skin {
        case .mist:
            CharacterSkinPalette(
                surfaceTop: Color(red: 0.98, green: 0.98, blue: 0.95),
                surfaceBottom: Color(red: 0.84, green: 0.93, blue: 0.93),
                shadow: Color(red: 0.18, green: 0.42, blue: 0.46)
            )
        case .midnight:
            CharacterSkinPalette(
                surfaceTop: Color(red: 0.91, green: 0.92, blue: 0.97),
                surfaceBottom: Color(red: 0.72, green: 0.76, blue: 0.87),
                shadow: Color(red: 0.20, green: 0.22, blue: 0.38)
            )
        case .grove:
            CharacterSkinPalette(
                surfaceTop: Color(red: 0.96, green: 0.97, blue: 0.91),
                surfaceBottom: Color(red: 0.80, green: 0.88, blue: 0.74),
                shadow: Color(red: 0.28, green: 0.43, blue: 0.24)
            )
        }
    }
}

private struct CharacterSkinPalette {
    let surfaceTop: Color
    let surfaceBottom: Color
    let shadow: Color
}

private struct SignatureFlourishValues {
    var liftY: CGFloat = 0
    var squashY: CGFloat = 1
    var lean: Angle = .zero
}

private struct SignatureFlourishModifier: ViewModifier {
    let flourish: PetSignatureFlourish?
    let active: Bool
    let diameter: CGFloat

    @State private var celebrationToken = 0

    func body(content: Content) -> some View {
        Group {
            if let flourish {
                animated(content, flourish: flourish)
            } else {
                content
            }
        }
        .task(id: active) {
            if active { celebrationToken += 1 }
        }
    }

    @ViewBuilder
    private func animated(
        _ content: Content,
        flourish: PetSignatureFlourish
    ) -> some View {
        switch flourish.kind {
        case .hop:
            content.keyframeAnimator(
                initialValue: SignatureFlourishValues(),
                trigger: celebrationToken
            ) { view, value in
                view
                    .scaleEffect(x: 1, y: value.squashY, anchor: .bottom)
                    .rotationEffect(value.lean, anchor: .bottom)
                    .offset(y: value.liftY * diameter)
            } keyframes: { _ in
                KeyframeTrack(\SignatureFlourishValues.liftY) {
                    CubicKeyframe(-0.13, duration: flourish.duration * 0.3)
                    SpringKeyframe(
                        0,
                        duration: flourish.duration * 0.7,
                        spring: .bouncy(duration: 0.42)
                    )
                }
                KeyframeTrack(\SignatureFlourishValues.squashY) {
                    CubicKeyframe(0.88, duration: flourish.duration * 0.14)
                    CubicKeyframe(1.06, duration: flourish.duration * 0.36)
                    CubicKeyframe(1, duration: flourish.duration * 0.5)
                }
            }
        case .settle:
            content.keyframeAnimator(
                initialValue: SignatureFlourishValues(),
                trigger: celebrationToken
            ) { view, value in
                view
                    .scaleEffect(x: 1, y: value.squashY, anchor: .bottom)
                    .rotationEffect(value.lean, anchor: .bottom)
                    .offset(y: value.liftY * diameter)
            } keyframes: { _ in
                KeyframeTrack(\SignatureFlourishValues.lean) {
                    CubicKeyframe(.degrees(-7), duration: flourish.duration * 0.35)
                    CubicKeyframe(.degrees(0), duration: flourish.duration * 0.65)
                }
                KeyframeTrack(\SignatureFlourishValues.squashY) {
                    CubicKeyframe(1.09, duration: flourish.duration * 0.4)
                    CubicKeyframe(1, duration: flourish.duration * 0.6)
                }
            }
        }
    }

}

extension View {
    fileprivate func signatureFlourish(
        _ flourish: PetSignatureFlourish?,
        active: Bool,
        diameter: CGFloat
    ) -> some View {
        modifier(SignatureFlourishModifier(
            flourish: flourish,
            active: active,
            diameter: diameter
        ))
    }
}

private struct DragLandingValues {
    var squashY: CGFloat = 1
}

/// A brief squash-and-settle the moment a drag ends, so the companion
/// visibly lands instead of snapping from a run frame straight back to
/// idle.
private struct DragLandingModifier: ViewModifier {
    let dragDirection: PetDragDirection?
    let active: Bool

    @State private var landingToken = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(
                initialValue: DragLandingValues(),
                trigger: landingToken
            ) { view, value in
                view.scaleEffect(x: 1, y: value.squashY, anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack(\DragLandingValues.squashY) {
                    CubicKeyframe(0.82, duration: 0.1)
                    SpringKeyframe(
                        1,
                        duration: 0.4,
                        spring: .bouncy(duration: 0.32)
                    )
                }
            }
            .onChange(of: dragDirection) { previous, next in
                if active, previous != nil, next == nil {
                    landingToken += 1
                }
            }
    }
}

/// Sprite rows switch instantly when the presentation state changes; a
/// quick settle (brief opacity dip plus a bottom-anchored spring) reads as
/// the character shifting posture instead of a hard cut.
private struct TransitionValues {
    var opacity: Double = 1
    var scale: CGFloat = 1
}

private struct StateTransitionModifier: ViewModifier {
    let state: CompanionPresentationState
    let active: Bool

    @State private var token = 0

    func body(content: Content) -> some View {
        content
            .keyframeAnimator(
                initialValue: TransitionValues(),
                trigger: token
            ) { view, value in
                view
                    .opacity(value.opacity)
                    .scaleEffect(value.scale, anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack(\TransitionValues.opacity) {
                    CubicKeyframe(0.55, duration: 0.08)
                    CubicKeyframe(1, duration: 0.3)
                }
                KeyframeTrack(\TransitionValues.scale) {
                    CubicKeyframe(0.94, duration: 0.09)
                    SpringKeyframe(
                        1,
                        duration: 0.32,
                        spring: .bouncy(duration: 0.28)
                    )
                }
            }
            .onChange(of: state) { _, _ in
                if active { token += 1 }
            }
    }
}

extension View {
    fileprivate func dragLanding(
        _ dragDirection: PetDragDirection?,
        active: Bool
    ) -> some View {
        modifier(DragLandingModifier(
            dragDirection: dragDirection,
            active: active
        ))
    }
}
