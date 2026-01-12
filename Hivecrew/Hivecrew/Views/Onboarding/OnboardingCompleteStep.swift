//
//  OnboardingCompleteStep.swift
//  Hivecrew
//
//  Completion step of the onboarding wizard
//

import SwiftUI

/// Success confirmation step
struct OnboardingCompleteStep: View {
    var body: some View {
        VStack(spacing: 32) {
            Spacer()
            
            // Success icon
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 120, height: 120)
                
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
            }
            
            // Title
            VStack(spacing: 8) {
                Text("You're All Set!")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Hivecrew is ready to run AI agents for you")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            
            // Quick tips
            VStack(alignment: .leading, spacing: 12) {
                QuickTip(
                    number: 1,
                    text: "Go to the Dashboard to create your first task"
                )
                QuickTip(
                    number: 2,
                    text: "Watch agents work in the Environments tab"
                )
                QuickTip(
                    number: 3,
                    text: "Adjust settings anytime with Cmd+,"
                )
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 20)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(12)
            
            Spacer()
            
            Text("Click \"Get Started\" to begin using Hivecrew")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .padding()
    }
}

// MARK: - Quick Tip

private struct QuickTip: View {
    let number: Int
    let text: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor)
                .clipShape(Circle())
            
            Text(text)
                .font(.callout)
        }
    }
}

#Preview {
    OnboardingCompleteStep()
        .frame(width: 600, height: 450)
}
