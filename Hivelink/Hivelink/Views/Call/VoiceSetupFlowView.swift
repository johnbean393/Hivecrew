//
//  VoiceSetupFlowView.swift
//  Hivelink
//
//  Initial voice configuration: provider, API key, voice name.
//

import SwiftUI
import HivecrewVoice

struct VoiceSetupFlowView: View {
    @EnvironmentObject private var orchestrator: HivelinkVoiceOrchestrator

    @AppStorage("hivelink.voiceProvider") private var voiceProvider = "gemini"
    @AppStorage("hivelink.voiceApiKey") private var voiceApiKey = ""
    @AppStorage("hivelink.voiceName") private var voiceName = "Leda"

    @State private var editingKey = ""
    @State private var editingName = ""
    @State private var showingKey = false

    private var isValid: Bool {
        !editingKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)

                Text("Set Up Voice")
                    .font(.title2.bold())

                Text("Configure a voice provider to start voice calls with your Hivecrew workers.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
                .frame(height: 40)

            VStack(spacing: 20) {
                Picker("Provider", selection: $voiceProvider) {
                    Text("Gemini").tag("gemini")
                    Text("OpenAI").tag("openai")
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text("API Key")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    HStack {
                        Group {
                            if showingKey {
                                TextField("Enter your API key", text: $editingKey)
                            } else {
                                SecureField("Enter your API key", text: $editingKey)
                            }
                        }
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                        Button {
                            showingKey.toggle()
                        } label: {
                            Image(systemName: showingKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 24)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Voice Name")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("Leda", text: $editingName)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                voiceApiKey = editingKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    voiceName = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                Task {
                    await orchestrator.startSession()
                }
            } label: {
                Text("Save & Start Call")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValid)
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .onAppear {
            editingKey = voiceApiKey
            editingName = voiceName
        }
    }
}

#Preview {
    VoiceSetupFlowView()
        .environmentObject(HivelinkVoiceOrchestrator())
}
