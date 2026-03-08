//
//  ToolSchemaBuilder+ManagementMethods.swift
//  HivecrewLLM
//
//  Tool schema definitions for management, auth, and subagent methods
//

import Foundation
import HivecrewAgentProtocol

extension ToolSchemaBuilder {
    func getManagementSchemaInfo(for method: AgentMethod) -> (description: String, parameters: [String: Any])? {
        switch method {
        case .createTodoList:
            return (
                "Create a todo list to organize and track subtasks. This helps break down complex tasks into manageable steps. Only one todo list exists per agent session.",
                objectSchema(
                    properties: [
                        "title": stringProperty("A descriptive title for the todo list"),
                        "items": arrayProperty("Optional: Initial list of todo items to add", itemType: ["type": "string"])
                    ],
                    required: ["title"]
                )
            )

        case .addTodoItem:
            return (
                "Add a new item to your todo list. The item will be added to the end of the list and assigned the next available number.",
                objectSchema(
                    properties: [
                        "item": stringProperty("The todo item description")
                    ],
                    required: ["item"]
                )
            )

        case .finishTodoItem:
            return (
                "Mark a todo item as completed by its number. Use the item number shown in the todo list (e.g., 1, 2, 3).",
                objectSchema(
                    properties: [
                        "index": numberProperty("The item number to mark as finished (1-based)")
                    ],
                    required: ["index"]
                )
            )

        case .requestUserIntervention:
            return (
                "Request user intervention when you need the user to perform a manual action like signing in, completing 2FA, or solving a CAPTCHA. The agent will pause until the user confirms completion.",
                objectSchema(
                    properties: [
                        "message": stringProperty("A message describing what action the user should take"),
                        "service": stringProperty("Optional: The name of the service (e.g., 'GitHub', 'Gmail')")
                    ],
                    required: ["message"]
                )
            )

        case .getLoginCredentials:
            return (
                "Get stored login credentials for authentication. Returns UUID tokens that can be used with keyboard_type to enter usernames and passwords securely. The real credentials are never exposed - only tokens that are substituted at typing time.",
                objectSchema(
                    properties: [
                        "service": stringProperty("Optional: Filter by service name (e.g., 'GitHub', 'Gmail'). If omitted, returns all available credentials.")
                    ],
                    required: []
                )
            )

        case .generateImage:
            return (
                "Generate or edit an image using AI. Provide a text prompt describing the desired output. For image editing, provide reference images via referenceImagePaths (or reference_image_paths). PNG, JPEG, and JPG inputs are supported. The FIRST image is the main image and is kept at full quality, while subsequent images are automatically compressed to 1/4 size (dimensions halved) to avoid payload size limits. You can provide up to 14 reference images. The generated image will be saved to the images inbox folder.",
                objectSchema(
                    properties: [
                        "prompt": stringProperty("Detailed description of the image to generate or how to edit the reference image(s). Be specific about style, composition, colors, and subject matter."),
                        "referenceImagePaths": arrayProperty(
                            "Paths to reference images for editing or style guidance. PNG, JPEG, and JPG files are supported. The FIRST image is treated as the main image (full quality), subsequent images are compressed. Paths can be relative to shared folder or absolute.",
                            itemType: ["type": "string"]
                        ),
                        "reference_image_paths": arrayProperty(
                            "Snake_case alias of referenceImagePaths.",
                            itemType: ["type": "string"]
                        ),
                        "aspectRatio": enumProperty(
                            "Aspect ratio for the generated image. Defaults to 1:1 if not specified.",
                            ["1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9"]
                        ),
                        "aspect_ratio": enumProperty(
                            "Snake_case alias of aspectRatio.",
                            ["1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9"]
                        )
                    ],
                    required: ["prompt"]
                )
            )

        case .spawnSubagent:
            return (
                "Spawn a background subagent to work asynchronously on a subtask. Use this for parallelizable work (research, asset generation, verification, or independent slide/content preparation) and long-running shell checks. For example, when creating a deck, delegate slide content or image generation to multiple subagents in parallel instead of doing them sequentially. If the subagent needs to write files (outbox paths, explicit filenames, or extensions), use the mixed domain so run_shell/read_file are available. For research: avoid listing models or facts from memory. Instruct the subagent to discover from sources and cite URLs. Use today's date for any 'latest' or 'current' requests; avoid hardcoding past dates unless explicitly required.",
                objectSchema(
                    properties: [
                        "goal": stringProperty("A clear, specific goal for the subagent to accomplish."),
                        "domain": enumProperty("Where the subagent operates", ["host", "vm", "mixed"]),
                        "toolAllowlist": arrayProperty(
                            "Optional list of allowed tools for this subagent. If omitted, defaults are chosen based on domain.",
                            itemType: ["type": "string"]
                        ),
                        "todoItems": arrayProperty(
                            "Prescribed todo list for the subagent to complete (3-7 concise items). This list must be provided by the main agent; subagents must not create or modify it.",
                            itemType: ["type": "string"]
                        ),
                        "timeoutSeconds": numberProperty("Optional timeout in seconds for the subagent."),
                        "modelOverride": stringProperty("Optional model ID to use instead of the default worker model."),
                        "purpose": stringProperty("Optional short label for UI and trace display.")
                    ],
                    required: ["goal", "domain", "todoItems"]
                )
            )

        case .getSubagentStatus:
            return (
                "Get the current status of a subagent by ID.",
                objectSchema(
                    properties: [
                        "subagentId": stringProperty("The subagent ID to query.")
                    ],
                    required: ["subagentId"]
                )
            )

        case .awaitSubagents:
            return (
                "Wait for multiple subagents to finish and return their final summaries.",
                objectSchema(
                    properties: [
                        "subagentIds": arrayProperty("The subagent IDs to wait for.", itemType: ["type": "string"]),
                        "timeoutSeconds": numberProperty("Optional timeout in seconds.")
                    ],
                    required: ["subagentIds"]
                )
            )

        case .cancelSubagent:
            return (
                "Cancel a running subagent.",
                objectSchema(
                    properties: [
                        "subagentId": stringProperty("The subagent ID to cancel.")
                    ],
                    required: ["subagentId"]
                )
            )

        case .listSubagents:
            return (
                "List all subagents associated with the current task.",
                emptyObjectSchema()
            )

        case .sendMessage:
            return (
                "Send a message to another agent (main agent or subagent). Messages are delivered automatically into the recipient's context before their next LLM call. Use this to share findings, send instructions, or coordinate with other agents.",
                objectSchema(
                    properties: [
                        "to": stringProperty("Recipient: 'main' for the root agent, a subagent ID, or 'broadcast' for all agents."),
                        "subject": stringProperty("Brief subject line for the message."),
                        "body": stringProperty("Message content — findings, instructions, questions, or data to share.")
                    ],
                    required: ["to", "subject", "body"]
                )
            )

        default:
            return nil
        }
    }
}
