//
//  StatCard.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import SwiftUI

/// A card displaying a single statistic with icon, value, and title
struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 8) {
            iconRow
            valueRow
            titleRow
        }
        .padding()
        .frame(width: 120)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    private var iconRow: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(color)
            Spacer()
        }
    }
    
    private var valueRow: some View {
        HStack {
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Spacer()
        }
    }
    
    private var titleRow: some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

#Preview {
    HStack {
        StatCard(title: "VMs", value: "3", icon: "desktopcomputer", color: .blue)
        StatCard(title: "Running", value: "1", icon: "play.circle.fill", color: .green)
    }
    .padding()
}
