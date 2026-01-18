//
//  AppVMRuntime.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/11/26.
//

import Foundation
import Virtualization
import HivecrewShared
import Combine

/// Manages running VMs in the app process for display purposes
/// VZVirtualMachine must be in the same process as VZVirtualMachineView
@MainActor
class AppVMRuntime: ObservableObject {
    static let shared = AppVMRuntime()
    
    @Published private(set) var runningVMs: [String: VZVirtualMachine] = [:]
    @Published private(set) var vmDelegates: [String: VMDelegate] = [:]
    
    private init() {}
    
    // MARK: - VM Lifecycle
    
    func startVM(id vmId: String) async throws {
        // Check if already running
        if runningVMs[vmId] != nil {
            print("AppVMRuntime: VM \(vmId) is already running")
            return
        }
        
        // Load VM configuration from bundle
        let bundlePath = AppPaths.vmBundlePath(id: vmId)
        let config = try await loadVMConfiguration(from: bundlePath)
        
        // Create VM on main thread
        let vm = VZVirtualMachine(configuration: config)
        let delegate = VMDelegate(vmId: vmId) { [weak self] stoppedVmId in
            Task { @MainActor in
                self?.handleVMStopped(id: stoppedVmId)
            }
        }
        vm.delegate = delegate
        
        runningVMs[vmId] = vm
        vmDelegates[vmId] = delegate
        
        // Start the VM
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success:
                    print("AppVMRuntime: VM \(vmId) started successfully")
                    continuation.resume()
                case .failure(let error):
                    print("AppVMRuntime: VM \(vmId) failed to start: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func stopVM(id vmId: String, force: Bool = false) async throws {
        guard let vm = runningVMs[vmId] else {
            print("AppVMRuntime: VM \(vmId) not found")
            return
        }
        
        if force {
            // Force stop - actually stop the VM, not just remove from tracking
            if vm.canStop {
                do {
                    try await vm.stop()
                    print("AppVMRuntime: VM \(vmId) force stopped via vm.stop()")
                } catch {
                    print("AppVMRuntime: VM \(vmId) vm.stop() failed: \(error), trying requestStop")
                    if vm.canRequestStop {
                        try vm.requestStop()
                    }
                }
            } else if vm.canRequestStop {
                try vm.requestStop()
                print("AppVMRuntime: VM \(vmId) stop requested (canStop was false)")
            }
            
            // Wait a bit for the VM to actually stop
            try? await Task.sleep(nanoseconds: 500_000_000)
            
            runningVMs.removeValue(forKey: vmId)
            vmDelegates.removeValue(forKey: vmId)
            print("AppVMRuntime: VM \(vmId) force stopped and removed from tracking")
            return
        }
        
        // Graceful stop
        if !vm.canRequestStop {
            print("AppVMRuntime: VM \(vmId) cannot request stop, forcing")
            if vm.canStop {
                try await vm.stop()
            }
            runningVMs.removeValue(forKey: vmId)
            vmDelegates.removeValue(forKey: vmId)
            return
        }
        
        try vm.requestStop()
        
        // Wait for VM to stop
        try await Task.sleep(nanoseconds: 1_000_000_000)
        
        runningVMs.removeValue(forKey: vmId)
        vmDelegates.removeValue(forKey: vmId)
        print("AppVMRuntime: VM \(vmId) stopped gracefully")
    }
    
    func getVM(id vmId: String) -> VZVirtualMachine? {
        return runningVMs[vmId]
    }
    
    /// Called when a VM stops (either from guest shutdown or error)
    private func handleVMStopped(id vmId: String) {
        runningVMs.removeValue(forKey: vmId)
        vmDelegates.removeValue(forKey: vmId)
        print("AppVMRuntime: VM \(vmId) removed from running VMs (guest stopped)")
    }
    
    // MARK: - Configuration Loading
    
    private func loadVMConfiguration(from bundlePath: URL) async throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        
        // Load instance config
        let configPath = bundlePath.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configPath)
        
        // Try multiple date decoding strategies:
        // - VMs from templates use ISO8601 string format
        // - Some VMs may use timestamp (Double) format
        let instanceConfig: VMInstanceConfig
        
        // First try ISO8601 (used by template-created VMs)
        let iso8601Decoder = JSONDecoder()
        iso8601Decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? iso8601Decoder.decode(VMInstanceConfig.self, from: configData) {
            instanceConfig = decoded
        } else {
            // Fall back to default (timestamp) decoding
            instanceConfig = try JSONDecoder().decode(VMInstanceConfig.self, from: configData)
        }
        
        // CPU and Memory
        config.cpuCount = instanceConfig.cpuCount
        config.memorySize = instanceConfig.memorySize
        
