//
//  QuickActionsCarouselView.swift
//  wonni
//
//  Created by Jerry Shi on 3/7/25.
//

import SwiftUI

struct QuickActionsCarouselView: View {
    //TODO: Replace with updated mock data logic -> swift data -> networking
    @EnvironmentObject var modelData: ModelData  // Access model data
    @State private var randomItems: [MenuItem] = []
    
    var body: some View {
        //TODO: Does it make sense to refactor this reuse of a scroll view?
        ScrollView(.horizontal) {
            LazyHStack (spacing: 10){
                //TODO: In future, this will be networking call to find most relevant quick actions / searches
                ForEach(0..<5) { i in
                    ShortcutView()
                        .cornerRadius(15) // Apply corner radius
                }
            }
            //.scrollTargetLayout()
        }
        //.scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .safeAreaPadding(.leading, 20)
        .navigationDestination(for: MenuItem.self) { item in
            ItemDetailView(item: item) // Navigate to the detail view
        }
    }
}

#Preview {
    QuickActionsCarouselView()
}
