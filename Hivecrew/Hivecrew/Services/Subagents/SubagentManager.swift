//
//  SubagentManager.swift
//  Hivecrew
//
//  Manages subagent lifecycle, tracing, and result delivery.
//

import Foundation
import HivecrewLLM
import HivecrewAgentProtocol

enum SubagentDomain: String, Sendable, CaseIterable {
    case host
    case vm
    case mixed
}

@MainActor
final class SubagentManager {
    enum Status: String, Sendable {
        case running
        case completed
        case failed
        case cancelled
    }
    
    struct Info: Sendable {
        let id: String
        let purpose: String?
        let domain: SubagentDomain
        let toolAllowlist: [String]
        let status: Status
        let startedAt: Date
        let endedAt: Date?
        let tracePath: String
        let summary: String?
        let errorMessage: String?
    }
    
    struct Completion: Sendable {
        let id: String
        let purpose: String?
        let summary: String
        let domain: SubagentDomain
    }
    
    private struct Handle {
        var info: Info
        var task: Task<SubagentRunner.Result, Error>?
    }
    
    private var handles: [String: Handle] = [:]
    private var completionQueue: [Completion] = []
    
    private let taskId: String
    private let vmId: String
    private let sessionPath: URL
    private let rootTracer: AgentTracer
    private weak var statePublisher: AgentStatePublisher?
    private let toolExecutor: SubagentToolExecutor
    private let llmClientFactory: @Sendable (String?) async throws -> any LLMClientProtocol
    private let vmScheduler: VMToolScheduler
    
    init(
        taskId: String,
        vmId: String,
        sessionPath: URL,
        rootTracer: AgentTracer,
        statePublisher: AgentStatePublisher,
        toolExecutor: SubagentToolExecutor,
        vmScheduler: VMToolScheduler,
        llmClientFactory: @escaping @Sendable (String?) async throws -> any LLMClientProtocol
    ) {
        self.taskId = taskId
        self.vmId = vmId
        self.sessionPath = sessionPath
        self.rootTracer = rootTracer
        self.statePublisher = statePublisher
        self.toolExecutor = toolExecutor
        self.llmClientFactory = llmClientFactory
        self.vmScheduler = vmScheduler
    }
    
    func setPaused(_ paused: Bool) async {
        await vmScheduler.setPaused(paused)
    }
    
    func spawn(
        goal: String,
        domain: SubagentDomain,
        toolAllowlist: [String]?,
        timeoutSeconds: Double?,
        modelOverride: String?,
        purpose: String?
    ) async -> Info {
        let id = UUID().uuidString
        let allowlist = normalizedAllowlist(goal: goal, domain: domain, requested: toolAllowlist)
        let subagentDir = sessionPath.appendingPathComponent("subagents").appendingPathComponent(id)
        let tracePath = subagentDir.appendingPathComponent("trace.jsonl")
        let relativeTracePath = "subagents/\(id)/trace.jsonl"
        
        let startedAt = Date()
        let info = Info(
            id: id,
            purpose: purpose,
            domain: domain,
            toolAllowlist: allowlist,
            status: .running,
            startedAt: startedAt,
            endedAt: nil,
            tracePath: relativeTracePath,
            summary: nil,
            errorMessage: nil
        )
        
        let handle = Handle(info: info, task: nil)
        handles[id] = handle
        
        statePublisher?.subagentStarted(
            id: id,
            goal: goal,
            purpose: purpose,
            domain: domain.rawValue
        )
        statePublisher?.subagentSetAction(id: id, action: "Queued")
        statePublisher?.subagentAppendLine(
            id: id,
            type: .info,
            summary: "Goal",
            details: goal
        )
        
        logLifecycleEvent(
            eventType: "subagent_started",
            subagentId: id,
            purpose: purpose,
            domain: domain,
            toolAllowlist: allowlist,
            tracePath: relativeTracePath,
            status: "running",
            durationMs: nil,
            errorMessage: nil
        )
        
        let task = Task { @MainActor [weak self] () -> SubagentRunner.Result in
            guard let self = self else { throw CancellationError() }
            let client = try await self.llmClientFactory(modelOverride)
            let tools = try await self.buildTools(for: allowlist)
            let tracer = try AgentTracer(sessionId: id, outputDirectory: subagentDir)
            
            try? await tracer.logSessionStart(
                taskId: self.taskId,
                taskDescription: goal,
                model: client.configuration.model,
                vmId: domain == .host ? nil : self.vmId
            )
            
            let runner = SubagentRunner(
                subagentId: id,
                goal: goal,
                domain: domain,
                toolAllowlist: allowlist,
                llmClient: client,
                tracer: tracer,
                toolExecutor: self.toolExecutor,
                tools: tools,
                onActionUpdate: { [weak self] action in
                    self?.statePublisher?.subagentSetAction(id: id, action: action)
                },
                onLine: { [weak self] line in
                    self?.statePublisher?.subagentAppendLine(
                        id: id,
                        type: line.type,
                        summary: line.summary,
                        details: line.details
                    )
                }
            )
            do {
                let result = try await withOptionalTimeout(seconds: timeoutSeconds) {
                    try await runner.run()
                }
                try? await tracer.logSessionEnd(status: "completed", summary: result.summary)
                return result
            } catch {
                try? await tracer.logSessionEnd(status: "failed", summary: error.localizedDescription)
                throw error
            }
        }
        
        handles[id]?.task = task
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            let _ = await self.awaitCompletion(subagentId: id)
        }
        
