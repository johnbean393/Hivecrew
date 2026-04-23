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
    _ = RemoteAccessKeychain.clearAll()
    let client = FakeRemoteAccessAPIClient(session: RemoteAccessAuthSession(
        token: "session-token",
        capabilities: RemoteAccessAccountCapabilities(
            isProtectedAccount: true,
            canDeleteAccount: false,
            deleteAccountBehavior: .logout
        )
    ))
    let manager = RemoteAccessAuthManager(apiClient: client)

    await manager.verifyOTP(email: "managed@example.test", code: String(repeating: "0", count: 6))
    #expect(manager.deleteAccountBehavior == .logout)

    let result = await manager.deleteAccount()
    let calls = await client.calls()

    #expect(result == .signedOut)
    #expect(calls.logout == 1)
    #expect(calls.deleteAccount == 0)
    #expect(manager.isAuthenticated == false)
    _ = RemoteAccessKeychain.clearAll()
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

    func calls() -> (logout: Int, deleteAccount: Int) {
        (logoutCallCount, deleteAccountCallCount)
    }
}
