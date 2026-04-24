//
//  VoiceSetupFlowView.swift
//  Hivelink
//
//  Initial voice configuration: provider, model, and voice.
//

import SwiftUI
import HivecrewLLM
import HivecrewShared
import HivecrewVoice

private enum OnboardingVoiceProviderChoice: String, CaseIterable, Identifiable {
    case chatGPTOAuth = "chatgpt_oauth"
    case gemini
    case openAIAPIKey = "openai_api_key"
    case xAIAPIKey = "xai_api_key"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatGPTOAuth:
            return "ChatGPT OAuth"
        case .gemini:
            return "Gemini"
        case .openAIAPIKey:
            return "OpenAI API"
        case .xAIAPIKey:
            return "xAI API"
        }
    }

    var provider: HivelinkVoiceProvider {
        switch self {
        case .chatGPTOAuth, .openAIAPIKey:
            return .openAI
        case .gemini:
            return .gemini
        case .xAIAPIKey:
            return .xAI
        }
    }

    var openAIAuthenticationMode: HivelinkOpenAIAuthenticationMode {
        switch self {
        case .chatGPTOAuth:
            return .chatGPTOAuth
        case .gemini, .openAIAPIKey, .xAIAPIKey:
            return .apiKey
        }
    }
}

struct VoiceSetupFlowView: View {
    @EnvironmentObject private var orchestrator: HivelinkVoiceOrchestrator
    @StateObject private var openAIOAuth = HivelinkChatGPTOAuthController()

    var title: String = "Set Up Voice"
    var subtitle: String = "Choose ChatGPT OAuth, Google Gemini, OpenAI API, or xAI API."
    var onConfigurationChange: ((Bool) -> Void)?

    @AppStorage(HivelinkVoicePreferences.providerKey)
    private var storedProviderRaw = HivelinkVoiceProvider.openAI.rawValue
    @AppStorage(HivelinkVoicePreferences.apiKeyKey)
    private var storedAPIKey = ""
    @AppStorage(HivelinkVoicePreferences.modelIDKey)
    private var storedModelID = "gpt-realtime-1.5"
    @AppStorage(HivelinkVoicePreferences.voiceNameKey)
    private var storedVoiceName = "marin"
    @AppStorage(HivelinkVoicePreferences.openAIAuthenticationModeKey)
    private var storedOpenAIAuthenticationModeRaw = HivelinkOpenAIAuthenticationMode.chatGPTOAuth.rawValue

    @State private var selectedChoice = OnboardingVoiceProviderChoice.chatGPTOAuth
    @State private var editingAPIKey = ""
    @State private var editingModelID = "gpt-realtime-1.5"
    @State private var editingVoiceName = "marin"
    @State private var showingKey = false

    private var availableModelOptions: [RealtimeVoiceModelOption] {
        HivelinkVoicePreferences.availableModels(for: selectedChoice.provider)
    }

    private var availableVoiceOptions: [RealtimeVoiceOption] {
        HivelinkVoicePreferences.availableVoices(for: selectedChoice.provider)
    }

