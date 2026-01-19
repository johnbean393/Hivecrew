//
//  VMPlaceholderView.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import SwiftUI

/// Placeholder view shown when VM display is not available
struct VMPlaceholderView: View {
    let icon: String
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(spacing: 16) {
            iconView
            titleView
            subtitleView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var iconView: some View {
        Image(systemName: icon)
            .font(.system(size: 64))
            .foregroundStyle(.secondary)
    }
    
    private var titleView: some View {
        Text(title)
            .font(.title2)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
    }
    
    private var subtitleView: some View {
        Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    VMPlaceholderView(
        icon: "desktopcomputer",
        title: "VM Stopped",
        subtitle: "Start the VM to see its display"
    )
    .background(Color.black)
}
