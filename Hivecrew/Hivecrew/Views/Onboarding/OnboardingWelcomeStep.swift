//
//  OnboardingWelcomeStep.swift
//  Hivecrew
//
//  Welcome step of the onboarding wizard
//

import SwiftUI

/// Welcome screen explaining Hivecrew's purpose
struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // App icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 100, height: 100)
                .shadow(color: .black.opacity(0.1), radius: 10)
            
            // Title
            VStack(spacing: 8) {
                Text("Welcome to Hivecrew")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("AI agents running in isolated macOS virtual machines")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            
            // Features
            VStack(alignment: .leading, spacing: 16) {
                FeatureRow(
                    icon: "brain.head.profile",
                    title: "Dispatch Tasks",
                    description: "Describe what you need done and let AI agents work autonomously"
                )
                
                FeatureRow(
                    icon: "desktopcomputer",
                    title: "Isolated Environments",
                    description: "Each agent runs in its own secure macOS virtual machine"
                )
                
                FeatureRow(
                    icon: "eye",
                    title: "Watch & Intervene",
                    description: "Monitor agents in real-time and step in when needed"
                )
                
                FeatureRow(
                    icon: "shield.lefthalf.filled",
                    title: "Safe by Default",
                    description: "Timeouts, permissions, and easy kill switch for peace of mind"
                )
            }
            .padding(.horizontal, 40)
            
            Spacer()
            
            Text("Let's get you set up in just a few steps.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .padding()
    }
}

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    OnboardingWelcomeStep()
        .frame(width: 600, height: 450)
}
