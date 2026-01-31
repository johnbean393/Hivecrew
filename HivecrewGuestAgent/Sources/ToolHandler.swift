//
//  ToolHandler.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import HivecrewAgentProtocol

/// Handles incoming JSON-RPC tool requests and dispatches to the appropriate tool implementation
final class ToolHandler {
    private let logger = AgentLogger.shared
    
    // Tool implementations
    private let screenshotTool = ScreenshotTool()
    private let healthCheckTool = HealthCheckTool()
    private let inputTool = InputTool()
    private let appTool = AppTool()
    private let fileTool = FileTool()
    private let accessibilityTool = AccessibilityTool()
    
    /// Handle an incoming JSON-RPC request and return a response
    func handleRequest(_ request: AgentRequest) -> AgentResponse {
        logger.log("Handling request: \(request.method) (id: \(request.id))")
        
        guard let method = AgentMethod(rawValue: request.method) else {
            logger.warning("Unknown method: \(request.method)")
            return AgentResponse.failure(
                id: request.id,
                code: AgentError.methodNotFound,
                message: "Unknown method: \(request.method)"
            )
        }
        
        do {
            let result = try executeMethod(method, params: request.params)
            logger.log("Request \(request.id) completed successfully")
            return AgentResponse.success(id: request.id, result: result)
        } catch let error as AgentError {
            logger.error("Request \(request.id) failed: \(error.message)")
            return AgentResponse(id: request.id, error: error)
        } catch {
            logger.error("Request \(request.id) failed: \(error.localizedDescription)")
            return AgentResponse.failure(
                id: request.id,
                code: AgentError.toolExecutionFailed,
                message: error.localizedDescription
            )
        }
    }
    
    private func executeMethod(_ method: AgentMethod, params: [String: AnyCodable]?) throws -> Any {
        switch method {
        // Observation tools (internal, not exposed to LLM)
        case .screenshot:
            return try screenshotTool.executeSync()
            
        case .healthCheck:
            return try healthCheckTool.execute()
            
        case .traverseAccessibilityTree:
            let pid = params?["pid"]?.intValue.map { Int32($0) }
            let onlyVisibleElements = params?["onlyVisibleElements"]?.boolValue ?? true
            return try accessibilityTool.traverseAccessibilityTree(pid: pid, onlyVisibleElements: onlyVisibleElements)
            
        // App tools
        case .openApp:
            let bundleId = params?["bundleId"]?.stringValue
            let appName = params?["appName"]?.stringValue
            try appTool.openApp(bundleId: bundleId, appName: appName)
            return ["success": true]
            
        case .openFile:
            guard let path = params?["path"]?.stringValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'path' parameter")
            }
            let withApp = params?["withApp"]?.stringValue
            try appTool.openFile(path: path, withApp: withApp)
            return ["success": true]
            
        case .openUrl:
            guard let urlString = params?["url"]?.stringValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'url' parameter")
            }
            try appTool.openUrl(urlString)
            return ["success": true]
            
        // Input tools
        case .mouseMove:
            guard let x = params?["x"]?.doubleValue,
                  let y = params?["y"]?.doubleValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'x' or 'y' parameter")
            }
            try inputTool.mouseMove(x: x, y: y)
            return ["success": true]
            
        case .mouseClick:
            guard let x = params?["x"]?.doubleValue,
                  let y = params?["y"]?.doubleValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'x' or 'y' parameter")
            }
            let button = params?["button"]?.stringValue.flatMap { MouseButton(rawValue: $0) } ?? .left
            let clickType = params?["clickType"]?.stringValue.flatMap { ClickType(rawValue: $0) } ?? .single
            try inputTool.mouseClick(x: x, y: y, button: button, clickType: clickType)
            return ["success": true]
            
        case .mouseDrag:
            guard let fromX = params?["fromX"]?.doubleValue,
                  let fromY = params?["fromY"]?.doubleValue,
                  let toX = params?["toX"]?.doubleValue,
                  let toY = params?["toY"]?.doubleValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing drag coordinates")
            }
            try inputTool.mouseDrag(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
            return ["success": true]
            
        case .keyboardType:
            guard let text = params?["text"]?.stringValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'text' parameter")
            }
            try inputTool.keyboardType(text: text)
            return ["success": true]
            
        case .keyboardKey:
            guard let key = params?["key"]?.stringValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'key' parameter")
            }
            var modifiers: [KeyModifier] = []
            if let modArray = params?["modifiers"]?.arrayValue as? [String] {
                modifiers = modArray.compactMap { KeyModifier(rawValue: $0) }
            }
            try inputTool.keyboardKey(key: key, modifiers: modifiers)
            return ["success": true]
            
        case .scroll:
            guard let x = params?["x"]?.doubleValue,
                  let y = params?["y"]?.doubleValue,
                  let deltaX = params?["deltaX"]?.doubleValue,
                  let deltaY = params?["deltaY"]?.doubleValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing scroll parameters")
            }
            try inputTool.scroll(x: x, y: y, deltaX: deltaX, deltaY: deltaY)
            return ["success": true]
            
        // File tools
        case .runShell:
            guard let command = params?["command"]?.stringValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'command' parameter")
            }
            let timeout = params?["timeout"]?.doubleValue
            return try fileTool.runShell(command: command, timeout: timeout)
            
        case .readFile:
            guard let path = params?["path"]?.stringValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'path' parameter")
            }
            return try fileTool.readFile(path: path)
            
        case .moveFile:
            guard let source = params?["source"]?.stringValue,
                  let destination = params?["destination"]?.stringValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'source' or 'destination' parameter")
            }
            try fileTool.moveFile(source: source, destination: destination)
            return ["success": true]
            
        // System tools
        case .wait:
            guard let seconds = params?["seconds"]?.doubleValue else {
                throw AgentError(code: AgentError.invalidParams, message: "Missing 'seconds' parameter")
            }
            Thread.sleep(forTimeInterval: seconds)
            return ["success": true]
            
        // Host-side tools - these should never reach the guest agent
        case .askTextQuestion, .askMultipleChoice, .requestUserIntervention,
             .getLoginCredentials,
             .webSearch, .readWebpageContent, .extractInfoFromWebpage, .getLocation,
             .createTodoList, .addTodoItem, .finishTodoItem,
             .generateImage:
            throw AgentError(code: AgentError.toolExecutionFailed, message: "This tool runs on the host, not in the guest VM")
        }
    }
}
