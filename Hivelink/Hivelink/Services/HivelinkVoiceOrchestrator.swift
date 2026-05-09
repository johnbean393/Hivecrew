//
//  HivelinkVoiceOrchestrator.swift
//  Hivelink
//
//  Central coordinator for voice mode on iOS. Adapted from the macOS
//  VoiceOrchestrator — no speaker isolation pipeline, no capture writer,
//  no compact-share mode.
//

import AVFoundation
import CallKit
import Combine
import Foundation
import MediaPlayer
import SafariServices
import SwiftUI
import HivecrewAPIModels
import HivecrewCore
import HivecrewLLM
import HivecrewVoice
import UIKit

// MARK: - Input Source

enum VoiceInputSource: String, CaseIterable, Identifiable {
    case none
    case camera
    case screenBroadcast

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .camera: return "Camera"
        case .screenBroadcast: return "Screen Broadcast"
        }
    }

    var systemImage: String {
        switch self {
        case .none: return "mic.fill"
        case .camera: return "camera.fill"
        case .screenBroadcast: return "rectangle.inset.filled.and.person.filled"
        }
    }
}

enum HivelinkVoiceProvider: String, CaseIterable, Identifiable {
    case gemini
    case openAI = "openai"
    case xAI = "xai"

    var id: String { rawValue }

    var backend: VoiceProviderBackend {
        switch self {
        case .gemini:
            return .geminiLive
        case .openAI:
            return .openAIRealtime
        case .xAI:
            return .xAIRealtime
        }
    }

    var displayName: String {
        switch self {
        case .gemini:
            return "Gemini"
        case .openAI:
            return "OpenAI"
        case .xAI:
            return "xAI"
        }
    }

    static func from(_ rawValue: String) -> Self {
        if rawValue == "openai_oauth" {
            return .openAI
        }
        return Self(rawValue: rawValue) ?? .gemini
    }
}

enum HivelinkOpenAIAuthenticationMode: String {
    case apiKey = "api_key"
    case chatGPTOAuth = "chatgpt_oauth"
}

@MainActor
final class HivelinkChatGPTOAuthController: ObservableObject {
    static let providerId = "hivelink.voice.openai_oauth"

    @Published private(set) var authState: CodexOAuthAuthState = .unauthenticated
    @Published private(set) var authMessage: String?
    @Published private(set) var isAuthenticating = false
    @Published private(set) var presentedAuthorizationURL: URL?

    private var pollingTask: Task<Void, Never>?
    private var loginId: String?

    init() {
        refreshStatus()
    }

    var isConnected: Bool {
        authState == .authenticated
    }

    var isFailed: Bool {
        authState == .failed
    }

    var statusText: String {
        switch authState {
        case .unauthenticated:
            return "Not connected"
        case .pending:
            return "Waiting for sign-in"
        case .authenticated:
            return "Connected"
        case .failed:
            return "Connection failed"
        }
    }

    func refreshStatus() {
        let snapshot = CodexOAuthCoordinator.shared.status(providerId: Self.providerId, loginId: loginId)
        authState = snapshot.status
        authMessage = snapshot.message
    }

