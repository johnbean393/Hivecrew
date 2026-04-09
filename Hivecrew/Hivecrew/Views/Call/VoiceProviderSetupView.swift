//
//  VoiceProviderSetupView.swift
//  Hivecrew
//
//  Shared view for configuring a voice model provider.
//  Used in onboarding (as a step) and standalone (when voice is not configured).
//  Follows the same visual pattern as OnboardingProviderStep.
//

import SwiftUI
import SwiftData
import HivecrewLLM
import HivecrewVoice

struct VoiceProviderSetupView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LLMProviderRecord.displayName) private var providers: [LLMProviderRecord]

    @Binding var isConfigured: Bool
    var showSkipButton: Bool = false
    var onSkip: (() -> Void)?
    var onConfigured: (() -> Void)?

    @State private var displayName: String = "Google AI Studio"
    @State private var apiKey: String = ""
    @State private var isTesting = false
    @State private var testResult: ConnectionTestResult?
    @State private var hasSaved = false

    private var hasConfiguredVoiceProvider: Bool {
        VoiceAvailability.isConfigured(modelContext: modelContext)
    }

    private var canSaveProvider: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                    
                    if hasConfiguredVoiceProvider {
                        alreadyConfiguredSection
                    } else {
                        formSection
                        actionSection
                    }
                }
                .frame(maxWidth: .infinity)
            }

            if hasConfiguredVoiceProvider || hasSaved {
                statusBanner
            }
        }
        .padding(.horizontal)
        .onAppear {
            isConfigured = hasConfiguredVoiceProvider
        }
        .onChange(of: providers.count) { _, _ in
            let configured = hasConfiguredVoiceProvider
            isConfigured = configured
            if configured {
                VoiceAvailability.autoConfigureIfNeeded(modelContext: modelContext)
            }
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 48))
                .foregroundStyle(.purple)

                Text("Configure Voice Provider")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Add a voice-capable provider to enable real-time voice conversations.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 20)
    }

    // MARK: - Already Configured

    private var alreadyConfiguredSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                Text("Voice provider detected")
                    .font(.callout)
            }

            Text("Your existing voice provider will be used for voice mode. You can update voice settings later in Settings → Voice.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .padding(.vertical, 20)
    }

    // MARK: - Form

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Provider Name")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g., Google AI Studio", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API Key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField("AIza...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("Get your API key from")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Google AI Studio", destination: URL(string: "https://aistudio.google.com/apikey")!)
                        .font(.caption)
                }
                Text("Base URL is pre-configured for the Gemini Live endpoint.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 60)
    }

    // MARK: - Actions

    private var actionSection: some View {
        VStack(spacing: 16) {
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
                .disabled(apiKey.isEmpty || isTesting)

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

            if showSkipButton {
                Button("Skip for now") {
                    onSkip?()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
    }

    // MARK: - Status

    private var statusBanner: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Voice provider configured")
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Logic

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            let result = await testGeminiAPIKey(apiKey)
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }

    private func testGeminiAPIKey(_ key: String) async -> ConnectionTestResult {
        guard var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models") else {
            return .failure("Invalid URL")
        }
        components.queryItems = [URLQueryItem(name: "key", value: key)]

        guard let url = components.url else {
            return .failure("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Invalid response")
            }
            switch http.statusCode {
            case 200:
                return .success
            case 400:
                return .failure("Invalid API key")
            case 401, 403:
                return .failure("Invalid API key")
            default:
                return .failure("HTTP \(http.statusCode)")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func saveProvider() {
        let provider = LLMProviderRecord(
            displayName: displayName,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            organizationId: nil,
            backendMode: .chatCompletions,
            authMode: .apiKey,
            isDefault: providers.isEmpty,
            timeoutInterval: 120
        )
        provider.storeAPIKey(apiKey)
        modelContext.insert(provider)

        hasSaved = true
        isConfigured = true

        VoiceAvailability.autoConfigureIfNeeded(modelContext: modelContext)

        displayName = ""
        apiKey = ""
        testResult = nil

        onConfigured?()
    }
}

struct VoiceSetupFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var onComplete: (() -> Void)?
    var onCancel: (() -> Void)?

    @State private var currentStep: Step = .provider
    @State private var providerConfigured = false
    @State private var enrollmentConfigured = false

    enum Step: Int, CaseIterable {
        case provider = 0
        case enrollment = 1

        var title: String {
            switch self {
            case .provider: return "Voice Provider"
            case .enrollment: return "Voice Enrollment"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            progressIndicator
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            navigationButtons
                .padding(20)
        }
        .frame(width: 720, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            refreshStepState()
        }
        .onChange(of: providerConfigured) { _, newValue in
            if newValue && currentStep == .provider {
                withAnimation {
                    currentStep = .enrollment
                }
            }
        }
        .onChange(of: enrollmentConfigured) { _, newValue in
            if newValue {
                completeSetup()
            }
        }
    }

    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(Step.allCases, id: \.rawValue) { step in
                HStack(spacing: 8) {
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)

                    Text(step.title)
                        .font(.caption)
                        .fontWeight(step == currentStep ? .semibold : .regular)
                        .foregroundStyle(step.rawValue <= currentStep.rawValue ? .primary : .secondary)

                    if step != Step.allCases.last {
                        Rectangle()
                            .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 30, height: 2)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .provider:
            VoiceProviderSetupView(
                isConfigured: $providerConfigured,
                onConfigured: {
                    withAnimation {
                        currentStep = .enrollment
                    }
                }
            )
        case .enrollment:
            VoiceEnrollmentSetupView(
                isConfigured: $enrollmentConfigured,
                onConfigured: {
                    completeSetup()
                }
            )
        }
    }

    private var navigationButtons: some View {
        HStack {
            if currentStep == .enrollment {
                Button("Back") {
                    withAnimation {
                        currentStep = .provider
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
            }

            Spacer()

            Button("Cancel") {
                onCancel?()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            if currentStep == .provider {
                Button("Continue") {
                    withAnimation {
                        currentStep = .enrollment
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(!providerConfigured)
            } else {
                Button("Done") {
                    completeSetup()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(!enrollmentConfigured)
            }
        }
    }

    private func refreshStepState() {
        providerConfigured = VoiceAvailability.isConfigured(modelContext: modelContext)
        enrollmentConfigured = VoiceIsolationProfileStore.loadProfile() != nil
        if !providerConfigured {
            currentStep = .provider
        } else if !enrollmentConfigured {
            currentStep = .enrollment
        } else {
            completeSetup()
        }
    }

    private func completeSetup() {
        guard providerConfigured, enrollmentConfigured else { return }
        onComplete?()
        dismiss()
    }
}
