//
//  ContentView.swift
//  Hivelink
//

import SwiftUI

struct ContentView: View {
    var body: some View {
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
    }
}

#Preview {
    ContentView()
}
