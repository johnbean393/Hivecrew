//
//  CloudflaredManager.swift
//  Hivecrew
//
//  Manages the bundled cloudflared binary lifecycle (start, stop, monitor)
//

import Foundation

/// Manages the cloudflared tunnel client process
actor CloudflaredManager {
    
    /// Current cloudflared process
    private var process: Process?
    
    /// Whether cloudflared is currently running
    var isRunning: Bool {
        process?.isRunning ?? false
    }
    
    /// Callback when cloudflared terminates unexpectedly
    var onUnexpectedTermination: ((Int32) -> Void)?
    
    // MARK: - Locate Binary
    
    /// Find the cloudflared binary in the app bundle
    private func cloudflaredURL() throws -> URL {
        // Try auxiliary executable first (Contents/MacOS/)
        if let url = Bundle.main.url(forAuxiliaryExecutable: "cloudflared") {
            return url
        }
        
        // Try Resources directory
        if let url = Bundle.main.url(forResource: "cloudflared", withExtension: nil, subdirectory: "cloudflared") {
            return url
        }
        
        // Try Resources root
        if let url = Bundle.main.url(forResource: "cloudflared", withExtension: nil) {
            return url
        }
        
        throw RemoteAccessError.cloudflaredNotFound
    }
    
    // MARK: - Start
    
    /// Start cloudflared with the given tunnel token
    /// - Parameter token: The tunnel-specific token from Cloudflare
    func start(token: String) async throws {
        guard !isRunning else {
            print("CloudflaredManager: Already running")
            return
        }
        
        let binaryURL = try cloudflaredURL()
        
        // Ensure the binary is executable
        let fileManager = FileManager.default
        var isExecutable = false
        if let attrs = try? fileManager.attributesOfItem(atPath: binaryURL.path),
           let perms = attrs[.posixPermissions] as? Int {
            isExecutable = (perms & 0o111) != 0
        }
        
        if !isExecutable {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: binaryURL.path
            )
        }
        
        // Configure the process
        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["tunnel", "run", "--token", token]
        
        // Suppress output noise — pipe to /dev/null or capture for debugging
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = errorPipe
        
        // Log stderr for debugging
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                print("cloudflared: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        
        // Monitor for unexpected termination
        proc.terminationHandler = { [weak self] process in
            let code = process.terminationStatus
            print("CloudflaredManager: cloudflared exited with code \(code)")
            
            Task { [weak self] in
                await self?.handleTermination(code: code)
            }
        }
        
        // Launch
        do {
            try proc.run()
            self.process = proc
            print("CloudflaredManager: Started cloudflared (PID: \(proc.processIdentifier))")
        } catch {
            throw RemoteAccessError.cloudflaredStartFailed(error.localizedDescription)
        }
        
        // Brief delay to detect immediate startup failures
        try? await Task.sleep(for: .seconds(2))
        
        if let proc = self.process, !proc.isRunning {
            let code = proc.terminationStatus
            self.process = nil
            throw RemoteAccessError.cloudflaredStartFailed("Process exited immediately with code \(code)")
        }
    }
    
    // MARK: - Stop
    
    /// Gracefully stop cloudflared
    func stop() {
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }
        
        print("CloudflaredManager: Stopping cloudflared (PID: \(proc.processIdentifier))")
        
        // Clear termination handler to avoid triggering "unexpected" callback
        proc.terminationHandler = nil
        
        // Send SIGTERM for graceful shutdown
        proc.terminate()
        
        // Give it a moment to shut down gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            if proc.isRunning {
                print("CloudflaredManager: Force killing cloudflared")
                proc.interrupt() // SIGINT
            }
            Task { await self?.clearProcess() }
        }
    }
    
    // MARK: - Internal
    
    private func clearProcess() {
        process = nil
    }
    
    private func handleTermination(code: Int32) {
        process = nil
        
        // Code 0 = normal shutdown (we called stop()), non-zero = unexpected
        if code != 0 {
            onUnexpectedTermination?(code)
        }
    }
}
