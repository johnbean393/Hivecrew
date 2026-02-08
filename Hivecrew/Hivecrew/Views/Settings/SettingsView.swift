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
        case mcp = "MCP"
        case credentials = "Credentials"
        case api = "Connect"
        case developer = "Developer"
        
        var id: String { rawValue }
        
        var localizedName: String {
            switch self {
            case .providers: return String(localized: "Providers")
            case .environment: return String(localized: "Environment")
            case .tasks: return String(localized: "Tasks")
            case .mcp: return "MCP"
            case .credentials: return String(localized: "Credentials")
            case .api: return String(localized: "Connect")
            case .developer: return String(localized: "Developer")
            }
        }
        
        var icon: String {
            switch self {
            case .providers: return "brain.head.profile"
            case .environment: return "desktopcomputer"
            case .tasks: return "checklist"
            case .mcp: return "puzzlepiece.extension"
            case .credentials: return "key.fill"
            case .api: return "antenna.radiowaves.left.and.right"
            case .developer: return "hammer"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            providersTab
            environmentTab
            tasksTab
            mcpTab
            credentialsTab
            apiTab
            developerTab
        }
        .frame(width: 650, height: 500)
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSettingsTab)) { notification in
            if let tab = notification.object as? SettingsTab {
                selectedTab = tab
            }
        }
    }
    
    // MARK: - Tabs
    
    private var providersTab: some View {
        ProvidersSettingsView()
            .tabItem { Label(SettingsTab.providers.localizedName, systemImage: SettingsTab.providers.icon) }
            .tag(SettingsTab.providers)
    }
    
    private var environmentTab: some View {
        EnvironmentSettingsView()
            .tabItem { Label(SettingsTab.environment.localizedName, systemImage: SettingsTab.environment.icon) }
            .tag(SettingsTab.environment)
    }
    
    private var tasksTab: some View {
        TaskDefaultsSettingsView()
            .tabItem { Label(SettingsTab.tasks.localizedName, systemImage: SettingsTab.tasks.icon) }
            .tag(SettingsTab.tasks)
    }
    
    private var mcpTab: some View {
        MCPSettingsView()
            .tabItem { Label(SettingsTab.mcp.localizedName, systemImage: SettingsTab.mcp.icon) }
            .tag(SettingsTab.mcp)
    }
    
    private var credentialsTab: some View {
        CredentialsSettingsView()
            .tabItem { Label(SettingsTab.credentials.localizedName, systemImage: SettingsTab.credentials.icon) }
            .tag(SettingsTab.credentials)
    }
    
    private var apiTab: some View {
        APISettingsView()
            .tabItem { Label(SettingsTab.api.localizedName, systemImage: SettingsTab.api.icon) }
            .tag(SettingsTab.api)
    }
    
    private var developerTab: some View {
        DeveloperSettingsView()
            .tabItem { Label(SettingsTab.developer.localizedName, systemImage: SettingsTab.developer.icon) }
            .tag(SettingsTab.developer)
    }
}

#Preview {
    SettingsView()
}
