//
//  SearchView.swift
//  wonni
//
//  Created by Jerry Shi on 3/10/25.
//

import SwiftUI

struct SearchView: View {
    @EnvironmentObject var modelData: ModelData  // Access model data

    var body: some View {
        SearchBarView()
        Spacer()
    }
}

#Preview {
    SearchView()
}
