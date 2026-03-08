import Foundation

extension AgentStatePublisher {
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
            subagents[index] = SubagentBoxState(
                id: id,
                goal: goal,
                purpose: purpose,
                domain: domain,
                status: .running,
                currentAction: "Starting…",
                lines: subagents[index].lines
            )
        } else {
            subagents.append(SubagentBoxState(
                id: id,
                goal: goal,
                purpose: purpose,
                domain: domain,
                status: .running,
                currentAction: "Starting…",
                lines: []
            ))
        }
    }

    func subagentSetAction(id: String, action: String) {
        guard let index = subagents.firstIndex(where: { $0.id == id }) else { return }
        subagents[index].currentAction = action
    }

    func subagentAppendLine(
        id: String,
        type: SubagentProgressLineType,
        summary: String,
        details: String? = nil
    ) {
        guard let index = subagents.firstIndex(where: { $0.id == id }) else { return }
        subagents[index].lines.append(SubagentProgressLine(type: type, summary: summary, details: details))
        if subagents[index].lines.count > 200 {
            subagents[index].lines.removeFirst(subagents[index].lines.count - 200)
        }
    }

    func subagentFinished(id: String, status: SubagentStatus, summary: String?) {
        guard let index = subagents.firstIndex(where: { $0.id == id }) else { return }
        subagents[index].status = status
        switch status {
        case .completed:
            subagents[index].currentAction = String(localized: "Completed")
        case .failed:
            subagents[index].currentAction = String(localized: "Failed")
        case .cancelled:
            subagents[index].currentAction = String(localized: "Cancelled")
        case .running:
            break
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
