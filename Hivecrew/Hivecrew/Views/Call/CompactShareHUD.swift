//
//  CompactShareHUD.swift
//  Hivecrew
//
//  Floating NSPanel HUD for when the user is in compact call mode.
//  Shows a mini orb, speaker/transcript, task counter, controls,
//  and a transient task-change tray. Positioned top-right of the
//  target screen, draggable by background.
//

import SwiftUI
import AppKit
import HivecrewVoice

// MARK: - Panel

final class CompactShareHUDPanel: NSPanel {

    static let panelWidth: CGFloat = 340
    private var topEdgeY: CGFloat = 0
    private var moveObserver: NSObjectProtocol?
    private var heightPollTimer: Timer?
    private var lastAppliedHeight: CGFloat = 0
    private var isResizing = false

    init(
        orchestrator: VoiceOrchestrator,
        taskService: TaskService,
        compactCallManager: CompactCallManager,
        targetScreen: NSScreen? = nil
    ) {
        let initialHeight: CGFloat = 200
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: initialHeight),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let hv = NSHostingView(
            rootView: CompactShareHUDContent()
                .environmentObject(orchestrator)
                .environmentObject(taskService)
                .environmentObject(compactCallManager)
        )
        hv.translatesAutoresizingMaskIntoConstraints = false
        contentView = hv

        if let cv = contentView {
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: cv.topAnchor),
                hv.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                hv.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            ])
        }

        let screen = targetScreen ?? NSScreen.main
        if let screen {
            let x = screen.visibleFrame.maxX - Self.panelWidth - 16
            let y = screen.visibleFrame.maxY - initialHeight - 16
            setFrameOrigin(NSPoint(x: x, y: y))
        }

        topEdgeY = frame.maxY
        lastAppliedHeight = initialHeight

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.isResizing else { return }
            self.topEdgeY = self.frame.maxY
        }

        heightPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.syncHeightFromContent()
        }

        DispatchQueue.main.async { [weak self] in
            self?.syncHeightFromContent()
        }
    }

    private func syncHeightFromContent() {
        guard !isResizing, let hv = contentView?.subviews.first ?? contentView else { return }

        let ideal = hv.fittingSize
        let h = ceil(max(ideal.height, 60))
        guard abs(lastAppliedHeight - h) > 1.0 else { return }

        isResizing = true

        let newFrame = NSRect(
            x: frame.origin.x,
            y: topEdgeY - h,
            width: Self.panelWidth,
            height: h
        )

        if lastAppliedHeight == 200 {
            lastAppliedHeight = h
            setFrame(newFrame, display: true)
            isResizing = false
        } else {
            lastAppliedHeight = h
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.animator().setFrame(newFrame, display: true)
            }, completionHandler: { [weak self] in
                self?.isResizing = false
            })
        }
    }

    deinit {
        heightPollTimer?.invalidate()
        if let obs = moveObserver { NotificationCenter.default.removeObserver(obs) }
    }
}

// MARK: - SwiftUI Content

struct CompactShareHUDContent: View {

    var body: some View {
        CompactHUDContentView()
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: CompactShareHUDPanel.panelWidth)
            .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
            .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
