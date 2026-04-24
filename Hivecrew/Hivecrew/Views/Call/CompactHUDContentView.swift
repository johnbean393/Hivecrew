//
//  CompactHUDContentView.swift
//  Hivecrew
//
//  Shared content view used by both the floating NSPanel HUD and the
//  DynamicNotch expanded view. Shows mini orb, speaker/transcript,
//  task counter, controls, and a transient task-change tray.
//

import SwiftUI
import HivecrewVoice
import HivecrewCore

struct CompactHUDContentView: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator
    @EnvironmentObject var taskService: TaskService
    @EnvironmentObject var compactCallManager: CompactCallManager

    var body: some View {
        VStack(spacing: 0) {
            topRow
            transcriptRow
            controlRow
            taskChangeTray
        }
        .animation(.easeInOut(duration: 0.25), value: lastTranscriptSnippet)
    }

    // MARK: - Top Row: Orb + Speaker + Task Counter

    private var topRow: some View {
        HStack(spacing: 10) {
            VoiceOrbView(
                inputLevel: orchestrator.inputLevel,
                outputLevel: orchestrator.outputLevel,
                isConnected: orchestrator.connectionState == .connected || orchestrator.connectionState == .reconnecting,
                isModelSpeaking: orchestrator.isModelSpeaking,
                size: 32
            )

            Text(currentSpeakerLabel)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)

            Spacer(minLength: 4)

            taskCounterPill
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: - Transcript Row

    private var transcriptRow: some View {
        Text(lastTranscriptSnippet ?? String(localized: "Start speaking to the voice agent…"))
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(lastTranscriptSnippet != nil ? 0.6 : 0.3))
            .italic(lastTranscriptSnippet == nil)
            .lineLimit(8)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
    }

    private var currentSpeakerLabel: String {
        if orchestrator.isModelSpeaking {
            return orchestrator.voiceName.capitalized
        }
        if let lastEntry = orchestrator.transcript.last(where: { if case .text = $0.content { return true } else { return false } }) {
            return lastEntry.role == .user ? String(localized: "You") : orchestrator.voiceName.capitalized
        }
        return String(localized: "Listening")
    }

    private var lastTranscriptSnippet: String? {
        guard let lastEntry = orchestrator.transcript.last(where: { if case .text = $0.content { return true } else { return false } }) else {
            return nil
        }
        let text = lastEntry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private var taskCounterPill: some View {
        let running = taskService.activeTasks.count
        let queued = taskService.queuedTasks.count

        return Group {
            if running > 0 || queued > 0 {
                Text("\(running) running · \(queued) queued")
                    .textSelection(.disabled)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.15), in: Capsule())
            }
        }
    }

    // MARK: - Control Row

    private var controlRow: some View {
        HStack(spacing: 0) {
            compactButton(
                icon: orchestrator.isMuted ? "mic.slash.fill" : "mic.fill",
                label: orchestrator.isMuted ? String(localized: "Unmute") : String(localized: "Mute")
            ) {
                orchestrator.isMuted.toggle()
            }

            Spacer()

            compactButton(
                icon: "arrow.up.left.and.arrow.down.right",
                label: String(localized: "Expand")
            ) {
                compactCallManager.exitCompactMode()
            }

            if orchestrator.supportsVideoInput, case .screen = orchestrator.videoSourceManager.activeSource {
                Spacer()

                compactButton(
                    icon: "rectangle.on.rectangle.slash",
                    label: String(localized: "Stop Share")
                ) {
                    Task { await orchestrator.videoSourceManager.deactivate() }
                }
            }

            Spacer()

            Button {
                orchestrator.endCall()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("End")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(red: 0.96, green: 0.26, blue: 0.21), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func compactButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Task Change Tray

    @ViewBuilder
    private var taskChangeTray: some View {
        if !compactCallManager.recentTaskChanges.isEmpty {
            VStack(spacing: 4) {
                Divider()
                    .background(.white.opacity(0.2))

                ForEach(compactCallManager.recentTaskChanges) { entry in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(for: entry.status))
                            .frame(width: 6, height: 6)

                        Text(entry.taskTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        Text(entry.status.displayName)
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.horizontal, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func statusColor(for status: TaskStatus) -> Color {
        switch status {
        case .running: .green
        case .completed: .green
        case .failed, .cancelled: .red
        case .queued, .waitingForVM, .paused, .planning, .planReview: .yellow
        case .timedOut, .maxIterations: .orange
        case .planFailed: .red
        case .writebackReview: .blue
        }
    }
}
