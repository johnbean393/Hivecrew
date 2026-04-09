//
//  VoiceSettingsView.swift
//  Hivecrew
//
//  Settings tab for voice mode configuration.
//  Mirrors the image generation settings pattern: voice provider is
//  auto-detected from configured LLM providers (Google AI Studio).
//

import SwiftUI
import SwiftData
import Combine
import HivecrewVoice

struct VoiceSettingsView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]
    @StateObject private var audioManager = AudioManager()
    @StateObject private var isolationController = VoiceIsolationSettingsController()

    @AppStorage("voice_provider_type") private var voiceProviderType: String = ""
    @AppStorage("voice_model") private var selectedModel: String = VoiceAvailability.defaultGeminiModel
    @AppStorage("voice_media_resolution") private var mediaResolutionRaw: String = "medium"
    @AppStorage("voice_input_device_id") private var inputDeviceIDRaw: String = ""

    private var hasGeminiProvider: Bool {
        VoiceAvailability.hasConfiguredProvider(type: .gemini, providers: providers)
    }

    private var hasOpenAIProvider: Bool {
        VoiceAvailability.hasConfiguredProvider(type: .openAI, providers: providers)
    }

    private var selectedProviderType: VoiceProviderType? {
        VoiceProviderType(rawValue: voiceProviderType)
    }

    private var isProviderConfigured: Bool {
        guard let type = selectedProviderType else {
            return false
        }
        return VoiceAvailability.hasConfiguredProvider(type: type, providers: providers)
    }

    var body: some View {
        Form {
            providerSection
            inputSection
            voiceIsolationSection
            advancedSection
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            syncDefaults()
            Task { await isolationController.refreshStatus() }
        }
        .onChange(of: providers.count) { _, _ in
            syncDefaults()
        }
    }

    private var inputSection: some View {
        Section("Input") {
            VoiceInputControlsSection(
                audioManager: audioManager,
                inputDeviceIDRaw: $inputDeviceIDRaw
            )
        }
    }

    private var voiceIsolationSection: some View {
        Section("Voice Isolation") {
            VoiceEnrollmentSetupCard(
                controller: isolationController,
                audioManager: audioManager,
                inputDeviceIDRaw: $inputDeviceIDRaw,
                primaryActionTitle: isolationController.hasProfile ? "Re-enroll Voice" : "Set Up Voice Isolation",
                showDeleteButton: true,
                showMicrophonePicker: false
            )
        }
    }

    // MARK: - Provider Section

    private var providerSection: some View {
        Section("Provider") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Provider", selection: $voiceProviderType) {
                    Text("Google Gemini").tag(VoiceProviderType.gemini.rawValue)
                    Text("OpenAI").tag(VoiceProviderType.openAI.rawValue)
                }
                .pickerStyle(.segmented)
                .onChange(of: voiceProviderType) { oldValue, newValue in
                    if let oldType = VoiceProviderType(rawValue: oldValue) {
                        VoiceAvailability.savePerProviderPreferences(for: oldType)
                    }
                    if let newType = VoiceProviderType(rawValue: newValue) {
                        VoiceAvailability.restorePerProviderPreferences(for: newType)
                        selectedModel = UserDefaults.standard.string(forKey: VoiceAvailability.voiceModelKey)
                            ?? VoiceAvailability.defaultModel(for: newType)
                    }
                }

                switch selectedProviderType {
                case .openAI:
                    openAIConfigStatus
                default:
                    geminiConfigStatus
                }

                Divider()

                modelPicker
            }
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch selectedProviderType {
            case .openAI:
                Picker("Model", selection: $selectedModel) {
                    Text("gpt-realtime-1.5").tag("gpt-realtime-1.5")
                    Text("gpt-realtime-mini").tag("gpt-realtime-mini")
                }

                Text("OpenAI Realtime speech-to-speech models.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            default:
                Picker("Model", selection: $selectedModel) {
                    Text("gemini-3.1-flash-live-preview").tag("gemini-3.1-flash-live-preview")
                    Text("gemini-2.5-flash-native-audio-preview-12-2025").tag("gemini-2.5-flash-native-audio-preview-12-2025")
                }

                Text("The live preview model for real-time voice conversations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var geminiConfigStatus: some View {
        providerConfigStatus(
            isConfigured: hasGeminiProvider,
            configuredMessage: "Using Google AI Studio provider from Providers settings",
            missingMessage: "No Google AI Studio provider configured. Add one in the Providers tab."
        )
    }

    private var openAIConfigStatus: some View {
        providerConfigStatus(
            isConfigured: hasOpenAIProvider,
            configuredMessage: "Using OpenAI provider from Providers settings",
            missingMessage: "No OpenAI provider configured. Add one in the Providers tab."
        )
    }

    private func providerConfigStatus(isConfigured: Bool, configuredMessage: String, missingMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: isConfigured ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(isConfigured ? .green : .orange)
                Text(isConfigured ? configuredMessage : missingMessage)
                    .font(.caption)
                    .foregroundStyle(isConfigured ? Color.secondary : Color.orange)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Advanced Section

    @ViewBuilder
    private var advancedSection: some View {
        if selectedProviderType == .gemini {
            Section("Advanced") {
                Picker("Media Resolution", selection: $mediaResolutionRaw) {
                    ForEach(VoiceSessionConfig.MediaResolution.allCases) { res in
                        Text(res.rawValue.capitalized).tag(res.rawValue)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func syncDefaults() {
        VoiceAvailability.autoConfigureIfNeeded(modelContext: modelContext)

        if let type = VoiceAvailability.selectedProviderFromDefaults() {
            voiceProviderType = type.rawValue
        }

        let normalizedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedModel.isEmpty, let type = VoiceProviderType(rawValue: voiceProviderType) {
            selectedModel = VoiceAvailability.defaultModel(for: type)
        }
    }
}

struct VoiceInputControlsSection: View {
    @ObservedObject var audioManager: AudioManager
    @Binding var inputDeviceIDRaw: String

    private var deviceSelection: Binding<String> {
        Binding(
            get: { inputDeviceIDRaw },
            set: { newValue in
                inputDeviceIDRaw = newValue
                Task { try? await audioManager.selectInputDevice(newValue) }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Microphone", selection: deviceSelection) {
                Text("System Default").tag("")
                ForEach(audioManager.availableInputDevices) { device in
                    Text(deviceRowLabel(for: device)).tag(device.id)
                }
            }
        }
        .task {
            audioManager.setPreferredInputDevice(inputDeviceIDRaw)
            audioManager.refreshInputDevices()
        }
    }

    private func deviceRowLabel(for device: AudioInputDevice) -> String {
        switch device.kind {
        case .builtIn:
            return "\(device.name) (Built-in)"
        case .external:
            return "\(device.name) (External)"
        case .aggregate:
            return "\(device.name) (Aggregate)"
        case .virtual:
            return "\(device.name) (Virtual)"
        case .unknown:
            return device.name
        }
    }
}

struct VoiceEnrollmentSetupView: View {
    @Binding var isConfigured: Bool
    var onConfigured: (() -> Void)?

    @StateObject private var controller = VoiceIsolationSettingsController()
    @StateObject private var audioManager = AudioManager()
    @AppStorage("voice_input_device_id") private var inputDeviceIDRaw: String = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    VStack(spacing: 8) {
                        Image(systemName: "person.wave.2.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.pink)

                        Text("Enroll Your Voice")
                            .font(.title2)
                            .fontWeight(.semibold)

                        Text("Record a short voice sample so Hivecrew can keep Gemini and GPT-Realtime focused on your speech.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)

                    VoiceEnrollmentSetupCard(
                        controller: controller,
                        audioManager: audioManager,
                        inputDeviceIDRaw: $inputDeviceIDRaw,
                        primaryActionTitle: controller.hasProfile ? "Re-enroll Voice" : "Start Voice Enrollment",
                        showDeleteButton: true,
                        showMicrophonePicker: true
                    )
                    .padding(.horizontal, 60)
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
            }

            if controller.hasProfile {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Voice enrollment complete")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
        .onAppear {
            Task {
                await controller.refreshStatus()
                isConfigured = controller.hasProfile
            }
        }
        .onChange(of: controller.hasProfile) { _, newValue in
            isConfigured = newValue
            if newValue {
                onConfigured?()
            }
        }
    }
}

struct VoiceEnrollmentSetupCard: View {
    @ObservedObject var controller: VoiceIsolationSettingsController
    @ObservedObject var audioManager: AudioManager
    @Binding var inputDeviceIDRaw: String
    var primaryActionTitle: String
    var showDeleteButton: Bool
    var showMicrophonePicker: Bool

    @State private var isMouseDown = false
    @State private var isSpaceDown = false
    @FocusState private var isRecordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: controller.statusSymbolName)
                    .foregroundStyle(controller.statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.statusTitle)
                    Text(controller.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showMicrophonePicker {
                VoiceInputControlsSection(
                    audioManager: audioManager,
                    inputDeviceIDRaw: $inputDeviceIDRaw
                )
            }

            switch controller.phase {
            case .idle:
                idleContent

            case .preparing:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Preparing microphone…")
                        .foregroundStyle(.secondary)
                }

            case .awaitingRecording(let index), .recording(let index):
                promptContent(index: index)

            case .processing:
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text("Building voice profile…")
                        .foregroundStyle(.secondary)
                }
            }

            if let errorText = controller.lastError {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Idle

    @ViewBuilder
    private var idleContent: some View {
        HStack {
            Button(primaryActionTitle) {
                Task {
                    await controller.beginEnrollment(
                        using: audioManager,
                        inputDeviceIDRaw: inputDeviceIDRaw
                    )
                }
            }
            .disabled(controller.isBusy)

            Spacer()

            if showDeleteButton && controller.hasProfile {
                Button("Delete Profile", role: .destructive) {
                    controller.deleteProfile()
                }
            }
        }

        Text("Record in a quiet room and read each prompt at your own pace.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: - Active Enrollment

    @ViewBuilder
    private func promptContent(index: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<controller.promptCount, id: \.self) { i in
                Circle()
                    .fill(i < index ? Color.green : (i == index ? Color.accentColor : Color.secondary.opacity(0.3)))
                    .frame(width: 8, height: 8)
            }
            Spacer()
            Text("\(index + 1) of \(controller.promptCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Read this aloud:")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(controller.currentPrompt ?? "")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

        VStack(spacing: 6) {
            recordButton
                .focusable()
                .focused($isRecordFocused)
                .onKeyPress(.space, phases: [.down, .up]) { keyPress in
                    handleSpaceKey(phase: keyPress.phase)
                    return .handled
                }

            if controller.isRecording {
                Text("Release to finish")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if controller.tooShortHint {
                Text("Hold for at least 1 second")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Press and hold, or hold **Space**")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .onAppear { isRecordFocused = true }

        HStack {
            Button("Cancel Enrollment", role: .destructive) {
                controller.cancelEnrollment()
            }
            Spacer()
        }
    }

    // MARK: - Record Button

    private var recordButton: some View {
        let recording = controller.isRecording

        return HStack(spacing: 8) {
            if recording {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                Text(String(format: "Recording… %.1fs", controller.recordingSeconds))
                    .monospacedDigit()
            } else {
                Image(systemName: "mic.fill")
                Text("Hold to Record")
            }
        }
        .font(.headline)
        .foregroundStyle(recording ? .white : .accentColor)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(recording ? Color.red : Color.accentColor.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(recording ? Color.red : Color.accentColor, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isMouseDown else { return }
                    isMouseDown = true
                    controller.startRecording()
                }
                .onEnded { _ in
                    guard isMouseDown else { return }
                    isMouseDown = false
                    controller.stopRecording()
                }
        )
        .accessibilityLabel(recording ? "Recording" : "Hold to record")
        .accessibilityHint("Press and hold to record your voice for this prompt")
    }

    private func handleSpaceKey(phase: KeyPress.Phases) {
        if phase == .down {
            guard !isSpaceDown else { return }
            isSpaceDown = true
            controller.startRecording()
        } else if phase == .up {
            guard isSpaceDown else { return }
            isSpaceDown = false
            controller.stopRecording()
        }
    }
}

// MARK: - Enrollment Phase

enum EnrollmentPhase: Equatable {
    case idle
    case preparing
    case awaitingRecording(promptIndex: Int)
    case recording(promptIndex: Int)
    case processing
}

// MARK: - Controller

@MainActor
final class VoiceIsolationSettingsController: ObservableObject {
    @Published var hasProfile = false
    @Published var phase: EnrollmentPhase = .idle
    @Published var lastError: String?
    @Published var recordingSeconds: TimeInterval = 0
    @Published var tooShortHint = false

    private let prompts = [
        "Hivecrew keeps my voice isolated so the assistant hears only me.",
        "Background conversations should not become instructions for the voice agent.",
        "Today I am testing reliable voice control in a noisy environment."
    ]

    private let minimumRecordingDuration: TimeInterval = 1.0

    private var collector: EnrollmentAudioCollector?
    private var audioManager: AudioManager?
    private var previousCaptureHandler: ((Data) -> Void)?
    private var recordingTimer: Timer?

    var isBusy: Bool { phase != .idle }

    var currentPrompt: String? {
        switch phase {
        case .awaitingRecording(let i), .recording(let i):
            return prompts[indices: i]
        default:
            return nil
        }
    }

    var promptCount: Int { prompts.count }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var statusTitle: String {
        switch phase {
        case .idle:
            return hasProfile ? "Voice profile ready" : "Voice profile required"
        case .preparing:
            return "Preparing…"
        case .awaitingRecording, .recording:
            return "Recording voice sample"
        case .processing:
            return "Building voice profile"
        }
    }

    var statusDetail: String {
        switch phase {
        case .idle:
            return hasProfile
                ? "Voice calls will use your saved profile for speaker isolation."
                : "Complete setup before starting voice mode."
        case .preparing:
            return "Setting up microphone…"
        case .awaitingRecording(let i):
            return "Hold the button and read prompt \(i + 1) of \(prompts.count) aloud."
        case .recording(let i):
            return "Recording prompt \(i + 1) of \(prompts.count)…"
        case .processing:
            return "Analyzing voice samples…"
        }
    }

    var statusSymbolName: String {
        switch phase {
        case .idle:
            return hasProfile ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .preparing, .processing:
            return "waveform.badge.magnifyingglass"
        case .awaitingRecording:
            return "mic"
        case .recording:
            return "mic.fill"
        }
    }

    var statusColor: Color {
        switch phase {
        case .idle:
            return hasProfile ? .green : .orange
        case .preparing, .processing:
            return .orange
        case .awaitingRecording:
            return .accentColor
        case .recording:
            return .red
        }
    }

    func refreshStatus() async {
        hasProfile = VoiceIsolationProfileStore.loadProfile() != nil
    }

    func deleteProfile() {
        VoiceIsolationProfileStore.deleteProfile()
        hasProfile = false
        lastError = nil
    }

    // MARK: - Enrollment Flow

    func beginEnrollment(using audioManager: AudioManager, inputDeviceIDRaw: String) async {
        guard phase == .idle else { return }
        phase = .preparing
        lastError = nil
        tooShortHint = false

        let newCollector = EnrollmentAudioCollector()
        self.collector = newCollector
        self.audioManager = audioManager
        self.previousCaptureHandler = audioManager.onAudioCaptured

        audioManager.onAudioCaptured = { data in
            Task { await newCollector.append(data) }
        }

        do {
            try await FluidAudioSpeakerEmbeddingProvider.shared.prepare()
            audioManager.configure(inputSampleRate: 16_000, outputSampleRate: 24_000)
            audioManager.setPreferredInputDevice(inputDeviceIDRaw)
            try await audioManager.startCapture(voiceProcessingEnabled: true)
            phase = .awaitingRecording(promptIndex: 0)
        } catch {
            lastError = error.localizedDescription
            teardown()
        }
    }

    func startRecording() {
        guard case .awaitingRecording(let index) = phase else { return }
        phase = .recording(promptIndex: index)
        recordingSeconds = 0
        tooShortHint = false

        Task { await collector?.startCollecting() }

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recordingSeconds += 0.1
            }
        }
    }

    func stopRecording() {
        guard case .recording(let index) = phase else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        if recordingSeconds < minimumRecordingDuration {
            Task { await collector?.discardCurrent() }
            phase = .awaitingRecording(promptIndex: index)
            recordingSeconds = 0
            tooShortHint = true
            return
        }

        tooShortHint = false
        Task { await collector?.commitCurrent() }

        let nextIndex = index + 1
        if nextIndex < prompts.count {
            phase = .awaitingRecording(promptIndex: nextIndex)
            recordingSeconds = 0
        } else {
            Task { await processEnrollment() }
        }
    }

    func cancelEnrollment() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        teardown()
    }

    private func processEnrollment() async {
        phase = .processing

        do {
            guard let capturedAudio = await collector?.snapshot(), !capturedAudio.isEmpty else {
                throw NSError(domain: "Enrollment", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "No audio was captured. Please try again."
                ])
            }

            let profile = try await FluidAudioSpeakerEmbeddingProvider.shared.buildProfile(
                fromPCM16Data: capturedAudio,
                sampleRate: 16_000
            )
            try VoiceIsolationProfileStore.saveProfile(profile)
            hasProfile = true
        } catch {
            lastError = error.localizedDescription
            hasProfile = VoiceIsolationProfileStore.loadProfile() != nil
        }

        teardown()
    }

    private func teardown() {
        audioManager?.onAudioCaptured = previousCaptureHandler
        audioManager?.stopCapture()
        audioManager?.refreshInputDevices()
        audioManager = nil
        collector = nil
        previousCaptureHandler = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        phase = .idle
        recordingSeconds = 0
    }
}

// MARK: - Audio Collector

private actor EnrollmentAudioCollector {
    private var committed = Data()
    private var current = Data()
    private(set) var isCollecting = false

    func startCollecting() {
        isCollecting = true
        current = Data()
    }

    func commitCurrent() {
        isCollecting = false
        committed.append(current)
        current = Data()
    }

    func discardCurrent() {
        isCollecting = false
        current = Data()
    }

    func append(_ chunk: Data) {
        guard isCollecting else { return }
        current.append(chunk)
    }

    func snapshot() -> Data {
        var all = committed
        all.append(current)
        return all
    }
}

private extension Array {
    subscript(indices index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
