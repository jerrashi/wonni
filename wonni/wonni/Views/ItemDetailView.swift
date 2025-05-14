//
//  ItemDetailView.swift
//  wonni
//
//  Created by Jerry Shi on 3/9/25.
//

import SwiftUI

struct ItemDetailView: View {
    //TODO: Replace with updated data model
    let item: MenuItem
    
    var body: some View {
        Text("Hello, \(item.name)!")
    }
}

/*
#Preview {
    ItemDetailView(modelData.menu[1])
}
*/
