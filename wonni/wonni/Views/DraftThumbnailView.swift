//
//  DraftThumbnailView.swift
//  wonni
//
//  A draft's photo thumbnail, loaded off the main thread. 2026-09-28: replaces the
//  `if let uiImage = item.thumbnail(for: assetId) { ... } else { PhotoItemView(...) }`
//  pattern — that decoded synchronously inside view bodies (camera photos), or ran a
//  synchronous PhotoKit fetch via `PhotoAsset(identifier:)` on every body pass (library
//  photos), which is what made the draft screens freeze. See Models/Listing.swift's
//  `loadThumbnailAsync` for the full mechanism.
//
//  Handles both photo sources: camera shots decode from the draft's local bytes,
//  library picks load from PhotoKit (they have no local bytes). Every draft-photo
//  call site uses this now.
//

import SwiftUI

struct DraftThumbnailView: View {
    let item: Item
    let assetId: String
    /// Content mode matches every current call site (`.scaledToFill()` inside a clipped
    /// frame) — no callers need `.fit`, so this isn't a param yet.

    /// Tagged with the assetId it belongs to: a view whose identity outlives its photo
    /// (e.g. a row showing `sourceAssetIdentifiers.first` after a reorder) must not keep
    /// showing the previous photo.
    @State private var loaded: (assetId: String, image: UIImage)?
    @State private var failedAssetId: String?

    var body: some View {
        Group {
            if let image = (loaded?.assetId == assetId ? loaded?.image : nil)
                ?? item.cachedThumbnailOnly(for: assetId) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failedAssetId == assetId {
                // No local bytes and no longer in the photo library.
                Color.gray.opacity(0.15)
                    .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            } else {
                Color.gray.opacity(0.15)
                    .overlay(ProgressView().scaleEffect(0.6))
            }
        }
        .task(id: assetId) {
            guard loaded?.assetId != assetId else { return }
            if let image = await item.loadThumbnailAsync(for: assetId) {
                loaded = (assetId, image)
            } else if !Task.isCancelled {
                failedAssetId = assetId
            }
        }
    }
}