        return info
    }
    
    func getStatus(subagentId: String) -> Info? {
        handles[subagentId]?.info
    }
    
    func list() -> [Info] {
        handles.values.map(\.info).sorted { $0.startedAt < $1.startedAt }
    }
    
    func cancel(subagentId: String) async -> Bool {
        guard var handle = handles[subagentId] else { return false }
        handle.task?.cancel()
        handle.info = updatedInfo(handle.info, status: .cancelled, summary: nil, errorMessage: "Cancelled")
        handles[subagentId] = handle
        statePublisher?.subagentFinished(id: subagentId, status: .cancelled, summary: nil)
        logLifecycleEvent(
            eventType: "subagent_cancelled",
            subagentId: subagentId,
            purpose: handle.info.purpose,
            domain: handle.info.domain,
            toolAllowlist: handle.info.toolAllowlist,
            tracePath: handle.info.tracePath,
            status: "cancelled",
            durationMs: durationMs(for: handle.info),
            errorMessage: "Cancelled"
        )
        return true
    }
    
    func cancelAll() async {
        for id in handles.keys {
            _ = await cancel(subagentId: id)
        }
    }
    
    func awaitResult(subagentId: String, timeoutSeconds: Double?) async -> Info? {
        guard let handle = handles[subagentId] else { return nil }
        if handle.info.status != .running { return handle.info }
        
        if let timeout = timeoutSeconds {
            _ = await awaitCompletionWithTimeout(subagentId: subagentId, timeoutSeconds: timeout)
        } else {
            _ = await awaitCompletion(subagentId: subagentId)
        }
        return handles[subagentId]?.info
    }
    
    func drainCompletions() -> [Completion] {
        let drained = completionQueue
        completionQueue.removeAll()
        return drained
    }
    
    // MARK: - Private
    
    private func awaitCompletion(subagentId: String) async -> Bool {
        guard let handle = handles[subagentId], let task = handle.task else { return false }
        do {
            let result = try await task.value
            finalizeSuccess(subagentId: subagentId, handle: handle, result: result)
            return true
        } catch {
            finalizeFailure(subagentId: subagentId, handle: handle, error: error)
            return false
        }
    }
    
    private func awaitCompletionWithTimeout(subagentId: String, timeoutSeconds: Double) async -> Bool {
        guard let handle = handles[subagentId], let task = handle.task else { return false }
        do {
            let result = try await withOptionalTimeout(seconds: timeoutSeconds) {
                try await task.value
            }
            finalizeSuccess(subagentId: subagentId, handle: handle, result: result)
            return true
        } catch is CancellationError {
            return false
        } catch {
            finalizeFailure(subagentId: subagentId, handle: handle, error: error)
            return false
        }
    }

    private func finalizeSuccess(subagentId: String, handle: Handle, result: SubagentRunner.Result) {
        var updatedHandle = handle
        updatedHandle.info = updatedInfo(updatedHandle.info, status: .completed, summary: result.summary, errorMessage: nil)
        handles[subagentId] = updatedHandle
        statePublisher?.subagentFinished(id: subagentId, status: .completed, summary: result.summary)
        
        completionQueue.append(Completion(
            id: subagentId,
            purpose: updatedHandle.info.purpose,
            summary: result.summary,
            domain: updatedHandle.info.domain
        ))
        
        logLifecycleEvent(
            eventType: "subagent_completed",
            subagentId: subagentId,
            purpose: updatedHandle.info.purpose,
            domain: updatedHandle.info.domain,
            toolAllowlist: updatedHandle.info.toolAllowlist,
            tracePath: updatedHandle.info.tracePath,
            status: "completed",
            durationMs: durationMs(for: updatedHandle.info),
            errorMessage: nil
        )
    }
    
    private func finalizeFailure(subagentId: String, handle: Handle, error: Error) {
        var updatedHandle = handle
        updatedHandle.info = updatedInfo(updatedHandle.info, status: .failed, summary: nil, errorMessage: error.localizedDescription)
        handles[subagentId] = updatedHandle
        statePublisher?.subagentFinished(id: subagentId, status: .failed, summary: error.localizedDescription)
        logLifecycleEvent(
            eventType: "subagent_failed",
            subagentId: subagentId,
            purpose: updatedHandle.info.purpose,
            domain: updatedHandle.info.domain,
            toolAllowlist: updatedHandle.info.toolAllowlist,
            tracePath: updatedHandle.info.tracePath,
            status: "failed",
            durationMs: durationMs(for: updatedHandle.info),
            errorMessage: error.localizedDescription
        )
    }
    
    private func defaultAllowlist(for domain: SubagentDomain) -> [String] {
        switch domain {
        case .host:
            return ["web_search", "read_webpage_content", "extract_info_from_webpage", "get_location", "create_todo_list", "add_todo_item", "finish_todo_item", "generate_image", "wait"]
        case .vm:
            return ["run_shell", "read_file", "move_file", "wait"]
        case .mixed:
            return ["web_search", "read_webpage_content", "extract_info_from_webpage", "get_location", "run_shell", "read_file", "move_file", "create_todo_list", "add_todo_item", "finish_todo_item", "generate_image", "wait"]
        }
    }
    
    private func normalizedAllowlist(
        goal: String,
        domain: SubagentDomain,
        requested: [String]?
    ) -> [String] {
        // Subagents always get all built-in tools plus all MCP tools.
        // This avoids mismatches where a subagent's goal requires a tool (file ops, images, etc.)
        // that wasn't included in an allowlist for its domain.
        var allowlist = Set(AgentMethod.allCases.map(\.rawValue))
        allowlist.insert("mcp_*")
        return Array(allowlist).sorted()
    }
    
    private func isResearchGoal(_ goal: String) -> Bool {
        let lowered = goal.lowercased()
        return lowered.contains("research") ||
        lowered.contains("latest") ||
        lowered.contains("compare") ||
        lowered.contains("benchmark") ||
        lowered.contains("pricing") ||
        lowered.contains("release date") ||
        lowered.contains("llm") ||
        lowered.contains("model")
    }
    
    private func requiresFileIO(_ goal: String) -> Bool {
        let lowered = goal.lowercased()
        if lowered.contains("outbox") || lowered.contains("inbox") {
            return true
        }
        if lowered.contains("~/") || lowered.contains("/desktop/") || lowered.contains("/documents/") {
            return true
        }
        let extensions = [
            ".md", ".txt", ".pdf", ".doc", ".docx", ".ppt", ".pptx", ".key",
            ".csv", ".json", ".rtf", ".html", ".png", ".jpg", ".jpeg", ".gif", ".webp"
        ]
        return extensions.contains(where: { lowered.contains($0) })
    }
    
    private func buildTools(for allowlist: [String]) async throws -> [LLMToolDefinition] {
        let schemaBuilder = ToolSchemaBuilder()
        var tools: [LLMToolDefinition] = []
        
        let methodNames = Set(AgentMethod.allCases.map(\.rawValue))
        let allowedBuiltins = allowlist.filter { methodNames.contains($0) }
        let allowedMethods = allowedBuiltins.compactMap { AgentMethod(rawValue: $0) }
        tools.append(contentsOf: schemaBuilder.buildTools(for: allowedMethods))
        
        let allowAllMCP = allowlist.contains("mcp_*")
        if allowAllMCP || allowlist.contains(where: { $0.hasPrefix("mcp_") }) {
            await MCPServerManager.shared.connectAllEnabledIfNeeded()
            let mcpTools = await MCPServerManager.shared.getAllTools()
            if allowAllMCP {
                tools.append(contentsOf: mcpTools)
            } else {
                let allowedMCP = Set(allowlist.filter { $0.hasPrefix("mcp_") })
                tools.append(contentsOf: mcpTools.filter { allowedMCP.contains($0.function.name) })
            }
        }
        
        return tools
    }
    
    private func durationMs(for info: Info) -> Int? {
        guard let endedAt = info.endedAt else { return nil }
        return Int(endedAt.timeIntervalSince(info.startedAt) * 1000)
    }
    
    private func updatedInfo(
        _ info: Info,
        status: Status,
        summary: String?,
        errorMessage: String?
    ) -> Info {
        Info(
            id: info.id,
            purpose: info.purpose,
            domain: info.domain,
            toolAllowlist: info.toolAllowlist,
            status: status,
            startedAt: info.startedAt,
            endedAt: Date(),
            tracePath: info.tracePath,
            summary: summary,
            errorMessage: errorMessage
        )
    }
    
    private func logLifecycleEvent(
        eventType: String,
        subagentId: String,
        purpose: String?,
        domain: SubagentDomain,
        toolAllowlist: [String],
        tracePath: String,
        status: String,
        durationMs: Int?,
        errorMessage: String?
    ) {
        var metadata: [String: String] = [
            "event_type": eventType,
            "subagent_id": subagentId,
            "domain": domain.rawValue,
            "trace_path": tracePath,
            "status": status
        ]
        if let purpose = purpose, !purpose.isEmpty {
            metadata["purpose"] = purpose
        }
        if let durationMs = durationMs {
            metadata["duration_ms"] = String(durationMs)
        }
        if let errorMessage = errorMessage, !errorMessage.isEmpty {
            metadata["error"] = errorMessage
        }
        if let allowlistData = try? JSONSerialization.data(withJSONObject: toolAllowlist, options: []),
           let allowlistString = String(data: allowlistData, encoding: .utf8) {
            metadata["tool_allowlist"] = allowlistString
        }
        
        Task {
            try? await rootTracer.logCustomEvent(metadata: metadata)
        }
    }
}

private func withOptionalTimeout<T>(
    seconds: Double?,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    guard let seconds = seconds else {
        return try await operation()
    }
    
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
