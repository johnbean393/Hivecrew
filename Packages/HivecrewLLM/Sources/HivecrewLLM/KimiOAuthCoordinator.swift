import Foundation

@MainActor
public final class KimiOAuthCoordinator {
    public static let shared = KimiOAuthCoordinator()

    private struct Session: Sendable {
        let loginId: String
        let providerId: String
        let deviceId: String
        let deviceCode: String
        let authURL: URL
        let userCode: String
        let interval: TimeInterval
        let expiresAt: Date
        let createdAt: Date
        var updatedAt: Date
        var nextPollAt: Date
        var status: CodexOAuthAuthState
        var message: String?
    }

    private let pendingSessionTimeout: TimeInterval = 900
    private let urlSession: URLSession

    private var sessionsByLoginId: [String: Session] = [:]

    private init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func startLogin(providerId: String) async throws -> CodexOAuthStartResult {
        clearSessions(providerId: providerId)

        let loginId = UUID().uuidString
        let deviceId = KimiOAuthTokenStore.retrieve(providerId: providerId)?.deviceId ?? makeKimiOAuthDeviceID()
        let auth = try await requestDeviceAuthorization(deviceId: deviceId)
        let now = Date()
        let message = "Complete sign-in in your browser to finish connecting Kimi."

        sessionsByLoginId[loginId] = Session(
            loginId: loginId,
            providerId: providerId,
            deviceId: deviceId,
            deviceCode: auth.deviceCode,
            authURL: auth.authURL,
            userCode: auth.userCode,
            interval: auth.interval,
            expiresAt: now.addingTimeInterval(auth.expiresIn),
            createdAt: now,
            updatedAt: now,
            nextPollAt: now.addingTimeInterval(auth.interval),
            status: .pending,
            message: message
        )

        return CodexOAuthStartResult(
            loginId: loginId,
            authURL: auth.authURL,
            message: message,
            updatedAt: now
        )
    }

    public func status(providerId: String, loginId: String?) async -> CodexOAuthStatusSnapshot {
        expireTimedOutSessions()

        let normalizedLoginId = loginId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingLoginId: String?

        if let normalizedLoginId,
           !normalizedLoginId.isEmpty,
           let session = sessionsByLoginId[normalizedLoginId],
           session.providerId == providerId {
            matchingLoginId = normalizedLoginId
        } else {
            matchingLoginId = sessionsByLoginId.values
                .filter { $0.providerId == providerId }
                .max(by: { $0.updatedAt < $1.updatedAt })?
                .loginId
        }

        if let matchingLoginId,
           var session = sessionsByLoginId[matchingLoginId] {
            if session.status == .pending {
                if Date() >= session.expiresAt {
                    session.status = .failed
                    session.updatedAt = Date()
                    session.message = "Kimi sign-in expired. Start again to continue."
                    sessionsByLoginId[matchingLoginId] = session
                } else if Date() >= session.nextPollAt {
                    session = await pollForTokens(session: session)
                    sessionsByLoginId[matchingLoginId] = session
                }
            }

            return snapshot(from: session)
        }

        if KimiOAuthTokenStore.retrieve(providerId: providerId) != nil {
            return CodexOAuthStatusSnapshot(
                status: .authenticated,
                loginId: nil,
                authURL: nil,
                message: "Connected to Kimi.",
                updatedAt: Date()
            )
        }

        return CodexOAuthStatusSnapshot(
            status: .unauthenticated,
            loginId: nil,
            authURL: nil,
            message: nil,
            updatedAt: nil
        )
    }

    public func logout(providerId: String) {
        _ = KimiOAuthTokenStore.delete(providerId: providerId)
        clearSessions(providerId: providerId)
    }

    public func clearSessions(providerId: String) {
        let loginIds = sessionsByLoginId.values
            .filter { $0.providerId == providerId }
            .map(\.loginId)

        for loginId in loginIds {
            sessionsByLoginId.removeValue(forKey: loginId)
        }
    }

    private func requestDeviceAuthorization(deviceId: String) async throws -> (
        userCode: String,
        deviceCode: String,
        authURL: URL,
        expiresIn: TimeInterval,
        interval: TimeInterval
    ) {
        var request = makeKimiOAuthURLRequest(
            url: kimiOAuthDeviceAuthorizationEndpoint,
            method: "POST",
            deviceId: deviceId,
            timeoutInterval: LLMConfiguration.defaultTimeout
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: kimiOAuthClientID)
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.authenticationError(message: "Invalid Kimi OAuth device authorization response")
        }

