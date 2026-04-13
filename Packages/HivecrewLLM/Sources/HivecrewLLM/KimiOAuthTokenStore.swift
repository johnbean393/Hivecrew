import Foundation
import Security

public let kimiOAuthClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
public let kimiOAuthAuthorizationHost = URL(string: "https://auth.kimi.com")!
public let kimiOAuthDeviceAuthorizationEndpoint = kimiOAuthAuthorizationHost.appendingPathComponent("api/oauth/device_authorization")
public let kimiOAuthTokenEndpoint = kimiOAuthAuthorizationHost.appendingPathComponent("api/oauth/token")
public let kimiOAuthClientVersion = "1.12.0"

public struct KimiOAuthTokens: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    public let scope: String
    public let expiresAt: Date
    public let deviceId: String

    public init(
        accessToken: String,
        refreshToken: String,
        tokenType: String,
        scope: String,
        expiresAt: Date,
        deviceId: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.scope = scope
        self.expiresAt = expiresAt
        self.deviceId = deviceId
    }

    public var isExpired: Bool {
        expiresAt <= Date()
    }

    public func shouldRefresh(within seconds: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSinceNow <= seconds
    }
}

struct KimiOAuthDeviceAuthorizationResponse: Decodable {
    let userCode: String
    let deviceCode: String
    let verificationURI: String?
    let verificationURIComplete: String
    let expiresIn: Int?
    let interval: Int?

    enum CodingKeys: String, CodingKey {
        case userCode = "user_code"
        case deviceCode = "device_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

struct KimiOAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let scope: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
    }
}

struct KimiOAuthErrorResponse: Decodable {
    let error: String?
    let errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

public enum KimiOAuthTokenStore {
    private static let keychainService = "com.pattonium.hivecrew.kimi-oauth"

    @discardableResult
    public static func store(providerId: String, tokens: KimiOAuthTokens) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(tokens) else { return false }

        let account = accountKey(providerId: providerId)
        _ = delete(providerId: providerId)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    public static func retrieve(providerId: String) -> KimiOAuthTokens? {
        let account = accountKey(providerId: providerId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(KimiOAuthTokens.self, from: data)
    }

    @discardableResult
    public static func delete(providerId: String) -> Bool {
        let account = accountKey(providerId: providerId)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func accountKey(providerId: String) -> String {
        "hivecrew.provider.\(providerId).kimi_oauth_tokens"
    }
}

func makeKimiOAuthRequestHeaders(deviceId: String) -> [String: String] {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    let deviceName = sanitizedKimiHeaderValue(ProcessInfo.processInfo.hostName, fallback: "unknown")
    let deviceModel = sanitizedKimiHeaderValue("\(kimiOAuthPlatformName()) \(osVersion) \(kimiOAuthArchitecture())")

    return [
        "User-Agent": "KimiCLI/\(kimiOAuthClientVersion)",
        "X-Msh-Platform": "kimi_cli",
        "X-Msh-Version": kimiOAuthClientVersion,
        "X-Msh-Device-Name": deviceName,
        "X-Msh-Device-Model": deviceModel,
        "X-Msh-Os-Version": sanitizedKimiHeaderValue(osVersion, fallback: "unknown"),
        "X-Msh-Device-Id": sanitizedKimiHeaderValue(deviceId, fallback: UUID().uuidString.lowercased())
    ]
}

func makeKimiOAuthDeviceID() -> String {
    UUID().uuidString.lowercased()
}

func makeKimiOAuthURLRequest(
    url: URL,
    method: String,
    deviceId: String,
    timeoutInterval: TimeInterval
) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = timeoutInterval

    for (header, value) in makeKimiOAuthRequestHeaders(deviceId: deviceId) {
        request.setValue(value, forHTTPHeaderField: header)
    }

    return request
}

func refreshKimiOAuthTokens(
    _ current: KimiOAuthTokens,
    timeoutInterval: TimeInterval,
    urlSession: URLSession
) async throws -> KimiOAuthTokens {
    var request = makeKimiOAuthURLRequest(
        url: kimiOAuthTokenEndpoint,
        method: "POST",
        deviceId: current.deviceId,
        timeoutInterval: timeoutInterval
    )
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

    var form = URLComponents()
    form.queryItems = [
        URLQueryItem(name: "client_id", value: kimiOAuthClientID),
        URLQueryItem(name: "grant_type", value: "refresh_token"),
        URLQueryItem(name: "refresh_token", value: current.refreshToken)
    ]
    request.httpBody = form.percentEncodedQuery?.data(using: .utf8)

    let (data, response) = try await urlSession.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
        throw LLMError.authenticationError(message: "Invalid Kimi OAuth token refresh response")
    }

    guard httpResponse.statusCode == 200 else {
        let message = parseKimiOAuthErrorMessage(from: data)
            ?? String(data: data, encoding: .utf8)
            ?? "Kimi OAuth token refresh failed (HTTP \(httpResponse.statusCode))"
        throw LLMError.authenticationError(message: message)
    }

    let decoded = try JSONDecoder().decode(KimiOAuthTokenResponse.self, from: data)
    return KimiOAuthTokens(
        accessToken: decoded.accessToken,
        refreshToken: decoded.refreshToken ?? current.refreshToken,
        tokenType: decoded.tokenType ?? current.tokenType,
        scope: decoded.scope ?? current.scope,
        expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expiresIn ?? 3600)),
        deviceId: current.deviceId
    )
}

func parseKimiOAuthErrorMessage(from data: Data) -> String? {
    if let decoded = try? JSONDecoder().decode(KimiOAuthErrorResponse.self, from: data) {
        let description = decoded.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let description, !description.isEmpty {
            return description
        }
        let error = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error, !error.isEmpty {
            return error
        }
    }
    return nil
}

private func sanitizedKimiHeaderValue(_ value: String, fallback: String = "unknown") -> String {
    let filtered = String(value.unicodeScalars.filter(\.isASCII))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return filtered.isEmpty ? fallback : filtered
}

private func kimiOAuthPlatformName() -> String {
    #if os(macOS)
    return "macOS"
    #elseif os(Linux)
    return "Linux"
    #elseif os(Windows)
    return "Windows"
    #else
    return "Unknown"
    #endif
}

private func kimiOAuthArchitecture() -> String {
    #if arch(arm64)
    return "arm64"
    #elseif arch(x86_64)
    return "x86_64"
    #else
    return "unknown"
    #endif
}
