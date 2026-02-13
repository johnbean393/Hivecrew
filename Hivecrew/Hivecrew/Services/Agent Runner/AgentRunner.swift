//
//  AgentRunner.swift
//  Hivecrew
//
//  Core agent loop implementation (observe -> decide -> execute)
//

import Foundation
import AppKit
import Virtualization
import OSLog
import HivecrewLLM
import HivecrewShared
import HivecrewAgentProtocol

/// Reason for agent termination
enum AgentTerminationReason: String, Sendable {
    case completed = "completed"          // Task finished successfully
    case failed = "failed"                // Task failed due to error
    case cancelled = "cancelled"          // User cancelled
    case timedOut = "timed_out"           // Exceeded timeout duration
    case maxIterations = "max_iterations" // Exceeded max iterations
}

/// Result of an agent run
struct AgentResult: Sendable {
    let success: Bool
    let summary: String?
    let errorMessage: String?
    let stepCount: Int
    let promptTokens: Int
    let completionTokens: Int
    let terminationReason: AgentTerminationReason
}

/// The core agent runner that implements the observe-decide-execute loop
@MainActor
final class AgentRunner {
    
    // MARK: - Properties
    
    let task: TaskRecord
    private let vmId: String
    let llmClient: any LLMClientProtocol
    let connection: GuestAgentConnection
    let tracer: AgentTracer
    let toolExecutor: ToolExecutor
    let statePublisher: AgentStatePublisher
    let subagentManager: SubagentManager
    let sessionPath: URL
    let vmToolScheduler: VMToolScheduler
    
    var conversationHistory: [LLMMessage] = []
    var stepCount: Int = 0
    var isCancelled: Bool = false
    var isTimedOut: Bool = false
    var isPaused: Bool = false
    let maxSteps: Int
    let timeoutMinutes: Int
    let screenshotsPath: URL
    
    /// Cached initial screenshot (used for first observation to avoid double-fetching)
    var initialScreenshot: ScreenshotResult?
    
    /// Tools available to the agent (includes both built-in and MCP tools)
    var tools: [LLMToolDefinition]
    
    /// Input file names available in the inbox
    private let inputFileNames: [String]
    
    /// Skills matched for this task
    private let matchedSkills: [Skill]
    
    /// Todo manager for tracking agent tasks
    let todoManager: TodoManager
    
    /// Plan state for tracking plan progress (if task has a plan)
    var planState: PlanState?
    
    /// Task for timeout monitoring
    private var timeoutTask: Task<Void, Never>?
    
    /// Continuation for waiting when paused
    private var pauseContinuation: CheckedContinuation<String?, Never>?
    
    /// Number of times the agent has attempted to complete but verification failed
    var completionAttempts: Int = 0
    
    /// Maximum number of completion verification retries before giving up
    let maxCompletionAttempts: Int = {
        let stored = UserDefaults.standard.integer(forKey: "maxCompletionAttempts")
        return stored > 0 ? min(max(stored, 1), 10) : 3
    }()
    
    /// Maximum number of retries for LLM calls
    let maxLLMRetries = 3
    
    /// Base delay for exponential backoff (in seconds)
    let baseRetryDelay: Double = 2.0
    
    /// Track if the last tool execution requires a new screenshot
    /// (false if all tools were host-side, true otherwise)
    var needsScreenshotUpdate: Bool = true
    
    /// Current image scale level for non-screenshot images
    /// Starts at medium (1024px max) and can be reduced on payload too large errors
    var currentImageScaleLevel: ImageDownscaler.ScaleLevel = .medium

    /// Whether the active model supports image input.
    let supportsVision: Bool
    
    // MARK: - Initialization
    
    init(
        task: TaskRecord,
        vmId: String,
        llmClient: any LLMClientProtocol,
        connection: GuestAgentConnection,
        sessionPath: URL,
        statePublisher: AgentStatePublisher,
        inputFileNames: [String] = [],
        matchedSkills: [Skill] = [],
        maxSteps: Int = 100,
        timeoutMinutes: Int = 30,
        taskService: TaskService,
        supportsVision: Bool = true
    ) throws {
        self.task = task
        self.vmId = vmId
        self.llmClient = llmClient
        self.connection = connection
        self.statePublisher = statePublisher
        self.sessionPath = sessionPath
        self.inputFileNames = inputFileNames
        self.matchedSkills = matchedSkills
        self.maxSteps = maxSteps
        self.timeoutMinutes = timeoutMinutes
        self.todoManager = TodoManager()
        self.vmToolScheduler = VMToolScheduler()
        self.supportsVision = supportsVision
        
        // Create screenshots directory
        self.screenshotsPath = sessionPath.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: screenshotsPath, withIntermediateDirectories: true)
        
