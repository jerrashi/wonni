/*
See the License.txt file for this sample’s licensing information.
*/

import SwiftUI
import Photos

struct PhotoItemView: View {
    var asset: PhotoAsset
    var cache: CachedImageManager?
    var imageSize: CGSize
    
    @State private var image: Image?
    @State private var imageRequestID: PHImageRequestID?

    var body: some View {
        
        Group {
            if let image = image {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .scaleEffect(0.5)
            }
        }
        .task {
            guard image == nil, let cache = cache else { return }
            imageRequestID = await cache.requestImage(for: asset, targetSize: imageSize) { result in
                Task {
                    if let result = result {
                        self.image = result.image
                    }
                }
            }
        }
    }
}

struct DraftStackThumbnailView: View {
    let draft: Item
    let cache: CachedImageManager?
    
    var body: some View {
        let count = draft.sourceAssetIdentifiers.count
        ZStack(alignment: .bottomTrailing) {
            if count == 0 {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 66, height: 66)
                    .overlay(
                        Image(systemName: "photo")
                            .foregroundColor(.secondary)
                    )
            } else {
                ForEach(0..<min(3, count), id: \.self) { index in
                    let assetId = draft.sourceAssetIdentifiers[index]
                    let zIndexVal = Double(3 - index)
                    let offsetVal = CGFloat(index) * 6
                    
                    Group {
                        if let uiImage = draft.image(for: assetId) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFill()
                        } else {
                            PhotoItemView(
                                asset: PhotoAsset(identifier: assetId),
                                cache: cache,
                                imageSize: CGSize(width: 120, height: 120)
                            )
                        }
                    }
                    .frame(width: 66, height: 66)
                    .cornerRadius(10)
                    .clipped()
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 3, x: 2, y: 2)
                    .offset(x: offsetVal, y: -offsetVal)
                    .zIndex(zIndexVal)
                }
            }
        }
        .frame(width: 82, height: 82)
    }
}
