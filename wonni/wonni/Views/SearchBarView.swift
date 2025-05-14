//
//  SearchBarView.swift
//  wonni
//
//  Created by Jerry Shi on 3/7/25.
//

import SwiftUI

struct SearchBarView: View {
    @EnvironmentObject var modelData: ModelData  // Access model data
    @FocusState private var isTextFieldFocused: Bool // Tracks whether the TextField is focused

    var body: some View {
        // TODO: figure out whether it makes sense to put subviews in separate file
        ZStack {
            // Background for the search bar
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
            
            HStack {
                /// We display camera button when not editing, back button when editing
                if isTextFieldFocused {
                    //MARK: Back Button
                    Button(action: {
                        isTextFieldFocused = false  // Dismiss keyboard
                    }) {
                        Image(systemName: "arrow.backward")
                            .padding(10)
                            .foregroundColor(.gray)
                    }
                    .frame(width: 40, height: 40)
                } else {
                    //MARK: Camera Button
                    Button(action: {
                        //TODO: Handle camera action
                    }) {
                        Image(systemName: "camera")
                            .padding(10)
                            .foregroundColor(.gray)
                    }
                    .frame(width: 40, height: 40)
                }
                
                /// Search text field
                TextField("Search...", text: $modelData.searchText)
                    .padding(10)
                    .foregroundColor(.black)
                    .background(Color.clear)  // Transparent background for text field
                    .cornerRadius(8)
                    // When user is inputting to search text field
                    .focused($isTextFieldFocused)
                    
                    // When user submits
                    .onSubmit {
                        //TODO: Handle search logic
                        isTextFieldFocused = false
                    }
                     
                /// We display search Icon when not editing, clear button if editing and there is text present
                if isTextFieldFocused {
                    if !modelData.searchText.isEmpty{
                        // MARK: Clear button
                        Button(action: {
                            modelData.searchText = ""  // Clear text
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .padding(10)
                                .foregroundColor(.gray)
                        }
                        .frame(width: 40, height: 40)
                    }
                }
                else {
                    //MARK: Search Icon
                    Image(systemName: "magnifyingglass")
                        .padding(10)
                        .foregroundColor(.gray)
                        .frame(width: 40, height: 40)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.horizontal)
        .frame(height: 40)  // Set a fixed height for the search bar
    }
}

#Preview {
    SearchBarView()
}
