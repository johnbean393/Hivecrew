//
//  OnboardingProviderStep.swift
//  Hivecrew
//
//  LLM Provider setup step of the onboarding wizard
//

import AppKit
import SwiftUI
import SwiftData
import TipKit
import HivecrewLLM

/// LLM Provider configuration step
struct OnboardingProviderStep: View {
    private static let oauthAuthAutoRefreshIntervalNanoseconds: UInt64 = 3_000_000_000

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]
    
    @Binding var isConfigured: Bool
    let onProviderConnected: () -> Void
    
    @State private var displayName: String = "OpenRouter"
    @State private var backendMode: LLMBackendMode = .chatCompletions
    @State private var authMode: LLMAuthMode = .apiKey
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var isTesting = false
    @State private var testResult: ConnectionTestResult?
    @State private var hasSaved = false
    @State private var draftProviderId: String = UUID().uuidString
    @State private var oauthAuthState: CodexOAuthAuthState = .unauthenticated
    @State private var oauthLoginId: String?
    @State private var oauthLastAuthURL: String?
    @State private var oauthAuthMessage: String?
    @State private var isAuthenticatingOAuth = false
    @State private var shouldAutoSaveOAuthProvider = false
    @State private var shouldAutoAdvanceAfterOAuth = false

    private let chatGPTSignInSubscriptionTip = ChatGPTSignInSubscriptionTip()

    private var isCodexMode: Bool {
        backendMode == .codexOAuth
    }

    private var activeProviderId: String {
        draftProviderId
    }

    private var activeOAuthLoginId: String? {
        oauthLoginId
    }

    private var shouldAutoRefreshOAuthAuth: Bool {
        isCodexMode && oauthAuthState == .pending && !isAuthenticatingOAuth
    }

    private var canSaveProvider: Bool {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        if isCodexMode {
            return oauthAuthState == .authenticated || CodexOAuthTokenStore.retrieve(providerId: activeProviderId) != nil
        }
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue)
                        
                        Text("Configure LLM Provider")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        Text("Connect an API-key provider or ChatGPT OAuth to power your agents")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)
                    
                    // Form
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Provider Name")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            TextField("e.g., OpenAI, Claude, Local LLM", text: $displayName)
                                .textFieldStyle(.roundedBorder)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Backend Mode")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("Backend Mode", selection: $backendMode) {
                                Text("Chat Completions").tag(LLMBackendMode.chatCompletions)
                                Text("Responses API").tag(LLMBackendMode.responses)
                                Text("ChatGPT OAuth (Codex)").tag(LLMBackendMode.codexOAuth)
                            }
                            .pickerStyle(.menu)
                            .onChange(of: backendMode) { _, newValue in
                                authMode = newValue == .codexOAuth ? .chatGPTOAuth : .apiKey
                                if newValue == .codexOAuth,
                                   displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName == "OpenRouter" {
                                    displayName = "ChatGPT OAuth"
                                }
                            }
                        }

                        if isCodexMode {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("ChatGPT OAuth")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                oauthAuthContent
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("API Key")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                SecureField("sk-...", text: $apiKey)
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Base URL (optional)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    TextField("Leave empty for OpenRouter default", text: $baseURL)
                                        .textFieldStyle(.roundedBorder)
                                    ProviderURLPickerMenu(baseURL: $baseURL)
                                }
                                Text("For custom endpoints like Azure, Anthropic, or local LLMs")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 60)
                    
                    // Test & Save
                    HStack(spacing: 16) {
                        Button {
                            testConnection()
                        } label: {
                            HStack(spacing: 6) {
                                if isTesting {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text("Test Connection")
                            }
                        }
                        .disabled((!isCodexMode && apiKey.isEmpty) || (isCodexMode && !canSaveProvider) || isTesting)
                        
                        if let result = testResult {
                            ConnectionTestResultView(result: result, style: .compact)
                        }
                        
                        Spacer()
                        
                        Button("Save Provider") {
                            saveProvider()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSaveProvider)
                    }
                    .padding(.horizontal, 60)

                    VStack(spacing: 14) {
                        HStack(spacing: 12) {
                            separatorLine
                            Text("or")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            separatorLine
                        }

                        Button {
                            signInWithChatGPT()
                        } label: {
                            Label {
                                Text("Sign in with ChatGPT")
                            } icon: {
                                Image("OpenAILogo")
                                    .renderingMode(.template)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 18, height: 18)
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isAuthenticatingOAuth)
                        .popoverTip(chatGPTSignInSubscriptionTip, arrowEdge: .top)
                    }
                    .padding(.horizontal, 60)
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
            }

            if hasSaved || !providers.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Provider configured")
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 20)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
        .onChange(of: providers.count) { _, newCount in
            isConfigured = newCount > 0
        }
        .task(id: shouldAutoRefreshOAuthAuth) {
            guard shouldAutoRefreshOAuthAuth else { return }

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.oauthAuthAutoRefreshIntervalNanoseconds)
                if Task.isCancelled {
                    break
                }

                await MainActor.run {
                    guard shouldAutoRefreshOAuthAuth else { return }
                    refreshOAuthStatus()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard shouldAutoRefreshOAuthAuth else { return }
            refreshOAuthStatus()
        }
        .onAppear {
            isConfigured = !providers.isEmpty
        }
    }

    @ViewBuilder
    private var oauthAuthContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(oauthStatusText)
                    .foregroundStyle(oauthStatusColor)
                if let oauthAuthMessage, !oauthAuthMessage.isEmpty {
                    Text(oauthAuthMessage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Connect your ChatGPT account before saving this provider.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                refreshOAuthStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh auth status")
            .disabled(isAuthenticatingOAuth)

            Button {
                startOAuthAuth()
            } label: {
                HStack(spacing: 6) {
                    if isAuthenticatingOAuth {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 14, height: 14)
                    }
                    Text(oauthAuthState == .authenticated ? "Reconnect ChatGPT" : "Connect ChatGPT")
                }
            }
            .disabled(isAuthenticatingOAuth)
            .buttonStyle(.borderedProminent)
        }
    }

    private var oauthStatusText: String {
        switch oauthAuthState {
        case .unauthenticated:
            return "Not connected"
        case .pending:
            return "Waiting for ChatGPT sign-in"
        case .authenticated:
            return "Connected to ChatGPT"
        case .failed:
            return "Connection failed"
        }
    }

    private var oauthStatusColor: Color {
        switch oauthAuthState {
        case .unauthenticated:
            return .secondary
        case .pending:
            return .orange
        case .authenticated:
            return .green
        case .failed:
            return .red
        }
    }
    
    private func testConnection() {
        isTesting = true
        testResult = nil
        
        Task {
            let result = await ProviderConnectionTester.test(
                baseURL: baseURL,
                apiKey: apiKey,
                backendMode: backendMode,
                authMode: authMode,
                oauthProviderId: isCodexMode ? activeProviderId : nil
            )
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }

    private func saveProvider() {
        let shouldAdvance = shouldAutoAdvanceAfterOAuth

        let provider = LLMProviderRecord(
            id: draftProviderId,
            displayName: displayName,
            baseURL: isCodexMode ? nil : normalizedOptional(baseURL),
            organizationId: nil,
            backendMode: backendMode,
            authMode: isCodexMode ? .chatGPTOAuth : .apiKey,
            oauthAuthState: oauthAuthState,
            oauthLoginId: oauthLoginId,
            oauthLastAuthURL: oauthLastAuthURL,
            oauthAuthUpdatedAt: isCodexMode ? Date() : nil,
            oauthAuthMessage: oauthAuthMessage,
            isDefault: providers.isEmpty, // First provider is default
            timeoutInterval: 120
        )
        if !isCodexMode {
            provider.storeAPIKey(apiKey)
        }
        modelContext.insert(provider)
        
        hasSaved = true
        isConfigured = true
        
        // Clear form for potential additional providers
        displayName = ""
        backendMode = .chatCompletions
        authMode = .apiKey
        apiKey = ""
        baseURL = ""
        testResult = nil
        draftProviderId = UUID().uuidString
        oauthAuthState = .unauthenticated
        oauthLoginId = nil
        oauthLastAuthURL = nil
        oauthAuthMessage = nil
        shouldAutoSaveOAuthProvider = false
        shouldAutoAdvanceAfterOAuth = false

        if shouldAdvance {
            onProviderConnected()
        }
    }

    private func startOAuthAuth() {
        isAuthenticatingOAuth = true
        oauthAuthMessage = nil

        Task {
            do {
                let startResult = try CodexOAuthCoordinator.shared.startLogin(providerId: activeProviderId)

                await MainActor.run {
                    NSWorkspace.shared.open(startResult.authURL)
                    oauthLoginId = startResult.loginId
                    oauthLastAuthURL = startResult.authURL.absoluteString
                    oauthAuthState = .pending
                    oauthAuthMessage = startResult.message
                    isAuthenticatingOAuth = false
                }
            } catch {
                await MainActor.run {
                    oauthAuthState = .failed
                    oauthAuthMessage = error.localizedDescription
                    isAuthenticatingOAuth = false
                    shouldAutoSaveOAuthProvider = false
                    shouldAutoAdvanceAfterOAuth = false
                }
            }
        }
    }

    private func refreshOAuthStatus() {
        let snapshot = CodexOAuthCoordinator.shared.status(providerId: activeProviderId, loginId: activeOAuthLoginId)
        oauthAuthState = snapshot.status
        oauthLoginId = snapshot.loginId
        oauthLastAuthURL = snapshot.authURL?.absoluteString ?? oauthLastAuthURL
        oauthAuthMessage = snapshot.message

        if snapshot.status == .authenticated,
           shouldAutoSaveOAuthProvider,
           !providers.contains(where: { $0.id == activeProviderId }) {
            saveProvider()
        } else if snapshot.status == .failed {
            shouldAutoSaveOAuthProvider = false
        }
    }

    private func signInWithChatGPT() {
        backendMode = .codexOAuth
        authMode = .chatGPTOAuth
        displayName = "ChatGPT OAuth"
        baseURL = ""
        apiKey = ""
        testResult = nil
        shouldAutoSaveOAuthProvider = true
        shouldAutoAdvanceAfterOAuth = true

        if oauthAuthState == .authenticated || CodexOAuthTokenStore.retrieve(providerId: activeProviderId) != nil {
            saveProvider()
            return
        }

        startOAuthAuth()
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var separatorLine: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
    }
}

