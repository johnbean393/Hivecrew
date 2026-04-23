//
//  RemoteAccessAuthManager.swift
//  HivecrewCore
//
//  Email/OTP auth for the remote access Worker API (session JWT in Keychain).
//  Tunnel / cloudflared lifecycle lives elsewhere.
//

import Combine
import Foundation

// MARK: - Status

/// Auth state for the remote access OTP sign-in flow (aligned with `RemoteAccessState` in the app shell).
public enum RemoteAccessStatus: Equatable, Sendable {
    /// No session / not configured (`notConfigured`).
    case disconnected
    /// OTP request in flight (`authenticating` during `register`).
    case connecting
    /// OTP sent; waiting for user to enter the code (`awaitingOTP`).
    case awaitingOTP
    /// Verifying OTP with the server (`authenticating` during `verify`).
    case verifyingOTP
    /// Session JWT stored; signed in for Worker API calls (`connected` to auth only — tunnel may not exist yet).
    case connected
    /// Last operation failed; see `errorMessage` (`failed`).
    case error
}

public enum RemoteAccessAccountDeletionResult: Equatable, Sendable {
    case deleted
    case signedOut
    case failed
}

// MARK: - Auth Manager

@MainActor
public final class RemoteAccessAuthManager: ObservableObject {

    @Published public private(set) var status: RemoteAccessStatus = .disconnected
    @Published public private(set) var email: String?
    /// Human-readable message when `status == .error`, or non-fatal errors while awaiting OTP.
    @Published public private(set) var errorMessage: String?
    /// Whether a session JWT is present in Keychain (same credential the Worker uses as Bearer token).
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var isSigningOut: Bool = false
    @Published public private(set) var isDeletingAccount: Bool = false
    @Published public private(set) var accountCapabilities: RemoteAccessAccountCapabilities = .standard

    public var deleteAccountBehavior: RemoteAccessDeleteAccountBehavior {
        accountCapabilities.deleteAccountBehavior
    }

    private let apiClient: any RemoteAccessAPIClientProtocol

    public init(apiClient: any RemoteAccessAPIClientProtocol = RemoteAccessAPIClient()) {
        self.apiClient = apiClient
    }

    /// Loads email and session token from Keychain and updates published state.
    public func loadStoredCredentials() {
        let storedEmail = RemoteAccessKeychain.retrieveEmail()
        let token = RemoteAccessKeychain.retrieveSessionToken()

        email = storedEmail
        isAuthenticated = token != nil
        accountCapabilities = token != nil ? RemoteAccessKeychain.retrieveAccountCapabilities() : .standard

        if token != nil {
            status = .connected
            errorMessage = nil
        } else {
            status = .disconnected
        }
    }

    /// Step 1: Request an OTP for the given email (`requestOTP` in `RemoteAccessManager`).
    public func requestOTP(email: String) async {
        self.email = email
        errorMessage = nil
        status = .connecting

        do {
            try await apiClient.register(email: email)
            status = .awaitingOTP
        } catch {
            status = .error
            errorMessage = error.localizedDescription
        }
    }

    /// Step 2: Verify OTP and persist session JWT + email (`verifyOTP` in `RemoteAccessManager`, without tunnel creation).
    public func verifyOTP(email: String, code: String) async {
        self.email = email
        errorMessage = nil
        status = .verifyingOTP

        do {
            let session = try await apiClient.verify(email: email, code: code)

            _ = RemoteAccessKeychain.storeSessionToken(session.token)
            _ = RemoteAccessKeychain.storeEmail(email)
            _ = RemoteAccessKeychain.storeAccountCapabilities(session.capabilities)

            isAuthenticated = true
            accountCapabilities = session.capabilities
            status = .connected
        } catch {
            status = .awaitingOTP
            errorMessage = error.localizedDescription
        }
    }

    /// Revoke the current remote session, unregister this device, and clear local credentials.
    public func logout() async {
        guard !isSigningOut else { return }

        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else {
            clearLocalCredentials()
            return
        }

        errorMessage = nil
        isSigningOut = true
        defer { isSigningOut = false }

        do {
            try await apiClient.logout(
                sessionToken: sessionToken,
                ownerId: RemoteAccessKeychain.retrieveTunnelId()
            )
            clearLocalCredentials()
        } catch {
            if shouldClearLocalCredentials(after: error) {
                clearLocalCredentials()
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Clears stored remote access credentials from Keychain and resets published state.
    private func clearLocalCredentials() {
        _ = RemoteAccessKeychain.clearAll()
        email = nil
        errorMessage = nil
        isAuthenticated = false
        isSigningOut = false
        isDeletingAccount = false
        accountCapabilities = .standard
        status = .disconnected
    }

    /// Permanently delete the authenticated account and revoke active sessions.
    @discardableResult
    public func deleteAccount() async -> RemoteAccessAccountDeletionResult {
        if accountCapabilities.deleteAccountBehavior == .logout {
            await logout()
            return errorMessage == nil ? .signedOut : .failed
        }

        guard let sessionToken = RemoteAccessKeychain.retrieveSessionToken() else {
            errorMessage = RemoteAccessError.notAuthenticated.localizedDescription
            return .failed
        }

        errorMessage = nil
        isDeletingAccount = true

        do {
            try await apiClient.deleteAccount(sessionToken: sessionToken)
            clearLocalCredentials()
            return .deleted
        } catch {
            isDeletingAccount = false
            errorMessage = error.localizedDescription
            return .failed
        }
    }

    private func shouldClearLocalCredentials(after error: Error) -> Bool {
        switch error {
        case RemoteAccessError.httpError(let statusCode):
            return statusCode == 401
        case RemoteAccessError.serverError(let statusCode, _):
            return statusCode == 401
        default:
            return false
        }
    }
}
