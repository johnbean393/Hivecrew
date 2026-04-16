//
//  SharedToolDeclarations.swift
//  HivecrewCore
//
//  JSON-schema-style tool definitions for voice orchestration (name, description,
//  parameters). Mirrors the former OrchestratorToolHandler.toolDeclarations content.
//

import Foundation

public enum SharedToolDeclarations {
    /// Tool schemas are generated on demand so descriptions can stay in sync with runtime prompt flags.
    /// Marked unsafe because `Any` is not `Sendable` (Swift 6 strict concurrency).
    public nonisolated(unsafe) static var declarations: [[String: Any]] { [
        tool(
            name: "create_task",
            description: "Create a new task for a worker agent. Each worker runs in a full macOS VM and can search the web, write files, run shell commands, and use GUI apps — so include the complete goal in one task rather than splitting simple multi-step work across workers. Returns the task ID and assigned worker name. To attach a captured reference image, pass its file path in the attachments array.",
            properties: [
                "description": stringProperty(description: "The full end-to-end goal for the worker, including all steps (e.g. research + write file)"),
                "attachments": stringProperty(description: "Comma-separated file paths to attach (e.g. from capture_reference)"),
                "plan_first": stringProperty(description: "If 'true', the worker will create a plan for review before executing. Use when the user explicitly asks to plan first or review a plan before work begins."),
            ],
            required: ["description"]
        ),
        tool(
            name: "get_task_status",
            description: "Get the current status of a task by worker name or task ID.",
            properties: [
                "query": stringProperty(description: "Worker name, role, or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "send_instruction",
            description: "Send a follow-up instruction or answer to a worker's question.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
                "message": stringProperty(description: "The instruction or answer"),
            ],
            required: ["query", "message"]
        ),
        tool(
            name: "pause_task",
            description: "Pause a running task.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "resume_task",
            description: "Resume a paused task.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "cancel_task",
            description: "Cancel a task.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "capture_reference",
            description: "Capture the current video frame as a reference image for task creation.",
            properties: [String: [String: Any]]()
        ),
        tool(
            name: "get_deliverables",
            description: "List output files from a completed task.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "focus_task",
            description: "Focus the UI task pane on a specific task.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "approve_plan",
            description: "Approve a worker's plan and begin execution. Use after reviewing the plan with the user and getting their approval.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "reject_plan",
            description: "Reject a worker's plan and cancel the planning task. Use when the user does not want to proceed with the plan.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "approve_writeback",
            description: "Approve pending file changes from a worker and write them to disk.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "discard_writeback",
            description: "Discard pending file changes from a worker without writing them to disk.",
            properties: [
                "query": stringProperty(description: "Worker name or task ID"),
            ],
            required: ["query"]
        ),
        tool(
            name: "end_call",
            description: endCallDescription,
            properties: [String: [String: Any]]()
        ),
        tool(
            name: "search_files",
            description: "Search the user's indexed files and folders by natural language description. Returns matching paths with relevance scores. Use when the user mentions files, codebases, documents, or assets to attach. Call multiple times in parallel for different things to find. Pass the resulting paths to create_task via the attachments parameter.",
            properties: [
                "query": stringProperty(description: "Natural language description of the files to find"),
                "source_filter": stringProperty(description: "Optional filter: 'file', 'email', 'message', 'calendar'"),
            ],
            required: ["query"]
        ),
        tool(
            name: "read_file",
            description: "Read the contents of a file on the host machine. Works with text, code, PDF, docx, xlsx, pptx, RTF, plist, and images. For image files, the image is loaded into your visual context so you can see and describe it. Use for reading deliverables or attached files.",
            properties: [
                "path": stringProperty(description: "Absolute path to the file"),
            ],
            required: ["path"]
        ),
        tool(
            name: "search_file_content",
            description: "Search within a file for content matching a query. Returns only matching sections with context. Faster than read_file for large files when you need specific information.",
            properties: [
                "path": stringProperty(description: "Absolute path to the file"),
                "query": stringProperty(description: "Text to search for within the file"),
            ],
            required: ["path", "query"]
        ),
        tool(
            name: "open_file",
            description: "Open a file or folder on the user's Mac using the default application, or reveal it in Finder.",
            properties: [
                "path": stringProperty(description: "Absolute path to the file or folder"),
                "reveal": stringProperty(description: "If 'true', reveal in Finder instead of opening. Default: false"),
            ],
            required: ["path"]
        ),
    ] }

    private static var endCallDescription: String {
        if OrchestratorSystemPrompt.allowEndCallWithActiveTasks {
            return "End the current voice call. Can be used even if tasks are still running; they will continue in the background and the user will be notified when they finish."
        }
        return "End the current voice call. Will only succeed when there are no active or queued tasks remaining."
    }
}

private func stringProperty(description: String) -> [String: Any] {
    ["type": "string", "description": description]
}

private func tool(
    name: String,
    description: String,
    properties: [String: [String: Any]],
    required: [String]? = nil
) -> [String: Any] {
    var parameters: [String: Any] = [
        "type": "object",
        "properties": properties,
    ]
    if let required {
        parameters["required"] = required
    }
    return [
        "name": name,
        "description": description,
        "parameters": parameters,
    ]
}
