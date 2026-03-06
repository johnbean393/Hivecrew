import Testing
@testable import HivecrewAPI

struct TaskBatchRequestSupportTests {

    @Test
    func validatedTargetsRejectEmptyInput() throws {
        #expect(throws: APIError.self) {
            try TaskBatchRequestSupport.validatedTargets([])
        }
    }

    @Test
    func validatedTargetsRejectInvalidCopyCount() throws {
        let targets = [
            CreateTaskBatchTarget(
                providerId: "provider-1",
                modelId: "model-1",
                copyCount: 0
            )
        ]

        #expect(throws: APIError.self) {
            try TaskBatchRequestSupport.validatedTargets(targets)
        }
    }

    @Test
    func expandedTargetsPreserveStableOrderAndReasoning() throws {
        let validated = try TaskBatchRequestSupport.validatedTargets([
            CreateTaskBatchTarget(
                providerId: "provider-1",
                modelId: "model-a",
                copyCount: 2,
                reasoningEnabled: true,
                reasoningEffort: nil
            ),
            CreateTaskBatchTarget(
                providerId: "provider-2",
                modelId: "model-b",
                copyCount: 1,
                reasoningEnabled: nil,
                reasoningEffort: "high"
            )
        ])

        let expanded = TaskBatchRequestSupport.expandedTargets(validated)

        #expect(expanded.count == 3)
        #expect(expanded[0] == CreateTaskBatchTarget(
            providerId: "provider-1",
            modelId: "model-a",
            copyCount: 1,
            reasoningEnabled: true,
            reasoningEffort: nil
        ))
        #expect(expanded[1] == CreateTaskBatchTarget(
            providerId: "provider-1",
            modelId: "model-a",
            copyCount: 1,
            reasoningEnabled: true,
            reasoningEffort: nil
        ))
        #expect(expanded[2] == CreateTaskBatchTarget(
            providerId: "provider-2",
            modelId: "model-b",
            copyCount: 1,
            reasoningEnabled: nil,
            reasoningEffort: "high"
        ))
    }
}
