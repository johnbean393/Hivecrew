import Foundation

@MainActor
extension AgentStatePublisher {
    private func updateSubagent(id: String, _ mutate: (inout SubagentBoxState) -> Void) {
        var updated = subagents
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        mutate(&updated[index])
        subagents = updated
    }

    func subagentStarted(
        id: String,
        goal: String,
        purpose: String?,
        domain: String
    ) {
        addActivity(AgentActivityEntry(
            type: .subagent,
            summary: "Subagent: \(purpose ?? id)",
            subagentId: id
        ))

        if let index = subagents.firstIndex(where: { $0.id == id }) {
            let existingLines = subagents[index].lines
            var updated = subagents
            updated[index] = SubagentBoxState(
                id: id,
                goal: goal,
                purpose: purpose,
                domain: domain,
                status: .running,
                currentAction: "Starting…",
                lines: existingLines
            )
            subagents = updated
        } else {
            var updated = subagents
            updated.append(SubagentBoxState(
                id: id,
                goal: goal,
                purpose: purpose,
                domain: domain,
                status: .running,
                currentAction: "Starting…",
                lines: []
            ))
            subagents = updated
        }
    }

    func subagentSetAction(id: String, action: String) {
        updateSubagent(id: id) { state in
            state.currentAction = action
        }
    }

    func subagentAppendLine(
        id: String,
        type: SubagentProgressLineType,
        summary: String,
        details: String? = nil
    ) {
        updateSubagent(id: id) { state in
            state.lines.append(SubagentProgressLine(type: type, summary: summary, details: details))
            if state.lines.count > 200 {
                state.lines.removeFirst(state.lines.count - 200)
            }
        }
    }

    func subagentFinished(id: String, status: SubagentStatus, summary: String?) {
        updateSubagent(id: id) { state in
            state.status = status
            switch status {
            case .completed:
                state.currentAction = String(localized: "Completed")
            case .failed:
                state.currentAction = String(localized: "Failed")
            case .cancelled:
                state.currentAction = String(localized: "Cancelled")
            case .running:
                break
            }
        }

        if let summary, !summary.isEmpty {
            subagentAppendLine(
                id: id,
                type: .info,
                summary: "Final summary",
                details: summary
            )
        }
    }

    func messageReceived(_ message: SubagentManager.AgentMessage) {
        recentMessages.append(message)
        if recentMessages.count > 50 {
            recentMessages.removeFirst(recentMessages.count - 50)
        }

        let senderLabel = message.from == "main" ? "main agent" : "subagent \(message.from.prefix(8))"
        let recipientLabel = message.to == "main"
            ? "main agent"
            : (message.to == "broadcast" ? "all agents" : "subagent \(message.to.prefix(8))")

        addActivity(AgentActivityEntry(
            type: .info,
            summary: "Mailbox: \(senderLabel) → \(recipientLabel): \(message.subject)"
        ))
    }
}
