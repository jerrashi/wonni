//
//  FeedView.swift
//  wonni
//
//  Created by Jerry Shi on 3/7/25.
//

import SwiftUI

struct FeedView: View {
    //TODO: Investigate if there is better way to simulatae collection view in swift UI
    @EnvironmentObject var modelData: ModelData  // Access model data

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))]) {
                //TODO: Update with different mock data and replace with networking call in future
                ForEach(modelData.menu) { section in
                    Section(header: Text(section.name)
                        .foregroundColor(.black)
                    )
                        {
                        ForEach(section.items){ item in
                            ProductTileView(item: item)
                        }
                    }
                }
            }
            .background(Color.white) // Set the background color of the ScrollView
            .cornerRadius(15) // Apply corner radius to the ScrollView
        }
        .navigationDestination(for: MenuItem.self) { item in
            ItemDetailView(item: item) // Navigate to the detail view
        }
    }
}

#Preview {
    FeedView()
}
