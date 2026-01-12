//
//  OnboardingView.swift
//  Hivecrew
//
//  First-launch onboarding wizard
//

import SwiftUI
import SwiftData

/// Main onboarding container that guides users through initial setup
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var vmService: VMServiceClient
    
    @Binding var isPresented: Bool
    
    @State private var currentStep: OnboardingStep = .welcome
    @State private var providerConfigured = false
    @State private var templateConfigured = false
    
    enum OnboardingStep: Int, CaseIterable {
        case welcome = 0
        case provider = 1
        case template = 2
        case complete = 3
        
        var title: String {
            switch self {
            case .welcome: return "Welcome"
            case .provider: return "LLM Provider"
            case .template: return "VM Template"
            case .complete: return "Ready"
            }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Progress indicator
            progressIndicator
                .padding(.top, 24)
                .padding(.bottom, 16)
            
            Divider()
            
            // Step content
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            Divider()
            
            // Navigation buttons
            navigationButtons
                .padding(20)
        }
        .frame(width: 600, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    // MARK: - Progress Indicator
    
    private var progressIndicator: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                HStack(spacing: 8) {
                    Circle()
                        .fill(step.rawValue <= currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 10, height: 10)
                    
                    Text(step.title)
                        .font(.caption)
                        .fontWeight(step == currentStep ? .semibold : .regular)
                        .foregroundStyle(step.rawValue <= currentStep.rawValue ? .primary : .secondary)
                    
                    if step != OnboardingStep.allCases.last {
                        Rectangle()
                            .fill(step.rawValue < currentStep.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 30, height: 2)
                    }
                }
            }
        }
    }
    
    // MARK: - Step Content
    
    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            OnboardingWelcomeStep()
            
        case .provider:
            OnboardingProviderStep(isConfigured: $providerConfigured)
            
        case .template:
            OnboardingTemplateStep(isConfigured: $templateConfigured)
            
        case .complete:
            OnboardingCompleteStep()
        }
    }
    
    // MARK: - Navigation
    
    private var navigationButtons: some View {
        HStack {
            if currentStep != .welcome {
                Button("Back") {
                    withAnimation {
                        goBack()
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
            }
            
            Spacer()
            
            if currentStep == .complete {
                Button("Get Started") {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
            } else {
                Button("Continue") {
                    withAnimation {
                        goNext()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)
                .disabled(!canContinue)
            }
        }
    }
    
    private var canContinue: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .provider:
            return providerConfigured
        case .template:
            return templateConfigured
        case .complete:
            return true
        }
    }
    
    private func goNext() {
        guard let nextStep = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = nextStep
    }
    
    private func goBack() {
        guard let prevStep = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prevStep
    }
    
    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        isPresented = false
    }
}

#Preview {
    OnboardingView(isPresented: .constant(true))
        .environmentObject(VMServiceClient.shared)
        .modelContainer(for: LLMProviderRecord.self, inMemory: true)
}
