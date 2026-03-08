import Foundation

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

struct OAuthAuthorizationCodeResponse: Decodable {
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

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
