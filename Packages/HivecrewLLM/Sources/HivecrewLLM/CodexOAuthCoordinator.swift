import CryptoKit
import Foundation
import Network
import Security

public enum CodexOAuthAuthState: String, Codable, CaseIterable, Sendable {
    case unauthenticated
    case pending
    case authenticated
    case failed
}

public struct CodexOAuthStartResult: Sendable {
    public let loginId: String
    public let authURL: URL
    public let message: String
    public let updatedAt: Date

    public init(loginId: String, authURL: URL, message: String, updatedAt: Date) {
        self.loginId = loginId
        self.authURL = authURL
        self.message = message
        self.updatedAt = updatedAt
    }
}

public struct CodexOAuthStatusSnapshot: Sendable {
    public let status: CodexOAuthAuthState
    public let loginId: String?
    public let authURL: URL?
    public let message: String?
    public let updatedAt: Date?

    public init(
        status: CodexOAuthAuthState,
        loginId: String?,
        authURL: URL?,
        message: String?,
        updatedAt: Date?
    ) {
        self.status = status
        self.loginId = loginId
        self.authURL = authURL
        self.message = message
        self.updatedAt = updatedAt
    }
}

@MainActor
public final class CodexOAuthCoordinator {
    public static let shared = CodexOAuthCoordinator()

    private struct Session: Sendable {
        let loginId: String
        let providerId: String
        let state: String
        let codeVerifier: String
        let authURL: URL
        let createdAt: Date
        var updatedAt: Date
        var status: CodexOAuthAuthState
        var message: String?
    }

    private let callbackPort: UInt16 = 1455
    private let callbackPath = "/auth/callback"
    private let listenerQueue = DispatchQueue(label: "com.pattonium.hivecrew.codex-oauth-listener")
    private let pendingSessionTimeout: TimeInterval = 900

    private var listener: NWListener?
    private var sessionsByLoginId: [String: Session] = [:]
    private var loginIdByState: [String: String] = [:]

    private init() {}

    public func startLogin(providerId: String) throws -> CodexOAuthStartResult {
        try ensureListenerStarted()
        clearSessions(providerId: providerId)

        let loginId = UUID().uuidString
        let codeVerifier = Self.randomURLSafeString(byteCount: 32)
        let state = Self.randomURLSafeString(byteCount: 24)
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let authURL = try buildAuthorizationURL(state: state, codeChallenge: codeChallenge)

        let now = Date()
        let session = Session(
            loginId: loginId,
            providerId: providerId,
            state: state,
            codeVerifier: codeVerifier,
            authURL: authURL,
            createdAt: now,
            updatedAt: now,
            status: .pending,
            message: "Complete sign-in in your browser to finish connecting ChatGPT."
        )

        sessionsByLoginId[loginId] = session
        loginIdByState[state] = loginId

        return CodexOAuthStartResult(
            loginId: loginId,
            authURL: authURL,
            message: session.message ?? "",
            updatedAt: now
        )
    }

    public func status(providerId: String, loginId: String?) -> CodexOAuthStatusSnapshot {
        expireTimedOutSessions()

        let normalizedLoginId = loginId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedLoginId,
           !normalizedLoginId.isEmpty,
           let session = sessionsByLoginId[normalizedLoginId],
           session.providerId == providerId {
            return snapshot(from: session)
        }

        if let latest = sessionsByLoginId.values
            .filter({ $0.providerId == providerId })
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            return snapshot(from: latest)
        }

