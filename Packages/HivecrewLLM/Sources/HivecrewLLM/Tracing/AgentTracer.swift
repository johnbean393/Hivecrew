//
//  AgentTracer.swift
//  HivecrewLLM
//
//  JSON-line logger for tracing agent execution
//

import Foundation

/// Logger for tracing agent execution to JSON-line files
///
/// The tracer writes each event as a single JSON line to a file,
/// enabling easy parsing and streaming analysis of agent sessions.
public actor AgentTracer {
    private let sessionId: String
    private let outputPath: URL
    private var currentStep: Int = 0
    private var fileHandle: FileHandle?
    private let encoder: JSONEncoder
    
    /// Token usage accumulator
    private var totalPromptTokens: Int = 0
    private var totalCompletionTokens: Int = 0
    
    /// Create a tracer for a new session
    ///
    /// - Parameters:
    ///   - sessionId: Unique identifier for this session
    ///   - outputDirectory: Directory to write the trace file to
    public init(sessionId: String, outputDirectory: URL) throws {
        self.sessionId = sessionId
        self.outputPath = outputDirectory.appendingPathComponent("trace.jsonl")
        
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.sortedKeys]
        
        // Create the output directory if needed
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        
        // Create and open the file
        FileManager.default.createFile(atPath: outputPath.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: outputPath)
    }
    
    deinit {
        try? fileHandle?.close()
    }
    
    /// Log a trace event
    public func log(_ event: TraceEvent) throws {
        let data = try encoder.encode(event)
        guard var jsonString = String(data: data, encoding: .utf8) else {
            return
        }
        jsonString += "\n"
        
        if let jsonData = jsonString.data(using: .utf8) {
            try fileHandle?.write(contentsOf: jsonData)
        }
    }
    
    /// Log session start
    public func logSessionStart(
        taskId: String,
        taskDescription: String,
        model: String,
        vmId: String?
    ) throws {
        let event = TraceEvent(
            sessionId: sessionId,
            type: .sessionStart,
            step: currentStep,
            data: .sessionStart(SessionStartData(
                taskId: taskId,
                taskDescription: taskDescription,
                model: model,
                vmId: vmId
            ))
        )
        try log(event)
    }
    
    /// Log session end
    public func logSessionEnd(
        status: String,
        estimatedCost: Double? = nil,
        summary: String? = nil
    ) throws {
        let event = TraceEvent(
            sessionId: sessionId,
            type: .sessionEnd,
            step: currentStep,
            data: .sessionEnd(SessionEndData(
                status: status,
                totalSteps: currentStep,
                totalTokens: totalPromptTokens + totalCompletionTokens,
                estimatedCost: estimatedCost,
                summary: summary
            ))
        )
        try log(event)
        try fileHandle?.synchronize()
    }
    
    /// Log an observation (screenshot, etc.)
    public func logObservation(
        observationType: String,
        screenshotPath: String? = nil,
        screenWidth: Int? = nil,
        screenHeight: Int? = nil,
        metadata: [String: String]? = nil
    ) throws {
        let event = TraceEvent(
            sessionId: sessionId,
            type: .observation,
            step: currentStep,
            data: .observation(ObservationData(
                observationType: observationType,
                screenshotPath: screenshotPath,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                metadata: metadata
            ))
        )
        try log(event)
    }
    
    /// Log an LLM request
    public func logLLMRequest(
        messageCount: Int,
        toolCount: Int,
        model: String,
        temperature: Double? = nil,
        maxTokens: Int? = nil
    ) throws {
        let event = TraceEvent(
            sessionId: sessionId,
            type: .llmRequest,
            step: currentStep,
            data: .llmRequest(LLMRequestData(
                messageCount: messageCount,
                toolCount: toolCount,
                model: model,
                temperature: temperature,
                maxTokens: maxTokens
            ))
        )
        try log(event)
    }
    
    /// Log an LLM response
    public func logLLMResponse(
        _ response: LLMResponse,
        latencyMs: Int
    ) throws {
        // Update token accumulators
        if let usage = response.usage {
            totalPromptTokens += usage.promptTokens
            totalCompletionTokens += usage.completionTokens
        }
        
        let toolCallCount = response.toolCalls?.count ?? 0
        
        // Truncate content for preview
        let contentPreview: String?
        if let text = response.text {
            contentPreview = String(text.prefix(500))
        } else {
            contentPreview = nil
        }
        
        // Store full response text only when there are no tool calls (pure text response)
        let responseText: String?
        if toolCallCount == 0 {
            responseText = response.text
        } else {
            responseText = nil
        }
        
        let event = TraceEvent(
            sessionId: sessionId,
            type: .llmResponse,
            step: currentStep,
            data: .llmResponse(LLMResponseData(
                responseId: response.id,
                model: response.model,
                finishReason: response.finishReason?.rawValue,
                toolCallCount: toolCallCount,
                promptTokens: response.usage?.promptTokens ?? 0,
                completionTokens: response.usage?.completionTokens ?? 0,
                totalTokens: response.usage?.totalTokens ?? 0,
                contentPreview: contentPreview,
                responseText: responseText,
                reasoning: response.reasoning
            )),
            durationMs: latencyMs
        )
        try log(event)
    }
    
    /// Log a tool call
    public func logToolCall(_ toolCall: LLMToolCall) throws {
        let event = TraceEvent(
            sessionId: sessionId,
            type: .toolCall,
            step: currentStep,
            data: .toolCall(ToolCallData(
                toolCallId: toolCall.id,
                toolName: toolCall.function.name,
                arguments: toolCall.function.arguments
            ))
        )
        try log(event)
    }
    
    /// Log a tool result
    public func logToolResult(
        toolCallId: String,
        toolName: String,
        success: Bool,
        result: String?,
        errorMessage: String? = nil,
        latencyMs: Int? = nil
    ) throws {
        // Truncate result for preview
        let resultPreview = result.map { String($0.prefix(1000)) }
        
        let event = TraceEvent(
            sessionId: sessionId,
            type: .toolResult,
            step: currentStep,
            data: .toolResult(ToolResultData(
                toolCallId: toolCallId,
                toolName: toolName,
                success: success,
                resultPreview: resultPreview,
                errorMessage: errorMessage
            )),
            durationMs: latencyMs
        )
        try log(event)
    }
    
    /// Log a user intervention
    public func logUserIntervention(
        type: String,
        message: String? = nil
    ) throws {
        let event = TraceEvent(
            sessionId: sessionId,
            type: .userIntervention,
            step: currentStep,
            data: .userIntervention(UserInterventionData(
                interventionType: type,
                message: message
            ))
        )
        try log(event)
    }
    
    /// Log an error
    public func logError(
        type: String,
        message: String,
        recoverable: Bool
    ) throws {
        let event = TraceEvent(
            sessionId: sessionId,
            type: .error,
            step: currentStep,
            data: .error(ErrorData(
                errorType: type,
                message: message,
                recoverable: recoverable
            ))
        )
        try log(event)
    }
    
    /// Log a custom event
    public func logCustomEvent(
        metadata: [String: String]
    ) throws {
        let event = TraceEvent(
            sessionId: sessionId,
            type: .custom,
            step: currentStep,
            data: .custom(metadata)
        )
        try log(event)
    }
    
    /// Advance to the next step
    public func nextStep() {
        currentStep += 1
    }
    
    /// Get the current step number
    public func getCurrentStep() -> Int {
        currentStep
    }
    
    /// Get accumulated token usage
    public func getTokenUsage() -> (prompt: Int, completion: Int, total: Int) {
        (totalPromptTokens, totalCompletionTokens, totalPromptTokens + totalCompletionTokens)
    }
    
    /// Flush any buffered data to disk
    public func flush() throws {
        try fileHandle?.synchronize()
    }
    
    /// Get the path to the trace file
    public func getOutputPath() -> URL {
        outputPath
    }
}

// MARK: - Static Helpers

extension AgentTracer {
    /// Parse a trace file and return all events
    public static func parseTraceFile(at path: URL) throws -> [TraceEvent] {
        let content = try String(contentsOf: path, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        return try lines.map { line in
            guard let data = line.data(using: .utf8) else {
                throw LLMError.decodingError(underlying: NSError(
                    domain: "AgentTracer",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 in trace line"]
                ))
            }
            return try decoder.decode(TraceEvent.self, from: data)
        }
    }
}