        // Create tracer
        self.tracer = try AgentTracer(sessionId: statePublisher.sessionId ?? UUID().uuidString, outputDirectory: sessionPath)
        
        // Create tool executor with todo manager and worker model support
        self.toolExecutor = ToolExecutor(
            connection: connection,
            todoManager: todoManager,
            taskProviderId: task.providerId,
            taskModelId: task.modelId,
            taskService: taskService,
            modelContext: taskService.modelContext,
            vmId: vmId,
            supportsVision: supportsVision
        )
        self.toolExecutor.taskId = task.id
        
        let subagentToolExecutor = SubagentToolExecutor(
            connection: connection,
            vmScheduler: vmToolScheduler,
            vmId: vmId,
            taskId: task.id,
            taskProviderId: task.providerId,
            taskModelId: task.modelId,
            taskService: taskService,
            todoManager: TodoManager(),
            modelContext: taskService.modelContext,
            mainModelSupportsVision: supportsVision
        )
        self.subagentManager = SubagentManager(
            taskId: task.id,
            vmId: vmId,
            sessionPath: sessionPath,
            rootTracer: tracer,
            statePublisher: statePublisher,
            toolExecutor: subagentToolExecutor,
            vmScheduler: vmToolScheduler,
            llmClientFactory: { modelOverride in
                if let override = modelOverride, !override.isEmpty {
                    return try await taskService.createLLMClient(providerId: task.providerId, modelId: override)
                }
                return try await taskService.createLLMClient(
                    providerId: task.providerId,
                    modelId: task.modelId
                )
            },
            visionCapabilityResolver: { modelId, client in
                let capability = await taskService.resolveVisionCapability(
                    providerId: task.providerId,
                    modelId: modelId,
                    using: client
                )
                return capability.supportsVision
            }
        )
        self.toolExecutor.subagentManager = self.subagentManager
        subagentToolExecutor.subagentManager = self.subagentManager
        
        // Set up question callback to use statePublisher
        self.toolExecutor.onAskQuestion = { [weak statePublisher] question in
            guard let publisher = statePublisher else { return "No response available" }
            return await publisher.askQuestion(question)
        }
        subagentToolExecutor.onAskQuestion = { [weak statePublisher] question in
            guard let publisher = statePublisher else { return "No response available" }
            return await publisher.askQuestion(question)
        }
        
        // Set up permission callback for dangerous tools
        self.toolExecutor.onRequestPermission = { [weak statePublisher] toolName, details in
            guard let publisher = statePublisher else { return false }
            return await publisher.requestPermission(toolName: toolName, details: details)
        }
        subagentToolExecutor.onRequestPermission = { [weak statePublisher] toolName, details in
            guard let publisher = statePublisher else { return false }
            return await publisher.requestPermission(toolName: toolName, details: details)
        }
        
        // Build essential CUA tool definitions (includes user interaction tools)
        // Note: Screenshot is NOT a tool - we automatically capture after each action
        let schemaBuilder = ToolSchemaBuilder()
        
        // Determine which tools to exclude based on availability
        var excludedTools: Set<AgentMethod> = []
        
        // Exclude image generation tool if not configured
        if let modelContext = taskService.modelContext {
            if !ImageGenerationAvailability.isAvailable(modelContext: modelContext) {
                excludedTools.insert(.generateImage)
            }
        } else {
            // No model context available, exclude image generation
            excludedTools.insert(.generateImage)
        }

        if !supportsVision {
            let visionDependentTools = AgentMethod.allCases.filter(\.isVisionDependentTool)
            excludedTools.formUnion(visionDependentTools)
        }
        
        if excludedTools.isEmpty {
            self.tools = schemaBuilder.buildCUATools()
        } else {
            self.tools = schemaBuilder.buildCUATools(excluding: excludedTools)
        }
        
        // Set up todo callbacks to sync with plan state
        // Note: Must be after self.tools is initialized since callbacks capture self
        self.toolExecutor.onTodoItemFinished = { [weak self] index, itemText in
            guard let self = self else { return }
            // Sync with plan state using item text
            self.completePlanItem(content: itemText)
        }
        
        self.toolExecutor.onTodoItemAdded = { [weak self] itemText in
            guard let self = self else { return }
            // Sync with plan state
            self.addPlanItem(content: itemText)
        }
        