/// Worker model configuration step shown during onboarding.
struct OnboardingWorkerModelStep: View {
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]
    @Binding var isConfigured: Bool

    @AppStorage("lastSelectedProviderId") private var mainModelProviderId: String = ""
    @AppStorage("lastSelectedModelId") private var mainModelId: String = ""
    @AppStorage("workerModelProviderId") private var workerModelProviderId: String?
    @AppStorage("workerModelId") private var workerModelId: String?

    @State private var availableMainModels: [LLMProviderModel] = []
    @State private var isLoadingMainModels = false
    @State private var mainModelErrorMessage: String?

    @State private var availableWorkerModels: [LLMProviderModel] = []
    @State private var isLoadingWorkerModels = false
    @State private var workerModelErrorMessage: String?

    private enum ModelLoadError: LocalizedError {
        case missingAPIKey

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "This provider has no API key configured."
            }
        }
    }

    private var selectedMainProvider: LLMProviderRecord? {
        let normalized = mainModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return providers.first(where: { $0.id == normalized })
    }

    private var selectedWorkerProvider: LLMProviderRecord? {
        guard let workerModelProviderId else { return nil }
        let normalized = workerModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return providers.first(where: { $0.id == normalized })
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "bolt.circle")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Configure Main & Worker Models")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Choose both the main chat model and worker model used for lightweight background tasks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Main Provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(
                        "Main Provider",
                        selection: Binding(
                            get: { mainModelProviderId },
                            set: { newValue in
                                let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                mainModelProviderId = normalized
                                mainModelId = ""
                                availableMainModels = []
                                mainModelErrorMessage = nil
                                loadMainModelsForSelectedProvider()
                                refreshConfiguredState()
                            }
                        )
                    ) {
                        ForEach(providers) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Main Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isLoadingMainModels {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading available models...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let mainModelErrorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(mainModelErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Retry Model Load") {
                                loadMainModelsForSelectedProvider()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else if availableMainModels.isEmpty {
                        Text("No models available for this provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "Main Model",
                            selection: Binding(
                                get: { mainModelId },
                                set: { newValue in
                                    mainModelId = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    refreshConfiguredState()
                                }
                            )
                        ) {
                            ForEach(availableMainModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Worker Provider")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(
                        "Worker Provider",
                        selection: Binding(
                            get: { workerModelProviderId ?? "" },
                            set: { newValue in
                                let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                workerModelProviderId = normalized.isEmpty ? nil : normalized
                                workerModelId = nil
                                availableWorkerModels = []
                                workerModelErrorMessage = nil
                                loadWorkerModelsForSelectedProvider()
                                refreshConfiguredState()
                            }
                        )
                    ) {
                        ForEach(providers) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Worker Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isLoadingWorkerModels {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading available models...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let workerModelErrorMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(workerModelErrorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                            Button("Retry Model Load") {
                                loadWorkerModelsForSelectedProvider()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else if availableWorkerModels.isEmpty {
                        Text("No models available for this provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "Worker Model",
                            selection: Binding(
                                get: { workerModelId ?? "" },
                                set: { newValue in
                                    let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                                    workerModelId = normalized.isEmpty ? nil : normalized
                                    refreshConfiguredState()
                                }
                            )
                        ) {
                            ForEach(availableWorkerModels) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Text("Choose a capable main model and a low-latency worker model. You can update both later in Settings.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 60)

            Spacer()

            if isConfigured {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Main and worker models configured")
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 8)
            } else {
                Text("Select main and worker providers + models to continue.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }
        }
        .padding()
        .onAppear {
            ensureProviderSelection()
            loadMainModelsForSelectedProvider()
            loadWorkerModelsForSelectedProvider()
            refreshConfiguredState()
        }
        .onChange(of: providers.count) { _, _ in
            ensureProviderSelection()
            loadMainModelsForSelectedProvider()
            loadWorkerModelsForSelectedProvider()
            refreshConfiguredState()
        }
    }

    private func ensureProviderSelection() {
        guard !providers.isEmpty else {
            mainModelProviderId = ""
            mainModelId = ""
            workerModelProviderId = nil
            workerModelId = nil
            availableMainModels = []
            availableWorkerModels = []
            return
        }

        let defaultProviderId = providers.first(where: { $0.isDefault })?.id ?? providers.first?.id ?? ""

        let normalizedMainProviderId = mainModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedMainProviderId.isEmpty || !providers.contains(where: { $0.id == normalizedMainProviderId }) {
            mainModelProviderId = defaultProviderId
            mainModelId = ""
        }

        let normalizedWorkerProviderId = workerModelProviderId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if normalizedWorkerProviderId.isEmpty || !providers.contains(where: { $0.id == normalizedWorkerProviderId }) {
            workerModelProviderId = defaultProviderId.isEmpty ? nil : defaultProviderId
            workerModelId = nil
        }
    }

    private func refreshConfiguredState() {
        let hasMainProvider = !mainModelProviderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasMainModel = !mainModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasWorkerProvider = !(workerModelProviderId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasWorkerModel = !(workerModelId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        isConfigured = hasMainProvider && hasMainModel && hasWorkerProvider && hasWorkerModel
    }

    private func loadMainModelsForSelectedProvider() {
        guard let provider = selectedMainProvider else {
            availableMainModels = []
            mainModelErrorMessage = "Select a provider to load models."
            mainModelId = ""
            refreshConfiguredState()
            return
        }

        isLoadingMainModels = true
        mainModelErrorMessage = nil

        Task {
            do {
                let models = try await fetchModels(for: provider)

                await MainActor.run {
                    availableMainModels = models
                    isLoadingMainModels = false
                    if models.contains(where: { $0.id == mainModelId }) {
                        refreshConfiguredState()
                    } else if let firstModel = models.first {
                        mainModelId = firstModel.id
                        refreshConfiguredState()
                    } else {
                        mainModelId = ""
                        refreshConfiguredState()
                    }
                }
            } catch {
                await MainActor.run {
                    availableMainModels = []
                    isLoadingMainModels = false
                    mainModelErrorMessage = error.localizedDescription
                    mainModelId = ""
                    refreshConfiguredState()
                }
            }
        }
    }

    private func loadWorkerModelsForSelectedProvider() {
        guard let provider = selectedWorkerProvider else {
            availableWorkerModels = []
            workerModelErrorMessage = "Select a provider to load models."
            workerModelId = nil
            refreshConfiguredState()
            return
        }

        isLoadingWorkerModels = true
        workerModelErrorMessage = nil

        Task {
            do {
                let models = try await fetchModels(for: provider)

                await MainActor.run {
                    availableWorkerModels = models
                    isLoadingWorkerModels = false
                    if let existing = workerModelId, models.contains(where: { $0.id == existing }) {
                        refreshConfiguredState()
                    } else if let firstModel = models.first {
                        workerModelId = firstModel.id
                        refreshConfiguredState()
                    } else {
                        workerModelId = nil
                        refreshConfiguredState()
                    }
                }
            } catch {
                await MainActor.run {
                    availableWorkerModels = []
                    isLoadingWorkerModels = false
                    workerModelErrorMessage = error.localizedDescription
                    workerModelId = nil
                    refreshConfiguredState()
                }
            }
        }
    }

    private func fetchModels(for provider: LLMProviderRecord) async throws -> [LLMProviderModel] {
        let apiKey: String
        if provider.authMode == .apiKey {
            guard let stored = provider.retrieveAPIKey(), !stored.isEmpty else {
                throw ModelLoadError.missingAPIKey
            }
            apiKey = stored
        } else {
            apiKey = ""
        }

        let config = provider.makeLLMConfiguration(
            model: provider.backendMode == .codexOAuth ? "gpt-5-codex" : "model-listing-placeholder",
            apiKey: apiKey
        )
        let client = LLMService.shared.createClient(from: config)
        return try await client.listModelsDetailed()
    }
}

#Preview {
    OnboardingProviderStep(
        isConfigured: .constant(false),
        onProviderConnected: {}
    )
        .modelContainer(for: LLMProviderRecord.self, inMemory: true)
        .frame(width: 720, height: 450)
}