    private var hasEnteredAPIKey: Bool {
        !editingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasChatGPTOAuthConnection: Bool {
        openAIOAuth.isConnected
            || CodexOAuthTokenStore.retrieve(providerId: HivelinkChatGPTOAuthController.providerId) != nil
    }

    private var configurationIsValid: Bool {
        switch selectedChoice {
        case .gemini, .openAIAPIKey, .xAIAPIKey:
            return hasEnteredAPIKey
        case .chatGPTOAuth:
            return hasChatGPTOAuthConnection
        }
    }

    private var apiKeyTitle: String {
        switch selectedChoice {
        case .gemini:
            return "Gemini API Key"
        case .chatGPTOAuth, .openAIAPIKey:
            return "OpenAI API Key"
        case .xAIAPIKey:
            return "xAI API Key"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            OnboardingStepHeaderView(
                systemImage: "waveform.circle.fill",
                tint: .accentColor,
                title: LocalizedStringKey(title),
                subtitle: LocalizedStringKey(subtitle)
            )

            Spacer()
                .frame(height: 32)

            configurationCard
                .padding(.horizontal, 24)

            Spacer(minLength: 24)
        }
        .onAppear {
            openAIOAuth.refreshStatus()
            loadStoredConfiguration()
            persistSelection()
        }
        .onChange(of: editingAPIKey) { _, _ in
            if selectedChoice != .chatGPTOAuth {
                persistSelection()
            }
        }
        .onChange(of: editingModelID) { _, _ in
            persistSelection()
        }
        .onChange(of: editingVoiceName) { _, _ in
            persistSelection()
        }
        .onChange(of: openAIOAuth.authState) { _, newState in
            handleOAuthStateChange(newState)
        }
        .sheet(
            isPresented: Binding(
                get: { openAIOAuth.presentedAuthorizationURL != nil },
                set: { isPresented in
                    if !isPresented {
                        openAIOAuth.dismissBrowser()
                    }
                }
            )
        ) {
            if let url = openAIOAuth.presentedAuthorizationURL {
                HivelinkOAuthSafariSheet(url: url)
                    .ignoresSafeArea()
            }
        }
    }

    private var configurationCard: some View {
        VStack(spacing: 0) {
            compactPickerRow(
                title: "Provider",
                selection: Binding(
                    get: { selectedChoice.rawValue },
                    set: { newValue in
                        switchChoice(to: OnboardingVoiceProviderChoice(rawValue: newValue) ?? .chatGPTOAuth)
                    }
                )
            ) {
                ForEach(OnboardingVoiceProviderChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice.rawValue)
                }
            }

            cardDivider

            switch selectedChoice {
            case .chatGPTOAuth:
                chatGPTOAuthRow
            case .gemini, .openAIAPIKey, .xAIAPIKey:
                apiKeyRow
            }

            cardDivider

            compactPickerRow(
                title: "Model",
                selection: Binding(
                    get: {
                        HivelinkVoicePreferences.normalizedModelID(
                            editingModelID,
                            for: selectedChoice.provider
                        )
                    },
                    set: { newValue in
                        editingModelID = HivelinkVoicePreferences.saveModelID(
                            newValue,
                            for: selectedChoice.provider
                        )
                    }
                )
            ) {
                ForEach(availableModelOptions) { model in
                    Text(model.displayName).tag(model.id)
                }
            }

            cardDivider

            compactPickerRow(
                title: "Voice",
                selection: Binding(
                    get: {
                        HivelinkVoicePreferences.normalizedVoiceName(
                            editingVoiceName,
                            for: selectedChoice.provider
                        )
                    },
                    set: { newValue in
                        editingVoiceName = HivelinkVoicePreferences.saveVoiceName(
                            newValue,
                            for: selectedChoice.provider
                        )
                    }
                )
            ) {
                ForEach(availableVoiceOptions) { voice in
                    Text(voice.displayName).tag(voice.id)
                }
            }
        }
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var apiKeyRow: some View {
        HStack(spacing: 12) {
            Text(apiKeyTitle)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Group {
                    if showingKey {
                        TextField("Enter your API key", text: $editingAPIKey)
                    } else {
                        SecureField("Enter your API key", text: $editingAPIKey)
                    }
                }
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.trailing)

                Button {
                    showingKey.toggle()
                } label: {
                    Image(systemName: showingKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 190)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var chatGPTOAuthRow: some View {
        VStack(spacing: 10) {
            if !openAIOAuth.isConnected {
                Button {
                    startChatGPTOAuth()
                } label: {
                    Label {
                        Text("Sign in with ChatGPT")
                    } icon: {
                        Image("OpenAILogo")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(openAIOAuth.isAuthenticating)

                if let authMessage = openAIOAuth.authMessage, !authMessage.isEmpty {
                    Text(authMessage)
                        .font(.caption)
                        .foregroundStyle(openAIOAuth.isFailed ? .red : .secondary)
                        .multilineTextAlignment(.center)
                }
            } else {
                compactValueRow(title: "ChatGPT", value: "Connected", valueColor: .green)

                Button("Disconnect ChatGPT", role: .destructive) {
                    disconnectChatGPT()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: 1)
            .padding(.horizontal, 18)
    }

    private func compactPickerRow<Content: View>(
        title: String,
        selection: Binding<String>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Picker(title, selection: selection) { content() }
                .pickerStyle(.menu)
                .labelsHidden()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func compactValueRow(title: String, value: String, valueColor: Color = .secondary) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)

            Spacer(minLength: 12)

            Text(value)
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func loadStoredConfiguration() {
        let provider = HivelinkVoicePreferences.normalizedProvider(storedProviderRaw)
        let authMode = HivelinkVoicePreferences.normalizedOpenAIAuthenticationMode(storedOpenAIAuthenticationModeRaw)
        selectedChoice = onboardingChoice(provider: provider, authenticationMode: authMode)
        editingAPIKey = HivelinkVoicePreferences.restoredAPIKey(
            for: selectedChoice.provider,
            currentAPIKey: storedAPIKey
        )
        editingModelID = HivelinkVoicePreferences.restoredModelID(
            for: selectedChoice.provider,
            currentModelID: storedModelID
        )
        editingVoiceName = HivelinkVoicePreferences.restoredVoiceName(
            for: selectedChoice.provider,
            currentVoiceName: storedVoiceName
        )
    }

    private func saveCurrentProviderScopedValues(for provider: HivelinkVoiceProvider) {
        storedAPIKey = HivelinkVoicePreferences.saveAPIKey(editingAPIKey, for: provider)
        storedModelID = HivelinkVoicePreferences.saveModelID(editingModelID, for: provider)
        storedVoiceName = HivelinkVoicePreferences.saveVoiceName(editingVoiceName, for: provider)
    }

    private func restoreEditingValues(for provider: HivelinkVoiceProvider) {
        editingAPIKey = HivelinkVoicePreferences.restoredAPIKey(
            for: provider,
            currentAPIKey: storedAPIKey
        )
        editingModelID = HivelinkVoicePreferences.restoredModelID(
            for: provider,
            currentModelID: storedModelID
        )
        editingVoiceName = HivelinkVoicePreferences.restoredVoiceName(
            for: provider,
            currentVoiceName: storedVoiceName
        )
    }

    private func switchChoice(to choice: OnboardingVoiceProviderChoice) {
        guard selectedChoice != choice else { return }

        saveCurrentProviderScopedValues(for: selectedChoice.provider)
        selectedChoice = choice
        storedOpenAIAuthenticationModeRaw = choice.openAIAuthenticationMode.rawValue
        restoreEditingValues(for: choice.provider)
        persistSelection()
    }

    private func startChatGPTOAuth() {
        if selectedChoice != .chatGPTOAuth {
            switchChoice(to: .chatGPTOAuth)
        }
        storedOpenAIAuthenticationModeRaw = HivelinkOpenAIAuthenticationMode.chatGPTOAuth.rawValue
        persistSelection()
        openAIOAuth.connect()
    }

    private func disconnectChatGPT() {
        openAIOAuth.disconnect()
        if !editingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedChoice = .openAIAPIKey
            storedOpenAIAuthenticationModeRaw = HivelinkOpenAIAuthenticationMode.apiKey.rawValue
        }
        persistSelection()
    }

    private func handleOAuthStateChange(_ newState: CodexOAuthAuthState) {
        if newState == .authenticated {
            selectedChoice = .chatGPTOAuth
            storedOpenAIAuthenticationModeRaw = HivelinkOpenAIAuthenticationMode.chatGPTOAuth.rawValue
        } else if newState == .unauthenticated,
                  selectedChoice == .chatGPTOAuth,
                  !editingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectedChoice = .openAIAPIKey
            storedOpenAIAuthenticationModeRaw = HivelinkOpenAIAuthenticationMode.apiKey.rawValue
        }
        persistSelection()
    }

    private func persistSelection() {
        storedProviderRaw = selectedChoice.provider.rawValue
        storedOpenAIAuthenticationModeRaw = selectedChoice.openAIAuthenticationMode.rawValue
        storedAPIKey = HivelinkVoicePreferences.saveAPIKey(editingAPIKey, for: selectedChoice.provider)
        storedModelID = HivelinkVoicePreferences.saveModelID(editingModelID, for: selectedChoice.provider)
        storedVoiceName = HivelinkVoicePreferences.saveVoiceName(editingVoiceName, for: selectedChoice.provider)
        orchestrator.notifyVoiceConfigurationChanged()
        onConfigurationChange?(configurationIsValid)
    }

    private func onboardingChoice(
        provider: HivelinkVoiceProvider,
        authenticationMode: HivelinkOpenAIAuthenticationMode
    ) -> OnboardingVoiceProviderChoice {
        switch provider {
        case .gemini:
            return .gemini
        case .openAI:
            return authenticationMode == .chatGPTOAuth ? .chatGPTOAuth : .openAIAPIKey
        case .xAI:
            return .xAIAPIKey
        }
    }
}

#Preview {
    VoiceSetupFlowView()
        .environmentObject(HivelinkVoiceOrchestrator())
}
