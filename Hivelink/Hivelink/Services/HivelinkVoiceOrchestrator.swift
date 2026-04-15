//
//  HivelinkVoiceOrchestrator.swift
//  Hivelink
//
//  Central coordinator for voice mode on iOS. Simplified from the macOS
//  VoiceOrchestrator — no speaker isolation pipeline, no capture writer,
//  no system sleep handling, no compact-share mode.
//

import AVFoundation
import CallKit
import Combine
import Foundation
import SwiftUI
import HivecrewAPIModels
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
    case suspended
}

// MARK: - CallKit Delegate

private final class CallKitDelegate: NSObject, CXProviderDelegate {
    weak var orchestrator: HivelinkVoiceOrchestrator?

    func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            self?.orchestrator?.handleProviderDidReset()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor [weak self] in
            guard let orchestrator = self?.orchestrator else {
                action.fail()
                return
            }
            await orchestrator.handleStartCallAction(action)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in
            self?.orchestrator?.handleEndCallAction(action)
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            await self?.orchestrator?.handleAudioSessionActivated()
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            self?.orchestrator?.handleAudioSessionDeactivated()
        }
    }
}

// MARK: - Voice Orchestrator

@MainActor
final class HivelinkVoiceOrchestrator: ObservableObject {

    // MARK: - Owned Services

    private(set) var provider: (any RealtimeVoiceProvider)?
    let audioManager = AudioManager()
    let cameraCapture = CameraCaptureManager()
    let workerRegistry = WorkerRegistry()

    // MARK: - CallKit

    private let callKitProvider: CXProvider
    private let callController = CXCallController()
    private let callKitDelegate: CallKitDelegate
    private var activeCallUUID: UUID?
    /// Whether a video source was requested when the call was started via CallKit.
    private var pendingVideoStart = false
    @Published private(set) var isInCall = false

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
    @Published private(set) var activeWorkerQuestions: [String: APIAgentQuestion] = [:]

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
    private var suspendTimer: Timer?
    private var inputLevelCancellable: AnyCancellable?
    private var taskObservers: [AnyCancellable] = []
    private var lastKnownStatuses: [String: TaskStatus] = [:]

    init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.supportedHandleTypes = [.generic]
        config.maximumCallsPerCallGroup = 1
        config.includesCallsInRecents = true
        config.iconTemplateImageData = UIImage(named: "AppIcon")?.pngData()

        let provider = CXProvider(configuration: config)
        self.callKitProvider = provider

        let delegate = CallKitDelegate()
        self.callKitDelegate = delegate

        setupAudioCallbacks()
        setupVideoCallbacks()

        delegate.orchestrator = self
        provider.setDelegate(delegate, queue: nil)

        audioManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - CallKit Call Lifecycle

