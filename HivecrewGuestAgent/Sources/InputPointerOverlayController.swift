//
//  InputPointerOverlayController.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 4/20/26.
//

import AppKit
import HivecrewAgentProtocol

@MainActor
final class InputPointerOverlayController {
    static let shared = InputPointerOverlayController()

    private let logger = AgentLogger.shared

    private var panel: PointerOverlayPanel?
    private var overlayView: PointerOverlayView?
    private var desktopFrame: CGRect = .zero
    private var cursorTrackingTimer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.rebuildWindowIfNeeded(force: true)
                self?.syncToSystemCursor()
            }
        }
    }

    /// Activate the persistent pointer overlay. Safe to call multiple times.
    func start() {
        ensureWindow()
        panel?.alphaValue = 1
        panel?.orderFrontRegardless()
        syncToSystemCursor()
        startCursorTracking()
    }

    func movePointer(to globalPoint: CGPoint) {
        ensureWindow()
        panel?.orderFrontRegardless()
        overlayView?.movePointer(to: globalPoint)
    }

    func showClick(at globalPoint: CGPoint, button: MouseButton) {
        ensureWindow()
        overlayView?.movePointer(to: globalPoint)
        overlayView?.performClickAnimation()
    }

    func showScroll(at globalPoint: CGPoint, deltaX: Double, deltaY: Double) {
        ensureWindow()
        overlayView?.movePointer(to: globalPoint)
        overlayView?.showScroll(deltaX: deltaX, deltaY: deltaY)
    }

    private func ensureWindow() {
        rebuildWindowIfNeeded(force: false)
    }

    private func rebuildWindowIfNeeded(force: Bool) {
        let newDesktopFrame = Self.combinedScreenFrame()
        guard force || panel == nil || desktopFrame != newDesktopFrame else { return }

        desktopFrame = newDesktopFrame
        panel?.close()

        let panel = PointerOverlayPanel(frame: newDesktopFrame)
        let overlayView = PointerOverlayView(
            frame: CGRect(origin: .zero, size: newDesktopFrame.size),
            desktopFrame: newDesktopFrame
        )

        panel.contentView = overlayView
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        self.panel = panel
        self.overlayView = overlayView

        logger.debug("Rebuilt pointer overlay window for desktop frame \(NSStringFromRect(newDesktopFrame))")
    }

    private func startCursorTracking() {
        guard cursorTrackingTimer == nil else { return }

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in
                InputPointerOverlayController.shared.syncToSystemCursor()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        cursorTrackingTimer = timer
    }

    private func syncToSystemCursor() {
        guard let location = CGEvent(source: nil)?.location else { return }
        overlayView?.movePointer(to: location)
    }

    private static func combinedScreenFrame() -> CGRect {
        let frames = NSScreen.screens.map(\.frame)
        return frames.reduce(into: CGRect.null) { partialResult, frame in
            partialResult = partialResult.union(frame)
        }
    }
}

