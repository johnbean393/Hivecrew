import Foundation

public func resolveChatGPTOAuthAccessToken(
    providerId: String,
    timeoutInterval: TimeInterval = 120,
    forceRefresh: Bool = false
) async throws -> String {
    guard var tokens = CodexOAuthTokenStore.retrieve(providerId: providerId) else {
        throw LLMError.authenticationError(message: "ChatGPT OAuth is not connected for this provider")
    }

    if forceRefresh || tokens.shouldRefresh(within: 120) {
        tokens = try await refreshChatGPTOAuthTokens(tokens, timeoutInterval: timeoutInterval)
        guard CodexOAuthTokenStore.store(providerId: providerId, tokens: tokens) else {
            throw LLMError.authenticationError(message: "Failed to persist refreshed ChatGPT OAuth tokens")
        }
    }

    return tokens.accessToken
}

private struct ChatGPTOAuthRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }
}

private func refreshChatGPTOAuthTokens(
    _ current: CodexOAuthTokens,
    timeoutInterval: TimeInterval
) async throws -> CodexOAuthTokens {
    var request = URLRequest(url: codexOAuthTokenEndpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = timeoutInterval

    var components = URLComponents()
    components.queryItems = [
        URLQueryItem(name: "grant_type", value: "refresh_token"),
        URLQueryItem(name: "refresh_token", value: current.refreshToken),
        URLQueryItem(name: "client_id", value: codexOAuthClientID)
    ]
    request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeoutInterval
    configuration.timeoutIntervalForResource = timeoutInterval
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw LLMError.authenticationError(message: "Invalid token refresh response")
    }

    guard httpResponse.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? "No response body"
        throw LLMError.apiError(statusCode: httpResponse.statusCode, message: body)
    }

    let decoded = try JSONDecoder().decode(ChatGPTOAuthRefreshResponse.self, from: data)
    let expiresIn = decoded.expiresIn ?? 3600

    return CodexOAuthTokens(
        accessToken: decoded.accessToken,
        refreshToken: decoded.refreshToken ?? current.refreshToken,
        idToken: decoded.idToken ?? current.idToken,
        expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
    )
}
