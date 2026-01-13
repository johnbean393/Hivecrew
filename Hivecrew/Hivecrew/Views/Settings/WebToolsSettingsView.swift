//
//  WebToolsSettingsView.swift
//  Hivecrew
//
//  Settings for web tools (search engine, etc.)
//

import SwiftUI

/// Web tools settings tab
struct WebToolsSettingsView: View {
    @AppStorage("searchEngine") private var searchEngine: String = "google"
    @AppStorage("defaultResultCount") private var defaultResultCount: Int = 10
    
    var body: some View {
        Form {
            searchEngineSection
            searchOptionsSection
        }
        .formStyle(.grouped)
        .padding()
    }
    
    // MARK: - Sections
    
    private var searchEngineSection: some View {
        Section("Search Engine") {
            Picker("Search Provider", selection: $searchEngine) {
                Label {
                    Text("Google")
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
                .tag("google")
                
                Label {
                    Text("DuckDuckGo")
                } icon: {
                    Image(systemName: "shield")
                }
                .tag("duckduckgo")
            }
            .pickerStyle(.inline)
            
            Text("Choose which search engine to use for the web_search tool. Google provides comprehensive results, while DuckDuckGo offers privacy-focused searching.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }
    
    private var searchOptionsSection: some View {
        Section("Search Options") {
            HStack {
                Text("Default Result Count")
                Spacer()
                TextField("", value: $defaultResultCount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("results")
                    .foregroundStyle(.secondary)
            }
            
            Text("Default number of search results to return when not specified (1-20).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    WebToolsSettingsView()
}
