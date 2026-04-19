//
//  IdleCallView.swift
//  Hivecrew
//
//  Shown when no call is active. Centered orb with start buttons.
//

import SwiftUI
import HivecrewVoice

struct IdleCallView: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator
    @State private var showSettingsPopover = false
    @State private var showVideoSourcePicker = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VoiceOrbView(
                inputLevel: 0,
                outputLevel: 0,
                isConnected: false,
                isModelSpeaking: false,
                size: 180
            )

            Text("Start a voice session")
                .font(.title3)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                CallControlButton(
                    icon: "phone.fill",
                    color: Color(red: 0.2, green: 0.78, blue: 0.35),
                    size: 64,
                    iconSize: 28
                ) {
                    NotificationCenter.default.post(name: .startVoiceCall, object: nil)
                }

                CallControlButton(
                    icon: "video.fill",
                    color: .blue,
                    size: 64,
                    iconSize: 24
                ) {
                    showVideoSourcePicker.toggle()
                }
                .popover(isPresented: $showVideoSourcePicker) {
                    InputSourcePickerView(startCallOnSelection: true)
                        .environmentObject(orchestrator)
                        .frame(minWidth: 320, minHeight: 200)
                }

                CallControlButton(
                    icon: "slider.horizontal.3",
                    color: Color.gray.opacity(0.35),
                    size: 48,
                    iconSize: 20
                ) {
                    showSettingsPopover.toggle()
                }
                .popover(isPresented: $showSettingsPopover) {
                    VoiceSettingsPopover()
                        .environmentObject(orchestrator)
                }
            }

            if case .error(let msg) = orchestrator.connectionState {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .frame(maxWidth: 400)
                    .textSelection(.enabled)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shared popover for voice call settings (voice, thinking, web search, thought summaries).
/// Used by both IdleCallView and CallControlBar.
struct VoiceSettingsPopover: View {

    @EnvironmentObject var orchestrator: VoiceOrchestrator

    private var currentProviderType: VoiceProviderType? {
        VoiceProviderType(rawValue: orchestrator.voiceProviderTypeRaw)
    }

    private var voicesForCurrentProvider: [RealtimeVoiceOption] {
        switch currentProviderType {
        case .openAI, .chatGPTOAuth:
            return RealtimeVoiceCatalog.openAIVoices
        default:
            return RealtimeVoiceCatalog.geminiVoices
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Voice", selection: $orchestrator.voiceName) {
                ForEach(voicesForCurrentProvider) { voice in
                    let label = voice.descriptor.map { "\(voice.displayName.capitalized) — \($0)" }
                        ?? voice.displayName.capitalized
                    Text(label).tag(voice.id)
                }
            }
            .labelsHidden()

            Divider()

            VoiceInputControlsSection(
                audioManager: orchestrator.audioManager,
                inputDeviceIDRaw: Binding(
                    get: { orchestrator.inputDeviceIDRaw },
                    set: { orchestrator.inputDeviceIDRaw = $0 }
                )
            )

            if currentProviderType == .gemini {
                Toggle("Web Search", isOn: $orchestrator.webSearchEnabled)
                    .toggleStyle(.switch)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Thinking")
                        .font(.subheadline)

                    Picker("Level", selection: $orchestrator.thinkingLevelRaw) {
                        Text("Minimal").tag("minimal")
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    Toggle("Thought Summaries", isOn: $orchestrator.includeThoughts)
                }
            }
        }
        .padding()
        .frame(width: 360)
    }
}
