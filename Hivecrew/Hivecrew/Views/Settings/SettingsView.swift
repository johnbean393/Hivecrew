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
        case providers = "LLM Providers"
        case environment = "Environment"
        case taskDefaults = "Task Defaults"
        case storage = "Storage"
        case safety = "Safety"
        case developer = "Developer"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .providers: return "brain.head.profile"
            case .environment: return "desktopcomputer"
            case .taskDefaults: return "checklist"
            case .storage: return "folder"
            case .safety: return "shield.lefthalf.filled"
            case .developer: return "hammer"
            }
        }
    }
    
    var body: some View {
        TabView(selection: $selectedTab) {
            providersTab
            environmentTab
            taskDefaultsTab
            storageTab
            safetyTab
            developerTab
        }
        .frame(width: 550, height: 500)
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
    
    private var taskDefaultsTab: some View {
        TaskDefaultsSettingsView()
            .tabItem { Label(SettingsTab.taskDefaults.rawValue, systemImage: SettingsTab.taskDefaults.icon) }
            .tag(SettingsTab.taskDefaults)
    }
    
    private var storageTab: some View {
        StorageSettingsView()
            .tabItem { Label(SettingsTab.storage.rawValue, systemImage: SettingsTab.storage.icon) }
            .tag(SettingsTab.storage)
    }
    
    private var safetyTab: some View {
        SafetySettingsView()
            .tabItem { Label(SettingsTab.safety.rawValue, systemImage: SettingsTab.safety.icon) }
            .tag(SettingsTab.safety)
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