    func connect() {
        do {
            let startResult = try CodexOAuthCoordinator.shared.startLogin(providerId: Self.providerId)
            loginId = startResult.loginId
            authState = .pending
            authMessage = startResult.message
            isAuthenticating = true
            presentedAuthorizationURL = startResult.authURL
            startPollingStatus()
        } catch {
            isAuthenticating = false
            authState = .failed
            authMessage = error.localizedDescription
            presentedAuthorizationURL = nil
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    func disconnect() {
        presentedAuthorizationURL = nil
        pollingTask?.cancel()
        pollingTask = nil
        isAuthenticating = false
        loginId = nil
        CodexOAuthCoordinator.shared.logout(providerId: Self.providerId)
        refreshStatus()
    }

    func dismissBrowser() {
        presentedAuthorizationURL = nil
        refreshStatus()
    }

    private func startPollingStatus() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.pollingTask = nil
            }

            while !Task.isCancelled {
                let snapshot = CodexOAuthCoordinator.shared.status(providerId: Self.providerId, loginId: self.loginId)
                self.authState = snapshot.status
                self.authMessage = snapshot.message

                if snapshot.status == .authenticated || snapshot.status == .failed {
                    self.isAuthenticating = false
                    self.presentedAuthorizationURL = nil
                    return
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

struct HivelinkOAuthSafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

enum HivelinkVoicePreferences {
    static let providerKey = "hivelink.voiceProvider"
    static let modelIDKey = "hivelink.voiceModel"
    static let voiceNameKey = "hivelink.voiceName"
    static let apiKeyKey = "hivelink.voiceApiKey"
    static let openAIAuthenticationModeKey = "hivelink.openAIAuthenticationMode"

    private static func perProviderVoiceKey(_ provider: HivelinkVoiceProvider) -> String {
        "hivelink.voiceName.\(provider.rawValue)"
    }

    private static func perProviderModelKey(_ provider: HivelinkVoiceProvider) -> String {
        "hivelink.voiceModel.\(provider.rawValue)"
    }

    private static func perProviderAPIKey(_ provider: HivelinkVoiceProvider) -> String {
        "hivelink.voiceApiKey.\(provider.rawValue)"
    }

    static func availableVoices(for provider: HivelinkVoiceProvider) -> [RealtimeVoiceOption] {
        RealtimeVoiceCatalog.voices(for: provider.backend)
    }

    static func availableModels(for provider: HivelinkVoiceProvider) -> [RealtimeVoiceModelOption] {
        RealtimeVoiceCatalog.models(for: provider.backend)
    }

    static func defaultVoiceName(for provider: HivelinkVoiceProvider) -> String {
        RealtimeVoiceCatalog.defaultVoiceName(for: provider.backend)
    }

    static func defaultModelID(for provider: HivelinkVoiceProvider) -> String {
        RealtimeVoiceCatalog.defaultModelID(for: provider.backend)
    }

    static func normalizedProvider(
        _ providerRawValue: String,
        defaults: UserDefaults = .standard
    ) -> HivelinkVoiceProvider {
        _ = defaults
        return HivelinkVoiceProvider.from(providerRawValue)
    }

    static func normalizedOpenAIAuthenticationMode(
        _ rawValue: String,
        defaults: UserDefaults = .standard
    ) -> HivelinkOpenAIAuthenticationMode {
        _ = defaults
        return HivelinkOpenAIAuthenticationMode(rawValue: rawValue) ?? .apiKey
    }

    static func normalizedVoiceName(_ voiceName: String, for provider: HivelinkVoiceProvider) -> String {
        let trimmed = voiceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultVoiceName(for: provider) }

        if availableVoices(for: provider).contains(where: { $0.id == trimmed }) {
            return trimmed
        }

        return defaultVoiceName(for: provider)
    }

    static func normalizedModelID(_ modelID: String, for provider: HivelinkVoiceProvider) -> String {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultModelID(for: provider) }

        if availableModels(for: provider).contains(where: { $0.id == trimmed }) {
            return trimmed
        }

        return defaultModelID(for: provider)
    }

    @discardableResult
    static func saveVoiceName(
        _ voiceName: String,
        for provider: HivelinkVoiceProvider,
        defaults: UserDefaults = .standard
    ) -> String {
        let normalized = normalizedVoiceName(voiceName, for: provider)
        defaults.set(normalized, forKey: voiceNameKey)
        defaults.set(normalized, forKey: perProviderVoiceKey(provider))
        return normalized
    }

    @discardableResult
    static func saveModelID(
        _ modelID: String,
        for provider: HivelinkVoiceProvider,
        defaults: UserDefaults = .standard
    ) -> String {
        let normalized = normalizedModelID(modelID, for: provider)
        defaults.set(normalized, forKey: modelIDKey)
        defaults.set(normalized, forKey: perProviderModelKey(provider))
        return normalized
    }

    @discardableResult
    static func saveAPIKey(
        _ apiKey: String,
        for provider: HivelinkVoiceProvider,
        defaults: UserDefaults = .standard
    ) -> String {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(trimmed, forKey: apiKeyKey)
        defaults.set(trimmed, forKey: perProviderAPIKey(provider))
        return trimmed
    }

    @discardableResult
    static func restoredVoiceName(
        for provider: HivelinkVoiceProvider,
        currentVoiceName: String? = nil,
        defaults: UserDefaults = .standard
    ) -> String {
        let stored = defaults.string(forKey: perProviderVoiceKey(provider))
            ?? currentVoiceName
            ?? defaults.string(forKey: voiceNameKey)
            ?? ""
        return normalizedVoiceName(stored, for: provider)
    }

    @discardableResult
    static func restoredModelID(
        for provider: HivelinkVoiceProvider,
        currentModelID: String? = nil,
        defaults: UserDefaults = .standard
    ) -> String {
        let stored = defaults.string(forKey: perProviderModelKey(provider))
            ?? currentModelID
            ?? defaults.string(forKey: modelIDKey)
            ?? ""
        return normalizedModelID(stored, for: provider)
    }

    @discardableResult
    static func restoredAPIKey(
        for provider: HivelinkVoiceProvider,
        currentAPIKey: String? = nil,
        defaults: UserDefaults = .standard
    ) -> String {
        let stored = defaults.string(forKey: perProviderAPIKey(provider))
            ?? currentAPIKey
            ?? defaults.string(forKey: apiKeyKey)
            ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func normalizeStoredSelection(
        providerRawValue: String,
        modelID: String,
        voiceName: String,
        defaults: UserDefaults = .standard
    ) -> (provider: HivelinkVoiceProvider, modelID: String, voiceName: String) {
        let provider = normalizedProvider(providerRawValue, defaults: defaults)
        defaults.set(provider.rawValue, forKey: providerKey)
        if providerRawValue == "openai_oauth" {
            defaults.set(HivelinkOpenAIAuthenticationMode.chatGPTOAuth.rawValue, forKey: openAIAuthenticationModeKey)
        }

        let normalizedModelID = restoredModelID(
            for: provider,
            currentModelID: modelID,
            defaults: defaults
        )
        let normalizedVoiceName = restoredVoiceName(
            for: provider,
            currentVoiceName: voiceName,
            defaults: defaults
        )
        _ = saveModelID(normalizedModelID, for: provider, defaults: defaults)
        _ = saveVoiceName(normalizedVoiceName, for: provider, defaults: defaults)
        _ = saveAPIKey(restoredAPIKey(for: provider, defaults: defaults), for: provider, defaults: defaults)
        return (provider, normalizedModelID, normalizedVoiceName)
    }
}

// MARK: - Call State

enum HivelinkCallState: Equatable {
    case idle
    case active
    case idleTimeout
    case suspended
}

// MARK: - Recovery

enum VoiceRecoveryPhase: Equatable {
    case idle
    case reconnecting(reason: String)
    case staleWhileSuspended(reason: String)
    case restarting(reason: String)
    case terminalFailure(reason: String)
}

enum VoiceRecoveryDecision: Equatable {
    case reconnecting
    case deferUntilResume
    case startFreshRestart
    case terminalFailure
}

struct VoiceRecoveryPolicy {
    static func decideNextStep(
        callState: HivelinkCallState,
        hasUsedFreshRestartInCurrentFailureEpisode: Bool
    ) -> VoiceRecoveryDecision {
        if hasUsedFreshRestartInCurrentFailureEpisode {
            return .terminalFailure
        }
        if callState == .suspended {
            return .deferUntilResume
        }
        return .startFreshRestart
    }
}

// MARK: - Transcript Replay

struct VoiceTranscriptReplaySerializer {
    private static let maxChunkLength = 2_000

    static func serialize(entries: [TranscriptEntry]) -> [String] {
        let renderedEntries = entries.compactMap(renderEntry(_:))
        guard !renderedEntries.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""

        for entry in renderedEntries {
            let candidate = current.isEmpty ? entry : "\(current)\n\n\(entry)"
            if candidate.count <= maxChunkLength {
                current = candidate
                continue
            }

            if !current.isEmpty {
                chunks.append(current)
                current = ""
            }

            if entry.count <= maxChunkLength {
                current = entry
                continue
            }

            for fragment in splitLongEntry(entry) {
                chunks.append(fragment)
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }

        return chunks
    }

    static func finalRecoveryInstruction(activeWorkerQuestions: [String: APIAgentQuestion]) -> String {
        var sections: [String] = [
            """
            Transport recovery complete. Continue this same conversation naturally.
            Do not mention that the voice call was restarted, reconnected, or recovered unless the user explicitly asks.
            Treat the replayed transcript as authoritative prior conversation context.
            """
        ]

        if !activeWorkerQuestions.isEmpty {
            let pendingQuestions = activeWorkerQuestions.map {
                "- \($0.key): \($0.value.question)"
            }.joined(separator: "\n")
            sections.append(
                """
                The following worker questions are still unresolved:
                \(pendingQuestions)
                """
            )
        }

        return sections.joined(separator: "\n\n")
    }

    private static func renderEntry(_ entry: TranscriptEntry) -> String? {
        switch entry.content {
        case .text(let text):
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            return "\(entry.role.replayLabel): \(normalized)"
        case .toolUse(let record):
            var lines = [
                "Tool \(record.toolName): \(record.summary)"
            ]
            let normalizedDetail = record.detail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedDetail.isEmpty, normalizedDetail != record.summary {
                lines.append(normalizedDetail)
            }
            let selectedFiles = record.fileResults.filter(\.isSelected).map(\.path)
            if !selectedFiles.isEmpty {
                lines.append("Selected files:\n" + selectedFiles.joined(separator: "\n"))
            }
            if let previewFilePath = record.previewFilePath, !previewFilePath.isEmpty {
                lines.append("Preview file: \(previewFilePath)")
            }
            return lines.joined(separator: "\n")
        case .deliverables(let workerName, let filePaths):
            return "Deliverables from \(workerName):\n" + filePaths.joined(separator: "\n")
        }
    }

    private static func splitLongEntry(_ entry: String) -> [String] {
        var fragments: [String] = []
        var remaining = entry[...]

        while remaining.count > maxChunkLength {
            let splitIndex = remaining.index(remaining.startIndex, offsetBy: maxChunkLength)
            fragments.append(String(remaining[..<splitIndex]))
            remaining = remaining[splitIndex...]
        }

        if !remaining.isEmpty {
            fragments.append(String(remaining))
        }

        return fragments
    }
}

private extension TranscriptEntry.Role {
    var replayLabel: String {
        switch self {
        case .user: return "User"
        case .model: return "Assistant"
        case .tool: return "Tool"
        }
    }
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

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self] in
            guard let orchestrator = self?.orchestrator else {
                action.fail()
                return
            }
            await orchestrator.handleAnswerCallAction(action)
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
    let broadcastReceiver = iOSScreenBroadcastReceiver()
    let workerRegistry = WorkerRegistry()

    // MARK: - CallKit

    private(set) var callKitProvider: CXProvider?
    private var callController: CXCallController?
    private var callKitDelegate: CallKitDelegate?
    private var activeCallUUID: UUID?
    /// Whether a video source was requested when the call was started via CallKit.
    private var pendingVideoStart = false
    @Published private(set) var isInCall = false

    // MARK: - External Dependencies

    private let appStoreRegionPolicy: AppStoreRegionPolicy
    private(set) weak var taskService: HivelinkTaskService?
    private(set) weak var incomingCallManager: IncomingCallManager?

    func configure(taskService: HivelinkTaskService) {
        self.taskService = taskService
    }

    func configure(incomingCallManager: IncomingCallManager) {
        self.incomingCallManager = incomingCallManager
    }

    // MARK: - Haptics

    let voiceHapticsEngine = VoiceHapticsEngine()
    private var hapticLevelCancellable: AnyCancellable?

    // MARK: - Published State

    @Published var callState: HivelinkCallState = .idle {
        didSet {
            switch callState {
            case .active where oldValue == .idle:
                voiceHapticsEngine.connectStarted()
                updateNowPlaying(state: .playing)
            case .active where oldValue == .suspended:
                updateNowPlaying(state: .playing)
            case .suspended:
                voiceHapticsEngine.suspended()
                updateNowPlaying(state: .paused)
            case .idle where oldValue != .idle:
                voiceHapticsEngine.ended()
                stopHapticLevelForwarding()
                clearNowPlaying()
            default:
                break
            }
        }
    }
    @Published var connectionState: VoiceConnectionState = .disconnected {
        didSet {
            switch connectionState {
            case .connected where oldValue != .connected:
                voiceHapticsEngine.connected()
                startHapticLevelForwarding()
            case .error:
                voiceHapticsEngine.error()
            case .disconnected where oldValue == .connected:
                stopHapticLevelForwarding()
            default:
                break
            }
        }
    }
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
    private var recoveryPhase: VoiceRecoveryPhase = .idle
    private var hasUsedFreshRestartInCurrentFailureEpisode = false
    private var isReplayingRecoveryTranscript = false

    /// Prefix to strip from model output transcriptions after a tool call.
    private var modelTranscriptPrefixToStrip: String = ""
    private lazy var toolCallCoordinator = VoiceToolCallCoordinator { [weak self] toolCalls in
        Task { @MainActor [weak self] in
            await self?.handleToolCallBatch(toolCalls)
        }
    }

    // MARK: - Settings

    @AppStorage("hivelink.voiceProvider") private var voiceProviderRaw = HivelinkVoiceProvider.openAI.rawValue
    @AppStorage("hivelink.voiceApiKey") private var voiceApiKey = ""
    @AppStorage("hivelink.voiceModel") private var voiceModelID = HivelinkVoicePreferences.defaultModelID(for: .openAI)
    @AppStorage("hivelink.voiceName") private var voiceName = "marin"
    @AppStorage("hivelink.openAIAuthenticationMode")
    private var openAIAuthenticationModeRaw = HivelinkOpenAIAuthenticationMode.chatGPTOAuth.rawValue
    @AppStorage("hivelink.mediaResolution") private var mediaResolutionRaw = "medium"
    @AppStorage("hivelink.reasoningEffort") private var reasoningEffortRaw = "low"

    @Published private(set) var voiceConfigurationVersion = 0

    private var selectedVoiceProvider: HivelinkVoiceProvider {
        HivelinkVoicePreferences.normalizedProvider(voiceProviderRaw)
    }

    private var selectedOpenAIAuthenticationMode: HivelinkOpenAIAuthenticationMode {
        HivelinkVoicePreferences.normalizedOpenAIAuthenticationMode(openAIAuthenticationModeRaw)
    }

    var isVoiceConfigured: Bool {
        switch selectedVoiceProvider {
        case .gemini:
            return !selectedAPIKey.isEmpty
        case .xAI:
            return !selectedAPIKey.isEmpty
        case .openAI:
            switch selectedOpenAIAuthenticationMode {
            case .apiKey:
                return !selectedAPIKey.isEmpty
            case .chatGPTOAuth:
                return CodexOAuthTokenStore.retrieve(providerId: HivelinkChatGPTOAuthController.providerId) != nil
            }
        }
    }

    var backend: VoiceProviderBackend {
        selectedVoiceProvider.backend
    }

    var supportsVideoInput: Bool {
        backend != .xAIRealtime
    }

    private var resolvedVoiceName: String {
        HivelinkVoicePreferences.restoredVoiceName(
            for: selectedVoiceProvider,
            currentVoiceName: voiceName
        )
    }

    private var selectedModel: String {
        HivelinkVoicePreferences.restoredModelID(
            for: selectedVoiceProvider,
            currentModelID: voiceModelID
        )
    }

    private var selectedAPIKey: String {
        HivelinkVoicePreferences.restoredAPIKey(
            for: selectedVoiceProvider,
            currentAPIKey: voiceApiKey
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeAudioPolicy() -> VoiceSessionConfig.AudioPolicy {
        let openAIConfig = VoiceSessionConfig.AudioPolicy.OpenAI(
            turnDetection: .server(
                threshold: 0.5,
                prefixPaddingMs: 300,
                silenceDurationMs: 700
            ),
            createResponse: true,
            interruptResponse: true,
            noiseReduction: .farField
        )

        let geminiConfig = VoiceSessionConfig.AudioPolicy.Gemini(
            automaticActivityDetectionEnabled: true,
            startOfSpeechSensitivity: .low,
            endOfSpeechSensitivity: .low,
            prefixPaddingMs: 180,
            silenceDurationMs: 700,
            activityHandling: .startOfActivityInterrupts,
            turnCoverage: nil
        )

        return VoiceSessionConfig.AudioPolicy(
            preset: .noisyRoom,
            streamEndBehavior: .init(sendOnMute: true, sendOnSuspend: true, sendOnCallEnd: true),
            localSpeakerIsolation: .init(enabled: false),
            openAI: openAIConfig,
            gemini: geminiConfig
        )
    }

    func notifyVoiceConfigurationChanged() {
        voiceConfigurationVersion += 1
        guard !supportsVideoInput, activeInputSource != .none else { return }
        Task { @MainActor [weak self] in
            await self?.setInputSource(.none)
        }
    }

    // MARK: - Internal

    private var cancellables = Set<AnyCancellable>()
    private var idleTimer: Timer?
    private var suspendTimer: Timer?
    private var inputLevelCancellable: AnyCancellable?
    private var taskObservers: [AnyCancellable] = []
    private var lastKnownStatuses: [String: TaskStatus] = [:]
    private static let agentPlaybackGain: Float = 0.6

    init(appStoreRegionPolicy: AppStoreRegionPolicy = .shared) {
        self.appStoreRegionPolicy = appStoreRegionPolicy
        audioManager.playbackGain = Self.agentPlaybackGain

        setupAudioCallbacks()
        setupVideoCallbacks()
        setupLifecycleObservers()
        configureCallKitIfAllowed()

        appStoreRegionPolicy.$installStorefrontCountryCode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshCallKitAvailability()
            }
            .store(in: &cancellables)

        audioManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func refreshCallKitAvailability() {
        if appStoreRegionPolicy.isCallKitAllowed {
            configureCallKitIfAllowed()
        } else {
            disableCallKit()
        }
    }

    private func configureCallKitIfAllowed() {
        guard appStoreRegionPolicy.isCallKitAllowed else { return }
        guard callKitProvider == nil else { return }

        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.supportedHandleTypes = [.generic]
        config.maximumCallsPerCallGroup = 1
        config.includesCallsInRecents = true
        config.iconTemplateImageData = UIImage(named: "AppIcon")?.pngData()

        let provider = CXProvider(configuration: config)
        callKitProvider = provider
        callController = CXCallController()

        let delegate = CallKitDelegate()
        callKitDelegate = delegate

        delegate.orchestrator = self
        provider.setDelegate(delegate, queue: nil)
        VoIPDiagnosticsLog.log("[HivelinkVoiceOrchestrator] CallKit configured")
    }

    private func disableCallKit() {
        guard callKitProvider != nil || callController != nil || callKitDelegate != nil else { return }
        callKitProvider?.setDelegate(nil, queue: nil)
        callKitProvider = nil
        callController = nil
        callKitDelegate = nil
        activeCallUUID = nil
        pendingVideoStart = false
        VoIPDiagnosticsLog.log("[HivelinkVoiceOrchestrator] CallKit disabled for App Store storefront")
    }

    // MARK: - CallKit Call Lifecycle

    func startCall(video: Bool = false, context: IncomingCallContext? = nil) {
        guard callState == .idle else { return }
        let requestedVideo = video && supportsVideoInput

        guard appStoreRegionPolicy.isCallKitAllowed else {
            isInCall = true
            pendingVideoStart = requestedVideo
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.startSession(context: context)
                if self.connectionState != .connected {
                    self.isInCall = false
                    self.pendingVideoStart = false
                }
            }
            return
        }

        configureCallKitIfAllowed()
        guard let callController else {
            connectionState = .error("CallKit is unavailable.")
            return
        }

        let uuid = UUID()
        activeCallUUID = uuid
        isInCall = true
        pendingVideoStart = requestedVideo
        pendingCallContext = context

        let handle = CXHandle(type: .generic, value: "Hivecrew Voice")
        let action = CXStartCallAction(call: uuid, handle: handle)
        action.isVideo = requestedVideo

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
        guard appStoreRegionPolicy.isCallKitAllowed, let callController else {
            endSession()
            return
        }

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
        UIDevice.current.isProximityMonitoringEnabled = true

        let update = CXCallUpdate()
        update.localizedCallerName = "Hivecrew"
        update.hasVideo = action.isVideo
        callKitProvider?.reportCall(with: action.callUUID, updated: update)

        await startSession(context: pendingCallContext)
        pendingCallContext = nil

        if connectionState != .connected {
            pendingVideoStart = false
        }
    }

    fileprivate func handleAnswerCallAction(_ action: CXAnswerCallAction) async {
        let context = incomingCallManager?.contextForAnsweredCall(uuid: action.callUUID)

        activeCallUUID = action.callUUID
        isInCall = true
        UIDevice.current.isProximityMonitoringEnabled = true
        HapticManager.incomingCallAnswered()
        action.fulfill()

        AppDependencyManager.shared.setSelectedTab?(1)

        await startSession(context: context)
    }

    fileprivate func handleEndCallAction(_ action: CXEndCallAction) {
        // Check if this is a declined incoming call (never answered).
        if callState == .idle, let incomingCallManager {
            incomingCallManager.handleDeclinedCall(uuid: action.callUUID)
            action.fulfill()
            return
        }
        endSession()
        action.fulfill()
    }

    fileprivate func handleProviderDidReset() {
        endSession()
        activeCallUUID = nil
        isInCall = false
        UIDevice.current.isProximityMonitoringEnabled = false
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

        if let uuid = activeCallUUID, let callKitProvider {
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

        let authentication: VoiceProviderAuthentication
        switch selectedVoiceProvider {
        case .gemini:
            guard !selectedAPIKey.isEmpty else {
                connectionState = .error("No Gemini API key configured. Add one in Settings → Voice.")
                return
            }
            authentication = .apiKey(selectedAPIKey)
        case .xAI:
            guard !selectedAPIKey.isEmpty else {
                connectionState = .error("No xAI API key configured. Add one in Settings → Voice.")
                return
            }
            authentication = .apiKey(selectedAPIKey)
        case .openAI:
            switch selectedOpenAIAuthenticationMode {
            case .apiKey:
                guard !selectedAPIKey.isEmpty else {
                    connectionState = .error("No OpenAI API key configured. Add one in Settings → Voice.")
                    return
                }
                authentication = .apiKey(selectedAPIKey)
            case .chatGPTOAuth:
                guard CodexOAuthTokenStore.retrieve(providerId: HivelinkChatGPTOAuthController.providerId) != nil else {
                    connectionState = .error("No ChatGPT OAuth connection configured. Sign in from Settings → Voice.")
                    return
                }
                authentication = .bearerToken {
                    try await resolveChatGPTOAuthAccessToken(providerId: HivelinkChatGPTOAuthController.providerId)
                }
            }
        }

        clearSession()
        connectionState = .connecting
        callState = .active

        let provider = RealtimeVoiceService.shared.createProvider(
            backend: backend,
            authentication: authentication,
            model: selectedModel
        )
        self.provider = provider
        wireProviderCallbacks(provider)

        let systemPrompt = makeSystemPrompt(context: context)

        let config = VoiceSessionConfig(
            systemPrompt: systemPrompt,
            voiceName: resolvedVoiceName,
            tools: HivelinkToolHandler.toolDeclarations(supportsVisualInput: supportsVideoInput),
            mediaResolution: VoiceSessionConfig.MediaResolution(rawValue: mediaResolutionRaw) ?? .medium,
            thinkingLevel: VoiceSessionConfig.ThinkingLevel(rawValue: reasoningEffortRaw) ?? .low,
            includeThoughts: true,
            webSearchEnabled: true,
            audioPolicy: makeAudioPolicy()
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

            if !appStoreRegionPolicy.isCallKitAllowed {
                if audioManager.isCapturing {
                    audioManager.stopCapture()
                }
                try await audioManager.startCapture(voiceProcessingEnabled: true)

                if pendingVideoStart {
                    pendingVideoStart = false
                    await setInputSource(.camera)
                }
            }

            // With CallKit, mic capture is deferred until didActivate. For
            // notification callback mode, capture starts above after connect.
            if context != nil {
                try? await provider.sendText("[SYSTEM] The user just answered the call. Greet them and address the call reason now.")
            }
        } catch {
            tearDownSession()
            connectionState = .error(error.localizedDescription)
            callState = .idle
        }
    }

    func endSession() {
        if let uuid = activeCallUUID {
            callKitProvider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
            activeCallUUID = nil
        }
        isInCall = false
        UIDevice.current.isProximityMonitoringEnabled = false
        tearDownSession()
        connectionState = .disconnected
        callState = .idle
        isModelSpeaking = false
        recoveryPhase = .idle
        hasUsedFreshRestartInCurrentFailureEpisode = false
        isReplayingRecoveryTranscript = false
    }

    // MARK: - Inline Delivery (during active call)

    /// Injects a text update into the active voice session when a VoIP push
    /// is suppressed because the user is already in a call.
    func deliverInlineUpdate(context: IncomingCallContext) {
        guard callState == .active || callState == .suspended else { return }
        let message: String
        switch context.trigger {
        case .completed:
            message = "[INLINE_UPDATE] By the way, \(context.workerName) just finished: \(context.summary)"
        case .failed:
            message = "[INLINE_UPDATE] Heads up — \(context.workerName) failed: \(context.summary)"
        case .question:
            message = "[INLINE_UPDATE] \(context.workerName) has a question: \(context.summary)"
        case .permission:
            message = "[INLINE_UPDATE] \(context.workerName) needs permission: \(context.summary)"
        case .planReady:
            message = "[INLINE_UPDATE] A plan is ready for review: \(context.summary)"
        case .writebackReady:
            message = "[INLINE_UPDATE] Changes are ready for review: \(context.summary)"
        }
        Task {
            await resumeIfSuspended()
            try? await provider?.sendText(message)
        }
    }

    private func tearDownSession() {
        pendingEndCall = false
        cancelTimers()
        unsubscribeFromInputLevel()
        teardownTaskObservers()
        audioManager.stopCapture()
        audioManager.stopPlayback()
        cameraCapture.stopCapture()
        broadcastReceiver.stopMonitoring()
        activeInputSource = .none

        let activeProvider = provider
        provider = nil
        activeProvider?.disconnect()
    }

    // MARK: - System Prompt

    private func makeSystemPrompt(context: IncomingCallContext?) -> String {
        OrchestratorSystemPrompt.allowEndCallWithActiveTasks = true
        var prompt = OrchestratorSystemPrompt.build(
            voiceName: voiceName.capitalized,
            excludedTools: HivelinkToolHandler.unsupportedTools
        )

        let existingTasksSummary = importActiveTasks()
        if !existingTasksSummary.isEmpty {
            prompt += "\n\n" + existingTasksSummary
        }

        if let context {
            prompt += buildCallReasonSection(context: context)
        }

        return prompt
    }

    private func buildCallReasonSection(context: IncomingCallContext) -> String {
        var section = "\n\n## [CALL REASON]\n"
        section += "Task: \(context.workerName)\nTask ID: \(context.taskId)\n"

        let task = taskService?.tasks.first { $0.id == context.taskId }
        let worker = workerRegistry.resolve(query: context.taskId)
        if let worker {
            section += "Worker name: \(worker.displayName)\n"
        }

        switch context.trigger {
        case .planReady:
            section += """
            A worker has finished planning and the plan is ready for your review.
            Summarize the plan for the user concisely — hit the key steps and ask if they want \
            to approve it, modify it, or reject it.
            - To approve: use `approve_plan` with the task ID.
            - To reject: use `reject_plan` with the task ID.
            - If the user wants changes, use `send_instruction` to tell the worker, then wait for \
            the updated plan.
            """
            if let plan = task?.planMarkdown, !plan.isEmpty {
                let truncated = plan.count > 3000 ? String(plan.prefix(3000)) + "\n[...truncated]" : plan
                section += "\n### Plan content\n\(truncated)\n"
            }

        case .writebackReady:
            let count = task?.pendingWritebackOperations.count ?? 0
            section += """
            A worker has \(count) file change\(count == 1 ? "" : "s") ready to write back to disk.
            Briefly describe what files are being changed and ask the user if they want to approve \
            or discard the changes.
            - To approve: use `approve_writeback` with the task ID.
            - To discard: use `discard_writeback` with the task ID.
            """

        case .question:
            section += """
            A worker has a question that needs the user's input.
            Question: \(context.summary)
            Relay the question naturally to the user, get their answer, then use `send_instruction` \
            with the task ID and the user's response.
            """

        case .permission:
            section += """
            A worker needs permission to proceed with an action.
            Details: \(context.summary)
            Explain what the worker wants to do and ask the user to approve or deny.
            """

        case .completed:
            section += """
            A worker has finished their task.
            Result: \(context.summary)
            Tell the user what was accomplished. Any output files are available on their device.
            """

        case .failed:
            section += """
            A worker's task has failed.
            Error: \(context.summary)
            Tell the user what went wrong and suggest next steps (retry, adjust, etc.).
            """
        }

        section += "\nAddress this reason naturally at the start of the conversation."
        return section
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
                self.toolCallCoordinator.enqueue(toolCall)
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
                self.toolCallCoordinator.flushNow()
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
                if self.recoveryPhase == .idle {
                    self.connectionState = .error(error.localizedDescription)
                }
            }
        }

        prov.onDisconnected = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleProviderDisconnect(event)
            }
        }

        prov.onInputActivity = { _ in }
        prov.onUsageUpdate = { _ in }
        prov.onReconnecting = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recoveryPhase = .reconnecting(reason: "Attempting to resume session")
                self.connectionState = .reconnecting
            }
        }
        prov.onReconnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.recoveryPhase = .idle
                self.hasUsedFreshRestartInCurrentFailureEpisode = false
                self.connectionState = .connected
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
                guard self?.supportsVideoInput == true else { return }
                try? await self?.provider?.sendVideoFrame(data)
            }
        }
        broadcastReceiver.onFrameReceived = { [weak self] data in
            Task { @MainActor [weak self] in
                guard self?.supportsVideoInput == true else { return }
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

    private func sendProviderToolResponses(_ responses: [VoiceToolResponse]) async {
        guard !responses.isEmpty else { return }
        do {
            if let batchingProvider = provider as? any RealtimeVoiceToolResponseBatching {
                try await batchingProvider.sendToolResponses(responses)
            } else {
                for response in responses {
                    try await provider?.sendToolResponse(
                        callId: response.callId,
                        name: response.name,
                        result: response.result
                    )
                }
            }
        } catch {
            connectionState = .error(error.localizedDescription)
        }
    }

    private func handleToolCall(_ toolCall: VoiceToolCall) async {
        await handleToolCallBatch([toolCall])
    }

    private func handleToolCallBatch(_ toolCalls: [VoiceToolCall]) async {
        guard !toolCalls.isEmpty else { return }
        var completed: [(VoiceToolCall, HivelinkToolCallResult)] = []

        for segment in VoiceToolExecutionPlanner.segments(for: toolCalls) {
            if segment.runsInParallel, segment.toolCalls.count > 1 {
                let segmentResults = await withTaskGroup(
                    of: (Int, VoiceToolCall, HivelinkToolCallResult).self,
                    returning: [(VoiceToolCall, HivelinkToolCallResult)].self
                ) { group in
                    for (index, toolCall) in segment.toolCalls.enumerated() {
                        group.addTask {
                            let result = await self.executeToolCall(toolCall)
                            return (index, toolCall, result)
                        }
                    }

                    var indexedResults: [(Int, VoiceToolCall, HivelinkToolCallResult)] = []
                    for await result in group {
                        indexedResults.append(result)
                    }
                    return indexedResults
                        .sorted { $0.0 < $1.0 }
                        .map { ($0.1, $0.2) }
                }
                completed.append(contentsOf: segmentResults)
            } else {
                for toolCall in segment.toolCalls {
                    completed.append((toolCall, await executeToolCall(toolCall)))
                }
            }
        }

        for (_, result) in completed {
            if let record = result.transcriptRecord {
                transcript.append(.toolUse(record))
            }

            if let imageData = result.imageData, supportsVideoInput {
                try? await provider?.sendVideoFrame(imageData)
            }
        }

        await sendProviderToolResponses(
            completed.map { toolCall, result in
                VoiceToolResponse(callId: toolCall.id, name: toolCall.name, result: result.text)
            }
        )
    }

    private func executeToolCall(_ toolCall: VoiceToolCall) async -> HivelinkToolCallResult {
        resetIdleTimer()
        guard let taskService else {
            return .textOnly("Voice tool failed: task service is unavailable.")
        }

        if let lastModel = transcript.last(where: { $0.role == .model }),
           case .text(let prevText) = lastModel.content {
            modelTranscriptPrefixToStrip = prevText
        }

        return await HivelinkToolHandler.handle(
            toolCall: toolCall,
            taskService: taskService,
            workerRegistry: workerRegistry,
            cameraCapture: cameraCapture,
            orchestrator: self
        )
    }

    // MARK: - Mute

    func toggleMute() {
        isMuted.toggle()
    }

    // MARK: - Input Source

    func setInputSource(_ source: VoiceInputSource) async {
        let source = supportsVideoInput ? source : .none
        let oldSource = activeInputSource
        activeInputSource = source

        if oldSource == .camera && source != .camera {
            cameraCapture.stopCapture()
        }
        if oldSource == .screenBroadcast && source != .screenBroadcast {
            broadcastReceiver.stopMonitoring()
        }

        switch source {
        case .camera:
            if !cameraCapture.isCapturing {
                do {
                    try await cameraCapture.startCapture()
                } catch {
                    activeInputSource = .none
                }
            }
        case .screenBroadcast:
            broadcastReceiver.startMonitoring()
        case .none:
            break
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
        toolCallCoordinator.reset()
        recoveryPhase = .idle
        hasUsedFreshRestartInCurrentFailureEpisode = false
        isReplayingRecoveryTranscript = false
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

            case .planReview:
                focusedTaskId = taskId
                var message = "[CALLBACK] \(workerName) has finished planning and the plan is ready for review."
                if let plan = task.planMarkdown, !plan.isEmpty {
                    let truncated = plan.count > 3000 ? String(plan.prefix(3000)) + "\n[...truncated]" : plan
                    message += "\n\nPlan:\n\(truncated)"
                }
                message += "\n\nSummarize the key steps for the user. To approve, use `approve_plan`. To reject, use `reject_plan`. If the user wants changes, use `send_instruction`."
                Task {
                    await resumeIfSuspended()
                    try? await provider?.sendText(message)
                }

            case .writebackReview:
                focusedTaskId = taskId
                let count = task.pendingWritebackOperations.count
                let message = "[CALLBACK] \(workerName) has \(count) file change\(count == 1 ? "" : "s") ready to write back. Ask the user if they want to approve or discard the changes. Use `approve_writeback` to approve or `discard_writeback` to discard."
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

    // MARK: - Disconnect Recovery

    private func handleProviderDisconnect(_ event: VoiceDisconnectEvent) {
        guard backend == .geminiLive, callState != .idle else {
            failCallTerminal(reason: event.message)
            return
        }

        switch VoiceRecoveryPolicy.decideNextStep(
            callState: callState,
            hasUsedFreshRestartInCurrentFailureEpisode: hasUsedFreshRestartInCurrentFailureEpisode
        ) {
        case .deferUntilResume:
            recoveryPhase = .staleWhileSuspended(reason: event.message)
            connectionState = .error(event.message)
        case .startFreshRestart:
            Task { @MainActor [weak self] in
                await self?.performFreshCallRestart(reason: event.message)
            }
        case .terminalFailure:
            failCallTerminal(reason: event.message)
        case .reconnecting:
            break
        }
    }

    private func performFreshCallRestart(reason: String) async {
        guard VoiceRecoveryPolicy.decideNextStep(
            callState: callState,
            hasUsedFreshRestartInCurrentFailureEpisode: hasUsedFreshRestartInCurrentFailureEpisode
        ) != .terminalFailure else {
            failCallTerminal(reason: reason)
            return
        }

        hasUsedFreshRestartInCurrentFailureEpisode = true
        recoveryPhase = .restarting(reason: reason)
        connectionState = .connecting

        let priorCallState = callState

        // Tear down the current provider without ending the CallKit call
        cancelTimers()
        unsubscribeFromInputLevel()
        audioManager.stopCapture()
        audioManager.stopPlayback()
        audioManager.setServerModelSpeaking(false)
        cameraCapture.stopCapture()
        broadcastReceiver.stopMonitoring()
        activeInputSource = .none
        let oldProvider = provider
        provider = nil
        oldProvider?.disconnect()

        callState = priorCallState == .suspended ? .suspended : .active
        isModelSpeaking = false

        do {
            let authentication: VoiceProviderAuthentication
            switch selectedVoiceProvider {
            case .gemini:
                guard !selectedAPIKey.isEmpty else {
                    failCallTerminal(reason: "No Gemini API key configured.")
                    return
                }
                authentication = .apiKey(selectedAPIKey)
            case .xAI:
                guard !selectedAPIKey.isEmpty else {
                    failCallTerminal(reason: "No xAI API key configured.")
                    return
                }
                authentication = .apiKey(selectedAPIKey)
            case .openAI:
                switch selectedOpenAIAuthenticationMode {
                case .apiKey:
                    guard !selectedAPIKey.isEmpty else {
                        failCallTerminal(reason: "No OpenAI API key configured.")
                        return
                    }
                    authentication = .apiKey(selectedAPIKey)
                case .chatGPTOAuth:
                    guard CodexOAuthTokenStore.retrieve(providerId: HivelinkChatGPTOAuthController.providerId) != nil else {
                        failCallTerminal(reason: "No ChatGPT OAuth connection configured.")
                        return
                    }
                    authentication = .bearerToken {
                        try await resolveChatGPTOAuthAccessToken(providerId: HivelinkChatGPTOAuthController.providerId)
                    }
                }
            }

            let newProvider = RealtimeVoiceService.shared.createProvider(
                backend: backend,
                authentication: authentication,
                model: selectedModel
            )
            self.provider = newProvider
            wireProviderCallbacks(newProvider)

            let systemPrompt = makeSystemPrompt(context: nil)
            let config = VoiceSessionConfig(
                systemPrompt: systemPrompt,
                voiceName: resolvedVoiceName,
                tools: HivelinkToolHandler.toolDeclarations(supportsVisualInput: supportsVideoInput),
                mediaResolution: VoiceSessionConfig.MediaResolution(rawValue: mediaResolutionRaw) ?? .medium,
                thinkingLevel: .low,
                includeThoughts: true,
                webSearchEnabled: true,
                audioPolicy: makeAudioPolicy()
            )

            audioManager.configure(
                inputSampleRate: newProvider.inputSampleRate,
                outputSampleRate: newProvider.outputSampleRate
            )

            try await audioManager.prepareAudioSession()
            try await newProvider.connect(config: config)
            try await replayTranscriptIfNeeded(using: newProvider)

            if priorCallState != .suspended {
                try await audioManager.startCapture(voiceProcessingEnabled: true)
                startIdleTimer()
                subscribeToInputLevel()
                callState = .active
            } else {
                callState = .suspended
            }

            connectionState = .connected
            recoveryPhase = .idle
        } catch {
            failCallTerminal(reason: error.localizedDescription)
        }
    }

    private func replayTranscriptIfNeeded(using provider: any RealtimeVoiceProvider) async throws {
        let replayChunks = VoiceTranscriptReplaySerializer.serialize(entries: transcript)
        guard !replayChunks.isEmpty else { return }

        isReplayingRecoveryTranscript = true
        defer { isReplayingRecoveryTranscript = false }

        for (index, chunk) in replayChunks.enumerated() {
            try await provider.sendText(
                """
                [RECOVERY_TRANSCRIPT_CHUNK \(index + 1)/\(replayChunks.count)]
                Historical conversation context. Do not acknowledge this chunk.

                \(chunk)
                """
            )
        }

        try await provider.sendText(
            VoiceTranscriptReplaySerializer.finalRecoveryInstruction(
                activeWorkerQuestions: activeWorkerQuestions
            )
        )
    }

    private func failCallTerminal(reason: String) {
        recoveryPhase = .terminalFailure(reason: reason)
        isReplayingRecoveryTranscript = false
        connectionState = .error(reason)
        if callState != .idle {
            if let uuid = activeCallUUID {
                callKitProvider?.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
                activeCallUUID = nil
            }
            isInCall = false
            UIDevice.current.isProximityMonitoringEnabled = false
            tearDownSession()
            callState = .idle
        }
    }

    // MARK: - App Lifecycle

    private func setupLifecycleObservers() {
        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.callState == .active || self.callState == .idleTimeout {
                    self.suspendCall()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                guard self.provider != nil, self.callState == .suspended else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.provider?.validateConnection()
                    } catch {
                        self.handleProviderDisconnect(
                            VoiceDisconnectEvent(message: error.localizedDescription, recoverable: false)
                        )
                    }
                }
            }
            .store(in: &cancellables)
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
        broadcastReceiver.stopMonitoring()
        activeInputSource = .none
        callState = .suspended
        isModelSpeaking = false
    }

    func resumeCall() async {
        guard callState == .suspended else { return }

        if case .staleWhileSuspended(let reason) = recoveryPhase {
            await performFreshCallRestart(reason: reason)
            if case .terminalFailure = recoveryPhase {
                return
            }
        } else if let provider {
            do {
                try await provider.validateConnection()
            } catch {
                handleProviderDisconnect(
                    VoiceDisconnectEvent(message: error.localizedDescription, recoverable: false)
                )
                if case .staleWhileSuspended = recoveryPhase {
                    await performFreshCallRestart(reason: error.localizedDescription)
                    if case .terminalFailure = recoveryPhase {
                        return
                    }
                }
            }
        }

        callState = .active
        audioManager.configure(
            inputSampleRate: provider?.inputSampleRate ?? 16000,
            outputSampleRate: provider?.outputSampleRate ?? 24000
        )
        try? await audioManager.startCapture(voiceProcessingEnabled: true)
        recoveryPhase = .idle
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

    // MARK: - Now Playing

    private func updateNowPlaying(state: NowPlayingState) {
        let center = MPNowPlayingInfoCenter.default()

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: "Hivelink",
            MPMediaItemPropertyArtist: voiceDisplayName,
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]

        if let iconImage = UIImage(named: "AppIcon") ?? UIImage(named: "hivecrew-icon") {
            let artwork = MPMediaItemArtwork(boundsSize: iconImage.size) { _ in iconImage }
            info[MPMediaItemPropertyArtwork] = artwork
        }

        center.nowPlayingInfo = info
        center.playbackState = state == .playing ? .playing : .paused
    }

    private func clearNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private enum NowPlayingState {
        case playing, paused
    }

    // MARK: - Haptic Level Forwarding

    private func startHapticLevelForwarding() {
        hapticLevelCancellable?.cancel()
        hapticLevelCancellable = $inputLevel
            .merge(with: $outputLevel)
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.isModelSpeaking {
                    self.voiceHapticsEngine.modelSpeakingTick(level: self.outputLevel)
                } else if !self.isMuted {
                    self.voiceHapticsEngine.listeningPulse(level: self.inputLevel)
                }
            }
    }

    private func stopHapticLevelForwarding() {
        hapticLevelCancellable?.cancel()
        hapticLevelCancellable = nil
        voiceHapticsEngine.stop()
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
        case deliverables(workerName: String, filePaths: [String])
    }

    let id = UUID()
    let role: Role
    let content: Content
    let timestamp: Date

    var text: String {
        switch content {
        case .text(let str): return str
        case .toolUse(let record): return record.summary
        case .deliverables(let worker, let paths):
            return "\(worker) — \(paths.count) file\(paths.count == 1 ? "" : "s")"
        }
    }

    static func speech(role: Role, text: String, timestamp: Date = Date()) -> TranscriptEntry {
        TranscriptEntry(role: role, content: .text(text), timestamp: timestamp)
    }

    static func toolUse(_ record: ToolUseRecord, timestamp: Date = Date()) -> TranscriptEntry {
        TranscriptEntry(role: .tool, content: .toolUse(record), timestamp: timestamp)
    }

    static func deliverables(workerName: String, filePaths: [String], timestamp: Date = Date()) -> TranscriptEntry {
        TranscriptEntry(role: .tool, content: .deliverables(workerName: workerName, filePaths: filePaths), timestamp: timestamp)
    }
}

// MARK: - Tool Use Record

struct ToolUseRecord: Identifiable, Equatable, Sendable {
    let id = UUID()
    let toolName: String
    let summary: String
    let detail: String
    var fileResults: [VoiceFileSearchResult]
    var previewFilePath: String?
}

struct VoiceFileSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let path: String
    let sourceType: String
    let relevanceScore: Double
    var isSelected: Bool = false
}
