//
//  ProductTileView.swift
//  wonni
//
//  Created by Jerry Shi on 3/9/25.
//

import SwiftUI

struct ProductTileView: View {
    //TODO: Update to new logic for updated mock data
    let item: MenuItem

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading){
                Image(item.mainImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100) // Set a fixed height for the image
                    .clipped() // Clip the image to the frame
                    .cornerRadius(10) // Round the corners of the image
                Text("\(item.name)")
                    .foregroundColor(.black)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 100, alignment: .leading) // Set a fixed width
                    .lineLimit(1) // Truncate with an ellipsis if the text is too long
                Text("$\(item.price)")
                    .foregroundColor(.black)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 100, alignment: .leading) // Set a fixed width
                    .lineLimit(1) // Truncate with an ellipsis if the text is too long
            }
        }
    }
}

/*
#Preview {
    ProductTileView()
}
*/
