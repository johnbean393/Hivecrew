//
//  ProviderEditSheet.swift
//  Hivecrew
//
//  Sheet view for adding and editing LLM providers
//

import SwiftUI
import SwiftData
import AppKit
import Combine
import HivecrewLLM

// MARK: - Provider Edit Sheet

struct ProviderEditSheet: View {
    private static let oauthAuthAutoRefreshIntervalNanoseconds: UInt64 = 3_000_000_000

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \LLMProviderRecord.displayName) private var allProviders: [LLMProviderRecord]

    let provider: LLMProviderRecord?
    let initialBackendMode: LLMBackendMode

    @State private var displayName: String = ""
    @State private var backendMode: LLMBackendMode = .chatCompletions
    @State private var authMode: LLMAuthMode = .apiKey

    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var existingAPIKey: String = ""
    @State private var organizationId: String = ""

    @State private var oauthAuthState: CodexOAuthAuthState = .unauthenticated
    @State private var oauthLoginId: String?
    @State private var oauthLastAuthURL: String?
    @State private var oauthAuthMessage: String?

    @State private var isDefault: Bool = false
    @State private var timeoutInterval: Double = 120.0
    @State private var draftProviderId: String = UUID().uuidString

    @State private var isTesting = false
    @State private var testResult: ConnectionTestResult?

    @State private var isAuthenticatingOAuth = false

    var isEditing: Bool {
        provider != nil
    }

    private var activeProviderId: String {
        provider?.id ?? draftProviderId
    }

    private var isCodexMode: Bool {
        backendMode == .codexOAuth
    }

    private var activeOAuthLoginId: String? {
        provider?.oauthLoginId ?? oauthLoginId
    }

    private var shouldAutoRefreshOAuthAuth: Bool {
        isCodexMode && oauthAuthState == .pending && !isAuthenticatingOAuth
    }

    init(provider: LLMProviderRecord?, initialBackendMode: LLMBackendMode = .chatCompletions) {
        self.provider = provider
        self.initialBackendMode = initialBackendMode
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Spacer()

                Text(isEditing ? "Edit Provider" : "Add Provider")
                    .fontWeight(.semibold)

                Spacer()

                Button("Save") {
                    save()
                }
                .keyboardShortcut(.return)
                .disabled(!isValid)
            }
            .padding()

            Divider()

            Form {
                Section("Provider Details") {
                    TextField("Display Name", text: $displayName)
                        .textFieldStyle(.roundedBorder)

                    Picker("Backend", selection: $backendMode) {
                        Text("Chat Completions").tag(LLMBackendMode.chatCompletions)
                        Text("Responses API").tag(LLMBackendMode.responses)
                        Text("ChatGPT OAuth (Codex)").tag(LLMBackendMode.codexOAuth)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: backendMode) { _, newValue in
                        authMode = (newValue == .codexOAuth) ? .chatGPTOAuth : .apiKey
                        if newValue == .codexOAuth {
                            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || displayName == "OpenRouter" {
                                displayName = "ChatGPT OAuth"
                            }
                        }
                    }

                    if !isCodexMode {
                        HStack {
                            TextField("Base URL (optional)", text: $baseURL)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.URL)
                            ProviderURLPickerMenu(baseURL: $baseURL)
                        }

                        Text("Leave empty to use the default OpenRouter API endpoint. For other providers, enter the full API base URL.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Authentication") {
                    if isCodexMode {
                        oauthAuthContent
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)

                        if isEditing && apiKey.isEmpty {
                            Text("Leave empty to keep the existing API key.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        TextField("Organization ID (optional)", text: $organizationId)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Section("Options") {
                    Toggle("Set as Default Provider", isOn: $isDefault)

                    HStack {
                        Text("Timeout")
                        Spacer()
                        TextField("", value: $timeoutInterval, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                        Text("seconds")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Test Connection") {
                    HStack {
                        Button {
                            testConnection()
                        } label: {
                            HStack {
                                if isTesting {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                        .frame(width: 16, height: 16)
                                } else {
                                    Image(systemName: "network")
                                }
                                Text("Test Connection")
                            }
                        }
                        .disabled(!canRunConnectionTest || isTesting)

                        Spacer()

                        if let result = testResult {
                            ConnectionTestResultView(result: result, style: .detailed)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 620)
        .onAppear {
            loadProvider()
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
    }

    @ViewBuilder
    private var oauthAuthContent: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(oauthStatusText)
                    .font(.body)
                    .foregroundStyle(oauthStatusColor)
                if let oauthAuthMessage, !oauthAuthMessage.isEmpty {
                    Text(oauthAuthMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

            if oauthAuthState == .authenticated {
                Button("Disconnect") {
                    logoutOAuth()
                }
                .disabled(isAuthenticatingOAuth)
            } else {
                Button {
                    startOAuthAuth()
                } label: {
                    HStack(spacing: 6) {
                        if isAuthenticatingOAuth {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        }
                        Image("OpenAILogo")
                            .renderingMode(.template)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 16, height: 16)
                            .foregroundStyle(.primary)
                        Text("Sign in with ChatGPT")
                    }
                }
                .disabled(isAuthenticatingOAuth)
                .buttonStyle(.borderedProminent)
            }
        }

        if !isEditing {
            Text("You can connect now. Auth state and tokens will be retained when you click Save.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canRunConnectionTest: Bool {
        if isCodexMode {
            return oauthAuthState == .authenticated || CodexOAuthTokenStore.retrieve(providerId: activeProviderId) != nil
        }
        return !currentAPIKey.isEmpty
    }

    private var currentAPIKey: String {
        if !apiKey.isEmpty {
            return apiKey
        }
        return existingAPIKey
    }

    private func loadProvider() {
        guard let provider else {
            backendMode = initialBackendMode
            authMode = initialBackendMode == .codexOAuth ? .chatGPTOAuth : .apiKey
            if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                displayName = initialBackendMode == .codexOAuth ? "ChatGPT OAuth" : "OpenRouter"
            }
            return
        }

        displayName = provider.displayName
        backendMode = provider.backendMode
        authMode = provider.authMode

        baseURL = provider.baseURL ?? ""
        organizationId = provider.organizationId ?? ""
        isDefault = provider.isDefault
        timeoutInterval = provider.timeoutInterval

        oauthAuthState = provider.oauthAuthState
        oauthLoginId = provider.oauthLoginId
        oauthLastAuthURL = provider.oauthLastAuthURL
        oauthAuthMessage = provider.oauthAuthMessage

        existingAPIKey = provider.retrieveAPIKey() ?? ""
    }

    private func save() {
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBaseURL = normalizedOptional(baseURL)
        let normalizedOrg = normalizedOptional(organizationId)

        if let existingProvider = provider {
            existingProvider.displayName = normalizedDisplayName
            existingProvider.backendMode = backendMode
            existingProvider.authMode = backendMode == .codexOAuth ? .chatGPTOAuth : .apiKey
            existingProvider.baseURL = backendMode == .codexOAuth ? nil : normalizedBaseURL
            existingProvider.organizationId = backendMode == .codexOAuth ? nil : normalizedOrg
            existingProvider.timeoutInterval = timeoutInterval

            existingProvider.oauthAuthState = oauthAuthState
            existingProvider.oauthLoginId = oauthLoginId
            existingProvider.oauthLastAuthURL = oauthLastAuthURL
            existingProvider.oauthAuthMessage = oauthAuthMessage
            existingProvider.oauthAuthUpdatedAt = Date()

            if backendMode != .codexOAuth {
                if !apiKey.isEmpty {
                    existingProvider.storeAPIKey(apiKey)
                }
            } else {
                existingProvider.deleteAPIKey()
            }

            if isDefault {
                setAsDefault(existingProvider)
            } else {
                existingProvider.isDefault = false
            }
        } else {
            let newProvider = LLMProviderRecord(
                id: activeProviderId,
                displayName: normalizedDisplayName,
                baseURL: backendMode == .codexOAuth ? nil : normalizedBaseURL,
                organizationId: backendMode == .codexOAuth ? nil : normalizedOrg,
                backendMode: backendMode,
                authMode: backendMode == .codexOAuth ? .chatGPTOAuth : .apiKey,
                oauthAuthState: oauthAuthState,
                oauthLoginId: oauthLoginId,
                oauthLastAuthURL: oauthLastAuthURL,
                oauthAuthUpdatedAt: Date(),
                oauthAuthMessage: oauthAuthMessage,
                isDefault: isDefault,
                timeoutInterval: timeoutInterval
            )

            if backendMode != .codexOAuth, !apiKey.isEmpty {
                newProvider.storeAPIKey(apiKey)
            }

            if isDefault {
                setAsDefault(newProvider)
            }

            modelContext.insert(newProvider)
        }

        dismiss()
    }

    private func setAsDefault(_ provider: LLMProviderRecord) {
        for p in allProviders where p.id != provider.id {
            p.isDefault = false
        }
        provider.isDefault = true
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        Task {
            let result = await ProviderConnectionTester.test(
                baseURL: baseURL,
                apiKey: currentAPIKey,
                organizationId: organizationId,
                backendMode: backendMode,
                authMode: authMode,
                oauthProviderId: activeProviderId,
                timeout: min(timeoutInterval, 30)
            )
            await MainActor.run {
                testResult = result
                isTesting = false
            }
        }
    }

    private func startOAuthAuth() {
        isAuthenticatingOAuth = true
        oauthAuthMessage = nil

        Task { @MainActor in
            do {
                let startResult = try CodexOAuthCoordinator.shared.startLogin(providerId: activeProviderId)

                persistOAuthStateIfNeeded(
                    authState: .pending,
                    loginId: startResult.loginId,
                    authURL: startResult.authURL.absoluteString,
                    message: startResult.message
                )

                NSWorkspace.shared.open(startResult.authURL)

                oauthLoginId = startResult.loginId
                oauthLastAuthURL = startResult.authURL.absoluteString
                oauthAuthState = .pending
                oauthAuthMessage = startResult.message
                isAuthenticatingOAuth = false
            } catch {
                oauthAuthState = .failed
                oauthAuthMessage = error.localizedDescription
                isAuthenticatingOAuth = false
                persistOAuthStateIfNeeded(
                    authState: .failed,
                    loginId: activeOAuthLoginId,
                    authURL: oauthLastAuthURL,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func refreshOAuthStatus() {
        if isAuthenticatingOAuth {
            return
        }

        isAuthenticatingOAuth = true

        Task { @MainActor in
            let snapshot = CodexOAuthCoordinator.shared.status(providerId: activeProviderId, loginId: activeOAuthLoginId)

            persistOAuthStateIfNeeded(
                authState: snapshot.status,
                loginId: snapshot.loginId,
                authURL: snapshot.authURL?.absoluteString ?? oauthLastAuthURL,
                message: snapshot.message
            )

            oauthAuthState = snapshot.status
            oauthLoginId = snapshot.loginId
            oauthLastAuthURL = snapshot.authURL?.absoluteString ?? oauthLastAuthURL
            oauthAuthMessage = snapshot.message
            isAuthenticatingOAuth = false
        }
    }

    private func logoutOAuth() {
        isAuthenticatingOAuth = true

        Task { @MainActor in
            CodexOAuthCoordinator.shared.logout(providerId: activeProviderId)

            persistOAuthStateIfNeeded(
                authState: .unauthenticated,
                loginId: nil,
                authURL: nil,
                message: nil
            )

            oauthAuthState = .unauthenticated
            oauthLoginId = nil
            oauthLastAuthURL = nil
            oauthAuthMessage = nil
            isAuthenticatingOAuth = false
        }
    }

    private func persistOAuthStateIfNeeded(
        authState: CodexOAuthAuthState,
        loginId: String?,
        authURL: String?,
        message: String?
    ) {
        guard let provider else { return }
        provider.oauthAuthState = authState
        provider.oauthLoginId = loginId
        provider.oauthLastAuthURL = authURL
        provider.oauthAuthUpdatedAt = Date()
        provider.oauthAuthMessage = message
        try? modelContext.save()
    }

    private func normalizedOptional(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
