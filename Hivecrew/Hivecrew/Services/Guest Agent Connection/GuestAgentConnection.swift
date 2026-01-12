//
//  GuestAgentConnection.swift
//  Hivecrew
//
//  Manages the connection to a GuestAgent running inside a VM via virtio-vsock
//

import Foundation
import Virtualization
import Combine

/// Manages the connection to a GuestAgent running inside a VM via virtio-vsock
@MainActor
class GuestAgentConnection: ObservableObject {
    /// Connection state
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }
    
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var lastHealthCheck: HealthCheckResult?
    
    private let vm: VZVirtualMachine
    private let vmId: String
    private var connection: VZVirtioSocketConnection?
    private var readHandle: FileHandle?
    private var writeHandle: FileHandle?
    private var pendingRequests: [String: CheckedContinuation<AgentResponse, Error>] = [:]
    private var readBuffer = Data()
    private var readTask: Task<Void, Never>?
    private var isDisconnecting = false
    
    /// The vsock port the agent listens on
    private let agentPort: UInt32 = 3748
    
    /// Default timeout for tool calls (30 seconds)
    private let defaultToolTimeout: UInt64 = 30_000_000_000
    
    /// Longer timeout for screenshot calls (60 seconds)
    private let screenshotTimeout: UInt64 = 60_000_000_000
    
    /// Extended timeout for keyboard typing (5 minutes)
    private let keyboardTypeTimeout: UInt64 = 300_000_000_000
    
    /// Extended timeout for shell commands (90 seconds)
    private let shellTimeout: UInt64 = 90_000_000_000
    
    init(vm: VZVirtualMachine, vmId: String) {
        self.vm = vm
        self.vmId = vmId
    }
    
    // MARK: - Connection Management
    
    /// Connect to the GuestAgent
    func connect() async throws {
        guard state != .connected && state != .connecting else { return }
        
        state = .connecting
        let startTime = Date()
        
        do {
            print("GuestAgentConnection: [\(elapsed(from: startTime))] Getting socket device...")
            guard let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice else {
                throw AgentConnectionError.noSocketDevice
            }
            
            print("GuestAgentConnection: [\(elapsed(from: startTime))] Connecting to port \(agentPort)...")
            connection = try await socketDevice.connect(toPort: agentPort)
            print("GuestAgentConnection: [\(elapsed(from: startTime))] Socket connected!")
            
            guard let conn = connection else {
                throw AgentConnectionError.connectionFailed
            }
            
            // Create file handles from the connection's file descriptor
            let fd = conn.fileDescriptor
            readHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            writeHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            
            state = .connected
            print("GuestAgentConnection: [\(elapsed(from: startTime))] Connected to agent on VM \(vmId)")
            
            // Start reading responses
            startReading()
            
            // Perform initial health check with shorter timeout
            print("GuestAgentConnection: [\(elapsed(from: startTime))] Starting health check...")
            do {
                let result = try await withTimeout(seconds: 5) {
                    try await self.healthCheck()
                }
                lastHealthCheck = result
                print("GuestAgentConnection: [\(elapsed(from: startTime))] Health check succeeded")
            } catch {
                print("GuestAgentConnection: [\(elapsed(from: startTime))] Health check failed: \(error)")
            }
            
            print("GuestAgentConnection: [\(elapsed(from: startTime))] Connect complete")
            
        } catch {
            print("GuestAgentConnection: [\(elapsed(from: startTime))] Connect failed: \(error)")
            state = .error(error.localizedDescription)
            throw error
        }
    }
    
    private func elapsed(from start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }
    
    /// Disconnect from the GuestAgent
    func disconnect() {
        // Set flag first to signal the read loop to stop
        isDisconnecting = true
        
        readTask?.cancel()
        readTask = nil
        
        // File handles don't own the fd (closeOnDealloc: false), so just nil them
        readHandle = nil
        writeHandle = nil
        
        // Close the connection (this closes the underlying file descriptor)
        connection = nil
        
        // Cancel all pending requests
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: AgentConnectionError.disconnected)
        }
        pendingRequests.removeAll()
        
        state = .disconnected
        isDisconnecting = false
    }
    
    // MARK: - JSON-RPC Communication
    
    func call(method: String, params: [String: Any]?) async throws -> AgentResponse {
        guard state == .connected else {
            throw AgentConnectionError.notConnected
        }
        
        let requestId = UUID().uuidString
        let request = AgentRequest(id: requestId, method: method, params: params?.mapValues { AnyCodable($0) })
        
        // Send the request
        try sendRequest(request)
        
        // Choose timeout based on method type
        let timeout: UInt64
        switch method {
        case "screenshot":
            timeout = screenshotTimeout
        case "keyboard_type":
            timeout = keyboardTypeTimeout
        case "run_shell":
            timeout = shellTimeout
        default:
            timeout = defaultToolTimeout
        }
        let timeoutSeconds = timeout / 1_000_000_000
        
        // Wait for response
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = continuation
            
            // Set a timeout
            Task {
                try? await Task.sleep(nanoseconds: timeout)
                if let cont = pendingRequests.removeValue(forKey: requestId) {
                    print("GuestAgentConnection: Request \(method) timed out after \(timeoutSeconds)s")
                    cont.resume(throwing: AgentConnectionError.timeout)
                }
            }
        }
    }
    
    private func sendRequest(_ request: AgentRequest) throws {
        guard let writeHandle = writeHandle else {
            throw AgentConnectionError.notConnected
        }

        let encoder = JSONEncoder()
        var data = try encoder.encode(request)
        data.append(UInt8(ascii: "\n")) // Newline delimiter

        print("GuestAgentConnection: Sending request '\(request.method)' (id: \(request.id), \(data.count) bytes)")
        try writeHandle.write(contentsOf: data)
    }
    
    private func startReading() {
        print("GuestAgentConnection: Starting read loop")
        readTask = Task { [weak self] in
            guard let self = self else { 
                print("GuestAgentConnection: Read loop - self is nil")
                return 
            }
            
            print("GuestAgentConnection: Read loop started")
            var loopCount = 0
            
            while !Task.isCancelled {
                loopCount += 1
                
                // Check if we're disconnecting before attempting to read
                let disconnecting = await MainActor.run { self.isDisconnecting }
                if disconnecting {
                    print("GuestAgentConnection: Read loop - disconnecting, exiting")
                    break
                }
                
                guard let readHandle = await self.readHandle else {
                    print("GuestAgentConnection: Read loop - no read handle, exiting")
                    break
                }
                
                // Capture the file descriptor
                let fd = readHandle.fileDescriptor
                
                if loopCount == 1 {
                    print("GuestAgentConnection: Read loop - waiting for data on fd \(fd)")
                }
                
                // Read data using low-level read() which is more reliable for sockets
                let readResult: Data? = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var buffer = [UInt8](repeating: 0, count: 4096)
                        let bytesRead = read(fd, &buffer, 4096)
                        
                        if bytesRead > 0 {
                            continuation.resume(returning: Data(buffer[0..<bytesRead]))
                        } else if bytesRead == 0 {
                            // EOF
                            continuation.resume(returning: Data())
                        } else {
                            // Error
                            let err = errno
                            print("GuestAgentConnection: Read error: \(err) (\(String(cString: strerror(err))))")
                            continuation.resume(returning: nil)
                        }
                    }
                }
                
                // Check again after the read completes
                let isDisconnecting = await MainActor.run { self.isDisconnecting }
                if isDisconnecting {
                    print("GuestAgentConnection: Read loop - disconnecting after read, exiting")
                    break
                }
                
                guard let data = readResult else {
                    print("GuestAgentConnection: Read loop - read returned nil, exiting")
                    break
                }
                
                if data.isEmpty {
                    // EOF - connection closed by remote
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                    continue
                }
                await self.handleData(data)
            }
            
            print("GuestAgentConnection: Read loop ended after \(loopCount) iterations")
        }
    }
    
    private func handleData(_ data: Data) async {
        readBuffer.append(data)
        
        // Process complete messages (newline-delimited)
        while let newlineIndex = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let messageData = readBuffer[..<newlineIndex]
            readBuffer = Data(readBuffer[(newlineIndex + 1)...])
            
            if let response = parseResponse(Data(messageData)) {
                if let continuation = pendingRequests.removeValue(forKey: response.id) {
                    continuation.resume(returning: response)
                }
            }
        }
    }
    
    private func parseResponse(_ data: Data) -> AgentResponse? {
        do {
            let decoder = JSONDecoder()
            let response = try decoder.decode(AgentResponse.self, from: data)
            print("GuestAgentConnection: Parsed response for request \(response.id)")
            return response
        } catch {
            let rawString = String(data: data, encoding: .utf8) ?? "(non-utf8 data)"
            print("GuestAgentConnection: Failed to parse response: \(error)")
            print("GuestAgentConnection: Raw data (\(data.count) bytes): \(rawString.prefix(500))")
            return nil
        }
    }
}
