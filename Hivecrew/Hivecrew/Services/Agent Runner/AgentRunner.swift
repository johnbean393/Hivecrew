//
//  AgentRunner.swift
//  Hivecrew
//
//  Core agent loop implementation (observe -> decide -> execute)
//

import Foundation
import AppKit
import Virtualization
import HivecrewLLM
import HivecrewShared

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
    
    /// Tools available to the agent
    let tools: [LLMToolDefinition]
    
    /// Input file names available in the inbox
    private let inputFileNames: [String]
    
    /// Task for timeout monitoring
    private var timeoutTask: Task<Void, Never>?
    
    /// Continuation for waiting when paused
    private var pauseContinuation: CheckedContinuation<String?, Never>?
    
    /// Number of times the agent has attempted to complete but verification failed
    var completionAttempts: Int = 0
    
    /// Maximum number of completion verification retries before giving up
    let maxCompletionAttempts: Int = 3
    
    /// Maximum number of retries for LLM calls
    let maxLLMRetries = 3
    
    /// Base delay for exponential backoff (in seconds)
    let baseRetryDelay: Double = 2.0
    
    // MARK: - Initialization
    
    init(
        task: TaskRecord,
        vmId: String,
        llmClient: any LLMClientProtocol,
        connection: GuestAgentConnection,
        sessionPath: URL,
        statePublisher: AgentStatePublisher,
        inputFileNames: [String] = [],
        maxSteps: Int = 100,
        timeoutMinutes: Int = 30
    ) throws {
        self.task = task
        self.vmId = vmId
        self.llmClient = llmClient
        self.connection = connection
        self.statePublisher = statePublisher
        self.inputFileNames = inputFileNames
        self.maxSteps = maxSteps
        self.timeoutMinutes = timeoutMinutes
        
        // Create screenshots directory
        self.screenshotsPath = sessionPath.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: screenshotsPath, withIntermediateDirectories: true)
        
        // Create tracer
        self.tracer = try AgentTracer(sessionId: statePublisher.sessionId ?? UUID().uuidString, outputDirectory: sessionPath)
        
        // Create tool executor
        self.toolExecutor = ToolExecutor(connection: connection)
        self.toolExecutor.taskId = task.id
        
        // Set up question callback to use statePublisher
        self.toolExecutor.onAskQuestion = { [weak statePublisher] question in
            guard let publisher = statePublisher else { return "No response available" }
            return await publisher.askQuestion(question)
        }
        
        // Set up permission callback for dangerous tools
        self.toolExecutor.onRequestPermission = { [weak statePublisher] toolName, details in
            guard let publisher = statePublisher else { return false }
            return await publisher.requestPermission(toolName: toolName, details: details)
        }
        
        // Build essential CUA tool definitions (includes user interaction tools)
        // Note: Screenshot is NOT a tool - we automatically capture after each action
        let schemaBuilder = ToolSchemaBuilder()
        self.tools = schemaBuilder.buildCUATools()
    }
    
    // MARK: - Public Methods
    
    /// Run the agent loop
    func run() async throws -> AgentResult {
        statePublisher.status = .running
        statePublisher.logInfo("Starting agent for task: \(task.title)")
        statePublisher.logInfo("Timeout: \(timeoutMinutes) min, Max iterations: \(maxSteps)")
        
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
        
        // Initialize conversation with system prompt including screen dimensions and input files
        let systemPrompt = AgentPrompts.systemPrompt(
            task: task.taskDescription,
            screenWidth: screenWidth,
            screenHeight: screenHeight,
            inputFiles: inputFileNames
        )
        conversationHistory = [.system(systemPrompt)]
        
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
        
        return result
    }
    
    /// Cancel the agent run
    func cancel() {
        isCancelled = true
        // Resume if paused so it can exit cleanly
        pauseContinuation?.resume(returning: nil)
        pauseContinuation = nil
    }
    
    /// Pause the agent run
    func pause() {
        isPaused = true
        statePublisher.status = .paused
        statePublisher.logInfo("Agent paused by user")
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
