//
//  SettingsView.swift
//  Hivecrew
//
//  Created by Hivecrew on 1/10/26.
//

import SwiftUI

/// Settings window - Configuration for LLM providers, VM defaults, and app settings
/// Accessible via Cmd+, or menu bar
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .providers
    
    enum SettingsTab: String, CaseIterable, Identifiable {
        case providers = "Providers"
        case environment = "Environment"
        case tasks = "Tasks"
        case credentials = "Credentials"
        case api = "API"
        case developer = "Developer"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .providers: return "brain.head.profile"
            case .environment: return "desktopcomputer"
            case .tasks: return "checklist"
            case .credentials: return "key.fill"
            case .api: return "network"
            case .developer: return "hammer"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            providersTab
            environmentTab
            tasksTab
            credentialsTab
            apiTab
            developerTab
        }
        .frame(width: 650, height: 500)
    }
    
    // MARK: - Tabs
    
    private var providersTab: some View {
        ProvidersSettingsView()
            .tabItem { Label(SettingsTab.providers.rawValue, systemImage: SettingsTab.providers.icon) }
            .tag(SettingsTab.providers)
    }
    
    private var environmentTab: some View {
        EnvironmentSettingsView()
            .tabItem { Label(SettingsTab.environment.rawValue, systemImage: SettingsTab.environment.icon) }
            .tag(SettingsTab.environment)
    }
    
    private var tasksTab: some View {
        TaskDefaultsSettingsView()
            .tabItem { Label(SettingsTab.tasks.rawValue, systemImage: SettingsTab.tasks.icon) }
            .tag(SettingsTab.tasks)
    }
    
    private var credentialsTab: some View {
        CredentialsSettingsView()
            .tabItem { Label(SettingsTab.credentials.rawValue, systemImage: SettingsTab.credentials.icon) }
            .tag(SettingsTab.credentials)
    }
    
    private var apiTab: some View {
        APISettingsView()
            .tabItem { Label(SettingsTab.api.rawValue, systemImage: SettingsTab.api.icon) }
            .tag(SettingsTab.api)
    }
    
    private var developerTab: some View {
        DeveloperSettingsView()
            .tabItem { Label(SettingsTab.developer.rawValue, systemImage: SettingsTab.developer.icon) }
            .tag(SettingsTab.developer)
    }
}

#Preview {
    SettingsView()
}
