import Foundation

public struct ToolCallHistoryRepairResult: Sendable, Equatable {
    public let messages: [LLMMessage]
    public let removedAssistantToolCalls: Int
    public let removedToolResults: Int

    public var changed: Bool {
        removedAssistantToolCalls > 0 || removedToolResults > 0
    }

    public init(
        messages: [LLMMessage],
        removedAssistantToolCalls: Int,
        removedToolResults: Int
    ) {
        self.messages = messages
        self.removedAssistantToolCalls = removedAssistantToolCalls
        self.removedToolResults = removedToolResults
    }
}

public enum LLMConversationRepair {
    public static func repairIncompleteToolCallHistory(_ messages: [LLMMessage]) -> ToolCallHistoryRepairResult {
        let toolResultIDs = Set(messages.compactMap { message -> String? in
            guard message.role == .tool else { return nil }
            guard let toolCallId = message.toolCallId, !toolCallId.isEmpty else { return nil }
            return toolCallId
        })

        let assistantToolCallIDs = Set(messages.flatMap { message -> [String] in
            guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else { return [] }
            return toolCalls.map(\.id).filter { !$0.isEmpty }
        })

        let matchedToolCallIDs = assistantToolCallIDs.intersection(toolResultIDs)

        var repairedMessages: [LLMMessage] = []
        var seenAssistantToolCallIDs: Set<String> = []
        var seenToolResultIDs: Set<String> = []
        var removedAssistantToolCalls = 0
        var removedToolResults = 0

        for message in messages {
            switch message.role {
            case .assistant:
                guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else {
                    repairedMessages.append(message)
                    continue
                }

                let retainedToolCalls = toolCalls.filter { matchedToolCallIDs.contains($0.id) }
                removedAssistantToolCalls += toolCalls.count - retainedToolCalls.count

                if !retainedToolCalls.isEmpty {
                    seenAssistantToolCallIDs.formUnion(retainedToolCalls.map(\.id))
                }

                if retainedToolCalls.isEmpty {
                    if assistantMessageHasContent(message) {
                        repairedMessages.append(
                            LLMMessage(
                                role: .assistant,
                                content: message.content,
                                name: message.name,
                                toolCalls: nil,
                                toolCallId: message.toolCallId,
                                reasoning: message.reasoning
                            )
                        )
                    }
                    continue
                }

                if retainedToolCalls.count == toolCalls.count {
                    repairedMessages.append(message)
                    continue
                }

                repairedMessages.append(
                    LLMMessage(
                        role: .assistant,
                        content: message.content,
                        name: message.name,
                        toolCalls: retainedToolCalls,
                        toolCallId: message.toolCallId,
                        reasoning: message.reasoning
                    )
                )

            case .tool:
                guard let toolCallId = message.toolCallId, !toolCallId.isEmpty else {
                    removedToolResults += 1
                    continue
                }

                guard matchedToolCallIDs.contains(toolCallId),
                      seenAssistantToolCallIDs.contains(toolCallId),
                      seenToolResultIDs.insert(toolCallId).inserted else {
                    removedToolResults += 1
                    continue
                }

                repairedMessages.append(message)

            case .system, .user:
                repairedMessages.append(message)
            }
        }

        return ToolCallHistoryRepairResult(
            messages: repairedMessages,
            removedAssistantToolCalls: removedAssistantToolCalls,
            removedToolResults: removedToolResults
        )
    }

    private static func assistantMessageHasContent(_ message: LLMMessage) -> Bool {
        let hasText = !message.textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReasoning = !(message.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasText || hasReasoning
    }
}
