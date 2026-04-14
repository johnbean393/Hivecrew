//
//  ContentView.swift
//  Hivelink
//

import HivecrewCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authManager: RemoteAccessAuthManager

    var body: some View {
        NavigationStack {
            TabView {
                Text("Tasks")
                    .tabItem {
                        Label("Tasks", systemImage: "list.bullet")
                    }

                Text("Call")
                    .tabItem {
                        Label("Call", systemImage: "phone.fill")
                    }

                Text("Cluster")
                    .tabItem {
                        Label("Cluster", systemImage: "server.rack")
                    }

                Text("Settings")
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .navigationTitle("Hivelink")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        authManager.logout()
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(RemoteAccessAuthManager())
}