        if CodexOAuthTokenStore.retrieve(providerId: providerId) != nil {
            return CodexOAuthStatusSnapshot(
                status: .authenticated,
                loginId: nil,
                authURL: nil,
                message: "Connected to ChatGPT.",
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
        _ = CodexOAuthTokenStore.delete(providerId: providerId)
        clearSessions(providerId: providerId)
    }

    public func clearSessions(providerId: String) {
        let loginIds = sessionsByLoginId.values
            .filter { $0.providerId == providerId }
            .map(\.loginId)

        for loginId in loginIds {
            if let state = sessionsByLoginId[loginId]?.state {
                loginIdByState.removeValue(forKey: state)
            }
            sessionsByLoginId.removeValue(forKey: loginId)
        }
    }

    private func ensureListenerStarted() throws {
        if listener != nil {
            return
        }

        guard let port = NWEndpoint.Port(rawValue: callbackPort) else {
            throw LLMError.invalidConfiguration(message: "Invalid OAuth callback port \(callbackPort)")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: parameters, on: port)
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.listener?.cancel()
                    self.listener = nil
                    self.failPendingSessions(message: "OAuth callback listener failed: \(error.localizedDescription)")
                }
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                self?.handleIncomingConnection(connection)
            }
        }

        newListener.start(queue: listenerQueue)
        listener = newListener
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: listenerQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let target = Self.extractRequestTarget(from: data)
            Task { @MainActor in
                let responseBody = await self.handleRedirectTarget(target)
                self.sendHTMLResponse(responseBody, on: connection)
            }
        }
    }

    private func sendHTMLResponse(_ body: String, on connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var payload = Data(headers.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func handleRedirectTarget(_ target: String?) async -> String {
        guard let target,
              let components = URLComponents(string: "http://localhost\(target)") else {
            return Self.failurePage(message: "Invalid redirect request.")
        }

        guard components.path == callbackPath else {
            return Self.failurePage(message: "Unknown redirect path.")
        }

        let queryItemPairs: [(String, String)] = (components.queryItems ?? []).compactMap { item in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }
        let queryItems = Dictionary(uniqueKeysWithValues: queryItemPairs)

        let state = queryItems["state"]
        if let oauthError = queryItems["error"] {
            let message = queryItems["error_description"] ?? oauthError
            updateSession(state: state, status: .failed, message: message)
            return Self.failurePage(message: message)
        }

        guard let code = queryItems["code"], let state else {
            return Self.failurePage(message: "Missing OAuth code or state.")
        }

        guard let loginId = loginIdByState[state],
              var session = sessionsByLoginId[loginId] else {
            return Self.failurePage(message: "OAuth session not found or already completed.")
        }

        do {
            let tokens = try await exchangeCodeForTokens(code: code, codeVerifier: session.codeVerifier)
            guard CodexOAuthTokenStore.store(providerId: session.providerId, tokens: tokens) else {
                throw LLMError.authenticationError(message: "Failed to store OAuth tokens in keychain")
            }

            session.status = CodexOAuthAuthState.authenticated
            session.message = "Connected to ChatGPT."
            session.updatedAt = Date()
            sessionsByLoginId[loginId] = session
            loginIdByState.removeValue(forKey: state)
            return Self.successPage(message: "ChatGPT connection is complete. You can return to Hivecrew.")
        } catch {
            session.status = CodexOAuthAuthState.failed
            session.message = error.localizedDescription
            session.updatedAt = Date()
            sessionsByLoginId[loginId] = session
            loginIdByState.removeValue(forKey: state)
            return Self.failurePage(message: error.localizedDescription)
        }
    }

    private func exchangeCodeForTokens(code: String, codeVerifier: String) async throws -> CodexOAuthTokens {
        var request = URLRequest(url: codexOAuthTokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: callbackURLString),
            URLQueryItem(name: "client_id", value: codexOAuthClientID),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.authenticationError(message: "Invalid OAuth token response")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? "No response body"
            throw LLMError.authenticationError(message: "OAuth token exchange failed (\(httpResponse.statusCode)): \(responseBody)")
        }

        let decoded = try JSONDecoder().decode(OAuthAuthorizationCodeResponse.self, from: data)
        let expiresIn = decoded.expiresIn ?? 3600

        return CodexOAuthTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            idToken: decoded.idToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
        )
    }

    private func buildAuthorizationURL(state: String, codeChallenge: String) throws -> URL {
        var components = URLComponents(url: codexOAuthAuthorizationEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: codexOAuthClientID),
            URLQueryItem(name: "redirect_uri", value: callbackURLString),
            URLQueryItem(name: "scope", value: "openid profile email offline_access"),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true")
        ]

        guard let url = components?.url else {
            throw LLMError.invalidConfiguration(message: "Failed to build OAuth authorization URL")
        }
        return url
    }

    private var callbackURLString: String {
        "http://localhost:\(callbackPort)\(callbackPath)"
    }

    private func snapshot(from session: Session) -> CodexOAuthStatusSnapshot {
        CodexOAuthStatusSnapshot(
            status: session.status,
            loginId: session.loginId,
            authURL: session.authURL,
            message: session.message,
            updatedAt: session.updatedAt
        )
    }

    private func updateSession(state: String?, status: CodexOAuthAuthState, message: String?) {
        guard let state,
              let loginId = loginIdByState[state],
              var session = sessionsByLoginId[loginId] else {
            return
        }

        session.status = status
        session.message = message
        session.updatedAt = Date()
        sessionsByLoginId[loginId] = session
        loginIdByState.removeValue(forKey: state)
    }

    private func expireTimedOutSessions() {
        let now = Date()
        for (loginId, session) in sessionsByLoginId where session.status == .pending {
            if now.timeIntervalSince(session.createdAt) > pendingSessionTimeout {
                var updated = session
                updated.status = .failed
                updated.message = "Sign-in timed out. Start ChatGPT OAuth again."
                updated.updatedAt = now
                sessionsByLoginId[loginId] = updated
                loginIdByState.removeValue(forKey: session.state)
            }
        }
    }

    private func failPendingSessions(message: String) {
        let now = Date()
        for (loginId, session) in sessionsByLoginId where session.status == .pending {
            var updated = session
            updated.status = .failed
            updated.message = message
            updated.updatedAt = now
            sessionsByLoginId[loginId] = updated
            loginIdByState.removeValue(forKey: session.state)
        }
    }

    nonisolated private static func extractRequestTarget(from data: Data?) -> String? {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let requestLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return String(parts[1])
    }

    nonisolated private static func randomURLSafeString(byteCount: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &buffer)
        if status == errSecSuccess {
            return Data(buffer).base64URLEncodedString()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    nonisolated private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    nonisolated private static func successPage(message: String) -> String {
        htmlPage(title: "Hivecrew OAuth Connected", message: message)
    }

    nonisolated private static func failurePage(message: String) -> String {
        htmlPage(title: "Hivecrew OAuth Failed", message: message)
    }

    nonisolated private static func htmlPage(title: String, message: String) -> String {
        let escapedTitle = escapeHTML(title)
        let escapedMessage = escapeHTML(message)
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <title>\(escapedTitle)</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 40px; color: #111; }
            h1 { margin-bottom: 12px; font-size: 20px; }
            p { margin-top: 0; line-height: 1.5; }
          </style>
        </head>
        <body>
          <h1>\(escapedTitle)</h1>
          <p>\(escapedMessage)</p>
        </body>
        </html>
        """
    }

    nonisolated private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private struct OAuthAuthorizationCodeResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