        guard httpResponse.statusCode == 200 else {
            let message = parseKimiOAuthErrorMessage(from: data)
                ?? String(data: data, encoding: .utf8)
                ?? "Kimi OAuth device authorization failed (HTTP \(httpResponse.statusCode))"
            throw LLMError.authenticationError(message: message)
        }

        let decoded = try JSONDecoder().decode(KimiOAuthDeviceAuthorizationResponse.self, from: data)
        guard let authURL = URL(string: decoded.verificationURIComplete) else {
            throw LLMError.authenticationError(message: "Kimi OAuth did not return a valid verification URL")
        }

        return (
            userCode: decoded.userCode,
            deviceCode: decoded.deviceCode,
            authURL: authURL,
            expiresIn: TimeInterval(decoded.expiresIn ?? 900),
            interval: TimeInterval(max(decoded.interval ?? 5, 1))
        )
    }

    private func pollForTokens(session: Session) async -> Session {
        var updatedSession = session
        updatedSession.updatedAt = Date()

        var request = makeKimiOAuthURLRequest(
            url: kimiOAuthTokenEndpoint,
            method: "POST",
            deviceId: session.deviceId,
            timeoutInterval: LLMConfiguration.defaultTimeout
        )
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: kimiOAuthClientID),
            URLQueryItem(name: "device_code", value: session.deviceCode),
            URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:device_code")
        ]
        request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                updatedSession.message = "Invalid Kimi OAuth polling response."
                updatedSession.nextPollAt = Date().addingTimeInterval(updatedSession.interval)
                return updatedSession
            }

            if httpResponse.statusCode == 200 {
                let decoded = try JSONDecoder().decode(KimiOAuthTokenResponse.self, from: data)
                let tokens = KimiOAuthTokens(
                    accessToken: decoded.accessToken,
                    refreshToken: decoded.refreshToken ?? "",
                    tokenType: decoded.tokenType ?? "Bearer",
                    scope: decoded.scope ?? "",
                    expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn ?? 3600)),
                    deviceId: session.deviceId
                )

                if KimiOAuthTokenStore.store(providerId: session.providerId, tokens: tokens) {
                    updatedSession.status = .authenticated
                    updatedSession.message = "Connected to Kimi."
                } else {
                    updatedSession.status = .failed
                    updatedSession.message = "Failed to store Kimi OAuth tokens in keychain."
                }
                return updatedSession
            }

            let errorPayload = try? JSONDecoder().decode(KimiOAuthErrorResponse.self, from: data)
            let errorCode = errorPayload?.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorDescription = errorPayload?.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)

            switch errorCode {
            case "authorization_pending":
                updatedSession.status = .pending
                updatedSession.message = errorDescription?.isEmpty == false
                    ? errorDescription
                    : "Waiting for Kimi sign-in in your browser."
                updatedSession.nextPollAt = Date().addingTimeInterval(updatedSession.interval)
            case "slow_down":
                updatedSession.status = .pending
                updatedSession.message = errorDescription?.isEmpty == false
                    ? errorDescription
                    : "Kimi requested a slower sign-in poll rate."
                updatedSession.nextPollAt = Date().addingTimeInterval(updatedSession.interval + 2)
            case "expired_token":
                updatedSession.status = .failed
                updatedSession.message = "Kimi sign-in expired. Start again to continue."
            default:
                updatedSession.status = .failed
                updatedSession.message = errorDescription?.isEmpty == false
                    ? errorDescription
                    : "Kimi sign-in failed."
            }

            return updatedSession
        } catch {
            updatedSession.status = .failed
            updatedSession.message = error.localizedDescription
            return updatedSession
        }
    }

    private func expireTimedOutSessions() {
        let now = Date()
        let expiredLoginIds = sessionsByLoginId.values.compactMap { session -> String? in
            if session.status == .authenticated {
                return nil
            }
            let age = now.timeIntervalSince(session.createdAt)
            return age >= pendingSessionTimeout ? session.loginId : nil
        }

        for loginId in expiredLoginIds {
            sessionsByLoginId.removeValue(forKey: loginId)
        }
    }

    private func snapshot(from session: Session) -> CodexOAuthStatusSnapshot {
        CodexOAuthStatusSnapshot(
            status: session.status,
            loginId: session.loginId,
            authURL: session.status == .pending ? session.authURL : nil,
            message: session.message,
            updatedAt: session.updatedAt
        )
    }
}
