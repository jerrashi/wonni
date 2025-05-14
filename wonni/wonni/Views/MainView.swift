//
//  MainView.swift
//  wonni
//
//  Created by Jerry Shi on 3/3/25.
//

import SwiftUI

struct MainView: View {
    // See ModelData.swift for json decoding logic
    @EnvironmentObject var modelData: ModelData
    
    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }

            NavigationStack {
                SearchView()
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }
            // Options to make view full screen
            // (iOS 17+) Hide tab bar when tapping into camera view
            // Use overlay for view
            NavigationStack {
                CameraViewController()
            }
            .tabItem {
                Label("Sell", systemImage: "plus.circle.fill")
            }

            NavigationStack {
                InboxView()
            }
            .tabItem {
                Label("Inbox", systemImage: "tray.fill")
            }

            NavigationStack {
                ProfileView()
            }
            .tabItem {
                Label("Profile", systemImage: "person.crop.circle.fill")
            }
        }
    }
}

#Preview {
    MainView()
}
