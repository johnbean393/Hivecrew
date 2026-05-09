import Testing
import HivecrewAPIModels
@testable import HivecrewCore

@Test func orchestratorPromptRequiresRealTaskCreationBeforeConfirmation() async throws {
    let prompt = OrchestratorSystemPrompt.build()

    #expect(prompt.contains("A task is only created when `create_task` succeeds."))
    #expect(prompt.contains("Do not spend the turn saying"))
    #expect(prompt.contains("Never imply success before the tool result arrives."))
}

@Test @MainActor func protectedAccountDeleteUsesLogoutPath() async throws {
    let client = FakeRemoteAccessAPIClient(session: RemoteAccessAuthSession(
        token: "session-token",
        capabilities: RemoteAccessAccountCapabilities(
            isProtectedAccount: true,
            canDeleteAccount: false,
            deleteAccountBehavior: .logout
        )
    ))
    let credentialStore = InMemoryRemoteAccessCredentialStore()
    let manager = RemoteAccessAuthManager(apiClient: client, credentialStore: credentialStore)

    await manager.verifyOTP(email: "managed@example.test", code: String(repeating: "0", count: 6))
    #expect(manager.deleteAccountBehavior == .logout)
    #expect(credentialStore.retrieveSessionToken() == "session-token")

    let result = await manager.deleteAccount()
    let calls = await client.calls()

    #expect(result == .signedOut)
    #expect(calls.logout == 1)
    #expect(calls.deleteAccount == 0)
    #expect(manager.isAuthenticated == false)
    #expect(credentialStore.retrieveSessionToken() == nil)
}

@Test func providerCapabilitiesMergeDuplicateProviderAndModelIds() async throws {
    let summaries = PeerAPIClient.normalizedProviderCapabilities([
        PeerProviderSummary(providerName: "OpenAI", modelIds: ["gpt-5.2", "gpt-5.2"]),
        PeerProviderSummary(providerName: "Anthropic", modelIds: ["claude-sonnet"]),
        PeerProviderSummary(providerName: "OpenAI", modelIds: ["gpt-5.2", "gpt-5.4"]),
    ])

    #expect(summaries == [
        PeerProviderSummary(providerName: "OpenAI", modelIds: ["gpt-5.2", "gpt-5.4"]),
        PeerProviderSummary(providerName: "Anthropic", modelIds: ["claude-sonnet"]),
    ])
}

private actor FakeRemoteAccessAPIClient: RemoteAccessAPIClientProtocol {
    private let session: RemoteAccessAuthSession
    private var logoutCallCount = 0
    private var deleteAccountCallCount = 0
    private var deleteTunnelCallCount = 0

    init(session: RemoteAccessAuthSession) {
        self.session = session
    }

    func register(email: String) async throws {}

    func verify(email: String, code: String) async throws -> RemoteAccessAuthSession {
        session
    }

    func logout(sessionToken: String, ownerId: String?) async throws {
        logoutCallCount += 1
    }

    func deleteAccount(sessionToken: String) async throws {
        deleteAccountCallCount += 1
    }

    func deleteTunnel(tunnelId: String, sessionToken: String) async throws {
        deleteTunnelCallCount += 1
    }

    func calls() -> (logout: Int, deleteAccount: Int, deleteTunnel: Int) {
        (logoutCallCount, deleteAccountCallCount, deleteTunnelCallCount)
    }
}

private final class InMemoryRemoteAccessCredentialStore: RemoteAccessCredentialStore, @unchecked Sendable {
    private var sessionToken: String?
    private var email: String?
    private var capabilities: RemoteAccessAccountCapabilities = .standard
    private var tunnelId: String?
    private var tunnelToken: String?

    func storeSessionToken(_ token: String) -> Bool {
        sessionToken = token
        return true
    }

    func retrieveSessionToken() -> String? {
        sessionToken
    }

    func storeEmail(_ email: String) -> Bool {
        self.email = email
        return true
    }

    func retrieveEmail() -> String? {
        email
    }

    func storeAccountCapabilities(_ capabilities: RemoteAccessAccountCapabilities) -> Bool {
        self.capabilities = capabilities
        return true
    }

    func retrieveAccountCapabilities() -> RemoteAccessAccountCapabilities {
        capabilities
    }

    func retrieveTunnelId() -> String? {
        tunnelId
    }

    func retrieveTunnelToken() -> String? {
        tunnelToken
    }

    func clearAll() -> Bool {
        sessionToken = nil
        email = nil
        capabilities = .standard
        tunnelId = nil
        tunnelToken = nil
        return true
    }
}
