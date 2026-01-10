//
//  HivecrewVMServiceProtocol.swift
//  HivecrewShared
//
//  Created by Hivecrew on 1/10/26.
//

import Foundation

/// XPC Service identifier
public let hivecrewVMServiceName = "com.pattonium.HivecrewVMService"

/// Protocol for the VM management XPC service
/// All methods use dictionaries for XPC compatibility since custom types require NSSecureCoding
@objc public protocol HivecrewVMServiceProtocol {
    
    /// Create a new VM from an IPSW restore image
    /// - Parameters:
    ///   - ipswPath: Path to the IPSW file
    ///   - configDict: VMConfiguration as dictionary
    ///   - reply: Callback with result dictionary containing either "vmId" on success or "error" on failure
    func createVM(
        fromIPSW ipswPath: String,
        config configDict: [String: Any],
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Start a stopped VM
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with result dictionary containing "success" bool or "error" on failure
    func startVM(
        id vmId: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Stop a running VM
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - force: If true, force stop immediately; if false, attempt graceful shutdown
    ///   - reply: Callback with result dictionary containing "success" bool or "error" on failure
    func stopVM(
        id vmId: String,
        force: Bool,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Delete a VM and all its associated files
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with result dictionary containing "success" bool or "error" on failure
    func deleteVM(
        id vmId: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// List all VMs
    /// - Parameter reply: Callback with array of VMInfo dictionaries
    func listVMs(
        reply: @escaping ([[String: Any]]) -> Void
    )
    
    /// Get the current status of a VM
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with status raw value (Int) or -1 if not found
    func getVMStatus(
        id vmId: String,
        reply: @escaping (Int) -> Void
    )
    
    /// Get detailed info about a VM
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with VMInfo dictionary or empty dictionary if not found
    func getVMInfo(
        id vmId: String,
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Get installation progress for a VM being created
    /// - Parameters:
    ///   - vmId: The unique identifier of the VM
    ///   - reply: Callback with progress (0.0 to 1.0) or -1 if not installing
    func getInstallProgress(
        id vmId: String,
        reply: @escaping (Double) -> Void
    )
    
    /// Download the latest supported macOS restore image
    /// - Parameter reply: Callback with result dictionary containing "path" on success or "error" on failure
    func downloadLatestIPSW(
        reply: @escaping ([String: Any]) -> Void
    )
    
    /// Get the download progress for the IPSW
    /// - Parameter reply: Callback with progress (0.0 to 1.0) or -1 if not downloading
    func getIPSWDownloadProgress(
        reply: @escaping (Double) -> Void
    )
}
