//
//  VMDisplayView.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import SwiftUI
import Virtualization

/// NSViewRepresentable wrapper for VZVirtualMachineView
struct VMDisplayView: NSViewRepresentable {
    let vmId: String
    @ObservedObject var vmRuntime: AppVMRuntime
    
    init(vmId: String, vmRuntime: AppVMRuntime = .shared) {
        self.vmId = vmId
        self.vmRuntime = vmRuntime
    }
    
    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.capturesSystemKeys = true
        
        // Attach VM if available
        if let vm = vmRuntime.getVM(id: vmId) {
            view.virtualMachine = vm
        }
        
        return view
    }
    
    func updateNSView(_ nsView: VZVirtualMachineView, context: Context) {
        // Update VM attachment when it changes
        if let vm = vmRuntime.getVM(id: vmId) {
            if nsView.virtualMachine !== vm {
                nsView.virtualMachine = vm
            }
        } else {
            nsView.virtualMachine = nil
        }
    }
}

#Preview {
    VMDisplayView(vmId: "test")
        .frame(width: 800, height: 600)
}
