//
//  PlanningStatePublisher.swift
//  Hivecrew
//
//  Observable state publisher for streaming plan generation UI updates
//

import Foundation
import Combine

/// Observable state for plan generation UI updates
@MainActor
public class PlanningStatePublisher: ObservableObject {
    
    // MARK: - Published Properties
    
    /// The streaming plan text as it's being generated
    @Published public var streamingPlanText: String = ""
    
    /// Streaming reasoning/thinking text from the LLM
    @Published public var streamingReasoningText: String = ""
    
    /// Whether plan generation is currently in progress
    @Published public var isGenerating: Bool = false
    
    /// Current tool call being executed (e.g., "Reading report.pdf...")
    @Published public var currentToolCall: String?
    
    /// List of files that have been read by the planning agent
    @Published public var readFiles: [String] = []
    
    /// Error that occurred during planning (if any)
    @Published public var error: Error?
    
    /// Selected skills for the task
    @Published public var selectedSkills: [String] = []
    
    /// Whether generation completed successfully
    @Published public var isComplete: Bool = false
    
    /// Current status message for the user
    @Published public var statusMessage: String = "Initializing..."
    
    // MARK: - Initialization
    
    public init() {}
    
    // MARK: - Public Methods
    
    /// Start the generation process
    public func startGeneration() {
        isGenerating = true
        isComplete = false
        error = nil
        streamingPlanText = ""
        streamingReasoningText = ""
        readFiles = []
        currentToolCall = nil
        statusMessage = "Starting plan generation..."
    }
    
    /// Append text to the streaming plan
    public func appendText(_ text: String) {
        streamingPlanText += text
    }
    
    /// Set the entire plan text (replaces existing)
    public func setPlanText(_ text: String) {
        streamingPlanText = text
    }
    
    /// Set the streaming reasoning text (LLM thinking)
    public func setReasoningText(_ text: String) {
        streamingReasoningText = text
    }
    
    /// Set the status message
    public func setStatus(_ message: String) {
        statusMessage = message
    }
    
    /// Set the current tool call status
    public func setToolCall(_ name: String?, details: String? = nil) {
        if let name = name {
            if let details = details {
                currentToolCall = "\(name): \(details)"
            } else {
                currentToolCall = name
            }
        } else {
            currentToolCall = nil
        }
    }
    
    /// Mark a file as having been read
    public func markFileRead(_ filename: String) {
        if !readFiles.contains(filename) {
            readFiles.append(filename)
        }
    }
    
    /// Set the selected skills
    public func setSelectedSkills(_ skills: [String]) {
        selectedSkills = skills
    }
    
    /// Mark generation as complete
    public func completeGeneration() {
        isGenerating = false
        isComplete = true
        currentToolCall = nil
    }
    
    /// Mark generation as failed with an error
    public func failGeneration(with error: Error) {
        self.error = error
        isGenerating = false
        isComplete = false
        currentToolCall = nil
    }
    
    /// Cancel the generation
    public func cancelGeneration() {
        isGenerating = false
        isComplete = false
        currentToolCall = nil
    }
}
