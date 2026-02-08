//
//  GuestAgentConnection+Tools.swift
//  Hivecrew
//
//  Tool methods for GuestAgentConnection
//

import Foundation

// MARK: - Tool Methods

extension GuestAgentConnection {
    
    /// Take a screenshot of the VM
    func screenshot() async throws -> ScreenshotResult {
        let response = try await call(method: "screenshot", params: nil)
        
        guard let result = response.result?.dictValue,
              let imageBase64 = result["imageBase64"] as? String,
              let width = result["width"] as? Int,
              let height = result["height"] as? Int else {
            throw AgentConnectionError.invalidResponse
        }
        
        return ScreenshotResult(imageBase64: imageBase64, width: width, height: height)
    }
    
    /// Open an application
    func openApp(bundleId: String? = nil, appName: String? = nil) async throws {
        var params: [String: Any] = [:]
        if let bundleId = bundleId { params["bundleId"] = bundleId }
        if let appName = appName { params["appName"] = appName }
        
        _ = try await call(method: "open_app", params: params)
    }
    
    /// Open a file
    func openFile(path: String, withApp: String? = nil) async throws {
        var params: [String: Any] = ["path": path]
        if let withApp = withApp { params["withApp"] = withApp }
        
        _ = try await call(method: "open_file", params: params)
    }
    
    /// Open a URL
    func openUrl(_ url: String) async throws {
        _ = try await call(method: "open_url", params: ["url": url])
    }
    
    /// Move or rename a file
    func moveFile(source: String, destination: String) async throws {
        _ = try await call(method: "move_file", params: [
            "source": source,
            "destination": destination
        ])
    }
    
    /// Move the mouse
    func mouseMove(x: Double, y: Double) async throws {
        _ = try await call(method: "mouse_move", params: ["x": x, "y": y])
    }
    
    /// Click the mouse
    func mouseClick(x: Double, y: Double, button: String = "left", clickType: String = "single") async throws {
        _ = try await call(method: "mouse_click", params: [
            "x": x,
            "y": y,
            "button": button,
            "clickType": clickType
        ])
    }
    
    /// Type text
    func keyboardType(text: String) async throws {
        _ = try await call(method: "keyboard_type", params: ["text": text])
    }
    
    /// Press a key
    func keyboardKey(key: String, modifiers: [String] = []) async throws {
        _ = try await call(method: "keyboard_key", params: [
            "key": key,
            "modifiers": modifiers
        ])
    }
    
    /// Scroll
    func scroll(x: Double, y: Double, deltaX: Double, deltaY: Double) async throws {
        _ = try await call(method: "scroll", params: [
            "x": x,
            "y": y,
            "deltaX": deltaX,
            "deltaY": deltaY
        ])
    }
    
    /// Drag the mouse from one position to another
    func mouseDrag(fromX: Double, fromY: Double, toX: Double, toY: Double) async throws {
        _ = try await call(method: "mouse_drag", params: [
            "fromX": fromX,
            "fromY": fromY,
            "toX": toX,
            "toY": toY
        ])
    }
    
    /// Run a shell command
    /// Note: The command is automatically wrapped to include common tool paths (Homebrew, Cargo, etc.)
    /// since the GuestAgent runs zsh non-interactively without sourcing profile files.
    func runShell(command: String, timeout: Double? = nil) async throws -> ShellResult {
        // Expand tilde and $HOME to the literal home path. Tilde expansion only works in unquoted 
        // shell contexts, and $HOME variables don't work when passed to programs like Node.js require().
        // The VM always runs as /Users/hivecrew/, so we use the literal path.
        let vmHomePath = "/Users/hivecrew"
        let expandedCommand = command
            .replacingOccurrences(of: "~/", with: "\(vmHomePath)/")
            .replacingOccurrences(of: "\"~\"", with: "\"\(vmHomePath)\"")
            .replacingOccurrences(of: "$HOME/", with: "\(vmHomePath)/")
            .replacingOccurrences(of: "${HOME}/", with: "\(vmHomePath)/")
        
        // Prepend common tool paths to ensure Homebrew, Cargo, Bun, and other tools are available.
        // The GuestAgent runs /bin/zsh -c which doesn't source ~/.zshrc or ~/.zprofile,
        // so tools installed via package managers won't be in PATH by default.
        //
        // Python fix: Also add user site-packages to PYTHONPATH and user bin dirs to PATH.
        // Without this, packages installed via pip for one Python version (e.g. system 3.9)
        // are invisible to another version (e.g. Homebrew 3.12) since each version has its
        // own user site-packages directory under ~/Library/Python/<version>/.
        let envSetup = """
            export PATH="$HOME/.bun/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.local/bin:$HOME/.cargo/bin:$HOME/.pyenv/shims:$HOME/.nvm/versions/node/$(ls -1 $HOME/.nvm/versions/node 2>/dev/null | tail -1)/bin:/Library/TeX/texbin:$PATH" 2>/dev/null
            for _d in "$HOME/Library/Python"/*/bin; do [ -d "$_d" ] && PATH="$_d:$PATH"; done 2>/dev/null; export PATH
            for _d in "$HOME/Library/Python"/*/lib/python/site-packages "$HOME/.local/lib/python"*/site-packages /opt/homebrew/lib/python*/site-packages; do [ -d "$_d" ] && PYTHONPATH="${PYTHONPATH:+$PYTHONPATH:}$_d"; done 2>/dev/null; export PYTHONPATH
            """
        let wrappedCommand = "\(envSetup); \(expandedCommand)"
        
        var params: [String: Any] = ["command": wrappedCommand]
        if let timeout = timeout { params["timeout"] = timeout }
        
        let response = try await call(method: "run_shell", params: params)
        
        guard let result = response.result?.dictValue,
              let stdout = result["stdout"] as? String,
              let stderr = result["stderr"] as? String,
              let exitCode = result["exitCode"] as? Int else {
            throw AgentConnectionError.invalidResponse
        }
        
        return ShellResult(stdout: stdout, stderr: stderr, exitCode: Int32(exitCode))
    }
    
