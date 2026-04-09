//
//  VoiceOrchestrator.swift
//  Hivecrew
//
//  Central coordinator for voice mode. Imports HivecrewVoice for provider
//  protocol and audio/video infrastructure. Owns tool dispatch and
//  TaskService integration.
//

import Foundation
import SwiftUI
import SwiftData
import Combine
import ScreenCaptureKit
import HivecrewVoice
import HivecrewShared

// MARK: - Call State Machine

enum CallState: Equatable {
    case idle
    case active
    case idleTimeout
    case suspended
    case compactShare
}

@MainActor
final class VoiceOrchestrator: ObservableObject {

    // MARK: - Services (from HivecrewVoice)

    private(set) var provider: (any RealtimeVoiceProvider)?
    let audioManager = AudioManager()
    let videoSourceManager = VideoSourceManager()
    let workerRegistry = WorkerRegistry()

    // MARK: - External Dependencies

    private(set) weak var taskService: TaskService?
    private(set) var modelContext: ModelContext?

    func configure(taskService: TaskService, modelContext: ModelContext) {
        self.taskService = taskService
        self.modelContext = modelContext
    }

    var isVoiceConfigured: Bool {
        guard let modelContext else { return false }
        return VoiceAvailability.isConfigured(modelContext: modelContext)
            && VoiceIsolationProfileStore.loadProfile() != nil
    }

    // MARK: - Published State

    @Published var callState: CallState = .idle
    @Published var connectionState: VoiceConnectionState = .disconnected
    @Published var transcript: [TranscriptEntry] = []

    /// Prefix to strip from model output transcriptions after a tool call.
    /// Gemini Live sends cumulative text for the entire server turn, so after
    /// a tool call the transcription includes the pre-tool text verbatim.
    private var modelTranscriptPrefixToStrip: String = ""
    @Published var relevantTaskIds: [String] = []
    @Published var focusedTaskId: String?
    @Published var isMuted = false {
        didSet {
            audioManager.isMuted = isMuted
            if isMuted, currentAudioPolicy.streamEndBehavior.sendOnMute {
                flushProviderInputStream(reason: "mute")
            }
        }
    }
    @Published var inputLevel: Float = 0
    @Published var outputLevel: Float = 0
    @Published var totalTokenCount: Int = 0
    @Published var isModelSpeaking = false
    @Published var activeWorkerQuestions: [AgentQuestion] = []

    /// When true, the call will end automatically once the model finishes speaking.
    private var pendingEndCall = false

    // MARK: - Settings

    @AppStorage("voice_provider_type") var voiceProviderTypeRaw: String = ""
    @AppStorage("voice_model") var selectedModel: String = VoiceAvailability.defaultGeminiModel
    @AppStorage("voice_voice_name") var voiceName: String = "Leda"
    @AppStorage("voice_thinking_level") var thinkingLevelRaw: String = "low"
    @AppStorage("voice_media_resolution") var mediaResolutionRaw: String = "medium"
    @AppStorage("voice_input_device_id") var inputDeviceIDRaw: String = ""
    @AppStorage("voice_include_thoughts") var includeThoughts: Bool = true
    @AppStorage("voice_web_search_enabled") var webSearchEnabled: Bool = true
    @AppStorage(VoiceAvailability.developerVoiceSessionCaptureKey) var developerVoiceSessionCaptureEnabled: Bool = false

    var backend: VoiceProviderBackend {
        guard let type = VoiceProviderType(rawValue: voiceProviderTypeRaw) else {
            return .geminiLive
        }
        return VoiceAvailability.backend(for: type)
    }

