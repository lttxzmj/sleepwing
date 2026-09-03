import AppKit
import SwiftUI

struct PerchBrandMark: View {
    var size: CGFloat
    var showsBackground = true

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width, canvasSize.height) / 200

            func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
                CGRect(x: x * scale, y: y * scale, width: width * scale, height: height * scale)
            }

            if showsBackground {
                let background = Path(
                    roundedRect: rect(0, 0, 200, 200),
                    cornerRadius: 44 * scale
                )
                context.fill(
                    background,
                    with: .linearGradient(
                        Gradient(colors: [PerchTheme.mintHighlight, PerchTheme.mint]),
                        startPoint: CGPoint(x: 28 * scale, y: 20 * scale),
                        endPoint: CGPoint(x: 178 * scale, y: 184 * scale)
                    )
                )
                context.stroke(background, with: .color(.white.opacity(0.5)), lineWidth: max(1, 2 * scale))
            }

            // The level-stance geometry is centered by construction; no offset needed.
            let bird = context

            var leftWing = Path()
            leftWing.move(to: CGPoint(x: 62 * scale, y: 68 * scale))
            leftWing.addQuadCurve(
                to: CGPoint(x: 52 * scale, y: 128 * scale),
                control: CGPoint(x: 38 * scale, y: 88 * scale)
            )
            bird.stroke(
                leftWing,
                with: .color(PerchTheme.brand),
                style: StrokeStyle(lineWidth: 20 * scale, lineCap: .round)
            )

            var rightWing = Path()
            rightWing.move(to: CGPoint(x: 138 * scale, y: 68 * scale))
            rightWing.addQuadCurve(
                to: CGPoint(x: 148 * scale, y: 128 * scale),
                control: CGPoint(x: 162 * scale, y: 88 * scale)
            )
            bird.stroke(
                rightWing,
                with: .color(PerchTheme.brand),
                style: StrokeStyle(lineWidth: 20 * scale, lineCap: .round)
            )

            var leftLeg = Path()
            leftLeg.move(to: CGPoint(x: 88 * scale, y: 132 * scale))
            leftLeg.addQuadCurve(
                to: CGPoint(x: 84 * scale, y: 146 * scale),
                control: CGPoint(x: 86 * scale, y: 140 * scale)
            )
            bird.stroke(
                leftLeg,
                with: .color(PerchTheme.brand),
                style: StrokeStyle(lineWidth: 14 * scale, lineCap: .round)
            )

            var rightLeg = Path()
            rightLeg.move(to: CGPoint(x: 112 * scale, y: 132 * scale))
            rightLeg.addQuadCurve(
                to: CGPoint(x: 116 * scale, y: 146 * scale),
                control: CGPoint(x: 114 * scale, y: 140 * scale)
            )
            bird.stroke(
                rightLeg,
                with: .color(PerchTheme.brand),
                style: StrokeStyle(lineWidth: 14 * scale, lineCap: .round)
            )

            bird.fill(Path(ellipseIn: rect(71, 141, 26, 14)), with: .color(PerchTheme.accent))
            bird.fill(Path(ellipseIn: rect(102, 141, 28, 14)), with: .color(PerchTheme.accent))
            bird.fill(Path(ellipseIn: rect(50, 44, 100, 96)), with: .color(PerchTheme.brand))
            bird.fill(Path(ellipseIn: rect(70, 73, 60, 64)), with: .color(PerchTheme.belly))

            bird.fill(Path(ellipseIn: rect(128, 71, 34, 22)), with: .color(PerchTheme.accent))

            var eye = Path()
            eye.move(to: CGPoint(x: 122 * scale, y: 68 * scale))
            eye.addQuadCurve(
                to: CGPoint(x: 134 * scale, y: 68 * scale),
                control: CGPoint(x: 128 * scale, y: 73 * scale)
            )
            bird.stroke(
                eye,
                with: .color(PerchTheme.ink),
                style: StrokeStyle(lineWidth: max(2, 3.5 * scale), lineCap: .round)
            )
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text("app.name"))
    }
}

enum PerchMenuBarIcon {
    /// AppKit template images are automatically rendered black or white by macOS.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            // Preserve the original outer geometry, then apply a small-size optical
            // correction so the eye survives and the belly does not dominate at 18 pt.
            let logoTransform = NSAffineTransform()
            logoTransform.translateX(by: 9, yBy: 9)
            logoTransform.scale(by: 0.136)
            logoTransform.translateX(by: -100, yBy: -99.5)
            logoTransform.concat()

            NSColor.black.setFill()
            NSColor.black.setStroke()

            func roundedStroke(_ path: NSBezierPath, width: CGFloat) {
                path.lineWidth = width
                path.lineCapStyle = .round
                path.stroke()
            }

            let leftWing = NSBezierPath()
            leftWing.move(to: NSPoint(x: 62, y: 68))
            leftWing.curve(
                to: NSPoint(x: 52, y: 128),
                controlPoint1: NSPoint(x: 46, y: 81.333),
                controlPoint2: NSPoint(x: 42.667, y: 101.333)
            )
            roundedStroke(leftWing, width: 20)

            let rightWing = NSBezierPath()
            rightWing.move(to: NSPoint(x: 138, y: 68))
            rightWing.curve(
                to: NSPoint(x: 148, y: 128),
                controlPoint1: NSPoint(x: 154, y: 81.333),
                controlPoint2: NSPoint(x: 157.333, y: 101.333)
            )
            roundedStroke(rightWing, width: 20)

            let leftLeg = NSBezierPath()
            leftLeg.move(to: NSPoint(x: 88, y: 132))
            leftLeg.curve(
                to: NSPoint(x: 84, y: 146),
                controlPoint1: NSPoint(x: 86.667, y: 137.333),
                controlPoint2: NSPoint(x: 85.333, y: 142)
            )
            roundedStroke(leftLeg, width: 14)

            let rightLeg = NSBezierPath()
            rightLeg.move(to: NSPoint(x: 112, y: 132))
            rightLeg.curve(
                to: NSPoint(x: 116, y: 146),
                controlPoint1: NSPoint(x: 113.333, y: 137.333),
                controlPoint2: NSPoint(x: 114.667, y: 142)
            )
            roundedStroke(rightLeg, width: 14)

            NSBezierPath(ovalIn: NSRect(x: 71, y: 141, width: 26, height: 14)).fill()
            NSBezierPath(ovalIn: NSRect(x: 102, y: 141, width: 28, height: 14)).fill()
            NSBezierPath(ovalIn: NSRect(x: 50, y: 44, width: 100, height: 96)).fill()

            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 76, y: 79, width: 48, height: 52)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            NSBezierPath(ovalIn: NSRect(x: 128, y: 71, width: 34, height: 22)).fill()

            NSGraphicsContext.current?.compositingOperation = .clear
            let closedEye = NSBezierPath()
            closedEye.move(to: NSPoint(x: 122, y: 68))
            closedEye.curve(
                to: NSPoint(x: 134, y: 68),
                controlPoint1: NSPoint(x: 126, y: 71.333),
                controlPoint2: NSPoint(x: 130, y: 71.333)
            )
            roundedStroke(closedEye, width: 6)
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        image.isTemplate = true
        return image
    }()
}
