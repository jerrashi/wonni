//
//  DraftThumbnailView.swift
//  wonni
//
//  A draft's own local photo, decoded off the main thread. 2026-09-28: replaces the
//  `if let uiImage = item.thumbnail(for: assetId) { ... } else { PhotoItemView(...) }`
//  pattern at the two highest-traffic call sites (DraftHistoryView, ActiveDraftCarouselView)
//  — those rendered several of these per row, synchronously, every time the row appeared,
//  which is what made opening the draft drawer freeze (and, held long enough, get the app
//  killed by the watchdog — reported as a crash). See Models/Listing.swift's
//  `loadThumbnailAsync` for the full mechanism.
//
//  The other synchronous `item.thumbnail(for:)` call sites (CreateListingView,
//  ProcessProgressView, DraftPhotoEditModal) are unmigrated follow-up — same fix applies,
//  lower traffic than the two done here.
//

import SwiftUI

struct DraftThumbnailView: View {
    let item: Item
    let assetId: String
    /// Content mode matches every current call site (`.scaledToFill()` inside a clipped
    /// frame) — no callers need `.fit`, so this isn't a param yet.

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image ?? item.cachedThumbnailOnly(for: assetId) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.15)
                    .overlay(ProgressView().scaleEffect(0.6))
            }
        }
        // id: assetId — a reused view (e.g. scrolled cell) loading a different photo
        // restarts the task instead of showing the previous photo's stale @State image.
        .task(id: assetId) {
            guard image == nil else { return }
            image = await item.loadThumbnailAsync(for: assetId)
        }
    }
}
