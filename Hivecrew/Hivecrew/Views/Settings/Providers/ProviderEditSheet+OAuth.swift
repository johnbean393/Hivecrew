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

    var oauthStatusText: String {
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

    func startOAuthAuth() {
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

    func refreshOAuthStatus() {
        guard !isAuthenticatingOAuth else { return }

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

    func logoutOAuth() {
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
