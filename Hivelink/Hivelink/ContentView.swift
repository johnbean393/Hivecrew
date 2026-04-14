//
//  ContentView.swift
//  Hivelink
//

import HivecrewCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authManager: RemoteAccessAuthManager

    var body: some View {
        TabView {
            NavigationStack {
                Text("Tasks")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Hivelink")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { signOutToolbar }
            }
            .tabItem {
                Label("Tasks", systemImage: "list.bullet")
            }

            NavigationStack {
                Text("Call")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Hivelink")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { signOutToolbar }
            }
            .tabItem {
                Label("Call", systemImage: "phone.fill")
            }

            NavigationStack {
                ClusterStatusView()
                    .navigationTitle("Cluster")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { signOutToolbar }
            }
            .tabItem {
                Label("Cluster", systemImage: "server.rack")
            }

            NavigationStack {
                Text("Settings")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("Hivelink")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { signOutToolbar }
            }
            .tabItem {
                Label("Settings", systemImage: "gear")
            }
        }
    }

    @ToolbarContentBuilder
    private var signOutToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                authManager.logout()
            } label: {
                Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RemoteAccessAuthManager())
        .environmentObject(HivelinkClusterCoordinator())
}
