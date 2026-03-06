//
//  LLMConfiguration.swift
//  HivecrewLLM
//
//  Configuration for an LLM provider connection
//

import Foundation

// MARK: - Default Provider Constants

/// Default OpenRouter API base URL used when no custom URL is specified
public let defaultLLMProviderBaseURL = URL(string: "https://openrouter.ai/api/v1")!

/// Default OpenRouter API base URL as a string
public let defaultLLMProviderBaseURLString = "https://openrouter.ai/api/v1"

public let codexOAuthBaseURL = URL(string: "https://chatgpt.com/backend-api/codex")!
let codexOAuthClientVersionQueryName = "client_version"
private let codexOAuthFallbackClientVersion = "0.107.0"
private let cachedCodexOAuthClientVersion = resolveCodexOAuthClientVersion()

func resolvedCodexOAuthClientVersion() -> String {
    cachedCodexOAuthClientVersion
}

func buildCodexOAuthURL(pathComponent: String, clientVersion: String? = nil) -> URL {
    var components = URLComponents(
        url: codexOAuthBaseURL.appendingPathComponent(pathComponent),
        resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
        URLQueryItem(name: codexOAuthClientVersionQueryName, value: clientVersion ?? resolvedCodexOAuthClientVersion())
    ]

    return components?.url ?? codexOAuthBaseURL.appendingPathComponent(pathComponent)
}

func parsedCodexCLIClientVersion(from output: String) -> String? {
    let pattern = #"\b\d+\.\d+\.\d+\b"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return nil
    }

    let nsRange = NSRange(output.startIndex..<output.endIndex, in: output)
    guard let match = regex.firstMatch(in: output, range: nsRange),
          let range = Range(match.range, in: output) else {
        return nil
    }

    return String(output[range])
}

private func resolveCodexOAuthClientVersion() -> String {
    guard let executableURL = resolvedCodexCLIExecutableURL(),
          let cliVersion = codexCLIClientVersion(executableURL: executableURL) else {
        return codexOAuthFallbackClientVersion
    }
    return cliVersion
}

private func codexCLIClientVersion(executableURL: URL) -> String? {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()

    process.executableURL = executableURL
    process.arguments = ["--version"]
    process.standardOutput = stdout
    process.standardError = stderr

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        return nil
    }

    let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
    let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: stdoutData + stderrData, encoding: .utf8) ?? ""
    return parsedCodexCLIClientVersion(from: output)
}

private func resolvedCodexCLIExecutableURL() -> URL? {
    var searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin"
    ]

    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        searchPaths.insert(contentsOf: pathEnv.split(separator: ":").map(String.init), at: 0)
    }

    var seenPaths = Set<String>()
    for directory in searchPaths {
        guard seenPaths.insert(directory).inserted else { continue }
        let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
    }

    return nil
}

// MARK: - Backend/Auth Modes

/// Backend protocol used to communicate with an LLM provider.
public enum LLMBackendMode: String, Sendable, Codable, CaseIterable {
    case chatCompletions = "chat_completions"
    case responses = "responses"
    case codexOAuth = "codex_oauth"
}

/// Authentication mode for a provider connection.
public enum LLMAuthMode: String, Sendable, Codable, CaseIterable {
    case apiKey = "api_key"
    case chatGPTOAuth = "chatgpt_oauth"
}

// MARK: - Configuration

/// Configuration for connecting to an LLM provider
public struct LLMConfiguration: Sendable, Codable, Equatable {
    /// Unique identifier for this configuration
    public let id: String

    /// Human-readable display name
    public let displayName: String

    /// Custom base URL for the API endpoint
    /// If nil, uses the default OpenRouter API endpoint
    public let baseURL: URL?

    /// API key for authentication
    public let apiKey: String

    /// Model identifier (e.g., "moonshotai/kimi-k2.5", "gpt-4-turbo")
    public let model: String

    /// Optional organization ID for OpenAI
    public let organizationId: String?

    /// Provider backend mode (`chat/completions`, `responses`, or `codex oauth`)
    public let backendMode: LLMBackendMode

    /// Authentication mode used for this provider
    public let authMode: LLMAuthMode

    /// Request timeout interval in seconds
    public let timeoutInterval: TimeInterval

    /// Optional reasoning toggle for providers that expose reasoning as on/off.
    public let reasoningEnabled: Bool?

    /// Optional reasoning effort for providers that expose explicit effort levels.
    public let reasoningEffort: String?

    /// Default timeout interval (60 seconds)
    public static let defaultTimeout: TimeInterval = 300.0

    public init(
        id: String = UUID().uuidString,
        displayName: String,
        baseURL: URL? = nil,
        apiKey: String,
        model: String,
        organizationId: String? = nil,
        backendMode: LLMBackendMode = .chatCompletions,
        authMode: LLMAuthMode = .apiKey,
        timeoutInterval: TimeInterval = LLMConfiguration.defaultTimeout,
        reasoningEnabled: Bool? = nil,
        reasoningEffort: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.organizationId = organizationId
        self.backendMode = backendMode
        self.authMode = authMode
        self.timeoutInterval = timeoutInterval
        self.reasoningEnabled = reasoningEnabled
        self.reasoningEffort = reasoningEffort
    }

    /// Extract host from baseURL if provided
    public var host: String? {
        baseURL?.host
    }

    /// Extract port from baseURL if provided
    public var port: Int? {
        baseURL?.port
    }

    /// Extract scheme from baseURL if provided (http or https)
    public var scheme: String? {
        baseURL?.scheme
    }

    /// Extract path from baseURL if provided
    public var basePath: String? {
        guard let baseURL = baseURL else { return nil }
        let path = baseURL.path
        return path.isEmpty ? nil : path
    }

    /// Whether this configuration points to OpenRouter API (true by default when no baseURL is set)
    public var isOpenRouter: Bool {
        guard let host = baseURL?.host?.lowercased() else { return true }
        return host.contains("openrouter.ai")
    }

    /// Convenience flag for Responses API backend.
    public var usesResponsesAPI: Bool {
        backendMode == .responses
    }

    /// Convenience flag for ChatGPT OAuth backend.
    public var usesCodexOAuth: Bool {
        backendMode == .codexOAuth
    }
}
