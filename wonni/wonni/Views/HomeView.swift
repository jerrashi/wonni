//
//  HomeView.swift
//  wonni
//
//  Created by Jerry Shi on 3/10/25.
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                SearchBarView()
                
                Spacer()
                
                VStack(spacing: 16) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("Feed Coming Soon")
                        .font(.headline)
                        .foregroundColor(.gray)
                }
                
                Spacer()
            }
        }
    }
}

#Preview {
    HomeView()
}
