//
//  ShortcutView.swift
//  wonni
//
//  Created by Jerry Shi on 3/9/25.
//

import SwiftUI

struct ShortcutView: View {
    //TODO: Replace with random items with networking logic for suggested items in future
    @EnvironmentObject var modelData: ModelData  // Access model data
    @State private var randomItems: [MenuItem] = []
    
    var body: some View {
        
        //TODO: Is lazy grid or grid better? Lazy grid is older so better for compatibility
        VStack{
            Text("Suggested For You")
                .foregroundColor(.black)
                .padding(.top, 5)
            if randomItems.count == 4 {
                Grid {
                    GridRow (alignment: .center){
                        ForEach(randomItems[0..<2]) { item in
                            ProductTileView(item: item)
                        }
                    }
                    GridRow (alignment: .center){
                        ForEach(randomItems[2..<4]) { item in
                            ProductTileView(item: item)
                        }
                    }
                }
                .padding([.leading, .trailing, .bottom], 5)
            } else {
                ProgressView() // Show a loading indicator while randomItems is being populated
            }
        }
        .background(Color(.white)) // Apply background color
        .onAppear {
            randomItems = modelData.getRandomMenuItems(count: 4) // Initialize randomItems
        }
    }
}

#Preview {
    ShortcutView()
}
