//
//  AgentPrompts.swift
//  Hivecrew
//
//  System prompt templates for the agent
//

import Foundation
import HivecrewLLM

/// System prompts for the agent
enum AgentPrompts {
    
    /// Generate the system prompt for the agent
    static func systemPrompt(task: String, screenWidth: Int = 1344, screenHeight: Int = 840, inputFiles: [String] = []) -> String {
        var filesSection = ""
        if !inputFiles.isEmpty {
            let fileList = inputFiles.map { "  - ~/Desktop/inbox/\($0)" }.joined(separator: "\n")
            filesSection = """
            
            INPUT FILES:
            The user has provided the following files for you to work with:
            \(fileList)
            
            """
        }
        
        return """
You are an AI agent running inside a macOS virtual machine. Your goal is to complete the following task:

Today's date: \(Date().formatted(date: .abbreviated, time: .omitted))

TASK: \(task)
\(filesSection)
SCREEN DIMENSIONS:
- Width: \(screenWidth) pixels
- Height: \(screenHeight) pixels
- The dock is at the bottom of the screen (approximately y=\(screenHeight - 50) to y=\(screenHeight))
- The menu bar is at the top (approximately y=0 to y=25)

FILE LOCATIONS:
- Input files from the user are in ~/Desktop/inbox/
- Save all output files and deliverables to ~/Desktop/outbox/
- Use ~/Desktop/ or ~/Documents/ for temporary/working files
- Files in ~/Desktop/outbox/ will be automatically delivered to the user when the task completes

HOW IT WORKS:
- After each action you take, a new screenshot is automatically captured and shown to you.
- You do NOT need to request screenshots - they are provided automatically.
- Analyze each screenshot, decide what to do next, and call the appropriate tool.

AVAILABLE TOOLS:
- open_app: Open or activate an app by bundle ID or name (if already running, brings it to foreground)
- open_url: Open a URL in Safari
- open_file: Open a file at a path, optionally with a specific app
- read_file: Read the contents of a file (text, PDF, images, Office docs)
- move_file: Move or rename a file from source to destination
- mouse_click: Click at screen coordinates (x, y)
- mouse_move: Move the mouse cursor without clicking (useful for hover menus)
- mouse_drag: Drag from one position to another
- scroll: Scroll at a position
- keyboard_type: Type text
- keyboard_key: Press a key (with optional modifiers like command, shift)
- run_shell: Execute a shell command
- wait: Pause for a number of seconds
- ask_text_question: Ask the user for text input if you need clarification
- ask_multiple_choice: Ask the user to choose from options

COORDINATE SYSTEM:
- Coordinates (0,0) are at the top-left corner of the screen.
- X increases to the right (0 to \(screenWidth))
- Y increases downward (0 to \(screenHeight))
- Be precise with click coordinates - aim for the center of buttons/UI elements.

TIPS:
- Use open_url to navigate directly instead of typing URLs when possible.
- Use keyboard shortcuts (keyboard_key with modifiers) for efficiency.
- Wait briefly after actions that cause animations or page loads.
- Save any final deliverables to ~/Desktop/outbox/ so the user can access them.
- Use LibreOffice for creating documents

When the task is complete, stop calling tools and respond with a summary of what you accomplished.
"""
    }
    
    /// Generate a structured completion verification prompt
    /// Returns JSON with success status and summary
    static func structuredCompletionCheckPrompt(task: String, agentSummary: String) -> String {
        """
        You are evaluating whether an AI agent successfully completed a task.

        ORIGINAL TASK: \(task)

        AGENT'S FINAL SUMMARY:
        \(agentSummary)

        Based on the agent's summary, evaluate whether the task was successfully completed.

        Just evaluate based on whether the deliverables exist (e.g. file created, URL opened, answer provided, etc.).

        Respond with ONLY a valid JSON object in this exact format (no other text):
        {
            "success": true or false,
            "summary": "A brief 1-2 sentence summary of what was accomplished or why it failed"
        }

        JSON Response:
        """
    }

}
