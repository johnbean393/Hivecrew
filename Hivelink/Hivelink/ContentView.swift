//
//  ContentView.swift
//  Hivelink
//

import HivecrewCore
import SwiftData
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authManager: RemoteAccessAuthManager

    @State private var tabSelection = 0

    var body: some View {
        TabView(selection: $tabSelection) {
            NavigationStack {
                TaskListView(tabSelection: $tabSelection)
                    .toolbar { signOutToolbar }
            }
            .tabItem {
                Label("Tasks", systemImage: "list.bullet")
            }
            .tag(0)

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
            .tag(1)

            NavigationStack {
                ClusterStatusView()
                    .navigationTitle("Cluster")
                    .navigationBarTitleDisplayMode(.large)
                    .toolbar { signOutToolbar }
            }
            .tabItem {
                Label("Cluster", systemImage: "server.rack")
            }
            .tag(2)

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
            .tag(3)
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
        .environmentObject(
            HivelinkTaskService(
                modelContext: ModelContext(try! ModelContainer(for: TaskRecord.self)),
                clusterCoordinator: HivelinkClusterCoordinator()
            )
        )
}
