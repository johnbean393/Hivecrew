import Foundation

enum SessionTraceParser {
    static func parseEvents(from content: String) -> [TraceEventInfo] {
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        return lines.compactMap { line -> TraceEventInfo? in
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            let id = json["id"] as? String ?? UUID().uuidString
            let type = json["type"] as? String ?? "unknown"
            let timestamp = json["timestamp"] as? String ?? ""
            let step = json["step"] as? Int ?? 0

            var summary = ""
            var details: String?
            var screenshotPath: String?
            var responseText: String?
            var reasoning: String?
            var tokenUsage: TraceTokenUsage = .zero
            var subagentTracePath: String?
            var subagentId: String?
            var subagentStatus: String?
            var subagentPurpose: String?
            var subagentDomain: String?

            if let eventData = json["data"] as? [String: Any] {
                let extracted = extractEventDetails(from: eventData, type: type)
                summary = extracted.summary
                details = extracted.details
                screenshotPath = extracted.screenshotPath
                responseText = extracted.responseText
                reasoning = extracted.reasoning
                tokenUsage = extracted.tokenUsage
                subagentTracePath = extracted.subagentTracePath
                subagentId = extracted.subagentId
                subagentStatus = extracted.subagentStatus
                subagentPurpose = extracted.subagentPurpose
                subagentDomain = extracted.subagentDomain
            }

            return TraceEventInfo(
                id: id,
                type: type,
                timestamp: timestamp,
                step: step,
                summary: summary,
                rawJSON: line,
                screenshotPath: screenshotPath,
                details: details,
                responseText: responseText,
                reasoning: reasoning,
                tokenUsage: tokenUsage,
                subagentTracePath: subagentTracePath,
                subagentId: subagentId,
                subagentStatus: subagentStatus,
                subagentPurpose: subagentPurpose,
                subagentDomain: subagentDomain
            )
        }
    }

