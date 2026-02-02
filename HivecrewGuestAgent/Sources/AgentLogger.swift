//
//  AgentLogger.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation

/// Log level for agent messages
enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

/// Simple file-based logger for the agent daemon
final class AgentLogger: @unchecked Sendable {
    static let shared = AgentLogger()
    
    private let logFileURL: URL
    private let fileHandle: FileHandle?
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.pattonium.agent.logger")
    
    private init() {
        // Create log directory
        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        
        logFileURL = logsDir.appendingPathComponent("HivecrewGuestAgent.log")
        
        // Create log file if it doesn't exist
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        
        // Open file handle for appending
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()
        
        // Set up date formatter
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    }
    
    deinit {
        try? fileHandle?.close()
    }
    
    /// Log a message with the specified level
    func log(_ message: String, level: LogLevel = .info) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            let timestamp = self.dateFormatter.string(from: Date())
            let logLine = "[\(timestamp)] [\(level.rawValue)] \(message)\n"
            
            // Write to file
            if let data = logLine.data(using: .utf8) {
                self.fileHandle?.write(data)
                try? self.fileHandle?.synchronize()
            }
            
            // Also print to stdout for debugging
            print(logLine, terminator: "")
        }
    }
    
    /// Log a debug message
    func debug(_ message: String) {
        log(message, level: .debug)
    }
    
    /// Log an error message
    func error(_ message: String) {
        log(message, level: .error)
    }
    
    /// Log a warning message
    func warning(_ message: String) {
        log(message, level: .warning)
    }
}
