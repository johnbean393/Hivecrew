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
                    Task { await orchestrator.startCall() }
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

    private let availableVoices: [(name: String, descriptor: String)] = [
        ("Zephyr", "Bright"),
        ("Puck", "Upbeat"),
        ("Charon", "Informative"),
        ("Kore", "Firm"),
        ("Fenrir", "Excitable"),
        ("Leda", "Youthful"),
        ("Orus", "Firm"),
        ("Aoede", "Breezy"),
        ("Callirrhoe", "Easy-going"),
        ("Autonoe", "Bright"),
        ("Enceladus", "Breathy"),
        ("Iapetus", "Clear"),
        ("Umbriel", "Easy-going"),
        ("Algieba", "Smooth"),
        ("Despina", "Smooth"),
        ("Erinome", "Clear"),
        ("Algenib", "Gravelly"),
        ("Rasalgethi", "Informative"),
        ("Laomedeia", "Upbeat"),
        ("Achernar", "Soft"),
        ("Alnilam", "Firm"),
        ("Schedar", "Even"),
        ("Gacrux", "Mature"),
        ("Pulcherrima", "Forward"),
        ("Achird", "Friendly"),
        ("Zubenelgenubi", "Casual"),
        ("Vindemiatrix", "Gentle"),
        ("Sadachbia", "Lively"),
        ("Sadaltager", "Knowledgeable"),
        ("Sulafat", "Warm"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Voice", selection: $orchestrator.voiceName) {
                ForEach(availableVoices, id: \.name) { voice in
                    Text("\(voice.name) — \(voice.descriptor)").tag(voice.name)
                }
            }
            .labelsHidden()

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
        .padding()
        .frame(width: 300)
    }
}
