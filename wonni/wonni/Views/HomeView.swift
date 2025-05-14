//
//  HomeView.swift
//  wonni
//
//  Created by Jerry Shi on 3/10/25.
//

import SwiftUI

struct HomeView: View {
    // See ModelData.swift for json decoding logic
    @EnvironmentObject var modelData: ModelData
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 10) {
                SearchBarView()
                
                ScrollView {
                    VStack(spacing: 15) {
                        FeaturedCarouselView()
                        QuickActionsCarouselView()
                        FeedView()
                    }
                    .padding(.horizontal)
                }
            }
        }
    }
}

#Preview {
    HomeView()
}
