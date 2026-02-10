//
//  PromptModelHoverPanel.swift
//  Hivecrew
//
//  Floating hover panel infrastructure for model metadata previews.
//

import AppKit
import Combine
import SwiftUI

struct ModelListViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

@MainActor
final class ModelHoverInfoPanelController: ObservableObject {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private var hideWorkItem: DispatchWorkItem?
    private var isRowHovered: Bool = false
    private var isPanelHovered: Bool = false
    
    func show(content: AnyView, anchorRowFrame: CGRect, horizontalOffset: CGFloat = 0) {
        ensurePanelExists()
        cancelScheduledHide()
        
        hostingView?.rootView = content
        
        guard let panel, let hostingView else { return }
        
        let fittingSize = hostingView.fittingSize
        let panelWidth = max(380, min(460, fittingSize.width))
        let panelHeight = max(220, min(540, fittingSize.height))
        
        var originX = anchorRowFrame.maxX + 10 + horizontalOffset
        var originY = anchorRowFrame.maxY - panelHeight
        
        if let screen = screenContaining(point: CGPoint(x: anchorRowFrame.midX, y: anchorRowFrame.midY)) {
            let visible = screen.visibleFrame
            
            // Prefer right side of the row; fall back to left side when needed.
            if originX + panelWidth > visible.maxX {
                originX = anchorRowFrame.minX - panelWidth - 10
            }
            originX = max(visible.minX + 8, min(originX, visible.maxX - panelWidth - 8))
            
            originY = max(visible.minY + 8, min(originY, visible.maxY - panelHeight - 8))
        }
        
        panel.setFrame(
            NSRect(x: originX, y: originY, width: panelWidth, height: panelHeight),
            display: true
        )
        panel.orderFront(nil)
    }
    
    func setRowHovered(_ hovered: Bool) {
        isRowHovered = hovered
        if hovered {
            cancelScheduledHide()
        } else {
            scheduleHideIfNeeded()
        }
    }
    
    func setPanelHovered(_ hovered: Bool) {
        isPanelHovered = hovered
        if hovered {
            cancelScheduledHide()
        } else {
            scheduleHideIfNeeded()
        }
    }
    
    func hide() {
        cancelScheduledHide()
        isRowHovered = false
        isPanelHovered = false
        panel?.orderOut(nil)
    }
    
    private func ensurePanelExists() {
        if panel != nil {
            return
        }
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 320),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        
        let hosting = NSHostingView(rootView: AnyView(EmptyView()))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        
        self.panel = panel
        self.hostingView = hosting
    }
    
    private func scheduleHideIfNeeded() {
        guard !isRowHovered && !isPanelHovered else { return }
        cancelScheduledHide()
        
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isRowHovered && !self.isPanelHovered {
                self.hide()
            }
        }
        hideWorkItem = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: task)
    }
    
    private func cancelScheduledHide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
    }
    
    private func screenContaining(point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
    }
}

struct ScreenFrameReader: NSViewRepresentable {
    let onFrameChange: (CGRect) -> Void
    
    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onFrameChange = onFrameChange
        return view
    }
    
    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onFrameChange = onFrameChange
        nsView.reportFrame()
    }
    
    final class TrackingView: NSView {
        var onFrameChange: ((CGRect) -> Void)?
        
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportFrame()
        }
        
        override func layout() {
            super.layout()
            reportFrame()
        }
        
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            reportFrame()
        }
        
        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            reportFrame()
        }
        
        func reportFrame() {
            guard let window else { return }
            let rectInWindow = convert(bounds, to: nil)
            let rectOnScreen = window.convertToScreen(rectInWindow)
            DispatchQueue.main.async { [weak self] in
                self?.onFrameChange?(rectOnScreen)
            }
        }
    }
}
