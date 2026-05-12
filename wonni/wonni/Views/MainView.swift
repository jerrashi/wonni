//
//  MainView.swift
//  wonni
//
//  Created by Jerry Shi on 3/3/25.
//

import SwiftUI

struct MainView: View {
    @EnvironmentObject var uploadManager: UploadManager

    var body: some View {
        TabView {
            NavigationStack { HomeView() }
                .tabItem { Label("Home", systemImage: "house.fill") }

            NavigationStack { SearchView() }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }

            NavigationStack { CameraViewController() }
                .tabItem { Label("Sell", systemImage: "plus.circle.fill") }

            NavigationStack { InboxView() }
                .tabItem { Label("Inbox", systemImage: "tray.fill") }

            NavigationStack { ProfileView() }
                .tabItem { Label("Profile", systemImage: "person.crop.circle.fill") }
        }
        .overlay(alignment: .bottom) {
            if uploadManager.isPillVisible {
                UploadPillView()
                    .environmentObject(uploadManager)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: uploadManager.isPillVisible)
    }
}

#Preview {
    MainView()
}