    func startCall(video: Bool = false, context: IncomingCallContext? = nil) {
        guard callState == .idle else { return }

        let uuid = UUID()
        activeCallUUID = uuid
        isInCall = true
        pendingVideoStart = video
        pendingCallContext = context

        let handle = CXHandle(type: .generic, value: "Hivecrew Voice")
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = video

        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeCallUUID = nil
                    self.isInCall = false
                    self.pendingVideoStart = false
                    self.pendingCallContext = nil
                    self.connectionState = .error("CallKit: \(error.localizedDescription)")
                }
            }
        }
    }

    func endCall() {
        guard let uuid = activeCallUUID else {
            endSession()
            return
        }
        let action = CXEndCallAction(call: uuid)
        callController.request(CXTransaction(action: action)) { [weak self] error in
            if let error {
                Task { @MainActor [weak self] in
                    self?.endSession()
                    print("[CallKit] End call request failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func endCallAfterSpeaking() {
        if isModelSpeaking {
            pendingEndCall = true
        } else {
            endCall()
        }
    }

    // MARK: - CallKit Handler Methods

    fileprivate func handleStartCallAction(_ action: CXStartCallAction) async {
        action.fulfill()

        let update = CXCallUpdate()
        update.localizedCallerName = "Hivecrew"
        update.hasVideo = action.isVideo
        callKitProvider.reportCall(with: action.callUUID, updated: update)

        await startSession(context: pendingCallContext)
        pendingCallContext = nil

        if connectionState != .connected {
            pendingVideoStart = false
        }
    }

    fileprivate func handleEndCallAction(_ action: CXEndCallAction) {
        endSession()
        action.fulfill()
    }

    fileprivate func handleProviderDidReset() {
        endSession()
        activeCallUUID = nil
        isInCall = false
    }

    /// Called by CallKit once the audio session is activated. Start the VPIO
    /// graph here so its echo-cancellation reference aligns with the active
    /// session -- starting it earlier causes AEC to lose its reference when
    /// CallKit reconfigures the audio hardware.
    fileprivate func handleAudioSessionActivated() async {
        guard callState == .active else { return }
        if audioManager.isCapturing {
            audioManager.stopCapture()
        }
        try? await audioManager.startCapture(voiceProcessingEnabled: true)

        if let uuid = activeCallUUID {
            callKitProvider.reportOutgoingCall(with: uuid, connectedAt: Date())
        }
        if pendingVideoStart {
            pendingVideoStart = false
            await setInputSource(.camera)
        }
    }

    fileprivate func handleAudioSessionDeactivated() {
        audioManager.stopCapture()
    }

    // MARK: - Session Lifecycle

    private var pendingCallContext: IncomingCallContext?

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
            try await audioManager.prepareAudioSession()
            try await provider.connect(config: config)
            connectionState = .connected
            startIdleTimer()
            subscribeToInputLevel()
            subscribeToTaskEvents()
        } catch {
            tearDownSession()
            connectionState = .error(error.localizedDescription)
            callState = .idle
        }
    }

    func endSession() {
        if let uuid = activeCallUUID {
            callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            activeCallUUID = nil
            isInCall = false
        }
        tearDownSession()
        connectionState = .disconnected
        callState = .idle
        isModelSpeaking = false
    }

    private func tearDownSession() {
        pendingEndCall = false
        cancelTimers()
        unsubscribeFromInputLevel()
        teardownTaskObservers()
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
                // Don't disable the echo gate here — audio may still be
                // draining from the playback buffer. onPlaybackFinished
                // disables it after the buffer empties + 300ms cooldown.
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
                self?.connectionState = .error(error.localizedDescription)
            }
        }

        prov.onDisconnected = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.connectionState = .error(event.message)
                if self.callState != .idle {
                    if let uuid = self.activeCallUUID {
                        self.callKitProvider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                        self.activeCallUUID = nil
                        self.isInCall = false
                    }
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
        if let task = taskService?.tasks.first(where: { $0.id == taskId }) {
            lastKnownStatuses[taskId] = task.status
        }
    }

    func clearSession() {
        pendingEndCall = false
        teardownTaskObservers()
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

    // MARK: - Task Event Subscriptions

    private func subscribeToTaskEvents() {
        teardownTaskObservers()

        for taskId in relevantTaskIds {
            if let task = taskService?.tasks.first(where: { $0.id == taskId }) {
                lastKnownStatuses[taskId] = task.status
            }
        }

        taskService?.$tasks
            .receive(on: RunLoop.main)
            .sink { [weak self] tasks in
                self?.handleTaskListUpdate(tasks)
            }
            .store(in: &taskObservers)

        taskService?.peerConnectionManager?.$taskPendingQuestions
            .receive(on: RunLoop.main)
            .sink { [weak self] questions in
                self?.handleQuestionChanges(questions)
            }
            .store(in: &taskObservers)
    }

    private func handleTaskListUpdate(_ tasks: [TaskRecord]) {
        for taskId in relevantTaskIds {
            guard let task = tasks.first(where: { $0.id == taskId }) else { continue }
            let newStatus = task.status
            let oldStatus = lastKnownStatuses[taskId]
            lastKnownStatuses[taskId] = newStatus

            guard oldStatus != nil, oldStatus != newStatus else { continue }

            let workerName = workerRegistry.resolve(query: taskId)?.displayName ?? "Worker"

            switch newStatus {
            case .completed:
                focusedTaskId = taskId
                let summary = task.resultSummary ?? "Task finished."
                var message = "[CALLBACK] \(workerName) finished their task. Result: \(summary)"
                if let deliverables = task.outputFilePaths, !deliverables.isEmpty {
                    message += "\nDeliverables saved at:\n" + deliverables.joined(separator: "\n")
                }
                if allSessionTasksFinished {
                    message += " [ALL_TASKS_DONE] All tasks are now complete. Ask the user if they need anything else, and offer to end the call using the `end_call` tool."
                }
                Task {
                    await resumeIfSuspended()
                    try? await provider?.sendText(message)
                }

            case .failed, .timedOut, .maxIterations, .planFailed:
                focusedTaskId = taskId
                let errorMsg = task.errorMessage ?? "Unknown error."
                var message = "[CALLBACK] \(workerName) failed. Error: \(errorMsg)"
                if allSessionTasksFinished {
                    message += " [ALL_TASKS_DONE] All tasks are now complete. Ask the user if they need anything else, and offer to end the call using the `end_call` tool."
                }
                Task {
                    await resumeIfSuspended()
                    try? await provider?.sendText(message)
                }

            case .cancelled:
                focusedTaskId = taskId
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
    }

    private func handleQuestionChanges(_ allQuestions: [String: APIAgentQuestion]) {
        for taskId in relevantTaskIds {
            let newQuestion = allQuestions[taskId]
            let oldQuestion = activeWorkerQuestions[taskId]

            if let newQuestion, newQuestion.id != oldQuestion?.id {
                activeWorkerQuestions[taskId] = newQuestion

                let workerName = workerRegistry.resolve(query: taskId)?.displayName ?? "Worker"
                var message = "[CALLBACK] \(workerName) needs your input: \(newQuestion.question)"
                if let options = newQuestion.suggestedAnswers, !options.isEmpty {
                    let opts = options.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: ", ")
                    message += " Options: \(opts)"
                }
                message += " — Ask the user and relay their answer using `send_instruction`."

                Task {
                    await resumeIfSuspended()
                    try? await provider?.sendText(message)
                }
            } else if newQuestion == nil, oldQuestion != nil {
                activeWorkerQuestions.removeValue(forKey: taskId)
            }
        }
    }

    private var allSessionTasksFinished: Bool {
        guard let taskService, !relevantTaskIds.isEmpty else { return false }
        let sessionTasks = taskService.tasks.filter { relevantTaskIds.contains($0.id) }
        return !sessionTasks.isEmpty && sessionTasks.allSatisfy { !$0.status.isActive }
    }

    private func resumeIfSuspended() async {
        guard callState == .suspended else { return }
        await resumeCall()
    }

    private func teardownTaskObservers() {
        taskObservers.removeAll()
        lastKnownStatuses.removeAll()
        activeWorkerQuestions.removeAll()
    }

    // MARK: - Suspend / Resume

    func suspendCall() {
        guard callState == .active || callState == .idleTimeout else { return }
        cancelTimers()
        unsubscribeFromInputLevel()
        audioManager.stopCapture()
        audioManager.stopPlayback()
        audioManager.setServerModelSpeaking(false)
        cameraCapture.stopCapture()
        activeInputSource = .none
        callState = .suspended
        isModelSpeaking = false
    }

    func resumeCall() async {
        guard callState == .suspended else { return }
        callState = .active

        audioManager.configure(
            inputSampleRate: provider?.inputSampleRate ?? 16000,
            outputSampleRate: provider?.outputSampleRate ?? 24000
        )
        try? await audioManager.startCapture(voiceProcessingEnabled: true)

        startIdleTimer()
        subscribeToInputLevel()
    }

    // MARK: - Idle / Suspend Timers

    private func startIdleTimer() {
        cancelTimers()
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
