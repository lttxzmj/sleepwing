import AppKit
import os
import SwiftUI

private let settingsWindowLogger = Logger(
    subsystem: "app.sleepwing.Perch",
    category: "settings-window"
)

/// Owns one native settings window for the menu-bar app. Unlike a SwiftUI
/// `Settings` scene, this can be opened deterministically during onboarding
/// and moved to the active Space without depending on a mounted view action.
@MainActor
enum SettingsWindowPresenter {
    enum Placement {
        case pointer
        case primaryDisplay
    }

    private static var controller: SettingsWindowController?

    static func open(
        model: PerchModel,
        placement: Placement = .pointer
    ) {
        settingsWindowLogger.notice("present requested")
        let controller = controller ?? SettingsWindowController(model: model)
        self.controller = controller
        controller.present(placement: placement)
    }
}

@MainActor
private final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: PerchModel
    private let hostingController: NSHostingController<AnyView>

    init(model: PerchModel) {
        settingsWindowLogger.notice("creating native settings window")
        self.model = model
        hostingController = NSHostingController(rootView: Self.rootView(for: model))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sleepwing"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.contentViewController = hostingController
        window.center()

        super.init(window: window)
        window.delegate = self
        Self.installCenteredTitle(in: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(placement: SettingsWindowPresenter.Placement) {
        settingsWindowLogger.notice("ordering native settings window front")
        // Reapply the locale so changing language in a previous visit is
        // reflected the next time the retained window opens.
        hostingController.rootView = Self.rootView(for: model)
        guard let window else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        move(window, placement: placement)
        // A menu-bar-only app is not guaranteed to become active when a
        // programmatic window opens. Keep the requested Settings window
        // temporarily above the current app; it returns to a normal level as
        // soon as the user focuses it.
        window.level = .floating
        showWindow(nil)
        for delay in [0.0, 0.05, 0.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window == self.window else { return }
        window.level = .normal
    }

    /// `NSWindow.center()` may choose a different display from the one whose
    /// menu-bar item was clicked. The pointer is
    /// on the display that received that click, so centering there keeps the
    /// Settings window visible without requiring Accessibility permission.
    private func move(
        _ window: NSWindow,
        placement: SettingsWindowPresenter.Placement
    ) {
        let pointer = NSEvent.mouseLocation
        let pointerScreen = NSScreen.screens.first(where: {
            NSMouseInRect(pointer, $0.frame, false)
        })
        let screen: NSScreen?
        switch placement {
        case .pointer:
            screen = pointerScreen
        case .primaryDisplay:
            screen = NSScreen.screens.first
        }
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else {
            return
        }
        let visible = screen.visibleFrame
        let frame = window.frame
        let centered = NSRect(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2,
            width: frame.width,
            height: frame.height
        )
        let placed = frameAvoidingFloatingWindows(
            centered,
            inside: visible,
            excluding: window
        )
        window.setFrameOrigin(placed.origin)
    }

    private func frameAvoidingFloatingWindows(
        _ proposed: NSRect,
        inside visible: NSRect,
        excluding settingsWindow: NSWindow
    ) -> NSRect {
        let gap: CGFloat = 20
        let obstacles = NSApp.windows.filter {
            $0 !== settingsWindow
                && $0.isVisible
                && $0.level > .normal
                && $0.frame.intersects(proposed.insetBy(dx: -gap, dy: -gap))
        }
        guard let obstacle = obstacles.first else { return proposed }
        let alternatives = [
            NSRect(
                x: obstacle.frame.minX - gap - proposed.width,
                y: proposed.minY,
                width: proposed.width,
                height: proposed.height
            ),
            NSRect(
                x: obstacle.frame.maxX + gap,
                y: proposed.minY,
                width: proposed.width,
                height: proposed.height
            ),
            NSRect(
                x: proposed.minX,
                y: obstacle.frame.minY - gap - proposed.height,
                width: proposed.width,
                height: proposed.height
            ),
        ]
        return alternatives.first(where: visible.contains) ?? proposed
    }

    private static func rootView(for model: PerchModel) -> AnyView {
        AnyView(
            SettingsView(model: model)
                .environment(\.locale, model.locale)
                .frame(width: 720, height: 600)
        )
    }

    private static func installCenteredTitle(in window: NSWindow) {
        guard let closeButton = window.standardWindowButton(.closeButton),
              let titlebar = closeButton.superview else {
            return
        }
        let label = NSTextField(labelWithString: "Sleepwing")
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityElement(false)
        titlebar.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: titlebar.centerXAnchor),
            label.centerYAnchor.constraint(
                equalTo: closeButton.centerYAnchor
            ),
        ])
    }
}
