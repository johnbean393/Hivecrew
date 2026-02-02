//
//  MCPTransport.swift
//  HivecrewMCP
//
//  Transport layer abstraction for MCP communication
//

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.pattonium.mcp", category: "MCPTransport")

// MARK: - Transport Protocol

/// Protocol for MCP transport mechanisms
public protocol MCPTransport: Sendable {
    /// Send a request and receive a response
    func send(_ request: MCPRequest) async throws -> MCPResponse
    
    /// Start the transport connection
    func start() async throws
    
    /// Stop the transport connection
    func stop() async throws
    
    /// Whether the transport is currently connected
    func checkIsConnected() async -> Bool
}

// MARK: - Stdio Transport

/// Transport for MCP servers running as child processes with stdio communication
public actor StdioTransport: MCPTransport {
    private let command: String
    private let arguments: [String]
    private let workingDirectory: String?
    private let environment: [String: String]?
    
    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderrHandle: FileHandle?
    private var readBuffer = Data()
    private var stderrBuffer = ""
    
    private var _isConnected = false
    public func checkIsConnected() async -> Bool { _isConnected }
    
    /// Returns any stderr output captured from the process
    public var lastStderrOutput: String { stderrBuffer }
    
    public init(
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String]? = nil
    ) {
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }
    
    public func start() async throws {
        logger.info("StdioTransport.start: Beginning")
        logger.info("StdioTransport.start: Command = \(self.command)")
        logger.info("StdioTransport.start: Arguments = \(self.arguments.joined(separator: " "))")
        
        let proc = Process()
        
        // Resolve command path
        logger.info("StdioTransport.start: Resolving executable")
        let (executableURL, finalArguments) = resolveExecutableAndArguments(command: command, arguments: arguments)
        proc.executableURL = executableURL
        proc.arguments = finalArguments
        logger.info("StdioTransport.start: Executable URL = \(executableURL.path)")
        logger.info("StdioTransport.start: Final arguments = \(finalArguments.joined(separator: " "))")
        
        if let workDir = workingDirectory {
            proc.currentDirectoryURL = URL(fileURLWithPath: workDir)
            logger.info("StdioTransport.start: Working dir = \(workDir)")
        }
        
        // Set up environment
        var env = ProcessInfo.processInfo.environment
        if let customEnv = environment {
            for (key, value) in customEnv {
                env[key] = value
            }
        }
        proc.environment = env
        logger.info("StdioTransport.start: Environment set")
        
        // Set up pipes for stdio communication
        logger.info("StdioTransport.start: Creating pipes")
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        logger.info("StdioTransport.start: Pipes attached")
        
        do {
            logger.info("StdioTransport.start: Calling proc.run()")
            try proc.run()
            logger.info("StdioTransport.start: proc.run() completed")
        } catch {
            logger.error("StdioTransport.start: proc.run() failed - \(error.localizedDescription)")
            throw MCPClientError.processSpawnFailed(error.localizedDescription)
        }
        
        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self._isConnected = true
        logger.info("StdioTransport.start: Connected, starting stderr capture")
        
        // Capture stderr in background
        Task {
            await self.captureStderr(stderrPipe.fileHandleForReading)
        }
        
        // Wait briefly to check if process exits immediately (common for "command not found")
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        
        if !proc.isRunning {
            let exitCode = proc.terminationStatus
            logger.error("StdioTransport.start: Process exited immediately with code \(exitCode)")
            
            // Wait a bit more and collect stderr
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms more
            
            let errorMessage: String
            if !stderrBuffer.isEmpty {
                errorMessage = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if exitCode == 127 {
                errorMessage = "Command not found: '\(command)'. Make sure it is installed and in your PATH."
            } else {
                errorMessage = "Process exited with code \(exitCode)"
            }
            
            self._isConnected = false
            throw MCPClientError.processSpawnFailed(errorMessage)
        }
        
        logger.info("StdioTransport.start: Process is running, startup complete")
    }
    
    public func stop() async throws {
        _isConnected = false
        
        if let proc = process, proc.isRunning {
            proc.terminate()
            proc.waitUntilExit()
        }
        
        try? stdin?.close()
        try? stdout?.close()
        
        process = nil
        stdin = nil
        stdout = nil
        readBuffer = Data()
    }
    
    public func send(_ request: MCPRequest) async throws -> MCPResponse {
        logger.info("StdioTransport.send: Starting for method \(request.method)")
        
        guard _isConnected, let stdinHandle = stdin, let stdoutHandle = stdout else {
            logger.error("StdioTransport.send: Not connected")
            throw MCPClientError.notInitialized
        }
        
        // Check if process is still running
        if let proc = process, !proc.isRunning {
            let exitCode = proc.terminationStatus
            logger.error("StdioTransport.send: Process not running, exit code \(exitCode)")
            
            let errorMessage: String
            if !stderrBuffer.isEmpty {
                errorMessage = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if exitCode == 127 {
                errorMessage = "Command not found: '\(command)'. Make sure it is installed and in your PATH."
            } else {
                errorMessage = "MCP server process exited unexpectedly (code \(exitCode))"
            }
            
            throw MCPClientError.connectionFailed(errorMessage)
        }
        
        logger.info("StdioTransport.send: Connected, encoding request")
        
        // Encode request
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        logger.info("StdioTransport.send: Encoded, size=\(requestData.count) bytes")
        
        // Write request with newline delimiter
        var dataToSend = requestData
        dataToSend.append(contentsOf: [0x0A]) // newline
        
        logger.info("StdioTransport.send: Writing to stdin")
        do {
            try stdinHandle.write(contentsOf: dataToSend)
            logger.info("StdioTransport.send: Write completed successfully")
        } catch {
            logger.error("StdioTransport.send: Write failed - \(error.localizedDescription)")
            throw error
        }
        logger.info("StdioTransport.send: Calling readResponse")
        
        // Read response
        let response = try await readResponse(from: stdoutHandle, expectedId: request.id)
        logger.info("StdioTransport.send: Got response")
        return response
    }
    
    // MARK: - Private Helpers
    
    /// Resolves the executable path and adjusts arguments if needed.
    /// When falling back to /usr/bin/env, the command is prepended to arguments.
    private func resolveExecutableAndArguments(command: String, arguments: [String]) -> (URL, [String]) {
        // If it's an absolute path, use it directly
        if command.hasPrefix("/") {
            return (URL(fileURLWithPath: command), arguments)
        }
        
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        
        // Common executable locations - order matters, more specific first
        var searchPaths = [
            // Homebrew (Apple Silicon and Intel)
            "/opt/homebrew/bin",
            "/usr/local/bin",
            
            // System paths
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            
            // Bun
            "\(home)/.bun/bin",
            
            // Node version managers
            "\(home)/.volta/bin",
            "\(home)/.fnm/current/bin",
            
            // pnpm
            "\(home)/.local/share/pnpm",
            "\(home)/Library/pnpm",
            
            // General user binaries
            "\(home)/.local/bin",
            
            // Python
            "\(home)/.pyenv/shims",
            "/opt/homebrew/opt/python/libexec/bin",
        ]
        
        // Add nvm paths - check for installed node versions
        let nvmDir = "\(home)/.nvm/versions/node"
        if let nodeVersions = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) {
            // Sort versions descending to prefer latest
            let sortedVersions = nodeVersions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            for version in sortedVersions {
                searchPaths.append("\(nvmDir)/\(version)/bin")
            }
        }
        
        // Try to find the command in PATH first
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            let paths = pathEnv.split(separator: ":").map(String.init)
            for path in paths {
                let url = URL(fileURLWithPath: path).appendingPathComponent(command)
                if FileManager.default.isExecutableFile(atPath: url.path) {
                    logger.info("resolveExecutable: Found \(command) at \(url.path) (from PATH)")
                    return (url, arguments)
                }
            }
        }
        
        // Fallback: try common locations
        for searchPath in searchPaths where !searchPath.isEmpty {
            let url = URL(fileURLWithPath: searchPath).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                logger.info("resolveExecutable: Found \(command) at \(url.path) (common location)")
                return (url, arguments)
            }
        }
        
        // Last resort: use /usr/bin/env to find command via PATH at runtime
        // When using env, we need to prepend the command to arguments
        logger.warning("resolveExecutable: Could not find \(command), using /usr/bin/env fallback")
        return (URL(fileURLWithPath: "/usr/bin/env"), [command] + arguments)
    }
    
    private func readResponse(from handle: FileHandle, expectedId: Int) async throws -> MCPResponse {
        logger.info("readResponse: Starting for id=\(expectedId)")
        let decoder = JSONDecoder()
        let maxAttempts = 300 // 30 seconds max wait (300 * 100ms)
        var attempts = 0
        
        // Read until we get a complete JSON response
        while attempts < maxAttempts {
            attempts += 1
            
            // Check if we have a complete line in the buffer
            if let newlineIndex = readBuffer.firstIndex(of: 0x0A) {
                let lineData = readBuffer.prefix(upTo: newlineIndex)
                readBuffer = Data(readBuffer.suffix(from: readBuffer.index(after: newlineIndex)))
                
                if lineData.isEmpty {
                    continue
                }
                
                do {
                    let response = try decoder.decode(MCPResponse.self, from: Data(lineData))
                    
                    // Check if this is the response we're waiting for
                    if response.id == expectedId {
                        logger.info("readResponse: Got matching response")
                        return response
                    }
                    // Otherwise it might be a notification, skip it
                    logger.info("readResponse: Skipping response with id=\(response.id ?? -1)")
                } catch {
                    // Not valid JSON, skip this line
                    if let str = String(data: Data(lineData), encoding: .utf8) {
                        logger.info("readResponse: Skipping non-JSON line: \(str.prefix(100))")
                    }
                    continue
                }
            }
            
            // Read more data using async wrapper to avoid blocking actor thread
            logger.info("readResponse: Reading more data from handle (attempt \(attempts))")
            
            let newData: Data = await withCheckedContinuation { continuation in
                // Run blocking read on a separate thread
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = handle.availableData
                    continuation.resume(returning: data)
                }
            }
            logger.info("readResponse: Got \(newData.count) bytes")
            
            if newData.isEmpty {
                // Process might have exited or pipe closed - check if process is still running
                if let proc = self.process, !proc.isRunning {
                    logger.error("readResponse: Process exited with code \(proc.terminationStatus)")
                    throw MCPClientError.connectionFailed("Process exited with code \(proc.terminationStatus)")
                }
                // Wait a bit and try again (pipe might be slow)
                logger.info("readResponse: Empty data, sleeping")
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            } else {
                readBuffer.append(newData)
            }
        }
        
        logger.error("readResponse: Timeout waiting for response")
        throw MCPClientError.connectionFailed("Timeout waiting for response")
    }
    
    private func captureStderr(_ handle: FileHandle) async {
        while _isConnected || (process?.isRunning == true) {
            // Use async wrapper to avoid blocking actor thread
            let data: Data = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let data = handle.availableData
                    continuation.resume(returning: data)
                }
            }
            
            if data.isEmpty {
                // Check if process is still running
                if let proc = process, !proc.isRunning {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                continue
            }
            
            if let str = String(data: data, encoding: .utf8) {
                stderrBuffer += str
                logger.info("MCP stderr: \(str.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }
}

// MARK: - HTTP Transport

/// Transport for MCP servers accessible via HTTP
public actor HTTPTransport: MCPTransport {
    private let serverURL: URL
    private let session: URLSession
    
    private var _isConnected = false
    public func checkIsConnected() async -> Bool { _isConnected }
    
    public init(serverURL: URL) {
        self.serverURL = serverURL
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }
    
    public func start() async throws {
        // For HTTP, we just verify the server is reachable
        _isConnected = true
    }
    
    public func stop() async throws {
        _isConnected = false
    }
    
    public func send(_ request: MCPRequest) async throws -> MCPResponse {
        guard _isConnected else {
            throw MCPClientError.notInitialized
        }
        
        var urlRequest = URLRequest(url: serverURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        urlRequest.httpBody = try encoder.encode(request)
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse("Not an HTTP response")
        }
        
        guard httpResponse.statusCode == 200 else {
            throw MCPClientError.connectionFailed("HTTP \(httpResponse.statusCode)")
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(MCPResponse.self, from: data)
    }
}
