//
//  HivelinkVoiceOrchestrator.swift
//  Hivelink
//
//  Central coordinator for voice mode on iOS. Simplified from the macOS
//  VoiceOrchestrator — no speaker isolation pipeline, no capture writer,
//  no system sleep handling, no compact-share mode.
//

import Combine
import Foundation
import SwiftUI
import HivecrewCore
import HivecrewVoice

// MARK: - Incoming Call Context

struct IncomingCallContext {
    let triggerEvent: String
    let taskId: String?
    let workerName: String?
    let summary: String?
}

// MARK: - Input Source

enum VoiceInputSource: String, CaseIterable, Identifiable {
    case none
    case camera

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .camera: return "Camera"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "mic.fill"
        case .camera: return "camera.fill"
        }
    }
}

// MARK: - Call State

enum HivelinkCallState: Equatable {
    case idle
    case active
    case idleTimeout
}

// MARK: - Voice Orchestrator

@MainActor
final class HivelinkVoiceOrchestrator: ObservableObject {

    // MARK: - Owned Services

    private(set) var provider: (any RealtimeVoiceProvider)?
    let audioManager = AudioManager()
    let cameraCapture = CameraCaptureManager()
    let workerRegistry = WorkerRegistry()

    // MARK: - External Dependencies

    private(set) weak var taskService: HivelinkTaskService?

    func configure(taskService: HivelinkTaskService) {
        self.taskService = taskService
    }

    // MARK: - Published State

    @Published var callState: HivelinkCallState = .idle
    @Published var connectionState: VoiceConnectionState = .disconnected
    @Published var transcript: [TranscriptEntry] = []
    @Published var isMuted = false {
        didSet { audioManager.isMuted = isMuted }
    }
    @Published var inputLevel: Float = 0
    @Published var outputLevel: Float = 0
    @Published var isModelSpeaking = false
    @Published var focusedTaskId: String?
    @Published var activeInputSource: VoiceInputSource = .none
    @Published private(set) var relevantTaskIds: [String] = []

    private var pendingEndCall = false

    /// Prefix to strip from model output transcriptions after a tool call.
    private var modelTranscriptPrefixToStrip: String = ""

    // MARK: - Settings

    @AppStorage("hivelink.voiceProvider") private var voiceProviderRaw = "gemini"
    @AppStorage("hivelink.voiceApiKey") private var voiceApiKey = ""
    @AppStorage("hivelink.voiceName") private var voiceName = "Leda"
    @AppStorage("hivelink.mediaResolution") private var mediaResolutionRaw = "medium"
    @AppStorage("hivelink.reasoningEffort") private var reasoningEffortRaw = "high"

    var isVoiceConfigured: Bool {
        !voiceApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var backend: VoiceProviderBackend {
        voiceProviderRaw == "openai" ? .openAIRealtime : .geminiLive
    }

    private var selectedModel: String {
        backend == .openAIRealtime ? "gpt-realtime-1.5" : "gemini-3.1-flash-live-preview"
    }

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()
    private var idleTimer: Timer?

    init() {
        setupAudioCallbacks()
        setupVideoCallbacks()

        audioManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Session Lifecycle

    func startSession(context: IncomingCallContext? = nil) async {
        guard callState == .idle else { return }

        let apiKey = voiceApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            connectionState = .error("No voice API key configured. Add one in Settings → Voice.")
            return
        }

        clearSession()
        connectionState = .connecting
        callState = .active

        let provider = RealtimeVoiceService.shared.createProvider(
            backend: backend,
            apiKey: apiKey,
            model: selectedModel
        )
        self.provider = provider
        wireProviderCallbacks(provider)

        let systemPrompt = makeSystemPrompt(context: context)

        let config = VoiceSessionConfig(
            systemPrompt: systemPrompt,
            voiceName: voiceName,
            tools: HivelinkToolHandler.toolDeclarations,
            mediaResolution: VoiceSessionConfig.MediaResolution(rawValue: mediaResolutionRaw) ?? .medium,
            thinkingLevel: .low,
            includeThoughts: true,
            webSearchEnabled: true,
            audioPolicy: VoiceSessionConfig.AudioPolicy(
                preset: .balanced,
                localSpeakerIsolation: .init(enabled: false)
            )
        )

        audioManager.configure(
            inputSampleRate: provider.inputSampleRate,
            outputSampleRate: provider.outputSampleRate
        )

        do {
            try await provider.connect(config: config)
            try await audioManager.startCapture(voiceProcessingEnabled: true)
            connectionState = .connected
            startIdleTimer()
        } catch {
            tearDownSession()
            connectionState = .error(error.localizedDescription)
            callState = .idle
        }
    }

    func endSession() {
        tearDownSession()
        connectionState = .disconnected
        callState = .idle
        isModelSpeaking = false
    }

    func endCallAfterSpeaking() {
        if isModelSpeaking {
            pendingEndCall = true
        } else {
            endSession()
        }
    }

    private func tearDownSession() {
        pendingEndCall = false
        cancelIdleTimer()
        audioManager.stopCapture()
        audioManager.stopPlayback()
        cameraCapture.stopCapture()
        activeInputSource = .none

        let activeProvider = provider
        provider = nil
        activeProvider?.disconnect()
    }

    // MARK: - System Prompt

    private func makeSystemPrompt(context: IncomingCallContext?) -> String {
        var prompt = OrchestratorSystemPrompt.build(voiceName: voiceName.capitalized)

        let existingTasksSummary = importActiveTasks()
        if !existingTasksSummary.isEmpty {
            prompt += "\n\n" + existingTasksSummary
        }

        if let context {
            var callReason = "\n\n## [CALL REASON]\n"
            callReason += "You are calling the user because: \(context.triggerEvent)"
            if let taskId = context.taskId {
                callReason += "\nTask ID: \(taskId)"
            }
            if let workerName = context.workerName {
                callReason += "\nWorker: \(workerName)"
            }
            if let summary = context.summary {
                callReason += "\nSummary: \(summary)"
            }
            callReason += "\nAddress this reason naturally at the start of the conversation."
            prompt += callReason
        }

        return prompt
    }

    // MARK: - Provider Callbacks

    private func wireProviderCallbacks(_ prov: any RealtimeVoiceProvider) {
        prov.onAudioReceived = { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
                self.handleTranscription(transcription)
            }
        }

        prov.onToolCall = { [weak self] toolCall in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.handleToolCall(toolCall)
            }
        }

