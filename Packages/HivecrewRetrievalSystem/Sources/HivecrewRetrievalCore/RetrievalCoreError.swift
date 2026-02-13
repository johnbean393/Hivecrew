import Foundation

public enum RetrievalCoreError: LocalizedError {
    case sqliteError(String)
    case malformedConfiguration(String)
    case unavailableEmbeddingRuntime
    case unauthorized
    case missingSuggestion(String)
    case invalidState(String)

    public var errorDescription: String? {
        switch self {
        case .sqliteError(let message):
            return "SQLite error: \(message)"
        case .malformedConfiguration(let message):
            return "Malformed retrieval configuration: \(message)"
        case .unavailableEmbeddingRuntime:
            return "No local embedding runtime is available."
        case .unauthorized:
            return "Unauthorized retrieval daemon request."
        case .missingSuggestion(let id):
            return "Missing suggestion with id \(id)."
        case .invalidState(let message):
            return "Invalid retrieval state: \(message)"
        }
    }
}