    private static func extractEventDetails(from data: [String: Any], type: String) -> (
        summary: String,
        details: String?,
        screenshotPath: String?,
        responseText: String?,
        reasoning: String?,
        tokenUsage: TraceTokenUsage,
        subagentTracePath: String?,
        subagentId: String?,
        subagentStatus: String?,
        subagentPurpose: String?,
        subagentDomain: String?
    ) {
        var summary = ""
        var details: String?
        var screenshotPath: String?
        var responseText: String?
        var reasoning: String?
        var tokenUsage: TraceTokenUsage = .zero
        var subagentTracePath: String?
        var subagentId: String?
        var subagentStatus: String?
        var subagentPurpose: String?
        var subagentDomain: String?

        switch type {
        case "session_start":
            if let sessionStart = data["sessionStart"] as? [String: Any],
               let inner = sessionStart["_0"] as? [String: Any] {
                summary = "Session started"
                details = inner["taskDescription"] as? String
            }
        case "session_end":
            if let sessionEnd = data["sessionEnd"] as? [String: Any],
               let inner = sessionEnd["_0"] as? [String: Any] {
                let status = inner["status"] as? String ?? "unknown"
                summary = "Session ended: \(status)"
                if let sessionSummary = inner["summary"] as? String {
                    details = sessionSummary
                    responseText = sessionSummary
                }
            }
        case "observation":
            if let observation = data["observation"] as? [String: Any],
               let inner = observation["_0"] as? [String: Any] {
                let width = inner["screenWidth"] as? Int ?? 0
                let height = inner["screenHeight"] as? Int ?? 0
                summary = "Screenshot captured"
                details = "\(width) x \(height)"
                screenshotPath = inner["screenshotPath"] as? String
            }
        case "llm_request":
            if let llmRequest = data["llmRequest"] as? [String: Any],
               let inner = llmRequest["_0"] as? [String: Any] {
                let model = inner["model"] as? String ?? "unknown"
                let messageCount = inner["messageCount"] as? Int ?? 0
                summary = "Sending request to LLM"
                details = "Model: \(model), \(messageCount) messages"
            }
        case "llm_response":
            if let llmResponse = data["llmResponse"] as? [String: Any],
               let inner = llmResponse["_0"] as? [String: Any] {
                let toolCallCount = inner["toolCallCount"] as? Int ?? 0
                let promptTokens = inner["promptTokens"] as? Int ?? 0
                let completionTokens = inner["completionTokens"] as? Int ?? 0
                let totalTokens = inner["totalTokens"] as? Int ?? 0
                let fullResponseText = inner["responseText"] as? String
                let contentPreview = inner["contentPreview"] as? String
                reasoning = inner["reasoning"] as? String
                tokenUsage = TraceTokenUsage(
                    prompt: promptTokens,
                    completion: completionTokens,
                    total: totalTokens
                )

                if toolCallCount > 0 {
                    summary = "LLM requested \(toolCallCount) tool call(s)"
                } else if let text = fullResponseText ?? contentPreview, !text.isEmpty {
                    summary = String(text.prefix(100)) + (text.count > 100 ? "..." : "")
                    responseText = fullResponseText ?? contentPreview
                } else {
                    summary = "LLM responded"
                }
                if tokenUsage.hasUsage {
                    let usageParts = [
                        promptTokens > 0 ? "+\(promptTokens) prompt" : nil,
                        completionTokens > 0 ? "+\(completionTokens) completion" : nil,
                        totalTokens > 0 ? "\(totalTokens) total" : nil
                    ]
                    .compactMap { $0 }

                    details = usageParts.isEmpty ? nil : usageParts.joined(separator: ", ")
                }
            }
        case "tool_call":
            if let toolCall = data["toolCall"] as? [String: Any],
               let inner = toolCall["_0"] as? [String: Any] {
                let toolName = inner["toolName"] as? String ?? "unknown"
                summary = "Executing: \(toolName)"
                if let args = inner["arguments"] as? [String: Any] {
                    let argSummary = args.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
                    if !argSummary.isEmpty {
                        details = argSummary
                    }
                }
            }
        case "tool_result":
            if let toolResult = data["toolResult"] as? [String: Any],
               let inner = toolResult["_0"] as? [String: Any] {
                let success = inner["success"] as? Bool ?? false
                let toolName = inner["toolName"] as? String ?? "tool"
                let durationMs = inner["durationMs"] as? Int ?? 0
                summary = success ? "✓ \(toolName)" : "✗ \(toolName)"
                if let result = inner["result"] as? String, !result.isEmpty {
                    details = "\(result)\n(\(durationMs)ms)"
                } else {
                    details = "(\(durationMs)ms)"
                }
            }
        case "error":
            if let error = data["error"] as? [String: Any],
               let inner = error["_0"] as? [String: Any] {
                summary = "Error occurred"
                details = inner["message"] as? String
            }
        case "custom":
            if let custom = data["custom"] as? [String: Any] {
                let inner = (custom["_0"] as? [String: Any]) ?? custom
                if let eventType = inner["event_type"] as? String, eventType.hasPrefix("subagent_") {
                    subagentId = inner["subagent_id"] as? String
                    subagentTracePath = inner["trace_path"] as? String
                    subagentStatus = inner["status"] as? String
                    subagentPurpose = inner["purpose"] as? String
                    subagentDomain = inner["domain"] as? String

                    let purposeText = subagentPurpose.map { " \($0)" } ?? ""
                    switch eventType {
                    case "subagent_started":
                        summary = "Subagent started:\(purposeText)"
                    case "subagent_completed":
                        summary = "Subagent completed:\(purposeText)"
                    case "subagent_failed":
                        summary = "Subagent failed:\(purposeText)"
                    case "subagent_cancelled":
                        summary = "Subagent cancelled:\(purposeText)"
                    default:
                        summary = "Subagent event:\(purposeText)"
                    }

                    var detailParts: [String] = []
                    if let domain = subagentDomain { detailParts.append("Domain: \(domain)") }
                    if let status = subagentStatus { detailParts.append("Status: \(status)") }
                    if let allowlist = inner["tool_allowlist"] as? String { detailParts.append("Tools: \(allowlist)") }
                    if let duration = inner["duration_ms"] as? String { detailParts.append("Duration: \(duration)ms") }
                    if let errorMessage = inner["error"] as? String { detailParts.append("Error: \(errorMessage)") }
                    details = detailParts.isEmpty ? nil : detailParts.joined(separator: " • ")
                } else {
                    summary = "Custom event"
                }
            }
        default:
            summary = type.replacingOccurrences(of: "_", with: " ").capitalized
        }

        return (
            summary,
            details,
            screenshotPath,
            responseText,
            reasoning,
            tokenUsage,
            subagentTracePath,
            subagentId,
            subagentStatus,
            subagentPurpose,
            subagentDomain
        )
    }
}
