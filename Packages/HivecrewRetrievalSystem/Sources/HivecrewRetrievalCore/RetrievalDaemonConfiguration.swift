import Foundation

public struct RetrievalDaemonConfiguration: Codable, Sendable {
    public let host: String
    public let port: Int
    public let authToken: String
    public let indexingProfile: String
    public let startupAllowlistRoots: [String]
    public let queueBatchSize: Int

    public init(
        host: String = "127.0.0.1",
        port: Int = 46299,
        authToken: String,
        indexingProfile: String = "balanced",
        startupAllowlistRoots: [String] = [],
        queueBatchSize: Int = 24
    ) {
        self.host = host
        self.port = port
        self.authToken = authToken
        self.indexingProfile = indexingProfile
        self.startupAllowlistRoots = startupAllowlistRoots
        self.queueBatchSize = queueBatchSize
    }

    public static func load(from url: URL) throws -> RetrievalDaemonConfiguration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
