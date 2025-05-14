//
//  CreateListingView.swift
//  wonni
//
//  Created by Jerry Shi on 3/10/25.
//

import SwiftUI

struct CreateListingView: View {
    @State private var isCameraPresented = false
    @State private var capturedImage: UIImage?

    var body: some View {
        VStack {
            if let image = capturedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 300)
            } else {
                Button("Take Photo") {
                    isCameraPresented = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .sheet(isPresented: $isCameraPresented) {
            CameraView()
        }
    }
}

#Preview {
    CreateListingView()
}
