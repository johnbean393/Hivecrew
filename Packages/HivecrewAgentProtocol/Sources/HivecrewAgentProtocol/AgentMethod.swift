//
//  AgentMethod.swift
//  HivecrewAgentProtocol
//

import Foundation

/// All available tool methods for the CUA (Computer Use Agent)
public enum AgentMethod: String, CaseIterable, Sendable {
    case screenshot = "screenshot"
    case healthCheck = "health_check"
    case traverseAccessibilityTree = "traverse_accessibility_tree"
    case openApp = "open_app"
    case openFile = "open_file"
    case openUrl = "open_url"
    case mouseMove = "mouse_move"
    case mouseClick = "mouse_click"
    case mouseDrag = "mouse_drag"
    case keyboardType = "keyboard_type"
    case keyboardKey = "keyboard_key"
    case scroll = "scroll"
    case runShell = "run_shell"
    case readFile = "read_file"
    case moveFile = "move_file"
    case wait = "wait"
    case askTextQuestion = "ask_text_question"
    case askMultipleChoice = "ask_multiple_choice"
    case requestUserIntervention = "request_user_intervention"
    case getLoginCredentials = "get_login_credentials"
    case webSearch = "web_search"
    case readWebpageContent = "read_webpage_content"
    case extractInfoFromWebpage = "extract_info_from_webpage"
    case getLocation = "get_location"
    case createTodoList = "create_todo_list"
    case addTodoItem = "add_todo_item"
    case finishTodoItem = "finish_todo_item"
    case generateImage = "generate_image"
    case spawnSubagent = "spawn_subagent"
    case getSubagentStatus = "get_subagent_status"
    case awaitSubagents = "await_subagents"
    case cancelSubagent = "cancel_subagent"
    case listSubagents = "list_subagents"
    case sendMessage = "send_message"

    public var isHostSideTool: Bool {
        switch self {
        case .webSearch, .readWebpageContent, .extractInfoFromWebpage,
             .getLocation, .createTodoList, .addTodoItem, .finishTodoItem,
             .askTextQuestion, .askMultipleChoice, .requestUserIntervention,
             .getLoginCredentials, .generateImage,
             .spawnSubagent, .getSubagentStatus, .awaitSubagents, .cancelSubagent, .listSubagents,
             .sendMessage:
            return true
        default:
            return false
        }
    }

    public var isVisionDependentTool: Bool {
        switch self {
        case .screenshot,
             .traverseAccessibilityTree,
             .openApp, .openFile, .openUrl,
             .mouseMove, .mouseClick, .mouseDrag,
             .keyboardType, .keyboardKey, .scroll:
            return true
        default:
            return false
        }
    }

    public var isInternalTool: Bool {
        switch self {
        case .screenshot, .healthCheck:
            return true
        default:
            return false
        }
    }
}
