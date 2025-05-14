//
//  ModelData.swift
//  wonni
//
//  Created by Jerry Shi on 3/7/25.
//

import Foundation
import SwiftUI

class ModelData: ObservableObject{
    //TODO: Replace logic with updated logic once mock data is updated
    @Published var menu: [MenuSection] = []
    @Published var searchText: String = ""
    
    init(){
        loadMenu()
    }
    
    // Function to load menu from json
    private func loadMenu(){
        menu = Bundle.main.decode([MenuSection].self, from: "menu.json")
    }
    
    // Function to get random menu items
    //TODO: Replace with featured listings / random -> swift data -> networking call
    func getRandomMenuItems(count: Int) -> [MenuItem] {
        let allItems = menu.flatMap { $0.items } // Flatten all items into a single array
        let shuffledItems = allItems.shuffled() // Shuffle the items
        return Array(shuffledItems.prefix(count)) // Return the first `count` items
    }
}
