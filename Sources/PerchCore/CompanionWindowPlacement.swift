import CoreGraphics

public enum CompanionWindowPlacement {
    public static func recoveredFrame(
        _ frame: CGRect,
        visibleFrames: [CGRect],
        fallbackVisibleFrame: CGRect,
        minimumVisibleFraction: CGFloat = 0.4,
        margin: CGFloat = 28
    ) -> CGRect {
        guard !visibleFrames.isEmpty else { return frame }
        let bestVisibleFrame = visibleFrames.max { lhs, rhs in
            intersectionArea(frame, lhs) < intersectionArea(frame, rhs)
        } ?? fallbackVisibleFrame
        let visibleArea = intersectionArea(frame, bestVisibleFrame)
        let requiredArea = max(0, frame.width * frame.height * minimumVisibleFraction)

        guard visibleArea >= requiredArea else {
            let target = visibleFrames.contains(fallbackVisibleFrame)
                ? fallbackVisibleFrame
                : visibleFrames[0]
            let width = min(frame.width, target.width)
            let height = min(frame.height, target.height)
            return CGRect(
                x: target.maxX - width - margin,
                y: target.minY + margin,
                width: width,
                height: height
            )
        }
        return constrainedFrame(frame, to: bestVisibleFrame)
    }

    /// Whether the companion may appear over another app's full-screen
    /// Space. Competing watchers that stay visible unconditionally are a
    /// top annoyance (pet over videos and games); ones that vanish
    /// entirely break the recall promise at exactly the moment it
    /// matters. The resolution is attention-priority: yield the screen
    /// while agents work, surface only when one actually needs the user
    /// — unless the user opted into always showing.
    public static func joinsFullScreenSpaces(
        showsOverFullScreen: Bool,
        phase: AgentPhase
    ) -> Bool {
        showsOverFullScreen || phase == .waitingForInput || phase == .failed
    }

    public static func constrainedFrame(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        let x = min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}
