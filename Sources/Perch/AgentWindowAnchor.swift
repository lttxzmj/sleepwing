import AppKit
import CoreGraphics

/// Locates another app's window so the companion can dock beside it, without
/// requesting Accessibility or Screen Recording permissions.
/// `CGWindowListCopyWindowInfo` exposes window bounds and the owning app's
/// identity unconditionally; only the window title text is redacted without
/// Screen Recording, and this never reads that field.
enum AgentWindowAnchor {
    struct AnchoredWindow {
        let windowNumber: CGWindowID
        let frame: NSRect
    }

    /// Prefers the window matching `preferredWindowNumber` if it is still
    /// present, so a caller can pin to one window across polls instead of
    /// flipping between several of the same app's windows tick to tick.
    /// Falls back to the frontmost matching window otherwise.
    static func window(
        ownedByProcessID pid: pid_t,
        preferringWindowNumber preferredWindowNumber: CGWindowID?
    ) -> AnchoredWindow? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: AnyObject]] else { return nil }

        var candidates: [AnchoredWindow] = []
        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { continue }
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let windowNumber = entry[kCGWindowNumber as String] as? CGWindowID else { continue }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  // Excludes small helper/status windows (hotkey panels,
                  // tooltips) that could otherwise be mistaken for the
                  // app's real document window.
                  width >= 200, height >= 120,
                  let frame = quartzRectToAppKit(CGRect(x: x, y: y, width: width, height: height))
            else { continue }
            candidates.append(AnchoredWindow(windowNumber: windowNumber, frame: frame))
        }
        guard !candidates.isEmpty else { return nil }
        if let preferredWindowNumber,
           let pinned = candidates.first(where: { $0.windowNumber == preferredWindowNumber }) {
            return pinned
        }
        return candidates.first
    }

    /// CGWindowList bounds use a top-left-origin global coordinate space;
    /// AppKit screen frames use a bottom-left-origin space anchored to the
    /// primary display (the screen containing the menu bar).
    private static func quartzRectToAppKit(_ rect: CGRect) -> NSRect? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        return NSRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

/// Tracks the most recently activated app other than Perch itself. Docking
/// follows whichever app the user was last actually working in — a GUI agent
/// app, or any terminal hosting a CLI-based agent (iTerm, Terminal.app,
/// Warp, or anything else) — instead of a fixed per-provider app name, which
/// cannot know which terminal emulator a given user prefers.
@MainActor
final class FrontmostApplicationTracker {
    private(set) var lastOtherApplicationProcessID: pid_t?
    private let selfProcessID = ProcessInfo.processInfo.processIdentifier

    // Kept for the controller's lifetime (never torn down), matching how
    // PerchModel's own long-lived NSWorkspace observers are never removed
    // either; this sidesteps needing a non-isolated deinit to remove it.
    private var observer: NSObjectProtocol?

    init() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != selfProcessID {
            lastOtherApplicationProcessID = frontmost.processIdentifier
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated {
                guard let self, app.processIdentifier != self.selfProcessID else { return }
                self.lastOtherApplicationProcessID = app.processIdentifier
            }
        }
    }
}
