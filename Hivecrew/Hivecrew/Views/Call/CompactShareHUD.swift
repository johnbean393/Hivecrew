//
//  CompactShareHUD.swift
//  Hivecrew
//
//  Floating NSPanel HUD for when the user is sharing video while working in
//  other apps. Shows a mini orb, status, worker count, and basic controls.
//

import SwiftUI
import AppKit
import HivecrewVoice

final class CompactShareHUDPanel: NSPanel {

    init(orchestrator: VoiceOrchestrator) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = CompactShareHUDContent()
            .environmentObject(orchestrator)

        contentView = NSHostingView(rootView: view)

        // Position at top-center of main screen
        if let screen = NSScreen.main {
            let x = (screen.frame.width - 320) / 2
            let y = screen.frame.height - 120
            setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}

struct CompactShareHUDContent: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator

    var body: some View {
        HStack(spacing: 12) {
            VoiceOrbView(
                inputLevel: orchestrator.inputLevel,
                outputLevel: orchestrator.outputLevel,
                isConnected: orchestrator.connectionState == .connected || orchestrator.connectionState == .reconnecting,
                isModelSpeaking: orchestrator.isModelSpeaking,
                size: 48
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(orchestrator.connectionState == .reconnecting ? "Reconnecting…" :
                     orchestrator.isModelSpeaking ? "Speaking" : "Listening")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                Text("\(orchestrator.workerRegistry.workers.count) workers")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.6))
            }

            Spacer()

            // Mic
            Button {
                orchestrator.isMuted.toggle()
            } label: {
                Image(systemName: orchestrator.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            // End
            Button {
                orchestrator.endCall()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color(red: 0.96, green: 0.26, blue: 0.21), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
        .frame(width: 320, height: 80)
    }
}
