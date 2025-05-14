//
//  FeaturedCarouselView.swift
//  wonni
//
//  Created by Jerry Shi on 3/7/25.
//

import SwiftUI

struct FeaturedCarouselView: View {
    //TODO: Replace with updated mock data logic -> swift data -> networking
    @EnvironmentObject var modelData: ModelData  // Access model data
    @State private var randomItems: [MenuItem] = []
    
    var body: some View {
        //TODO: Fill up whole screen at least width-wise
        //TODO: Learn more about how to configure scrollView
        //TODO: Use relative sizing so UI looks good across a variety of devices
        ScrollView(.horizontal) {
            LazyHStack (spacing: 10){
                /*
                 ForEach(0..<10) { i in
                 RoundedRectangle(cornerRadius: 25)
                 .fill(Color(hue: Double(i) / 10, saturation: 1, brightness: 1).gradient)
                 .frame(width: 300, height: 200)
                 }
                 */
                ForEach(modelData.getRandomMenuItems(count: 6)) { item in
                    NavigationLink(value: item) {
                        Image(item.mainImage)
                            .frame(width: 290, height: 200)
                            .scaledToFill()
                            .clipShape(RoundedRectangle(cornerRadius: 25))
                    }
                }
            }
            .navigationDestination(for: MenuItem.self) { item in
                //TODO: figure out how to link to a featured view (search results view with custom view on top? TBD)
                ItemDetailView(item: item) // Navigate to the detail view
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
        .safeAreaPadding(.leading, 20)
    }
}

#Preview {
    FeaturedCarouselView()
}