    var selectedInputDeviceID: String? {
        let trimmed = inputDeviceIDRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var automaticallyDerivedAudioPreset: VoiceSessionConfig.AudioPolicy.Preset {
        audioManager.recommendedPreset(for: selectedInputDeviceID)
    }

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()
    private var idleTimer: Timer?
    private var suspendTimer: Timer?
    private var taskObservers: [AnyCancellable] = []
    private var taskStatusCancellables: [String: AnyCancellable] = [:]
    private var taskQuestionCancellables: [String: AnyCancellable] = [:]
    private var lastKnownStatuses: [String: AgentStatus] = [:]
    private var tokenCountBase: Int = 0
    private var pendingOverlapStartedAt: TimeInterval?
    private var loggedFirstOverlapUplink = false
    private var loggedFirstInputTranscriptAfterOverlap = false
    private var currentAudioPolicy = VoiceSessionConfig.AudioPolicy()
    private var metrics = VoiceSessionMetrics()
    private var uplinkPipeline: UplinkAudioPipeline?
    private var captureWriter: VoiceSessionCaptureWriter?
    private var activeIsolationProfile: SpeakerIsolationProfile?
    private var activeVoiceSessionID: String?

    private struct VoiceSessionMetrics {
        var startedAt = Date()
        var preset: String = ""
        var inputDeviceName: String = "System Default"
        var activeMicrophoneModeName: String = "Standard"
        var speechStartedCount = 0
        var speechStoppedCount = 0
        var streamCommittedCount = 0
        var interruptionCount = 0
        var inputTranscriptCount = 0
        var outputTranscriptCount = 0
        var isolationPassCount = 0
        var isolationAttenuateCount = 0
        var isolationMuteCount = 0
        var averageIsolationDistance: Float = 0
        var captureDirectoryPath: String?
    }

    init() {
        setupAudioCallbacks()
        setupVideoCallbacks()

        audioManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        videoSourceManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private func makeAudioPolicy() -> VoiceSessionConfig.AudioPolicy {
        let preset = automaticallyDerivedAudioPreset
        let selectedDeviceKind = audioManager.inputDevice(matching: selectedInputDeviceID)?.kind
            ?? audioManager.inputDevice(matching: audioManager.activeInputDeviceID)?.kind
            ?? .unknown

        let openAINoiseReduction: VoiceSessionConfig.AudioPolicy.OpenAI.NoiseReduction? = {
            switch selectedDeviceKind {
            case .builtIn, .aggregate, .virtual:
                return .farField
            case .external:
                return .nearField
            case .unknown:
                return nil
            }
        }()

        let openAIConfig: VoiceSessionConfig.AudioPolicy.OpenAI
        let geminiConfig: VoiceSessionConfig.AudioPolicy.Gemini

        switch preset {
        case .balanced:
            openAIConfig = .init(
                turnDetection: .semantic(eagerness: .low),
                createResponse: true,
                interruptResponse: true,
                noiseReduction: openAINoiseReduction
            )
            geminiConfig = .init(
                automaticActivityDetectionEnabled: true,
                startOfSpeechSensitivity: .high,
                endOfSpeechSensitivity: .low,
                prefixPaddingMs: 100,
                silenceDurationMs: 500,
                activityHandling: .startOfActivityInterrupts,
                turnCoverage: nil
            )
        case .noisyRoom:
            openAIConfig = .init(
                turnDetection: .server(
                    threshold: 0.72,
                    prefixPaddingMs: 300,
                    silenceDurationMs: 700
                ),
                createResponse: true,
                interruptResponse: true,
                noiseReduction: openAINoiseReduction ?? .farField
            )
            geminiConfig = .init(
                automaticActivityDetectionEnabled: true,
                startOfSpeechSensitivity: .low,
                endOfSpeechSensitivity: .low,
                prefixPaddingMs: 180,
                silenceDurationMs: 700,
                activityHandling: .startOfActivityInterrupts,
                turnCoverage: nil
            )
        }

        return VoiceSessionConfig.AudioPolicy(
            preset: preset,
            streamEndBehavior: .init(sendOnMute: true, sendOnSuspend: true, sendOnCallEnd: true),
            localSpeakerIsolation: .init(
                enabled: true,
                strictMode: true,
                internalSampleRate: 16_000,
                analysisWindowMs: 900,
                decisionStrideMs: 180,
                outputHoldbackMs: 300,
                confidenceThresholds: .init(pass: 0.48, attenuate: 0.66, mute: 0.86),
                profileUpdatePolicy: .highConfidenceOnly,
                extractorKind: .baselinePassthrough
            ),
            openAI: openAIConfig,
            gemini: geminiConfig
        )
    }

    private func flushProviderInputStream(reason: String) {
        guard let provider else { return }
        recordCaptureEvent(category: .provider, message: "flush_input_stream", metadata: ["reason": reason])
        Task { @MainActor in
            try? await provider.sendAudioStreamEnd()
            print("[VoiceMetrics] Flushed provider input stream due to \(reason)")
        }
    }

    private func disconnectProvider(flushStreamFirst: Bool) {
        let activeProvider = provider
        provider = nil

        guard let activeProvider else { return }
        if flushStreamFirst {
            Task { @MainActor in
                try? await activeProvider.sendAudioStreamEnd()
                activeProvider.disconnect()
            }
        } else {
            activeProvider.disconnect()
        }
    }

    private func recordInputActivity(_ activity: VoiceInputActivityEvent) {
        switch activity.kind {
        case .speechStarted:
            metrics.speechStartedCount += 1
        case .speechStopped:
            metrics.speechStoppedCount += 1
        case .streamCommitted:
            metrics.streamCommittedCount += 1
        }

        if let offsetMs = activity.offsetMs {
            print("[VoiceMetrics] Provider input activity \(activity.kind.rawValue) at \(offsetMs) ms")
        } else {
            print("[VoiceMetrics] Provider input activity \(activity.kind.rawValue)")
        }
    }

    private func logAudioSessionStart() {
        print(
            "[VoiceMetrics] Session started provider=\(backend) preset=\(currentAudioPolicy.preset.rawValue) " +
            "device=\(audioManager.activeInputDeviceName) micMode=\(audioManager.activeMicrophoneModeName) " +
            "speaker_isolation=\(currentAudioPolicy.localSpeakerIsolation.enabled)"
        )
    }

    private func logVoiceMetricsSummary() {
        let duration = Int(Date().timeIntervalSince(metrics.startedAt))
        print(
            "[VoiceMetrics] Session summary duration_s=\(duration) preset=\(metrics.preset) " +
            "device=\(metrics.inputDeviceName) micMode=\(metrics.activeMicrophoneModeName) " +
            "speech_started=\(metrics.speechStartedCount) speech_stopped=\(metrics.speechStoppedCount) " +
            "stream_commits=\(metrics.streamCommittedCount) interruptions=\(metrics.interruptionCount) " +
            "input_transcripts=\(metrics.inputTranscriptCount) output_transcripts=\(metrics.outputTranscriptCount) " +
            "isolation_pass=\(metrics.isolationPassCount) isolation_attenuate=\(metrics.isolationAttenuateCount) " +
            "isolation_mute=\(metrics.isolationMuteCount) avg_distance=\(String(format: "%.3f", metrics.averageIsolationDistance))"
        )
        if let captureDirectoryPath = metrics.captureDirectoryPath {
            print("[VoiceMetrics] Session capture saved at \(captureDirectoryPath)")
        }
    }

    private func updateIsolationMetrics(with decision: SpeakerIsolationDecision) {
        switch decision.gate {
        case .pass:
            metrics.isolationPassCount += 1
        case .attenuate:
            metrics.isolationAttenuateCount += 1
        case .mute:
            metrics.isolationMuteCount += 1
        }
        if let distance = decision.distance {
            let totalDecisions = max(1, metrics.isolationPassCount + metrics.isolationAttenuateCount + metrics.isolationMuteCount)
            let previousTotal = metrics.averageIsolationDistance * Float(max(0, totalDecisions - 1))
            metrics.averageIsolationDistance = (previousTotal + distance) / Float(totalDecisions)
        }
        Task {
            await captureWriter?.record(
                .init(
                    category: .capture,
                    message: "speaker_isolation_decision",
                    metadata: [
                        "gate": decision.gate.rawValue,
                        "distance": decision.distance.map { String(format: "%.4f", $0) } ?? "n/a",
                        "analysis_power": String(format: "%.4f", decision.analysisPower)
                    ]
                )
            )
        }
    }

    private func recordCaptureEvent(
        category: VoiceSessionCaptureEvent.Category,
        message: String,
        metadata: [String: String] = [:]
    ) {
        guard let captureWriter else { return }
        Task {
            await captureWriter.record(.init(category: category, message: message, metadata: metadata))
        }
    }

    private func makeCaptureWriter(
        providerInputSampleRate: Double,
        providerOutputSampleRate: Double,
        audioPolicy: VoiceSessionConfig.AudioPolicy,
        startedAt: Date,
        sessionID: String
    ) -> VoiceSessionCaptureWriter? {
        guard developerVoiceSessionCaptureEnabled else { return nil }
        let directoryURL = AppPaths.debugVoiceModeSessionDirectory(id: sessionID, startedAt: startedAt)
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let buildVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        let metadata = VoiceSessionCaptureMetadata(
            provider: backend.rawValue,
            model: selectedModel,
            sessionID: sessionID,
            startedAt: startedAt,
            inputDeviceName: audioManager.activeInputDeviceName,
            microphoneModeName: audioManager.activeMicrophoneModeName,
            audioPreset: audioPolicy.preset.rawValue,
            localSpeakerIsolation: audioPolicy.localSpeakerIsolation,
            appVersion: appVersion,
            buildVersion: buildVersion
        )
        do {
            let enhancedRate: Int? = audioPolicy.localSpeakerIsolation.speechEnhancerKind != .none
                ? Int(audioPolicy.localSpeakerIsolation.internalSampleRate)
                : nil
            let writer = try VoiceSessionCaptureWriter(
                configuration: .init(
                    directoryURL: directoryURL,
                    metadata: metadata,
                    rawInputSampleRate: Int(audioPolicy.localSpeakerIsolation.internalSampleRate),
                    enhancedSampleRate: enhancedRate,
                    uplinkSampleRate: Int(providerInputSampleRate),
                    downlinkSampleRate: Int(providerOutputSampleRate)
                )
            )
            metrics.captureDirectoryPath = directoryURL.path
            return writer
        } catch {
            print("[VoiceMetrics] Failed to create voice session capture writer: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Connection Lifecycle

    func startCall() async {
        guard callState == .idle || callState == .suspended else { return }

        clearSession()

        guard let modelContext else {
            connectionState = .error("Voice not initialized")
            return
        }

        VoiceAvailability.autoConfigureIfNeeded(modelContext: modelContext)

        guard let credentials = VoiceAvailability.getCredentials(modelContext: modelContext) else {
            connectionState = .error("No voice provider configured. Add a provider in Settings → Providers.")
            return
        }

        let startedAt = Date()

        let prov = RealtimeVoiceService.shared.createProvider(
            backend: backend,
            apiKey: credentials.apiKey,
            model: selectedModel
        )
        self.provider = prov

        wireProviderCallbacks(prov)

        let thinkingLevel = VoiceSessionConfig.ThinkingLevel(rawValue: thinkingLevelRaw) ?? .low
        let mediaRes = VoiceSessionConfig.MediaResolution(rawValue: mediaResolutionRaw) ?? .medium
        let audioPolicy = makeAudioPolicy()

        guard !audioPolicy.localSpeakerIsolation.enabled || VoiceIsolationProfileStore.loadProfile() != nil else {
            connectionState = .error("Voice isolation setup is required. Complete Settings → Voice before starting a call.")
            provider = nil
            return
        }

        let captureInputSampleRate = audioPolicy.localSpeakerIsolation.enabled
            ? audioPolicy.localSpeakerIsolation.internalSampleRate
            : prov.inputSampleRate

        audioManager.configure(
            inputSampleRate: captureInputSampleRate,
            outputSampleRate: prov.outputSampleRate
        )
        audioManager.setPreferredInputDevice(inputDeviceIDRaw)

        // Import active tasks from previous sessions so the voice model can manage them.
        let existingTasksSummary = importActiveTasks()

        var systemPrompt = OrchestratorSystemPrompt.build(
            voiceName: voiceName.capitalized
        )
        if !existingTasksSummary.isEmpty {
            systemPrompt += "\n\n" + existingTasksSummary
        }

        let tools = OrchestratorToolHandler.toolDeclarations

        let config = VoiceSessionConfig(
            systemPrompt: systemPrompt,
            voiceName: voiceName,
            tools: tools,
            mediaResolution: mediaRes,
            thinkingLevel: thinkingLevel,
            includeThoughts: includeThoughts,
            webSearchEnabled: webSearchEnabled,
            audioPolicy: audioPolicy
        )
        currentAudioPolicy = audioPolicy
        activeIsolationProfile = VoiceIsolationProfileStore.loadProfile()
        activeVoiceSessionID = UUID().uuidString.lowercased()
        metrics = VoiceSessionMetrics(
            startedAt: startedAt,
            preset: audioPolicy.preset.rawValue,
            inputDeviceName: audioManager.inputDevice(matching: inputDeviceIDRaw)?.name ?? audioManager.activeInputDeviceName,
            activeMicrophoneModeName: audioManager.activeMicrophoneModeName
        )

        captureWriter = activeVoiceSessionID.map {
            makeCaptureWriter(
                providerInputSampleRate: prov.inputSampleRate,
                providerOutputSampleRate: prov.outputSampleRate,
                audioPolicy: audioPolicy,
                startedAt: startedAt,
                sessionID: $0
            )
        } ?? nil

        if audioPolicy.localSpeakerIsolation.enabled, let activeIsolationProfile {
            let speechEnhancer: (any SpeechEnhancer)? =
                audioPolicy.localSpeakerIsolation.speechEnhancerKind == .hush
                ? HushSpeechEnhancer()
                : nil

            uplinkPipeline = UplinkAudioPipeline(
                configuration: .init(
                    providerInputSampleRate: prov.inputSampleRate,
                    captureSampleRate: captureInputSampleRate,
                    targetProfile: activeIsolationProfile,
                    policy: audioPolicy.localSpeakerIsolation
                ),
                engine: SpeakerIsolationEngine(extractor: PassthroughTargetSpeakerExtractor()),
                speechEnhancer: speechEnhancer,
                captureWriter: captureWriter,
                decisionHandler: { [weak self] decision in
                    self?.updateIsolationMetrics(with: decision)
                },
                outputHandler: { [weak self] data, _ in
                    guard let self else { return }
                    self.logFirstOverlapUplinkChunk(data)
                    try? await self.provider?.sendAudio(data)
                }
            )
        } else {
            uplinkPipeline = nil
        }
        refreshAudioCaptureCallback()

        connectionState = .connecting
        callState = .active

        do {
            if let uplinkPipeline {
                try await uplinkPipeline.prepare()
            }
            recordCaptureEvent(category: .lifecycle, message: "session_prepared", metadata: [
                "provider": backend.rawValue,
                "model": selectedModel,
                "session_id": activeVoiceSessionID ?? "n/a"
            ])
            try await prov.connect(config: config)
            if let actualModel = prov.activeModel, actualModel != selectedModel {
                selectedModel = actualModel
            }
            try await audioManager.startCapture(voiceProcessingEnabled: true)
            metrics.inputDeviceName = audioManager.activeInputDeviceName
            metrics.activeMicrophoneModeName = audioManager.activeMicrophoneModeName
            logAudioSessionStart()
            recordCaptureEvent(category: .lifecycle, message: "session_started", metadata: [
                "device": metrics.inputDeviceName,
                "mic_mode": metrics.activeMicrophoneModeName
            ])
            connectionState = .connected
            startIdleTimer()
            subscribeToInputLevel()
            subscribeToTaskEvents()
        } catch {
            recordCaptureEvent(category: .error, message: "session_start_failed", metadata: [
                "error": error.localizedDescription
            ])
            disconnectProvider(flushStreamFirst: false)
            let pipeline = uplinkPipeline
            let writer = captureWriter
            uplinkPipeline = nil
            captureWriter = nil
            activeIsolationProfile = nil
            activeVoiceSessionID = nil
            refreshAudioCaptureCallback()
            Task {
                if let pipeline {
                    _ = await pipeline.finish(flushPendingAudio: false)
                }
                await writer?.finish()
            }
            connectionState = .error(error.localizedDescription)
            callState = .idle
        }
    }

    func endCall() {
        recordCaptureEvent(category: .lifecycle, message: "session_ending")
        logVoiceMetricsSummary()
        pendingEndCall = false
        resetOverlapMetrics()
        cancelTimers()
        unsubscribeFromInputLevel()
        audioManager.stopCapture()
        audioManager.stopPlayback()
        let pipeline = uplinkPipeline
        let writer = captureWriter
        uplinkPipeline = nil
        captureWriter = nil
        activeIsolationProfile = nil
        activeVoiceSessionID = nil
        refreshAudioCaptureCallback()
        disconnectProvider(flushStreamFirst: currentAudioPolicy.streamEndBehavior.sendOnCallEnd)
        Task { await videoSourceManager.deactivate() }
        Task {
            if let pipeline {
                _ = await pipeline.finish(flushPendingAudio: false)
            }
            await writer?.finish()
        }
        connectionState = .disconnected
        callState = .idle
        isModelSpeaking = false
        totalTokenCount = 0
        tokenCountBase = 0
        currentAudioPolicy = .init()
        restoreQuestionWindowsAndCleanup()
    }

    /// Schedule the call to end once the model finishes its current turn.
    /// If the model is not currently speaking, ends immediately.
    func endCallAfterSpeaking() {
        if isModelSpeaking {
            pendingEndCall = true
        } else {
            endCall()
        }
    }

    // MARK: - Provider Callback Wiring

    private func wireProviderCallbacks(_ prov: any RealtimeVoiceProvider) {
        prov.onAudioReceived = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                Task {
                    await self.captureWriter?.appendDownlinkPCM(data)
                }
                if !self.isModelSpeaking {
                    self.isModelSpeaking = true
                    self.audioManager.setServerModelSpeaking(true)
                }
                self.audioManager.queueAudio(data)
            }
        }

        prov.onTranscription = { [weak self] transcription in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordCaptureEvent(category: .transcript, message: "transcription", metadata: [
                    "source": transcription.source == .input ? "input" : "output",
                    "length": "\(transcription.text.count)",
                    "text": transcription.text
                ])
                self.handleTranscription(transcription)
            }
        }

        prov.onToolCall = { [weak self] toolCall in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordCaptureEvent(category: .provider, message: "tool_call", metadata: [
                    "tool_name": toolCall.name,
                    "tool_id": toolCall.id
                ])
                await self.handleToolCall(toolCall)
            }
        }

        prov.onInputActivity = { [weak self] activity in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordCaptureEvent(category: .provider, message: "input_activity", metadata: [
                    "kind": activity.kind.rawValue,
                    "offset_ms": activity.offsetMs.map(String.init) ?? "n/a"
                ])
                self.recordInputActivity(activity)
            }
        }

        prov.onInterrupted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.metrics.interruptionCount += 1
                self.resetIdleTimer()
                self.logServerInterrupted()
                self.recordCaptureEvent(category: .interruption, message: "server_interrupted")
                self.audioManager.clearPlaybackQueue()
                self.audioManager.setServerModelSpeaking(false)
                self.isModelSpeaking = false
            }
        }

        prov.onTurnComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let startedAt = self.pendingOverlapStartedAt {
                    let elapsedMs = Int((Date().timeIntervalSinceReferenceDate - startedAt) * 1000)
                    print("[VoiceInterruption] Turn completed without server interruption after \(elapsedMs) ms")
                    self.resetOverlapMetrics()
                }
                self.recordCaptureEvent(category: .provider, message: "turn_complete")
                self.isModelSpeaking = false
                self.audioManager.setServerModelSpeaking(false)
                if self.pendingEndCall {
                    self.pendingEndCall = false
                    self.endCall()
                } else {
                    self.resetIdleTimer()
                }
            }
        }

        prov.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordCaptureEvent(category: .error, message: "provider_error", metadata: [
                    "error": error.localizedDescription
                ])
                self.connectionState = .error(error.localizedDescription)
            }
        }

        prov.onUsageUpdate = { [weak self] sessionTokenCount in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.totalTokenCount = self.tokenCountBase + sessionTokenCount
            }
        }

        prov.onReconnecting = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordCaptureEvent(category: .lifecycle, message: "provider_reconnecting")
                self.connectionState = .reconnecting
            }
        }

        prov.onReconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recordCaptureEvent(category: .lifecycle, message: "provider_reconnected")
                self.connectionState = .connected
            }
        }
    }

    // MARK: - Audio Callbacks

    private func setupAudioCallbacks() {
        audioManager.onPlaybackFinished = { [weak self] in
            Task { @MainActor [weak self] in
                // Brief holdoff so trailing speaker echo dissipates before
                // the mic starts forwarding audio to the server again.
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !self.isModelSpeaking else { return }
                self.audioManager.setServerModelSpeaking(false)
            }
        }

        audioManager.$inputLevel.receive(on: RunLoop.main).assign(to: &$inputLevel)
        audioManager.$outputLevel.receive(on: RunLoop.main).assign(to: &$outputLevel)
        refreshAudioCaptureCallback()
    }

    private func refreshAudioCaptureCallback() {
        let pipeline = uplinkPipeline
        audioManager.onAudioCaptured = { [weak self, pipeline] data in
            guard !data.isEmpty else { return }
            if let pipeline {
                Task {
                    await pipeline.enqueueCapturedPCM(data)
                }
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.logFirstOverlapUplinkChunk(data)
                    try? await self.provider?.sendAudio(data)
                }
            }
        }
    }

    private func logFirstOverlapUplinkChunk(_ data: Data) {
        guard !data.isEmpty, isModelSpeaking else { return }

        let startedAt: TimeInterval
        if let pendingOverlapStartedAt {
            startedAt = pendingOverlapStartedAt
        } else {
            let now = Date().timeIntervalSinceReferenceDate
            pendingOverlapStartedAt = now
            loggedFirstOverlapUplink = false
            loggedFirstInputTranscriptAfterOverlap = false
            startedAt = now
        }

        guard !loggedFirstOverlapUplink else { return }
        loggedFirstOverlapUplink = true
        let elapsedMs = Int((Date().timeIntervalSinceReferenceDate - startedAt) * 1000)
        print("[VoiceInterruption] First overlap uplink chunk while model speaking: \(elapsedMs) ms (\(data.count) bytes)")
    }

    private func logFirstInputTranscriptAfterOverlap(_ text: String) {
        guard !loggedFirstInputTranscriptAfterOverlap, !text.isEmpty, let startedAt = pendingOverlapStartedAt else { return }
        loggedFirstInputTranscriptAfterOverlap = true
        let elapsedMs = Int((Date().timeIntervalSinceReferenceDate - startedAt) * 1000)
        print("[VoiceInterruption] First input transcription after overlap: \(elapsedMs) ms (\(text.prefix(80)))")
    }

    private func logServerInterrupted() {
        guard let startedAt = pendingOverlapStartedAt else {
            resetOverlapMetrics()
            return
        }
        let elapsedMs = Int((Date().timeIntervalSinceReferenceDate - startedAt) * 1000)
        print("[VoiceInterruption] Server interruption confirmed after \(elapsedMs) ms")
        resetOverlapMetrics()
    }

    private func resetOverlapMetrics() {
        pendingOverlapStartedAt = nil
        loggedFirstOverlapUplink = false
        loggedFirstInputTranscriptAfterOverlap = false
    }

    // MARK: - Video Callbacks

    private func setupVideoCallbacks() {
        videoSourceManager.onFrameCaptured = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.provider?.sendVideoFrame(data)
            }
        }
    }

    // MARK: - Transcription

    private func handleTranscription(_ transcription: VoiceTranscription) {
        resetIdleTimer()
        if transcription.source == .input {
            metrics.inputTranscriptCount += 1
            logFirstInputTranscriptAfterOverlap(transcription.text)
            modelTranscriptPrefixToStrip = ""
            print("[VoiceMetrics] Input transcript chunk #\(metrics.inputTranscriptCount) length=\(transcription.text.count)")
        } else {
            metrics.outputTranscriptCount += 1
        }
        let role: TranscriptEntry.Role = transcription.source == .input ? .user : .model

        var text = transcription.text
        if role == .model, !modelTranscriptPrefixToStrip.isEmpty,
           text.hasPrefix(modelTranscriptPrefixToStrip) {
            text = String(text.dropFirst(modelTranscriptPrefixToStrip.count))
        }

        if let last = transcript.last, last.role == role, case .text = last.content {
            transcript[transcript.count - 1] = .speech(
                role: role,
                text: text,
                timestamp: last.timestamp
            )
        } else {
            guard !text.isEmpty else { return }
            transcript.append(.speech(role: role, text: text))
        }
    }

    // MARK: - Tool Calls

    private func handleToolCall(_ toolCall: VoiceToolCall) async {
        resetIdleTimer()
        guard let taskService else { return }

        // Snapshot the model's current text so we can strip it from the
        // cumulative transcription Gemini sends after the tool response.
        if let lastModel = transcript.last(where: { $0.role == .model }),
           case .text(let prevText) = lastModel.content {
            modelTranscriptPrefixToStrip = prevText
        }

        let result = await OrchestratorToolHandler.handle(
            toolCall: toolCall,
            taskService: taskService,
            workerRegistry: workerRegistry,
            videoSourceManager: videoSourceManager,
            orchestrator: self
        )

        if let record = result.transcriptRecord {
            transcript.append(.toolUse(record))
        }

        // If the tool produced image data, send it via the realtime input
        // stream BEFORE the tool response so the model has the image in
        // context when it processes the result and starts generating.
        if let imageData = result.imageData {
            try? await provider?.sendVideoFrame(imageData)
        }

        try? await provider?.sendToolResponse(
            callId: toolCall.id,
            name: toolCall.name,
            result: result.text
        )
    }

    // MARK: - Task Event Subscription

    private func subscribeToTaskEvents() {
        guard let taskService else { return }

        taskService.$statePublishers
            .receive(on: RunLoop.main)
            .sink { [weak self] publishers in
                self?.syncTaskObservers(publishers: publishers)
            }
            .store(in: &taskObservers)
    }

    /// Wire up Combine observers for each relevant task's state publisher.
    /// Idempotent — skips tasks that already have subscriptions.
    private func syncTaskObservers(publishers: [String: AgentStatePublisher]) {
        for taskId in relevantTaskIds {
            guard let publisher = publishers[taskId] else { continue }
            guard taskStatusCancellables[taskId] == nil else { continue }

            // Suppress floating question window during voice call
            publisher.isTracePanelVisible = true

            // Subscribe without .dropFirst() so we never miss a terminal status
            // that was set before this subscription was established.
            // handleTaskStatusChange deduplicates via lastKnownStatuses.
            let statusSub = publisher.$status
                .receive(on: RunLoop.main)
                .sink { [weak self, weak publisher] newStatus in
                    guard let self, let publisher else { return }
                    self.handleTaskStatusChange(taskId: taskId, newStatus: newStatus, publisher: publisher)
                }
            taskStatusCancellables[taskId] = statusSub

            // Question changes
            let questionSub = publisher.$pendingQuestion
                .receive(on: RunLoop.main)
                .sink { [weak self] question in
                    self?.handleWorkerQuestionChange(taskId: taskId, question: question)
                }
            taskQuestionCancellables[taskId] = questionSub
        }
    }

    // MARK: - Task Status Callbacks

    private func handleTaskStatusChange(taskId: String, newStatus: AgentStatus, publisher: AgentStatePublisher) {
        let oldStatus = lastKnownStatuses[taskId]
        lastKnownStatuses[taskId] = newStatus

        guard oldStatus != newStatus else { return }

        let workerName = workerRegistry.resolve(query: taskId)?.displayName ?? "Worker"
        let task = taskService?.tasks.first { $0.id == taskId }

        switch newStatus {
        case .completed:
            self.focusedTaskId = taskId
            let summary = publisher.completionSummary ?? task?.resultSummary ?? "Task finished."
            let deliverablePaths = task?.outputFilePaths ?? []
            var message = "[CALLBACK] \(workerName) finished their task. Result: \(summary)"
            if !deliverablePaths.isEmpty {
                message += "\nDeliverables saved to host at:\n" + deliverablePaths.joined(separator: "\n")
                message += "\nIMPORTANT: When telling the user about deliverable files, use the host paths above — NOT any paths mentioned in the result summary (those refer to the worker's internal VM, not the user's machine). You can open these files using the `open_file` tool."
            }
            let progress = publisher.progressSummary
            if !progress.isEmpty {
                message += " Progress detail: \(progress)"
            }
            if allSessionTasksFinished {
                message += " [ALL_TASKS_DONE] All tasks are now complete. Ask the user if they need anything else, and offer to end the call using the `end_call` tool."
            }
            Task {
                await resumeIfSuspended()
                try? await provider?.sendText(message)
            }

        case .failed:
            self.focusedTaskId = taskId
            let errorMsg = publisher.completionSummary ?? task?.errorMessage ?? "Unknown error."
            var message = "[CALLBACK] \(workerName) failed. Error: \(errorMsg)"
            if allSessionTasksFinished {
                message += " [ALL_TASKS_DONE] All tasks are now complete. Ask the user if they need anything else, and offer to end the call using the `end_call` tool."
            }
            Task {
                await resumeIfSuspended()
                try? await provider?.sendText(message)
            }

        case .cancelled:
            self.focusedTaskId = taskId
            var message = "[CALLBACK] \(workerName) was cancelled."
            if allSessionTasksFinished {
                message += " [ALL_TASKS_DONE] All tasks are now complete. Ask the user if they need anything else, and offer to end the call using the `end_call` tool."
            }
            Task {
                await resumeIfSuspended()
                try? await provider?.sendText(message)
            }

        default:
            break
        }
    }

    // MARK: - Worker Question Callbacks

    private func handleWorkerQuestionChange(taskId: String, question: AgentQuestion?) {
        // Remove any previous question for this task
        activeWorkerQuestions.removeAll { $0.taskId == taskId }

        guard let question else { return }

        activeWorkerQuestions.append(question)

        let workerName = workerRegistry.resolve(query: taskId)?.displayName ?? "Worker"
        var message = "[CALLBACK] \(workerName) needs your input: \(question.question)"

        if case .multipleChoice(let mcq) = question {
            let opts = mcq.options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: ", ")
            message += " Options: \(opts)"
        }

        if case .intervention(let req) = question {
            if let service = req.service {
                message += " (Service: \(service))"
            }
            message += " — This requires manual user action. Ask the user to complete it, then use send_instruction to confirm."
        }

        Task {
            await resumeIfSuspended()
            try? await provider?.sendText(message)
        }
    }

    /// Called from the voice UI question banner when the user answers via tap / text.
    func answerWorkerQuestion(_ question: AgentQuestion, answer: String) {
        guard let taskService else { return }
        if let publisher = taskService.statePublishers[question.taskId] {
            publisher.provideAnswer(answer)
            taskService.answerQuestion(question.id)
        }
        activeWorkerQuestions.removeAll { $0.id == question.id }

        let workerName = workerRegistry.resolve(query: question.taskId)?.displayName ?? "Worker"
        let notification = "[CALLBACK] User answered \(workerName)'s question via UI: \"\(answer)\""
        Task { try? await provider?.sendText(notification) }
    }

    // MARK: - Transcript File Search

    /// Gathers selected file paths from all search_files tool-use records in the transcript.
    func confirmedTranscriptFileSearchPaths() -> [String] {
        transcript.compactMap { entry -> [String]? in
            guard case .toolUse(let record) = entry.content else { return nil }
            return record.fileResults.filter(\.isSelected).map(\.path)
        }.flatMap { $0 }
    }

    // MARK: - Cleanup

    /// Restore floating question windows for any unanswered questions, then tear down observers.
    private func restoreQuestionWindowsAndCleanup() {
        guard let taskService else {
            teardownTaskObservers()
            return
        }

        for taskId in relevantTaskIds {
            guard let publisher = taskService.statePublishers[taskId] else { continue }
            publisher.isTracePanelVisible = false

            if let question = publisher.pendingQuestion {
                QuestionWindowController.shared.showQuestion(
                    question,
                    taskTitle: publisher.taskTitle,
                    statePublisher: publisher
                )
            }
        }

        teardownTaskObservers()
    }

    private func teardownTaskObservers() {
        taskObservers.removeAll()
        taskStatusCancellables.removeAll()
        taskQuestionCancellables.removeAll()
        lastKnownStatuses.removeAll()
        activeWorkerQuestions.removeAll()
    }

    // MARK: - Suspend / Resume

    /// Pause audio engines to stop streaming. WebSocket stays connected so
    /// callbacks can still be delivered and the model can respond once resumed.
    func suspendCall() {
        guard callState == .active || callState == .idleTimeout else { return }
        recordCaptureEvent(category: .lifecycle, message: "session_suspended")
        if currentAudioPolicy.streamEndBehavior.sendOnSuspend {
            flushProviderInputStream(reason: "suspend")
        }
        cancelTimers()
        unsubscribeFromInputLevel()
        audioManager.stopCapture()
        audioManager.stopPlayback()
        callState = .suspended
        isModelSpeaking = false
    }

    /// Restart audio engines after a suspend, returning to active state.
    /// Awaitable so callers can ensure audio is ready before sending messages.
    func resumeCall() async {
        guard callState == .suspended else { return }
        callState = .active
        audioManager.setPreferredInputDevice(inputDeviceIDRaw)
        try? await audioManager.startCapture(voiceProcessingEnabled: true)
        metrics.inputDeviceName = audioManager.activeInputDeviceName
        metrics.activeMicrophoneModeName = audioManager.activeMicrophoneModeName
        recordCaptureEvent(category: .lifecycle, message: "session_resumed")
        startIdleTimer()
        subscribeToInputLevel()
    }

    /// Resume if currently suspended, used by callbacks that need to relay
    /// audio to the user (task completed, failed, question, etc.).
    /// Awaits audio setup so the model's response is audible.
    private func resumeIfSuspended() async {
        guard callState == .suspended else { return }
        await resumeCall()
    }

    // MARK: - Idle / Suspend Timers

    private func startIdleTimer() {
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.callState == .active else { return }
                if self.isModelSpeaking {
                    self.startIdleTimer()
                    return
                }
                self.callState = .idleTimeout
                self.startSuspendTimer()
            }
        }
    }

    private func startSuspendTimer() {
        suspendTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.callState == .idleTimeout else { return }
                self.suspendCall()
            }
        }
    }

    private func resetIdleTimer() {
        cancelTimers()
        if callState == .idleTimeout {
            callState = .active
        }
        if callState == .active {
            startIdleTimer()
        }
    }

    private func cancelTimers() {
        idleTimer?.invalidate()
        idleTimer = nil
        suspendTimer?.invalidate()
        suspendTimer = nil
    }

    private var inputLevelCancellable: AnyCancellable?

    private func subscribeToInputLevel() {
        inputLevelCancellable?.cancel()
        inputLevelCancellable = audioManager.$inputLevel
            .filter { $0 > 0.2 }
            .throttle(for: .seconds(2), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.resetIdleTimer()
            }
    }

    private func unsubscribeFromInputLevel() {
        inputLevelCancellable?.cancel()
        inputLevelCancellable = nil
    }

    /// True when every task in this session has reached a terminal state.
    private var allSessionTasksFinished: Bool {
        guard let taskService, !relevantTaskIds.isEmpty else { return false }
        let sessionTasks = taskService.tasks.filter { relevantTaskIds.contains($0.id) }
        return !sessionTasks.isEmpty && sessionTasks.allSatisfy { !$0.status.isActive }
    }

    func addRelevantTask(_ taskId: String) {
        guard !relevantTaskIds.contains(taskId) else { return }
        relevantTaskIds.append(taskId)
        if let publishers = taskService?.statePublishers {
            syncTaskObservers(publishers: publishers)
        }
    }

    func clearSession() {
        pendingEndCall = false
        resetOverlapMetrics()
        restoreQuestionWindowsAndCleanup()
        transcript.removeAll()
        relevantTaskIds.removeAll()
        focusedTaskId = nil
        workerRegistry.clearAll()
    }

    // MARK: - Pre-existing Task Import

    /// Discover active/recent tasks from TaskService, register them in the
    /// WorkerRegistry, add them to relevantTaskIds, and return a system prompt
    /// supplement describing them so the voice model is aware from the start.
    private func importActiveTasks() -> String {
        guard let taskService else { return "" }

        let activeTasks = taskService.tasks.filter { $0.status.isActive }
        guard !activeTasks.isEmpty else { return "" }

        var lines: [String] = []
        for task in activeTasks {
            let worker = workerRegistry.importExisting(taskId: task.id, taskTitle: task.title)
            addRelevantTask(task.id)

            let desc = task.taskDescription.prefix(200)
            lines.append("- \(worker.displayName) (\(task.title)): \"\(desc)\" — status: \(task.status.displayName)")
        }

        return """
        ## Active tasks from previous sessions
        The following tasks are already running or queued. You can manage them with \
        `get_task_status`, `send_instruction`, `cancel_task`, etc. — refer to them by name.

        \(lines.joined(separator: "\n"))
        """
    }

}

// MARK: - Transcript Entry

struct TranscriptEntry: Identifiable, Equatable {
    enum Role: String {
        case user, model, tool
    }

    enum Content: Equatable {
        case text(String)
        case toolUse(ToolUseRecord)
    }

    let id = UUID()
    let role: Role
    let content: Content
    let timestamp: Date

    var text: String {
        switch content {
        case .text(let str): return str
        case .toolUse(let record): return record.summary
        }
    }

    static func speech(role: Role, text: String, timestamp: Date = Date()) -> TranscriptEntry {
        TranscriptEntry(role: role, content: .text(text), timestamp: timestamp)
    }

    static func toolUse(_ record: ToolUseRecord, timestamp: Date = Date()) -> TranscriptEntry {
        TranscriptEntry(role: .tool, content: .toolUse(record), timestamp: timestamp)
    }
}

// MARK: - Tool Use Record

struct ToolUseRecord: Identifiable, Equatable {
    let id = UUID()
    let toolName: String
    let summary: String
    let detail: String
    var fileResults: [VoiceFileSearchResult]
    var previewFilePath: String?
}