        prov.onInterrupted = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.resetIdleTimer()
                self.audioManager.clearPlaybackQueue()
                self.audioManager.setServerModelSpeaking(false)
                self.isModelSpeaking = false
            }
        }

        prov.onTurnComplete = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isModelSpeaking = false
                self.audioManager.setServerModelSpeaking(false)
                if self.pendingEndCall {
                    self.pendingEndCall = false
                    self.endSession()
                } else {
                    self.resetIdleTimer()
                }
            }
        }

        prov.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.connectionState = .error(error.localizedDescription)
            }
        }

        prov.onDisconnected = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectionState = .error(event.message)
                if self.callState != .idle {
                    self.tearDownSession()
                    self.callState = .idle
                }
            }
        }

        prov.onInputActivity = { _ in }
        prov.onUsageUpdate = { _ in }
        prov.onReconnecting = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connectionState = .reconnecting
            }
        }
        prov.onReconnected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connectionState = .connected
            }
        }
    }

    // MARK: - Audio Callbacks

    private func setupAudioCallbacks() {
        audioManager.onAudioCaptured = { [weak self] data in
            Task { @MainActor [weak self] in
                try? await self?.provider?.sendAudio(data)
            }
        }

        audioManager.onPlaybackFinished = { [weak self] in
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !self.isModelSpeaking else { return }
                self.audioManager.setServerModelSpeaking(false)
            }
        }

        audioManager.$inputLevel.receive(on: RunLoop.main).assign(to: &$inputLevel)
        audioManager.$outputLevel.receive(on: RunLoop.main).assign(to: &$outputLevel)
    }

    // MARK: - Video Callbacks

    private func setupVideoCallbacks() {
        cameraCapture.onFrameCaptured = { [weak self] data in
            Task { @MainActor [weak self] in
                try? await self?.provider?.sendVideoFrame(data)
            }
        }
    }

    // MARK: - Transcription

    private func handleTranscription(_ transcription: VoiceTranscription) {
        resetIdleTimer()
        let role: TranscriptEntry.Role = transcription.source == .input ? .user : .model

        var text = transcription.text
        if role == .model, !modelTranscriptPrefixToStrip.isEmpty,
           text.hasPrefix(modelTranscriptPrefixToStrip) {
            text = String(text.dropFirst(modelTranscriptPrefixToStrip.count))
        }

        if transcription.source == .input {
            modelTranscriptPrefixToStrip = ""
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

        if let lastModel = transcript.last(where: { $0.role == .model }),
           case .text(let prevText) = lastModel.content {
            modelTranscriptPrefixToStrip = prevText
        }

        let result = await HivelinkToolHandler.handle(
            toolCall: toolCall,
            taskService: taskService,
            workerRegistry: workerRegistry,
            cameraCapture: cameraCapture,
            orchestrator: self
        )

        if let record = result.transcriptRecord {
            transcript.append(.toolUse(record))
        }

        if let imageData = result.imageData {
            try? await provider?.sendVideoFrame(imageData)
        }

        try? await provider?.sendToolResponse(
            callId: toolCall.id,
            name: toolCall.name,
            result: result.text
        )
    }

    // MARK: - Mute

    func toggleMute() {
        isMuted.toggle()
    }

    // MARK: - Input Source

    func setInputSource(_ source: VoiceInputSource) async {
        let oldSource = activeInputSource
        activeInputSource = source

        if oldSource == .camera && source != .camera {
            cameraCapture.stopCapture()
        }

        if source == .camera && !cameraCapture.isCapturing {
            do {
                try await cameraCapture.startCapture()
            } catch {
                activeInputSource = .none
            }
        }
    }

    // MARK: - Task Management

    func addRelevantTask(_ taskId: String) {
        guard !relevantTaskIds.contains(taskId) else { return }
        relevantTaskIds.append(taskId)
    }

    func clearSession() {
        pendingEndCall = false
        transcript.removeAll()
        relevantTaskIds.removeAll()
        focusedTaskId = nil
        workerRegistry.clearAll()
        modelTranscriptPrefixToStrip = ""
    }

    // MARK: - Active Task Import

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

    // MARK: - Idle Timer

    private func startIdleTimer() {
        cancelIdleTimer()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.callState == .active else { return }
                if self.isModelSpeaking {
                    self.startIdleTimer()
                    return
                }
                self.endSession()
            }
        }
    }

    private func resetIdleTimer() {
        if callState == .active {
            startIdleTimer()
        }
    }

    private func cancelIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }
}

// MARK: - Transcript Entry (shared with macOS)

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

struct VoiceFileSearchResult: Identifiable, Equatable {
    let id: String
    let title: String
    let path: String
    let sourceType: String
    let relevanceScore: Double
    var isSelected: Bool = false
}
