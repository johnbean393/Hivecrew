//
//  CompactCallNotch.swift
//  Hivecrew
//
//  DynamicNotchKit integration for the compact in-call HUD.
//  Provides compact leading/trailing views (tiny orb + recording dot)
//  and expands on hover to show the full CompactHUDContentView.
//

import SwiftUI
import DynamicNotchKit
import HivecrewVoice

// MARK: - Compact Leading: Tiny Orb

struct NotchCompactLeading: View {
    @EnvironmentObject var orchestrator: VoiceOrchestrator

    var body: some View {
        VoiceOrbView(
            inputLevel: orchestrator.inputLevel,
            outputLevel: orchestrator.outputLevel,
            isConnected: orchestrator.connectionState == .connected || orchestrator.connectionState == .reconnecting,
            isModelSpeaking: orchestrator.isModelSpeaking,
            size: 16
        )
        .clipShape(Circle())
    }
}

// MARK: - Compact Trailing: Recording Indicator

struct NotchCompactTrailing: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 0.4 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}

// MARK: - Factory

/// Type-erased wrapper so `.environmentObject()` doesn't change the concrete
/// view type expected by DynamicNotch's generic parameters.
struct NotchExpandedContent: View {
    let orchestrator: VoiceOrchestrator
    let taskService: TaskService
    let compactCallManager: CompactCallManager

    var body: some View {
        CompactHUDContentView()
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: CompactShareHUDPanel.panelWidth)
            .environmentObject(orchestrator)
            .environmentObject(taskService)
            .environmentObject(compactCallManager)
    }
}

struct NotchLeadingContent: View {
    let orchestrator: VoiceOrchestrator

    var body: some View {
        NotchCompactLeading()
            .environmentObject(orchestrator)
    }
}

@MainActor
func makeCompactCallNotch(
    orchestrator: VoiceOrchestrator,
    taskService: TaskService,
    compactCallManager: CompactCallManager
) -> DynamicNotch<NotchExpandedContent, NotchLeadingContent, NotchCompactTrailing> {
    DynamicNotch(
        hoverBehavior: .all,
        style: .auto,
        expanded: {
            NotchExpandedContent(
                orchestrator: orchestrator,
                taskService: taskService,
                compactCallManager: compactCallManager
            )
        },
        compactLeading: {
            NotchLeadingContent(orchestrator: orchestrator)
        },
        compactTrailing: {
            NotchCompactTrailing()
        }
    )
}
