import Foundation

public struct CodexRateLimitWindowSnapshot: Codable, Equatable, Sendable {
    public let usedPercent: Int
    public let windowMinutes: Int
    public let resetAt: Date?

    public init(
        usedPercent: Int,
        windowMinutes: Int,
        resetAt: Date?
    ) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetAt = resetAt
    }

    public var remainingPercent: Int {
        max(0, 100 - usedPercent)
    }

    public var compactLabel: String {
        if windowMinutes == 10_080 {
            return "Wk"
        }
        if windowMinutes % 1_440 == 0 {
            return "\(windowMinutes / 1_440)d"
        }
        if windowMinutes % 60 == 0 {
            return "\(windowMinutes / 60)h"
        }
        return "\(windowMinutes)m"
    }
}

public struct CodexCreditsSnapshot: Codable, Equatable, Sendable {
    public let hasCredits: Bool?
    public let unlimited: Bool?
    public let balance: Double?

    public init(
        hasCredits: Bool?,
        unlimited: Bool?,
        balance: Double?
    ) {
        self.hasCredits = hasCredits
        self.unlimited = unlimited
        self.balance = balance
    }
}

public struct CodexRateLimitSnapshot: Codable, Equatable, Sendable {
    public let planType: String?
    public let primary: CodexRateLimitWindowSnapshot?
    public let secondary: CodexRateLimitWindowSnapshot?
    public let credits: CodexCreditsSnapshot?
    public let updatedAt: Date

    public init(
        planType: String?,
        primary: CodexRateLimitWindowSnapshot?,
        secondary: CodexRateLimitWindowSnapshot?,
        credits: CodexCreditsSnapshot?,
        updatedAt: Date = Date()
    ) {
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
        self.updatedAt = updatedAt
    }

    public func isFresh(maxAge: TimeInterval) -> Bool {
        Date().timeIntervalSince(updatedAt) <= maxAge
    }
}

public func codexProviderDisplayName(for planType: String?) -> String? {
    guard let normalizedPlanType = planType?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased(),
          !normalizedPlanType.isEmpty else {
        return nil
    }

    switch normalizedPlanType {
    case "plus":
        return "ChatGPT Plus"
    case "pro":
        return "ChatGPT Pro"
    case "team":
        return "ChatGPT Team"
    case "enterprise":
        return "ChatGPT Enterprise"
    case "edu":
        return "ChatGPT Edu"
    default:
        return nil
    }
}

private struct CodexUsageResponse: Decodable {
    let planType: String?
    let rateLimit: CodexUsageLimitDetails?
    let credits: CodexUsageCredits?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }
}

private struct CodexUsageLimitDetails: Decodable {
    let primaryWindow: CodexUsageWindow?
    let secondaryWindow: CodexUsageWindow?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct CodexUsageWindow: Decodable {
    let usedPercent: Int
    let limitWindowSeconds: Int
    let resetAt: Date?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

private struct CodexUsageCredits: Decodable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?

    enum CodingKeys: String, CodingKey {
        case hasCredits = "has_credits"
        case unlimited
        case balance
    }
}

public enum CodexRateLimitStore {
    public static let didChangeNotification = Notification.Name("HivecrewLLM.CodexRateLimitStore.didChange")
    public static let providerIdUserInfoKey = "providerId"

    private static let defaultsKeyPrefix = "hivecrew.codex.rate-limits."

    @discardableResult
    public static func store(providerId: String, snapshot: CodexRateLimitSnapshot) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else {
            return false
        }

        UserDefaults.standard.set(data, forKey: defaultsKey(providerId: providerId))
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: [providerIdUserInfoKey: providerId]
        )
        return true
    }

    public static func retrieve(providerId: String) -> CodexRateLimitSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey(providerId: providerId)) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexRateLimitSnapshot.self, from: data)
    }

    @discardableResult
    public static func delete(providerId: String) -> Bool {
        UserDefaults.standard.removeObject(forKey: defaultsKey(providerId: providerId))
        NotificationCenter.default.post(
            name: didChangeNotification,
            object: nil,
            userInfo: [providerIdUserInfoKey: providerId]
        )
        return true
    }

    private static func defaultsKey(providerId: String) -> String {
        defaultsKeyPrefix + providerId
    }
}

public func parseCodexRateLimitSnapshot(from event: [String: Any]) -> CodexRateLimitSnapshot? {
    guard (event["type"] as? String) == "codex.rate_limits" else {
        return nil
    }

    let rateLimits = event["rate_limits"] as? [String: Any]
    let primary = parseCodexRateLimitWindow(from: rateLimits?["primary"])
    let secondary = parseCodexRateLimitWindow(from: rateLimits?["secondary"])
    let credits = parseCodexCreditsSnapshot(from: event["credits"])

    guard primary != nil || secondary != nil || credits != nil else {
        return nil
    }

    return CodexRateLimitSnapshot(
        planType: event["plan_type"] as? String,
        primary: primary,
        secondary: secondary,
        credits: credits
    )
}