private final class PointerOverlayPanel: NSPanel {
    init(frame: CGRect) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        worksWhenModal = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class PointerOverlayView: NSView {
    private let desktopFrame: CGRect

    private var pointerPosition: CGPoint?

    private var clickAnimationStart: CFTimeInterval?
    private static let clickAnimationDuration: CFTimeInterval = 0.25
    private static let clickMinScale: CGFloat = 0.8

    private var scrollPulse: CGFloat = 0
    private var scrollVector = CGVector(dx: 0, dy: 1)

    private var animationTimer: Timer?
    private var lastTick = CACurrentMediaTime()

    init(frame: CGRect, desktopFrame: CGRect) {
        self.desktopFrame = desktopFrame
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { false }
    // Flip to match CGEvent's top-left coordinate space so that points coming
    // from the input tool (and from CGEvent.location) render at the correct Y.
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    func movePointer(to globalPoint: CGPoint) {
        if let current = pointerPosition,
           abs(current.x - globalPoint.x) < 0.5,
           abs(current.y - globalPoint.y) < 0.5 {
            return
        }
        pointerPosition = globalPoint
        needsDisplay = true
    }

    func performClickAnimation() {
        clickAnimationStart = CACurrentMediaTime()
        ensureAnimationTimer()
        needsDisplay = true
    }

    func showScroll(deltaX: Double, deltaY: Double) {
        scrollPulse = 1.0
        let magnitude = sqrt((deltaX * deltaX) + (deltaY * deltaY))
        if magnitude > 0.001 {
            // View is flipped (y-down). Keep the vector in the same space.
            scrollVector = CGVector(dx: deltaX / magnitude, dy: deltaY / magnitude)
        } else {
            scrollVector = CGVector(dx: 0, dy: 1)
        }
        ensureAnimationTimer()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let pointerPosition,
              let context = NSGraphicsContext.current?.cgContext else { return }

        let localPoint = CGPoint(
            x: pointerPosition.x - desktopFrame.origin.x,
            y: pointerPosition.y - desktopFrame.origin.y
        )

        context.saveGState()
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        drawScrollAccent(in: context, at: localPoint)
        drawPointer(in: context, at: localPoint)

        context.restoreGState()
    }

    private func ensureAnimationTimer() {
        guard animationTimer == nil else { return }

        lastTick = CACurrentMediaTime()
        animationTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(handleAnimationTimer),
            userInfo: nil,
            repeats: true
        )

        if let animationTimer {
            RunLoop.main.add(animationTimer, forMode: .common)
        }
    }

    @objc
    private func handleAnimationTimer() {
        let now = CACurrentMediaTime()
        let delta = now - lastTick
        lastTick = now

        scrollPulse = max(0, scrollPulse - CGFloat(delta * 2.2))

        if let start = clickAnimationStart, now - start >= Self.clickAnimationDuration {
            clickAnimationStart = nil
        }

        needsDisplay = true

        if clickAnimationStart == nil && scrollPulse <= 0.001 {
            animationTimer?.invalidate()
            animationTimer = nil
        }
    }

    private func currentPointerScale() -> CGFloat {
        guard let start = clickAnimationStart else { return 1.0 }
        let elapsed = CACurrentMediaTime() - start
        let duration = Self.clickAnimationDuration
        guard elapsed < duration else { return 1.0 }

        // First half: shrink 1.0 → minScale. Second half: return minScale → 1.0.
        let progress = CGFloat(elapsed / duration)
        if progress < 0.5 {
            let t = progress * 2
            return 1.0 - (1.0 - Self.clickMinScale) * easeOutQuad(t)
        } else {
            let t = (progress - 0.5) * 2
            return Self.clickMinScale + (1.0 - Self.clickMinScale) * easeOutQuad(t)
        }
    }

    private func easeOutQuad(_ t: CGFloat) -> CGFloat {
        1 - (1 - t) * (1 - t)
    }

    private func drawPointer(in context: CGContext, at point: CGPoint) {
        let clickScale = currentPointerScale()

        // Ported from the reference SVG (viewBox 0 0 24 24), wrapped in
        //   <g transform="rotate(18 12 12)"> ... </g>
        // The shape is filled at 50% white and stroked at 95% white with a
        // 1.4 pt rounded-join outline. Tip is at (5.1, 4.4) in viewBox coords.
        let rawPath = CGMutablePath()
        rawPath.move(to: CGPoint(x: 5.1, y: 4.4))
        rawPath.addCurve(
            to: CGPoint(x: 3.8, y: 5.7),
            control1: CGPoint(x: 4.2, y: 4.0),
            control2: CGPoint(x: 3.4, y: 4.8)
        )
        rawPath.addLine(to: CGPoint(x: 8.1, y: 15.6))
        rawPath.addCurve(
            to: CGPoint(x: 10.2, y: 15.7),
            control1: CGPoint(x: 8.5, y: 16.5),
            control2: CGPoint(x: 9.7, y: 16.6)
        )
        rawPath.addLine(to: CGPoint(x: 11.6, y: 13.0))
        rawPath.addLine(to: CGPoint(x: 14.4, y: 11.7))
        rawPath.addCurve(
            to: CGPoint(x: 14.4, y: 9.6),
            control1: CGPoint(x: 15.3, y: 11.3),
            control2: CGPoint(x: 15.3, y: 10.0)
        )
        rawPath.addLine(to: CGPoint(x: 5.1, y: 4.4))
        rawPath.closeSubpath()

        // Composite transform for the SVG's own scale + rotation: scale(1.5)
        // applied on top of rotate(18°) around the viewBox centre (12, 12).
        // Computing the tip's post-transform position lets us translate the
        // final shape so the tip lands exactly on the cursor point.
        let rotationAngle = 18.0 * .pi / 180.0
        var svgTransform = CGAffineTransform.identity
        svgTransform = svgTransform.scaledBy(x: 1.5, y: 1.5)
        svgTransform = svgTransform.translatedBy(x: 12, y: 12)
        svgTransform = svgTransform.rotated(by: rotationAngle)
        svgTransform = svgTransform.translatedBy(x: -12, y: -12)
        let tipAfter = CGPoint(x: 5.1, y: 4.4).applying(svgTransform)

        context.saveGState()

        // Click animation scale, pivoted on the cursor tip.
        context.translateBy(x: point.x, y: point.y)
        context.scaleBy(x: clickScale, y: clickScale)

        // Shift so the transformed tip lands at (0, 0) within this frame.
        context.translateBy(x: -tipAfter.x, y: -tipAfter.y)

        // Replicate the SVG: scale(1.5) outside, rotate(18 12 12) inside.
        context.scaleBy(x: 1.5, y: 1.5)
        context.translateBy(x: 12, y: 12)
        context.rotate(by: rotationAngle)
        context.translateBy(x: -12, y: -12)

        // Dark drop shadow so the pointer reads against any background.
        context.setShadow(
            offset: CGSize(width: 0.4, height: 1.2),
            blur: 4.0,
            color: NSColor(calibratedWhite: 0, alpha: 0.55).cgColor
        )

        context.addPath(rawPath)
        context.setFillColor(NSColor(calibratedWhite: 1.0, alpha: 0.5).cgColor)
        context.fillPath()

        context.addPath(rawPath)
        context.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.95).cgColor)
        context.setLineWidth(1.4)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.strokePath()

