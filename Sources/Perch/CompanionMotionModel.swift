import AppKit
import Combine
import PerchCore

@MainActor
final class CompanionMotionModel: ObservableObject {
    @Published private(set) var dragDirection: PetDragDirection?
    @Published private(set) var lookDirection: PetLookDirection?

    private var panelFrame: NSRect?
    private var lastPanelOrigin: NSPoint?
    private var dragResetTask: Task<Void, Never>?
    private var gaze = CompanionGazeEngine()
    private var lastPointerLocation: NSPoint?

    func updatePanelFrame(_ frame: NSRect, detectMovement: Bool = true) {
        defer {
            panelFrame = frame
            lastPanelOrigin = frame.origin
            updatePointer()
        }

        guard detectMovement, let lastPanelOrigin else { return }
        let deltaX = frame.origin.x - lastPanelOrigin.x
        guard abs(deltaX) >= 1.5 else { return }

        dragDirection = deltaX < 0 ? .left : .right
        dragResetTask?.cancel()
        dragResetTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.dragDirection = nil
        }
    }

    func updatePointer(location: NSPoint = NSEvent.mouseLocation) {
        guard let panelFrame else {
            lookDirection = nil
            return
        }
        let moved = lastPointerLocation.map {
            hypot(location.x - $0.x, location.y - $0.y) > 2
        } ?? true
        lastPointerLocation = location
        lookDirection = gaze.update(
            deltaX: location.x - panelFrame.midX,
            deltaY: location.y - panelFrame.midY,
            pointerMoved: moved,
            at: Date()
        )
    }
}
