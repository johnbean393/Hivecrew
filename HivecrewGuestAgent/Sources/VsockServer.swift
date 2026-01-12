//
//  VsockServer.swift
//  HivecrewGuestAgent
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import HivecrewAgentProtocol

/// A server that listens for connections from the host via virtio-vsock
/// 
/// In macOS VMs, vsock appears as a standard socket that can be accessed
/// using the AF_VSOCK address family. The guest connects to a specific port
/// and the host can then send/receive data.
final class VsockServer {
    private let port: UInt32
    private let handler: ToolHandler
    private let logger = AgentLogger.shared
    
    private var serverSocket: Int32 = -1
    private var clientSocket: Int32 = -1
    private var isRunning = false
    private var acceptThread: Thread?
    private var readThread: Thread?
    
    // AF_VSOCK constants (from Linux/virtio headers)
    private let AF_VSOCK: Int32 = 40  // macOS uses 40 for AF_VSOCK
    private let VMADDR_CID_HOST: UInt32 = 2  // Host CID
    private let VMADDR_CID_ANY: UInt32 = 0xFFFFFFFF  // Any CID
    
    init(port: UInt32, handler: ToolHandler) {
        self.port = port
        self.handler = handler
    }
    
    /// Start listening for connections
    func start() throws {
        // Create vsock socket
        print("Creating vsock socket with AF_VSOCK=\(AF_VSOCK)...")
        serverSocket = socket(AF_VSOCK, SOCK_STREAM, 0)
        if serverSocket < 0 {
            let err = errno
            print("Socket creation failed: errno=\(err) (\(String(cString: strerror(err))))")
            throw VsockError.socketCreationFailed(errno: err)
        }
        print("Socket created: fd=\(serverSocket)")
        
        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        
        // Bind to port
        var addr = sockaddr_vm()
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_cid = VMADDR_CID_ANY
        addr.svm_port = port
        
        print("Binding to port \(port) with CID=\(VMADDR_CID_ANY)...")
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        
        if bindResult != 0 {
            let err = errno
            print("Bind failed: errno=\(err) (\(String(cString: strerror(err))))")
            close(serverSocket)
            throw VsockError.bindFailed(errno: err)
        }
        print("Bound successfully")
        
        // Listen for connections
        print("Starting to listen...")
        if listen(serverSocket, 1) != 0 {
            let err = errno
            print("Listen failed: errno=\(err) (\(String(cString: strerror(err))))")
            close(serverSocket)
            throw VsockError.listenFailed(errno: err)
        }
        print("Listening on vsock port \(port)")
        
        isRunning = true
        
        // Start accept thread
        acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread?.name = "VsockAcceptThread"
        acceptThread?.start()
    }
    
    /// Stop the server
    func stop() {
        isRunning = false
        
        if clientSocket >= 0 {
            close(clientSocket)
            clientSocket = -1
        }
        
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
    
    private func acceptLoop() {
        while isRunning {
            logger.log("Waiting for connection on vsock port \(port)...")
            
            var clientAddr = sockaddr_vm()
            var addrLen = socklen_t(MemoryLayout<sockaddr_vm>.size)
            
            let newSocket = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }
            
            guard newSocket >= 0 else {
                if isRunning {
                    logger.error("Accept failed: \(String(cString: strerror(errno)))")
                }
                continue
            }
            
            logger.log("Client connected from CID \(clientAddr.svm_cid)")
            
            // Close any existing client connection
            if clientSocket >= 0 {
                close(clientSocket)
            }
            clientSocket = newSocket
            
            // Handle client in a new thread
            readThread = Thread { [weak self] in
                self?.handleClient(socket: newSocket)
            }
            readThread?.name = "VsockClientThread"
            readThread?.start()
        }
    }
    
    private func handleClient(socket: Int32) {
        var buffer = Data()
        let readBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { readBuffer.deallocate() }
        
        while isRunning && socket == clientSocket {
            let bytesRead = read(socket, readBuffer, 4096)
            
            if bytesRead <= 0 {
                if bytesRead < 0 && errno != EAGAIN {
                    logger.error("Read error: \(String(cString: strerror(errno)))")
                }
                break
            }
            
            buffer.append(readBuffer, count: bytesRead)
            
            // Try to parse complete messages (newline-delimited JSON)
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let messageData = buffer[..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])
                
                if let request = parseRequest(Data(messageData)) {
                    let response = handler.handleRequest(request)
                    sendResponse(response, to: socket)
                }
            }
        }
        
        logger.log("Client disconnected")
        if socket == clientSocket {
            clientSocket = -1
        }
    }
    
    private func parseRequest(_ data: Data) -> AgentRequest? {
        do {
            let decoder = JSONDecoder()
            return try decoder.decode(AgentRequest.self, from: data)
        } catch {
            logger.error("Failed to parse request: \(error)")
            return nil
        }
    }
    
    private func sendResponse(_ response: AgentResponse, to socket: Int32) {
        do {
            let encoder = JSONEncoder()
            var data = try encoder.encode(response)
            data.append(UInt8(ascii: "\n"))  // Newline delimiter
            
            data.withUnsafeBytes { buffer in
                guard let ptr = buffer.baseAddress else { return }
                _ = write(socket, ptr, buffer.count)
            }
        } catch {
            logger.error("Failed to encode response: \(error)")
        }
    }
}

// MARK: - sockaddr_vm structure

/// The vsock address structure
struct sockaddr_vm {
    var svm_family: sa_family_t = 0
    var svm_reserved1: UInt16 = 0
    var svm_port: UInt32 = 0
    var svm_cid: UInt32 = 0
    var svm_zero: (UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0)
    
    init() {}
}

// MARK: - Errors

enum VsockError: Error, LocalizedError {
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case connectFailed(errno: Int32)
    
    var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let errno):
            return "Failed to create vsock socket: \(String(cString: strerror(errno)))"
        case .bindFailed(let errno):
            return "Failed to bind vsock socket: \(String(cString: strerror(errno)))"
        case .listenFailed(let errno):
            return "Failed to listen on vsock socket: \(String(cString: strerror(errno)))"
        case .connectFailed(let errno):
            return "Failed to connect vsock socket: \(String(cString: strerror(errno)))"
        }
    }
}