        context.restoreGState()
    }

    private func drawScrollAccent(in context: CGContext, at point: CGPoint) {
        guard scrollPulse > 0.001 else { return }

        // Anchor the scroll accents just below the pointer tip.
        let center = CGPoint(x: point.x + 7, y: point.y + 14)
        let vector = normalized(scrollVector)
        let angle = atan2(vector.dy, vector.dx)

        for index in 0..<3 {
            let spacing = CGFloat(index) * 8
            let alpha = scrollPulse * (0.32 - CGFloat(index) * 0.08)
            let width = 9 + (scrollPulse * 10) - CGFloat(index)
            let height = 3 + (scrollPulse * 2)

            context.saveGState()
            context.translateBy(
                x: center.x - (vector.dx * spacing),
                y: center.y - (vector.dy * spacing)
            )
            context.rotate(by: angle)
            let rect = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
            let path = CGPath(
                roundedRect: rect,
                cornerWidth: height / 2,
                cornerHeight: height / 2,
                transform: nil
            )
            context.addPath(path)
            context.setFillColor(NSColor(calibratedWhite: 1.0, alpha: alpha).cgColor)
            context.setShadow(
                offset: CGSize(width: 0, height: 1),
                blur: 2.5,
                color: NSColor(calibratedWhite: 0, alpha: 0.4).cgColor
            )
            context.fillPath()
            context.restoreGState()
        }
    }

    private func normalized(_ vector: CGVector) -> CGVector {
        let length = max(0.001, sqrt((vector.dx * vector.dx) + (vector.dy * vector.dy)))
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }
}
