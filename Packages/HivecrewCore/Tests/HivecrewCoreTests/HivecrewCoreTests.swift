import Testing
@testable import HivecrewCore

@Test func orchestratorPromptRequiresRealTaskCreationBeforeConfirmation() async throws {
    let prompt = OrchestratorSystemPrompt.build()

    #expect(prompt.contains("A task is only created when `create_task` succeeds."))
    #expect(prompt.contains("Do not spend the turn saying"))
    #expect(prompt.contains("Never imply success before the tool result arrives."))
}