        self.toolExecutor.onTodoListUpdated = { [weak self] list in
            guard let self = self else { return }
            self.syncPlanProgressFromTodoList(list)
        }
    }
    
    // MARK: - Public Methods
    
    /// Run the agent loop
    func run() async throws -> AgentResult {
        statePublisher.status = .running
        statePublisher.logInfo("Starting agent for task: \(task.title)")
        statePublisher.logInfo("Timeout: \(timeoutMinutes) min, Max iterations: \(maxSteps)")
        
        // Add MCP tools from already-connected servers (connected at app startup)
        await addMCPTools()
        
        // Start timeout timer
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(self?.timeoutMinutes ?? 30) * 60 * 1_000_000_000)
                await MainActor.run {
                    self?.isTimedOut = true
                }
            } catch {
                // Task was cancelled, ignore
            }
        }
        
        defer {
            // Cancel timeout task when we're done
            timeoutTask?.cancel()
        }
        
        // Log session start
        try await tracer.logSessionStart(
            taskId: task.id,
            taskDescription: task.taskDescription,
            model: llmClient.configuration.model,
            vmId: vmId
        )
        
        // Take initial screenshot to get screen dimensions
        let initialScreenshot = try await connection.screenshot()
        let screenWidth = initialScreenshot.width
        let screenHeight = initialScreenshot.height
        
        statePublisher.logInfo("Screen dimensions: \(screenWidth)x\(screenHeight)")
        
        // Log matched skills
        if !matchedSkills.isEmpty {
            statePublisher.logInfo("Matched \(matchedSkills.count) skill(s): \(matchedSkills.map { $0.name }.joined(separator: ", "))")
        }
        
        // Initialize conversation with system prompt including screen dimensions, input files, skills, and plan
        let systemPrompt = AgentPrompts.systemPrompt(
            task: task.taskDescription,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            inputFiles: inputFileNames,
            skills: matchedSkills,
            plan: task.planMarkdown,
            approvedContextBlocks: task.retrievalInlineContextBlocks,
            supportsVision: supportsVision
        )
        conversationHistory = [.system(systemPrompt)]
        
        // Initialize plan state if task has a plan
        if let planMarkdown = task.planMarkdown {
            initializePlanState(from: planMarkdown)
        }
        
        // Store initial screenshot for the first observation
        self.initialScreenshot = initialScreenshot
        
        var result: AgentResult
        
        do {
            result = try await runLoop()
        } catch {
            statePublisher.status = .failed
            statePublisher.logError(error.localizedDescription)
            
            try await tracer.logSessionEnd(status: "failed", summary: error.localizedDescription)
            
            let tokenUsage = await tracer.getTokenUsage()
            result = AgentResult(
                success: false,
                summary: nil,
                errorMessage: error.localizedDescription,
                stepCount: stepCount,
                promptTokens: tokenUsage.prompt,
                completionTokens: tokenUsage.completion,
                terminationReason: .failed
            )
        }
        
        // Save todo lists to session trace
        await saveTodoListsToTrace()
        
        // Cancel any lingering subagents
        Task { [subagentManager] in
            await subagentManager.cancelAll()
        }
        
        return result
    }
    
    /// Save todo list to the session trace for later review
    private func saveTodoListsToTrace() async {
        do {
            if let todoList = todoManager.getList() {
                let jsonData = try todoManager.toJSON()
                if let jsonString = String(data: jsonData, encoding: .utf8) {
                    try await tracer.logCustomEvent(
                        metadata: [
                            "event_type": "todo_list",
                            "message": "Agent created todo list: \(todoList.title)",
                            "list": jsonString
                        ]
                    )
                }
            }
        } catch {
            statePublisher.logError("Failed to save todo list to trace: \(error.localizedDescription)")
        }
        
        // Also save plan state if it exists
        await savePlanState()
    }
    
    // MARK: - Plan State Management
    
    /// Initialize plan state from the task's plan markdown
    /// Also populates the TodoManager so the agent can use finish_todo_item tool
    private func initializePlanState(from planMarkdown: String) {
        let items = PlanParser.parseTodos(from: planMarkdown)
        planState = PlanState(items: items)
        statePublisher.planProgress = planState
        
        // Also create a todo list from the plan items so the agent can use todo tools
        if !items.isEmpty {
            let itemTexts = items.map { $0.content }
            _ = todoManager.createList(title: "Execution Plan", items: itemTexts)
            statePublisher.logInfo("Plan loaded with \(items.count) todo item(s) - todo list created")
        } else {
            statePublisher.logInfo("Plan loaded (no todo items found)")
        }
    }
    
    /// Mark a plan item as completed
    func completePlanItem(content: String) {
        guard var state = planState else { return }
        
        if let index = state.items.firstIndex(where: { $0.content == content }) {
            state.items[index].isCompleted = true
            state.items[index].completedAt = Date()
            planState = state
            statePublisher.planProgress = state
            
            statePublisher.logInfo("Plan item completed: \(content.prefix(50))...")
        }
    }
    
    /// Add a new item to the plan during execution
    func addPlanItem(content: String) {
        guard var state = planState else { return }
        
        let item = state.addItem(content: content)
        planState = state
        statePublisher.planProgress = state
        
        statePublisher.logInfo("Plan item added: \(item.content.prefix(50))...")
    }
    
    /// Record a deviation from the plan
    func recordPlanDeviation(description: String, reasoning: String) {
        guard var state = planState else { return }
        
        state.recordDeviation(description: description, reasoning: reasoning)
        planState = state
        statePublisher.planProgress = state
        
        statePublisher.logInfo("Plan deviation: \(description.prefix(50))...")
    }
    
    /// Sync plan progress from todo list when no plan markdown exists
    private func syncPlanProgressFromTodoList(_ list: TodoList) {
        guard task.planMarkdown == nil else { return }
        
        let items = list.items.map { item in
            PlanTodoItem(
                id: item.id,
                content: item.text,
                isCompleted: item.isCompleted,
                completedAt: item.completedAt,
                wasSkipped: false,
                deviationReason: nil,
                addedDuringExecution: true
            )
        }
        
        let state = PlanState(items: items)
        planState = state
        statePublisher.planProgress = state
    }
    
    /// Save plan state to the session directory
    private func savePlanState() async {
        guard let state = planState, let sessionId = task.sessionId else { return }
        
        do {
            let planStatePath = AppPaths.sessionPlanStatePath(id: sessionId)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: planStatePath)
            
            // Also save the original plan markdown
            if let planMarkdown = task.planMarkdown {
                let planPath = AppPaths.sessionPlanPath(id: sessionId)
                try planMarkdown.write(to: planPath, atomically: true, encoding: .utf8)
            }
        } catch {
            statePublisher.logError("Failed to save plan state: \(error.localizedDescription)")
        }
    }
    
    // MARK: - MCP Integration
    
    /// Logger for MCP debugging
    private static let mcpLogger = Logger(subsystem: "com.pattonium.Hivecrew", category: "MCP")
    
    /// Add MCP tools from enabled servers to the available tools list
    /// MCP servers are connected on-demand to avoid startup latency
    private func addMCPTools() async {
        Self.mcpLogger.info("Fetching MCP tools from connected servers...")
        
        await MCPServerManager.shared.connectAllEnabledIfNeeded()
        
        let mcpTools = await MCPServerManager.shared.getAllTools()
        
        if !mcpTools.isEmpty {
            statePublisher.logInfo("MCP: Added \(mcpTools.count) tool(s) from MCP servers")
            tools.append(contentsOf: mcpTools)
        }
        
        Self.mcpLogger.info("MCP tools fetch completed: \(mcpTools.count) tools")
    }
    
    /// Cancel the agent run
    func cancel() {
        isCancelled = true
        // Resume if paused so it can exit cleanly
        pauseContinuation?.resume(returning: nil)
        pauseContinuation = nil
        Task { [subagentManager] in
            await subagentManager.cancelAll()
        }
    }
    
    /// Pause the agent run
    func pause() {
        isPaused = true
        statePublisher.status = .paused
        statePublisher.logInfo("Agent paused by user")
        Task { [subagentManager] in
            await subagentManager.setPaused(true)
        }
    }
    
    /// Resume the agent run with optional instructions
    func resume(withInstructions instructions: String? = nil) {
        isPaused = false
        statePublisher.status = .running
        
        if let instructions = instructions, !instructions.isEmpty {
            statePublisher.logInfo("Agent resumed with instructions: \(instructions)")
        } else {
            statePublisher.logInfo("Agent resumed")
        }
        
        // Resume the continuation
        pauseContinuation?.resume(returning: instructions)
        pauseContinuation = nil
        Task { [subagentManager] in
            await subagentManager.setPaused(false)
        }
    }
    
    // MARK: - Private Methods
    
    /// Wait if paused, returns any resume instructions
    func waitIfPaused() async -> String? {
        guard isPaused else { return nil }
        
        return await withCheckedContinuation { continuation in
            self.pauseContinuation = continuation
        }
    }
}

/// Errors from the agent runner
enum AgentRunnerError: Error, LocalizedError {
    case taskFailed(String)
    case connectionFailed(String)
    case cancelled
    
    var errorDescription: String? {
        switch self {
        case .taskFailed(let reason):
            return "Task failed: \(reason)"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .cancelled:
            return "Agent was cancelled"
        }
    }
}
