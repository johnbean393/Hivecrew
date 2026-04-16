//
//  VoiceCallView.swift
//  Hivelink
//
//  Main Call tab: setup → idle → active call, styled after the macOS Hivecrew app.
//

import AVFoundation
import SwiftUI
import HivecrewCore
import HivecrewVoice

struct VoiceCallView: View {
    @EnvironmentObject private var orchestrator: HivelinkVoiceOrchestrator

    var body: some View {
        Group {
            if !orchestrator.isVoiceConfigured {
                VoiceSetupFlowView()
            } else if orchestrator.callState == .idle {
                idleView
            } else {
                activeCallView
            }
        }
        .navigationTitle("Hivelink")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Idle

    private var idleView: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            VStack(spacing: isLandscape ? 24 : 32) {
                Spacer()

                if isLandscape {
                    HStack(spacing: 40) {
                        idleOrbSection

                        idleButtonColumn
                    }
                } else {
                    VStack(spacing: 32) {
                        idleOrbSection
                        idleButtonRow
                    }
                }

                if case .error(let message) = orchestrator.connectionState {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .lineLimit(nil)
                        .padding(.horizontal, 32)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
        }
    }

    private var idleOrbSection: some View {
        VStack(spacing: 32) {
            VoiceOrbView(
                inputLevel: 0,
                outputLevel: 0,
                isConnected: false,
                isModelSpeaking: false,
                size: 180
            )

            Text("Start a voice session")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var idleButtonRow: some View {
        HStack(spacing: 16) {
            idleVoiceButton
            idleVideoButton
        }
    }

    private var idleButtonColumn: some View {
        VStack(spacing: 16) {
            idleVoiceButton
            idleVideoButton
        }
    }

    private var idleVoiceButton: some View {
        CallControlButton(
            icon: "phone.fill",
            color: Color(red: 0.2, green: 0.78, blue: 0.35),
            size: 64,
            iconSize: 28
        ) {
            orchestrator.startCall(video: false)
        }
    }

    private var idleVideoButton: some View {
        CallControlButton(
            icon: "video.fill",
            color: .blue,
            size: 64,
            iconSize: 24
        ) {
            orchestrator.startCall(video: true)
        }
    }

    // MARK: - Active Call

    private var activeCallView: some View {
        VStack(spacing: 0) {
            orbSection
                .padding(.top, 8)
                .padding(.bottom, 4)

            TranscriptView(entries: orchestrator.transcript)
                .frame(maxHeight: .infinity)

            if !orchestrator.workerRegistry.workers.isEmpty {
                workerPills
                    .padding(.top, 4)
                    .padding(.bottom, 4)
            }

            controlBar
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .overlay {
            if orchestrator.callState == .suspended {
                suspendedOverlay
            }
        }
    }

    // MARK: - Suspended Overlay

    private var suspendedOverlay: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.title2)
                        .foregroundStyle(.yellow)
                    Text("Call paused to save costs")
                        .font(.subheadline.weight(.medium))
                }

                Text("Resume the session when you're ready to continue.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button {
                        Task { await orchestrator.resumeCall() }
                    } label: {
                        Label("Resume", systemImage: "mic.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button {
                        orchestrator.endCall()
                    } label: {
                        Label("End Call", systemImage: "phone.down.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.regular)
                }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 16)
            .padding(.bottom, 80)
        }
    }

    // MARK: - Orb Section

    private var activeCameraSession: AVCaptureSession? {
        if orchestrator.activeInputSource == .camera, orchestrator.cameraCapture.isCapturing {
            return orchestrator.cameraCapture.captureSession
        }
        return nil
    }

    private var orbSection: some View {
        VStack(spacing: 8) {
            VoiceOrbView(
                inputLevel: orchestrator.inputLevel,
                outputLevel: orchestrator.outputLevel,
                isConnected: orchestrator.connectionState == .connected
                    || orchestrator.connectionState == .reconnecting,
                isModelSpeaking: orchestrator.isModelSpeaking,
                size: 140,
                cameraSession: activeCameraSession
            )

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if orchestrator.callState == .suspended {
            return "Paused"
        }
        switch orchestrator.connectionState {
        case .error(let msg): return "Error: \(msg)"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .connected:
            return orchestrator.isModelSpeaking ? "Speaking" : "Listening"
        case .disconnected:
            return "Disconnected"
        }
    }

    // MARK: - Control Bar

    @State private var showSourcePicker = false

    private var videoActive: Bool {
        orchestrator.activeInputSource == .camera
    }

    private var controlBar: some View {
        HStack(spacing: 20) {
            CallControlButton(
                icon: orchestrator.isMuted ? "mic.slash.fill" : "mic.fill",
                color: orchestrator.isMuted ? Color(red: 0.96, green: 0.26, blue: 0.21) : .black
            ) {
                orchestrator.toggleMute()
            }

            CallControlButton(
                icon: videoActive ? "video.fill" : "video.slash.fill",
                color: videoActive ? .blue : .black
            ) {
                showSourcePicker = true
            }
            .sheet(isPresented: $showSourcePicker) {
                InputSourcePickerView()
                    .environmentObject(orchestrator)
            }

            CallControlButton(
                icon: "xmark",
                color: Color(red: 0.96, green: 0.26, blue: 0.21)
            ) {
                orchestrator.endCall()
            }
        }
    }

    // MARK: - Worker Pills

    private var workerPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(orchestrator.workerRegistry.workers) { worker in
                    workerPill(worker)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func workerPill(_ worker: WorkerIdentity) -> some View {
        let isFocused = orchestrator.focusedTaskId == worker.id

        return HStack(spacing: 4) {
            Circle()
                .fill(statusColor(for: worker.id))
                .frame(width: 6, height: 6)
            Text(worker.displayName)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            isFocused ? Color.accentColor.opacity(0.15) : Color(.systemGray6),
            in: Capsule()
        )
        .overlay(
            Capsule()
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
        )
    }

    private func statusColor(for taskId: String) -> Color {
        guard let task = orchestrator.taskService?.tasks.first(where: { $0.id == taskId }) else {
            return .gray
        }
        switch task.status {
        case .running, .waitingForVM:
            return .green
        case .completed:
            return .blue
        case .failed, .timedOut, .maxIterations, .planFailed:
            return .red
        case .cancelled:
            return .orange
        case .paused:
            return .yellow
        default:
            return .gray
        }
    }
}

// MARK: - Call Control Button (iOS port)

struct CallControlButton: View {
    let icon: String
    let color: Color
    var size: CGFloat = 52
    var iconSize: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                color.opacity(0.9),
                                color,
                                color.mix(with: .black, by: 0.25)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                    )
                    .shadow(color: color.opacity(0.4), radius: 6, y: 3)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)

                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Orchestrator Helpers

extension HivelinkVoiceOrchestrator {
    var voiceDisplayName: String {
        let name = UserDefaults.standard.string(forKey: "hivelink.voiceName")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Leda" : name
    }
}

#Preview {
    NavigationStack {
        VoiceCallView()
            .environmentObject(HivelinkVoiceOrchestrator())
    }
}
