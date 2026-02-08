//
//  PairingWindowController.swift
//  Hivecrew
//
//  Floating window controller for device pairing approval
//

import AppKit
import SwiftUI
import HivecrewAPI

// MARK: - Custom Panel

/// Custom NSPanel subclass that can become key for text input
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Controller for a floating pairing approval window that appears over all apps
@MainActor
final class PairingWindowController {
    
    // MARK: - Singleton
    
    static let shared = PairingWindowController()
    
    // MARK: - Properties
    
    private var panel: NSPanel?
    private var currentRequestId: String?
    
    private init() {}
    
    // MARK: - Public API
    
    /// Show a pairing approval window for the given request
    func showPairingRequest(_ request: APIPairingRequest) {
        // Close any existing panel
        closePanel()
        
        currentRequestId = request.id
        
        let panel = createPanel(for: request)
        self.panel = panel
        
        centerPanel(panel)
        
        // Show the panel and make it key for text input
        panel.orderFrontRegardless()
        panel.makeKey()
        
        // Play an attention sound
        NSSound.beep()
    }
    
    /// Close the pairing window
    func closePanel() {
        panel?.close()
        panel = nil
        currentRequestId = nil
    }
    
    /// Whether a specific request is currently being shown
    func isShowing(requestId: String) -> Bool {
        currentRequestId == requestId
    }
    
    // MARK: - Panel Creation
    
    private func createPanel(for request: APIPairingRequest) -> NSPanel {
        let pairingView = FloatingPairingView(
            request: request,
            onApprove: { [weak self] customName in
                Task {
                    await DeviceAuthService.shared.approvePairing(id: request.id, customName: customName)
                }
                self?.closePanel()
            },
            onReject: { [weak self] in
                Task {
                    await DeviceAuthService.shared.rejectPairing(id: request.id)
                }
                self?.closePanel()
            }
        )
        
        let hostingView = NSHostingView(rootView: pairingView)
        hostingView.setFrameSize(hostingView.fittingSize)
        
        let contentSize = hostingView.fittingSize
        let panelSize = NSSize(
            width: max(contentSize.width, 380),
            height: max(contentSize.height, 200)
        )
        
        let panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        // Float above other windows but not as aggressively as the question window
        panel.level = .floating
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = false
        
        // Visual effect background
        let visualEffectView = NSVisualEffectView()
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.material = .hudWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 12
        visualEffectView.layer?.masksToBounds = true
        
        visualEffectView.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
            hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor)
        ])
        
        panel.contentView = visualEffectView
        
        let finalSize = hostingView.fittingSize
        panel.setContentSize(NSSize(
            width: max(finalSize.width, 380),
            height: max(finalSize.height, 200)
        ))
        
        return panel
    }
    
    private func centerPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        
        let screenFrame = screen.visibleFrame
        let panelFrame = panel.frame
        
        let x = screenFrame.midX - panelFrame.width / 2
        let y = screenFrame.midY - panelFrame.height / 2 + 80
        
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Floating Pairing View

/// SwiftUI view for the floating pairing approval panel
private struct FloatingPairingView: View {
    let request: APIPairingRequest
    let onApprove: (String?) -> Void
    let onReject: () -> Void
    
    @State private var deviceName: String
    
    init(request: APIPairingRequest, onApprove: @escaping (String?) -> Void, onReject: @escaping () -> Void) {
        self.request = request
        self.onApprove = onApprove
        self.onReject = onReject
        self._deviceName = State(initialValue: request.deviceInfo.displayName)
    }
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "link.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.blue)
                
                Text("Device Pairing Request")
                    .font(.headline)
            }
            
            // Pairing code display
            VStack(spacing: 8) {
                Text("Verify this code matches the one in the browser:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                
                HStack(spacing: 16) {
                    Text(String(request.code.prefix(3)))
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                    
                    Text(String(request.code.suffix(3)))
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
            }
            
            // Device info
            HStack(spacing: 6) {
                Image(systemName: deviceTypeIcon)
                    .foregroundStyle(.secondary)
                Text(request.deviceInfo.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            // Device name field
            VStack(alignment: .leading, spacing: 4) {
                Text("Device name:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                TextField("Device name", text: $deviceName)
                    .textFieldStyle(.roundedBorder)
            }
            
            // Action buttons
            HStack(spacing: 12) {
                Button("Reject") {
                    onReject()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])
                
                Button("Approve") {
                    let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
                    onApprove(name.isEmpty ? nil : name)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(24)
        .frame(width: 360)
        .background(Color.clear)
    }
    
    private var deviceTypeIcon: String {
        switch request.deviceInfo.deviceType {
        case .desktop: return "desktopcomputer"
        case .mobile: return "iphone"
        case .tablet: return "ipad"
        }
    }
}
