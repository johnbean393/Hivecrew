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
                "Request user intervention only when you need the user to perform a manual action like signing in, completing 2FA, or solving a CAPTCHA. Do not use this for staged writeback approval, review, or verification; staged local changes are approved only after the run finishes.",
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

        case .listLocalEntries:
            return (
                "List the contents of a granted local file or folder on the host Mac. Use this for host paths such as Downloads/Desktop/Documents. Do not use VM directory tools for these host paths.",
                objectSchema(
                    properties: [
                        "path": stringProperty("Granted host path to inspect. This must be one of the granted files/folders or a child path inside a granted folder.")
                    ],
                    required: ["path"]
                )
            )

        case .importLocalFile:
            return (
                "Copy granted local content from the host Mac into the VM so you can edit it there. This supports a single file, a single directory, or many files at once. After importing, use VM tools like read_file, write_file, list_directory, and move_file on the VM copy.",
                objectSchema(
                    properties: [
                        "sourcePath": stringProperty("Single granted host file or directory path to import."),
                        "destinationPath": stringProperty("Destination path inside the VM for a single sourcePath import."),
                        "sourcePaths": arrayProperty(
                            "Multiple granted host file or directory paths to import in one call.",
                            itemType: ["type": "string"]
                        ),
                        "destinationDirectory": stringProperty("Destination directory inside the VM for a multi-source import. Imported entries keep their top-level names.")
                    ],
                    required: []
                )
            )

        case .stageWritebackCopy:
            return (
                "Stage copying VM content back to granted local filesystem destinations. This supports a single file or directory, or many VM files/directories at once. You may also provide original local paths that should be deleted after apply when reorganizing a local folder. It only stages the change for review; it does not write to the local filesystem immediately.",
                objectSchema(
                    properties: [
                        "sourcePath": stringProperty("Single source file or directory path inside the VM."),
                        "destinationPath": stringProperty("Granted local destination path for a single sourcePath stage."),
                        "sourcePaths": arrayProperty(
                            "Multiple source file or directory paths inside the VM to stage in one call.",
                            itemType: ["type": "string"]
                        ),
                        "destinationDirectory": stringProperty("Granted local destination folder for a multi-source stage. Each source keeps its top-level name."),
                        "deleteOriginalLocalPaths": arrayProperty(
                            "Optional granted host file or directory paths to remove after the staged writeback is successfully applied. Use this for reorganization tasks so the original local items do not remain behind.",
                            itemType: ["type": "string"]
                        )
                    ],
                    required: []
                )
            )

        case .stageWritebackMove:
            return (
                "Stage moving a file produced inside the VM back to a granted local filesystem destination. You may also provide original local paths that should be deleted after apply when reorganizing a local folder. This stages a handoff for user review; the destination is not touched until approval.",
                objectSchema(
                    properties: [
                        "sourcePath": stringProperty("Path to the source file inside the VM."),
                        "destinationPath": stringProperty("Granted local destination path that should receive the moved file."),
                        "deleteOriginalLocalPaths": arrayProperty(
                            "Optional granted host file or directory paths to remove after the staged writeback is successfully applied.",
                            itemType: ["type": "string"]
                        )
                    ],
                    required: ["sourcePath", "destinationPath"]
                )
            )

        case .stageAttachedFileUpdate:
            return (
                "Stage replacing an attached local file with an updated file from the VM. Use this after editing an attached file inside the VM and before final user review.",
                objectSchema(
                    properties: [
                        "sourcePath": stringProperty("Path to the updated source file inside the VM."),
                        "attachmentPath": stringProperty("Optional original attached file path to replace. Omit only when there is a single obvious attached file target.")
                    ],
                    required: ["sourcePath"]
                )
            )

        case .listWritebackTargets:
            return (
                "List the local filesystem destinations currently granted for staged writeback, including attached files that can be updated in place.",
                emptyObjectSchema()
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