public func fetchLiveCodexRateLimitSnapshot(
    providerId: String,
    timeoutInterval: TimeInterval = 10
) async throws -> CodexRateLimitSnapshot {
    let accessToken = try await resolveCodexOAuthAccessToken(
        providerId: providerId,
        timeoutInterval: timeoutInterval
    )

    var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/codex/usage")!)
    request.httpMethod = "GET"
    request.timeoutInterval = timeoutInterval
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeoutInterval
    configuration.timeoutIntervalForResource = timeoutInterval
    configuration.waitsForConnectivity = false
    let session = URLSession(configuration: configuration)

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw LLMError.unknown(message: "Invalid usage response type")
    }

    guard httpResponse.statusCode == 200 else {
        let body = String(data: data, encoding: .utf8) ?? "No response body"
        throw LLMError.apiError(statusCode: httpResponse.statusCode, message: body)
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let decoded = try decoder.decode(CodexUsageResponse.self, from: data)

    let snapshot = CodexRateLimitSnapshot(
        planType: decoded.planType,
        primary: decoded.rateLimit?.primaryWindow.map { window in
            CodexRateLimitWindowSnapshot(
                usedPercent: window.usedPercent,
                windowMinutes: max(1, window.limitWindowSeconds / 60),
                resetAt: window.resetAt
            )
        },
        secondary: decoded.rateLimit?.secondaryWindow.map { window in
            CodexRateLimitWindowSnapshot(
                usedPercent: window.usedPercent,
                windowMinutes: max(1, window.limitWindowSeconds / 60),
                resetAt: window.resetAt
            )
        },
        credits: decoded.credits.map { credits in
            CodexCreditsSnapshot(
                hasCredits: credits.hasCredits,
                unlimited: credits.unlimited,
                balance: credits.balance.flatMap(Double.init)
            )
        }
    )
    _ = CodexRateLimitStore.store(providerId: providerId, snapshot: snapshot)
    return snapshot
}

private func parseCodexRateLimitWindow(from value: Any?) -> CodexRateLimitWindowSnapshot? {
    guard let payload = value as? [String: Any] else {
        return nil
    }

    guard let usedPercent = intValue(payload["used_percent"]),
          let windowMinutes = intValue(payload["window_minutes"]) else {
        return nil
    }

    let resetTimestamp = intValue(payload["reset_at"]) ?? intValue(payload["resets_at"])
    let resetAt = resetTimestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) }

    return CodexRateLimitWindowSnapshot(
        usedPercent: usedPercent,
        windowMinutes: windowMinutes,
        resetAt: resetAt
    )
}

private func parseCodexCreditsSnapshot(from value: Any?) -> CodexCreditsSnapshot? {
    guard let payload = value as? [String: Any] else {
        return nil
    }

    let hasCredits = boolValue(payload["has_credits"])
    let unlimited = boolValue(payload["unlimited"])
    let balance = doubleValue(payload["balance"])

    if hasCredits == nil && unlimited == nil && balance == nil {
        return nil
    }

    return CodexCreditsSnapshot(
        hasCredits: hasCredits,
        unlimited: unlimited,
        balance: balance
    )
}

private func intValue(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
        return int
    case let number as NSNumber:
        return number.intValue
    case let string as String:
        return Int(string)
    default:
        return nil
    }
}

private func doubleValue(_ value: Any?) -> Double? {
    switch value {
    case let double as Double:
        return double
    case let number as NSNumber:
        return number.doubleValue
    case let string as String:
        return Double(string)
    default:
        return nil
    }
}

private func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
        return bool
    case let number as NSNumber:
        return number.boolValue
    case let string as String:
        return Bool(string)
    default:
        return nil
    }
}

private struct OAuthRefreshResponse: Decodable {
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

private func resolveCodexOAuthAccessToken(
    providerId: String,
    timeoutInterval: TimeInterval
) async throws -> String {
    guard var tokens = CodexOAuthTokenStore.retrieve(providerId: providerId) else {
        throw LLMError.authenticationError(message: "ChatGPT OAuth is not connected for this provider")
    }

    if tokens.shouldRefresh(within: 120) {
        tokens = try await refreshCodexOAuthTokens(tokens, timeoutInterval: timeoutInterval)
        guard CodexOAuthTokenStore.store(providerId: providerId, tokens: tokens) else {
            throw LLMError.authenticationError(message: "Failed to persist refreshed ChatGPT OAuth tokens")
        }
    }

    return tokens.accessToken
}

private func refreshCodexOAuthTokens(
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

    let decoded = try JSONDecoder().decode(OAuthRefreshResponse.self, from: data)
    let expiresIn = decoded.expiresIn ?? 3600

    return CodexOAuthTokens(
        accessToken: decoded.accessToken,
        refreshToken: decoded.refreshToken ?? current.refreshToken,
        idToken: decoded.idToken ?? current.idToken,
        expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn))
    )
}