        // Platform configuration
        let platform = VZMacPlatformConfiguration()
        
        // Machine identifier
        let machineIdPath = bundlePath.appendingPathComponent("MachineIdentifier.bin")
        let machineIdData = try Data(contentsOf: machineIdPath)
        guard let machineId = VZMacMachineIdentifier(dataRepresentation: machineIdData) else {
            throw VMRuntimeError.invalidConfiguration("Invalid machine identifier")
        }
        platform.machineIdentifier = machineId
        
        // Load hardware model (required - must exist in VM bundle)
        let hardwareModelPath = bundlePath.appendingPathComponent("HardwareModel.bin")
        guard FileManager.default.fileExists(atPath: hardwareModelPath.path) else {
            throw VMRuntimeError.invalidConfiguration("Hardware model file not found")
        }
        let hardwareModelData = try Data(contentsOf: hardwareModelPath)
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareModelData) else {
            throw VMRuntimeError.invalidConfiguration("Invalid hardware model data")
        }
        platform.hardwareModel = hardwareModel
        
        // Auxiliary storage - create if missing
        let auxPath = bundlePath.appendingPathComponent("auxiliary")
        if FileManager.default.fileExists(atPath: auxPath.path) {
            platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: auxPath)
        } else {
            // Create new auxiliary storage using the hardware model
            print("AppVMRuntime: Creating missing auxiliary storage for VM")
            platform.auxiliaryStorage = try VZMacAuxiliaryStorage(
                creatingStorageAt: auxPath,
                hardwareModel: hardwareModel,
                options: []
            )
        }
        
        config.platform = platform
        
        // Boot loader
        config.bootLoader = VZMacOSBootLoader()
        
        // Graphics
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 144)
        ]
        config.graphicsDevices = [graphics]
        
        // Disk
        let diskPath = bundlePath.appendingPathComponent("disk.img")
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskPath, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)]
        
        // Network (NAT with persistent MAC address)
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        
        // Load or generate a persistent MAC address for this VM
        let macAddressPath = bundlePath.appendingPathComponent("MACAddress.txt")
        if let macString = try? String(contentsOf: macAddressPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let macAddress = VZMACAddress(string: macString) {
            network.macAddress = macAddress
        } else {
            // Generate and save a new MAC address
            let newMac = VZMACAddress.randomLocallyAdministered()
            network.macAddress = newMac
            try? newMac.string.write(to: macAddressPath, atomically: true, encoding: .utf8)
        }
        
        config.networkDevices = [network]
        
        // Audio
        let audio = VZVirtioSoundDeviceConfiguration()
        let audioInput = VZVirtioSoundDeviceInputStreamConfiguration()
        audioInput.source = VZHostAudioInputStreamSource()
        let audioOutput = VZVirtioSoundDeviceOutputStreamConfiguration()
        audioOutput.sink = VZHostAudioOutputStreamSink()
        audio.streams = [audioInput, audioOutput]
        config.audioDevices = [audio]
        
        // Keyboard and pointing device
        config.keyboards = [VZUSBKeyboardConfiguration()]
        config.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        
        // Vsock device for host-guest communication
        let vsock = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [vsock]
        
        // VirtioFS shared folder
        let sharedFolderURL = bundlePath.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedFolderURL, withIntermediateDirectories: true)
        let sharedDir = VZSharedDirectory(url: sharedFolderURL, readOnly: false)
        let share = VZSingleDirectoryShare(directory: sharedDir)
        let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "shared")
        fsConfig.share = share
        config.directorySharingDevices = [fsConfig]
        
        // Validate
        try config.validate()
        
        return config
    }
    
}

// MARK: - VM Instance Config (matches XPC service)

private struct VMInstanceConfig: Codable {
    let id: String
    var name: String
    var cpuCount: Int
    var memorySize: UInt64
    var diskSize: UInt64
    let createdAt: Date
    var lastUsedAt: Date?
}

// MARK: - VM Delegate

class VMDelegate: NSObject, VZVirtualMachineDelegate {
    let vmId: String
    private let onStopped: (String) -> Void
    
    init(vmId: String, onStopped: @escaping (String) -> Void) {
        self.vmId = vmId
        self.onStopped = onStopped
    }
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        print("VMDelegate: VM \(vmId) stopped with error: \(error)")
        onStopped(vmId)
    }
    
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("VMDelegate: VM \(vmId) guest did stop")
        onStopped(vmId)
    }
}

// MARK: - Errors

enum VMRuntimeError: LocalizedError {
    case invalidConfiguration(String)
    case vmNotFound
    
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason):
            return "Invalid VM configuration: \(reason)"
        case .vmNotFound:
            return "VM not found"
        }
    }
}
