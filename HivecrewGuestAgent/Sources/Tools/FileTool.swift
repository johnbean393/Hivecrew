//
//  FileTool.swift
//  HivecrewGuestAgent
//
//  Tool for file operations and shell commands
//

import Foundation
import AppKit
import HivecrewAgentProtocol

/// Tool for file operations and shell commands
final class FileTool {
    let logger = AgentLogger.shared
    
    /// Default shell command timeout in seconds
    private let defaultShellTimeout: Double = 60.0
    
    /// Run a shell command and return the result
    func runShell(command: String, timeout: Double?) throws -> [String: Any] {
        logger.log("Running shell command: \(command)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // Use login shell (-l) so that /etc/zprofile (which runs path_helper) and
        // ~/.zprofile are sourced. Without this, the PATH is minimal and user-installed
        // tools (Python packages, Homebrew binaries, etc.) are not found.
        process.arguments = ["-l", "-c", command]
        
        // Ensure common paths are present even if profile files are incomplete.
        // Merge with inherited environment so we don't lose existing variables.
        var env = ProcessInfo.processInfo.environment
        let currentPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let additionalPaths = [
            "/usr/local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
        ]
        let pathComponents = currentPath.split(separator: ":").map(String.init)
        let missingPaths = additionalPaths.filter { !pathComponents.contains($0) }
        if !missingPaths.isEmpty {
            env["PATH"] = (missingPaths + pathComponents).joined(separator: ":")
        }
        
        // Add the active Python version's user site-packages to PYTHONPATH and bin to PATH.
        // We detect the running python3's version by resolving the Homebrew symlink chain
        // and ONLY add that version's directories — adding all versions causes ImportErrors
        // when compiled C extensions (e.g. Pillow's _imaging.cpython-39-darwin.so) are loaded
        // by a different Python version.
        let homeDir = env["HOME"] ?? NSHomeDirectory()
        let activePythonVersion: String? = {
            for candidate in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                // Resolve the full symlink chain; the final binary is typically
                // named "python3.13" (or similar) which encodes the version.
                let resolved = URL(fileURLWithPath: candidate).resolvingSymlinksInPath().lastPathComponent
                guard resolved.hasPrefix("python") else { continue }
                let version = String(resolved.dropFirst("python".count))
                let parts = version.split(separator: ".")
                if parts.count == 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
                    return version
                }
            }
            return nil
        }()
        if let pyVer = activePythonVersion {
            let userSitePkgs = "\(homeDir)/Library/Python/\(pyVer)/lib/python/site-packages"
            let userBin = "\(homeDir)/Library/Python/\(pyVer)/bin"
            let brewSitePkgs = "/opt/homebrew/lib/python\(pyVer)/site-packages"
            
            var sitePaths: [String] = []
            for path in [userSitePkgs, brewSitePkgs] {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    sitePaths.append(path)
                }
            }
            if !sitePaths.isEmpty {
                let existing = env["PYTHONPATH"] ?? ""
                let all = sitePaths + (existing.isEmpty ? [] : [existing])
                env["PYTHONPATH"] = all.joined(separator: ":")
            }
            
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: userBin, isDirectory: &isDir), isDir.boolValue {
                env["PATH"] = "\(userBin):\(env["PATH"] ?? "")"
            }
        }
        
        process.environment = env
        
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        
        // Semaphores for coordinating completion
        let processSemaphore = DispatchSemaphore(value: 0)
        let stdoutSemaphore = DispatchSemaphore(value: 0)
        let stderrSemaphore = DispatchSemaphore(value: 0)
        
        // Output storage
        var stdoutData = Data()
        var stderrData = Data()
        
        // Set up termination handler
        process.terminationHandler = { _ in
            processSemaphore.signal()
        }
        
        do {
            try process.run()
        } catch {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to run command: \(error.localizedDescription)")
        }
        
        logger.log("Process started (PID: \(process.processIdentifier))")
        
        // Start async readers IMMEDIATELY to prevent pipe buffer deadlock
        // If output exceeds ~64KB and we don't read, the process blocks forever
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            stdoutSemaphore.signal()
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            stderrSemaphore.signal()
        }
        
        // Wait for process to complete (with timeout)
        let effectiveTimeout = timeout ?? defaultShellTimeout
        let processWaitResult = processSemaphore.wait(timeout: .now() + effectiveTimeout)
        
        let timedOut = (processWaitResult == .timedOut)
        if timedOut {
            logger.warning("Command timed out after \(effectiveTimeout)s, terminating PID \(process.processIdentifier)")
            process.terminate()
            // Give termination handler a chance to fire
            _ = processSemaphore.wait(timeout: .now() + 1.0)
        }
        
        // Wait for readers to complete (they will once pipes close after process exit)
        _ = stdoutSemaphore.wait(timeout: .now() + 5.0)
        _ = stderrSemaphore.wait(timeout: .now() + 5.0)
        
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        
        logger.log("Command done: exit=\(process.terminationStatus), stdout=\(stdout.count)b, stderr=\(stderr.count)b")
        
        if timedOut {
            return [
                "stdout": stdout,
                "stderr": stderr + "\n[Command timed out after \(effectiveTimeout) seconds]",
                "exitCode": -1
            ]
        }
        
        return [
            "stdout": stdout,
            "stderr": stderr,
            "exitCode": Int(process.terminationStatus)
        ]
    }
    
    /// Read a file's contents with support for multiple file formats
    ///
    /// Supported formats:
    /// - Plain text files (with encoding detection)
    /// - PDF documents (text extraction)
    /// - RTF documents (text extraction)
    /// - Office documents (.docx, .xlsx, .pptx)
    /// - Property lists (.plist)
    /// - Images (returned as base64)
    func readFile(path: String) throws -> [String: Any] {
        logger.log("Reading file: \(path)")
        
        let resolvedPath = resolvePath(path)
        
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "File not found: \(path)")
        }
        
        let fileType = FileType.from(path: resolvedPath)
        logger.log("Detected file type: \(fileType) for \(path)")
        
        do {
            switch fileType {
            case .pdf:
                let contents = try extractTextFromPDF(at: resolvedPath)
                return ["contents": contents, "fileType": "pdf", "mimeType": fileType.mimeType]
                
            case .rtf:
                let contents = try extractTextFromRTF(at: resolvedPath)
                return ["contents": contents, "fileType": "rtf", "mimeType": fileType.mimeType]
                
            case .officeDocument(let docType):
                let contents = try extractTextFromOfficeDocument(at: resolvedPath, type: docType)
                let typeStr: String
                switch docType {
                case .docx: typeStr = "docx"
                case .xlsx: typeStr = "xlsx"
                case .pptx: typeStr = "pptx"
                }
                return ["contents": contents, "fileType": typeStr, "mimeType": fileType.mimeType]
                
            case .plist:
                let contents = try extractTextFromPlist(at: resolvedPath)
                return ["contents": contents, "fileType": "plist", "mimeType": fileType.mimeType]
                
            case .image:
                let result = try readImageAsBase64(at: resolvedPath)
                return result
                
            case .plainText, .binary:
                let (contents, encoding) = try readWithEncodingFallback(at: resolvedPath)
                return ["contents": contents, "fileType": "text", "encoding": encoding]
            }
        } catch let error as AgentError {
            throw error
        } catch {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to read file: \(error.localizedDescription)")
        }
    }
    
    /// Write contents to a file
    func writeFile(path: String, contents: String) throws {
        logger.log("Writing file: \(path)")
        
        let resolvedPath = resolvePath(path)
        
        // Create parent directories if needed
        let parentDir = (resolvedPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        
        do {
            try contents.write(toFile: resolvedPath, atomically: true, encoding: .utf8)
        } catch {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to write file: \(error.localizedDescription)")
        }
    }
    
    /// List contents of a directory
    func listDirectory(path: String) throws -> [[String: Any]] {
        logger.log("Listing directory: \(path)")
        
        let resolvedPath = resolvePath(path)
        
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Directory not found: \(path)")
        }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: resolvedPath)
            
            return contents.map { name in
                let fullPath = (resolvedPath as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir)
                
                var entry: [String: Any] = [
                    "name": name,
                    "isDirectory": isDir.boolValue
                ]
                
                if let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) {
                    if let size = attrs[.size] as? Int {
                        entry["size"] = size
                    }
                    if let modDate = attrs[.modificationDate] as? Date {
                        entry["modifiedAt"] = modDate.timeIntervalSince1970
                    }
                }
                
                return entry
            }
        } catch {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to list directory: \(error.localizedDescription)")
        }
    }
    
    /// Move a file or directory
    func moveFile(source: String, destination: String) throws {
        logger.log("Moving file from \(source) to \(destination)")
        
        let resolvedSource = resolvePath(source)
        let resolvedDest = resolvePath(destination)
        
        guard FileManager.default.fileExists(atPath: resolvedSource) else {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Source not found: \(source)")
        }
        
        // Create parent directories if needed
        let parentDir = (resolvedDest as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        
        do {
            try FileManager.default.moveItem(atPath: resolvedSource, toPath: resolvedDest)
        } catch {
            throw AgentError(code: AgentError.toolExecutionFailed, message: "Failed to move file: \(error.localizedDescription)")
        }
    }
    
    /// Read text from the clipboard
    func clipboardRead() throws -> [String: Any] {
        logger.log("Reading clipboard")
        
        let pasteboard = NSPasteboard.general
        
        if let text = pasteboard.string(forType: .string) {
            return ["text": text]
        }
        
        return ["text": ""]
    }
    
    /// Write text to the clipboard
    func clipboardWrite(text: String) throws {
        logger.log("Writing to clipboard: \(text.prefix(50))...")
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    /// Resolve a path, handling tilde expansion and relative paths within the shared folder
    func resolvePath(_ path: String) -> String {
        // Handle tilde expansion (e.g., ~/Desktop/file.txt)
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        
        // Absolute paths are used as-is
        if path.hasPrefix("/") {
            return path
        }
        
        // Relative paths are resolved against the shared folder
        return (AgentProtocol.sharedFolderMountPath as NSString).appendingPathComponent(path)
    }
}