    /// Read a file's contents (supports multiple formats: text, PDF, RTF, Office docs, images)
    /// For images, returns base64-encoded image data that can be injected into the model context
    func readFile(path: String) async throws -> FileReadResult {
        let response = try await call(method: "read_file", params: ["path": path])
        
        guard let result = response.result?.dictValue else {
            throw AgentConnectionError.invalidResponse
        }
        
        // The result contains "contents" and optional metadata like "fileType", "encoding", "mimeType"
        if let contents = result["contents"] as? String {
            let fileType = result["fileType"] as? String ?? "unknown"
            let isBase64 = result["isBase64"] as? Bool ?? false
            
            if isBase64 {
                // For images, return the actual base64 data so it can be injected into model context
                let mimeType = result["mimeType"] as? String ?? "image/png"
                let width = result["width"] as? Int
                let height = result["height"] as? Int
                return .image(base64: contents, mimeType: mimeType, width: width, height: height)
            } else {
                // For text-based files, return the contents with type info
                let encoding = result["encoding"] as? String
                var prefix = ""
                if fileType != "text" {
                    prefix = "[\(fileType.uppercased()) file"
                    if let enc = encoding {
                        prefix += ", encoding: \(enc)"
                    }
                    prefix += "]\n\n"
                }
                return .text(content: prefix + contents, fileType: fileType)
            }
        }
        
        throw AgentConnectionError.invalidResponse
    }
    
    /// Perform a health check
    func healthCheck() async throws -> HealthCheckResult {
        let response = try await call(method: "health_check", params: nil)
        
        guard let result = response.result?.dictValue else {
            throw AgentConnectionError.invalidResponse
        }
        
        return HealthCheckResult(
            status: result["status"] as? String ?? "unknown",
            accessibilityPermission: result["accessibilityPermission"] as? Bool ?? false,
            screenRecordingPermission: result["screenRecordingPermission"] as? Bool ?? false,
            sharedFolderMounted: result["sharedFolderMounted"] as? Bool ?? false,
            sharedFolderPath: result["sharedFolderPath"] as? String,
            agentVersion: result["agentVersion"] as? String ?? "unknown"
        )
    }
    
    /// Get the frontmost app
    func getFrontmostApp() async throws -> FrontmostAppResult {
        let response = try await call(method: "get_frontmost_app", params: nil)
        
        guard let result = response.result?.dictValue else {
            throw AgentConnectionError.invalidResponse
        }
        
        return FrontmostAppResult(
            bundleId: result["bundleId"] as? String,
            appName: result["appName"] as? String,
            windowTitle: result["windowTitle"] as? String
        )
    }
    
    /// Traverse the accessibility tree of an application
    func traverseAccessibilityTree(pid: Int32? = nil, onlyVisibleElements: Bool = true) async throws -> AccessibilityTraversalResult {
        var params: [String: Any] = ["onlyVisibleElements": onlyVisibleElements]
        if let pid = pid { params["pid"] = Int(pid) }
        
        let response = try await call(method: "traverse_accessibility_tree", params: params)
        
        guard let result = response.result?.dictValue,
              let appName = result["appName"] as? String,
              let elementsArray = result["elements"] as? [[String: Any]],
              let processingTime = result["processingTimeSeconds"] as? String else {
            throw AgentConnectionError.invalidResponse
        }
        
        let elements = elementsArray.map { elem in
            AccessibilityElementResult(
                role: elem["role"] as? String ?? "Unknown",
                text: elem["text"] as? String,
                x: elem["x"] as? Double,
                y: elem["y"] as? Double,
                width: elem["width"] as? Double,
                height: elem["height"] as? Double
            )
        }
        
        return AccessibilityTraversalResult(
            appName: appName,
            elements: elements,
            processingTimeSeconds: processingTime
        )
    }
}
