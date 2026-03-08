import Foundation

/// Client for OpenAI Responses API-compatible providers.
public final class ResponsesAPIClient: LLMClientProtocol, @unchecked Sendable {
    public let configuration: LLMConfiguration

    let urlSession: URLSession
    let defaultCodexOAuthInstructions = "You are a helpful assistant."

    var usesChatGPTOAuth: Bool {
        configuration.authMode == .chatGPTOAuth || configuration.backendMode == .codexOAuth
    }

    public init(configuration: LLMConfiguration) {
        self.configuration = configuration

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfiguration.timeoutIntervalForResource = configuration.timeoutInterval
        sessionConfiguration.waitsForConnectivity = false
        self.urlSession = URLSession(configuration: sessionConfiguration)
    }

    public func chat(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?
    ) async throws -> LLMResponse {
        do {
            return try await sendChat(messages: messages, tools: tools, forceRefresh: false)
        } catch let error as LLMError {
            throw error
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw LLMError.timeout
            case .cancelled:
                throw LLMError.cancelled
            default:
                throw LLMError.networkError(underlying: urlError)
            }
        } catch {
            throw LLMError.unknown(message: error.localizedDescription)
        }
    }

    public func chatWithStreaming(
        messages: [LLMMessage],
        tools: [LLMToolDefinition]?,
        onReasoningUpdate: ReasoningStreamCallback?,
        onContentUpdate: ContentStreamCallback?
    ) async throws -> LLMResponse {
        do {
            return try await sendChatWithStreaming(
                messages: messages,
                tools: tools,
                onReasoningUpdate: onReasoningUpdate,
                onContentUpdate: onContentUpdate,
                forceRefresh: false
            )
        } catch let error as LLMError {
            throw error
        } catch is CancellationError {
            throw LLMError.cancelled
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw LLMError.timeout
            case .cancelled:
                throw LLMError.cancelled
            default:
                throw LLMError.networkError(underlying: urlError)
            }
        } catch {
            throw LLMError.unknown(message: error.localizedDescription)
        }
    }

    public func testConnection() async throws -> Bool {
        _ = try await listModelsDetailed()
        return true
    }

    public func listModels() async throws -> [String] {
        try await listModelsDetailed().map(\.id)
    }

    public func listModelsDetailed() async throws -> [LLMProviderModel] {
        do {
            return try await fetchModels(forceRefresh: false)
        } catch let error as LLMError {
            throw error
        } catch let error as URLError {
            if error.code == .timedOut {
                throw LLMError.timeout
            }
            if error.code == .cancelled {
                throw LLMError.cancelled
            }
            throw LLMError.networkError(underlying: error)
        } catch {
            throw LLMError.unknown(message: error.localizedDescription)
        }
    }
}

final class ModelsDebugLoggingState: @unchecked Sendable {
    static let shared = ModelsDebugLoggingState()

    private let lock = NSLock()
    private var hasLoggedStrictDecodeFailure = false

    func shouldLogStrictDecodeFailure() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !hasLoggedStrictDecodeFailure else {
            return false
        }

        hasLoggedStrictDecodeFailure = true
        return true
    }
}
