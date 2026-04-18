import AppKit
import SwiftUI
import SwiftData
import HivecrewLLM

extension ProviderEditSheet {
    @ViewBuilder
    var oauthAuthContent: some View {
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
            .help(String(localized: "Refresh auth status"))
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
                        oauthProviderImage
                        Text("Sign in with \(oauthProviderDisplayName)")
                    }
                }
                .disabled(isAuthenticatingOAuth)
                .buttonStyle(.borderedProminent)
            }
        }

        if !isEditing {
            Text(String(localized: "You can connect now. Auth state and tokens will be retained when you click Save."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var oauthStatusText: String {
        switch oauthAuthState {
        case .unauthenticated:
            return String(localized: "Not connected")
        case .pending:
            return String(localized: "Waiting for \(oauthProviderDisplayName) sign-in")
        case .authenticated:
            return String(localized: "Connected to \(oauthProviderDisplayName)")
        case .failed:
            return String(localized: "Connection failed")
        }
    }

    var oauthStatusColor: Color {
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

    var oauthProviderDisplayName: String {
        activeOAuthProviderKind?.displayName ?? "Provider"
    }

    @ViewBuilder
    var oauthProviderImage: some View {
        if activeOAuthProviderKind == .chatgpt {
            Image("OpenAILogo")
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)
        } else {
            Image("KimiLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
    }

    func startOAuthAuth() {
        isAuthenticatingOAuth = true
        oauthAuthMessage = nil

        Task { @MainActor in
            do {
                let startResult: CodexOAuthStartResult
                switch activeOAuthProviderKind {
                case .chatgpt:
                    startResult = try CodexOAuthCoordinator.shared.startLogin(providerId: activeProviderId)
                case .kimi:
                    startResult = try await KimiOAuthCoordinator.shared.startLogin(providerId: activeProviderId)
                case .none:
                    throw LLMError.invalidConfiguration(message: String(localized: "OAuth is not available for this provider"))
                }

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

    func refreshOAuthStatus() {
        guard !isAuthenticatingOAuth else { return }

        isAuthenticatingOAuth = true

        Task { @MainActor in
            let snapshot: CodexOAuthStatusSnapshot
            switch activeOAuthProviderKind {
            case .chatgpt:
                snapshot = CodexOAuthCoordinator.shared.status(providerId: activeProviderId, loginId: activeOAuthLoginId)
            case .kimi:
                snapshot = await KimiOAuthCoordinator.shared.status(providerId: activeProviderId, loginId: activeOAuthLoginId)
            case .none:
                snapshot = CodexOAuthStatusSnapshot(
                    status: .unauthenticated,
                    loginId: nil,
                    authURL: nil,
                    message: nil,
                    updatedAt: nil
                )
            }

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

    func logoutOAuth() {
        isAuthenticatingOAuth = true

        Task { @MainActor in
            switch activeOAuthProviderKind {
            case .chatgpt:
                CodexOAuthCoordinator.shared.logout(providerId: activeProviderId)
            case .kimi:
                KimiOAuthCoordinator.shared.logout(providerId: activeProviderId)
            case .none:
                break
            }

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

    func persistOAuthStateIfNeeded(
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
}
